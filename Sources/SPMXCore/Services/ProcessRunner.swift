/*
 *  File: ProcessRunner.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Captured output from a single subprocess execution.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstraction over running a child process.
///
/// Exists so unit tests can stub out `git ls-remote` (and any future shell-outs) without
/// touching the network or the local filesystem. Production code uses `SystemProcessRunner`.
public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult
}

/// Error thrown when a subprocess exceeds its configured timeout.
public struct ProcessTimedOut: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let timeout: TimeInterval
    public var description: String {
        "Process timed out after \(Int(timeout)) seconds."
    }
    public var errorDescription: String? { description }
}

/// Real `ProcessRunning` backed by `Foundation.Process`.
///
/// Completion uses Process's termination callback; blocking pipe reads run on Dispatch
/// queues. Both output streams are drained while the child runs, so full pipe buffers
/// cannot prevent it from exiting.
///
/// Inherits the parent environment with one critical override: `GIT_TERMINAL_PROMPT=0`. Without
/// this, an SSH-keyed pin to a private repo without credentials available would cause `git
/// ls-remote` to *prompt* for a password, which from a non-interactive subprocess hangs forever.
/// With the flag set, git fails fast and we surface a clean `.fetchFailed` row instead of
/// burning a `TaskGroup` slot indefinitely.
///
/// ## Cancellation
///
/// On parent-task cancellation, the handler sends `SIGTERM` to the subprocess.
/// After termination and pipe drainage, `run` throws `CancellationError`.
///
/// ## Timeout
///
/// A configurable timeout (default 30 seconds) kills the subprocess with `SIGTERM` if it
/// hasn't exited within the limit. This prevents a hung `git clone` or `git ls-remote`
/// from blocking `spmx` indefinitely. The timeout applies per-invocation — eight concurrent
/// `ls-remote` calls each get their own 30-second window.
public struct SystemProcessRunner: ProcessRunning {
    /// Timeout per subprocess invocation. `nil` means no timeout.
    private let timeout: TimeInterval?

    public init(timeout: TimeInterval? = 30) {
        self.timeout = timeout
    }

    public func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        // Bail before even launching if the parent task is already cancelled.
        try Task.checkCancellation()

        let exec = executable
        let args = arguments
        let timeoutSeconds = timeout

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let completion = ProcessCompletion()
        process.terminationHandler = { _ in completion.finish() }
        try process.run()

        let pid = process.processIdentifier
        let didTimeout = DidTimeout()

        // Timeout watchdog: SIGTERM the process if it overruns its budget. The
        // timer is cancelled in the cleanup path below regardless of how the
        // wait completes (normal exit, timeout, or cancellation).
        var timer: DispatchSourceTimer?
        if let seconds = timeoutSeconds {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + seconds)
            t.setEventHandler { [didTimeout] in
                didTimeout.set()
                kill(pid, SIGTERM)
            }
            t.resume()
            timer = t
        }

        let box = ProcessIOBox(stdout: stdoutPipe, stderr: stderrPipe)

        let (outData, errData) = await withTaskCancellationHandler {
            async let stdout = box.readOutput(standardError: false)
            async let stderr = box.readOutput(standardError: true)
            await completion.wait()
            return await (stdout, stderr)
        } onCancel: {
            // Foundation makes no guarantees about safe Process access from
            // arbitrary threads, but `kill(2)` on a captured pid is signal-safe
            // and that's all this needs.
            kill(pid, SIGTERM)
        }

        timer?.cancel()

        // Order matters: a cancellation that races with a timeout should surface
        // as cancellation (the user's intent), not as a spurious timeout.
        if Task.isCancelled {
            throw CancellationError()
        }
        if didTimeout.value, let seconds = timeoutSeconds {
            throw ProcessTimedOut(timeout: seconds)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

/// Each pipe has exactly one reader. The references are immutable; output crosses
/// queues as Data. Process status is read only after the termination callback.
private final class ProcessIOBox: @unchecked Sendable {
    let stdout: Pipe
    let stderr: Pipe
    init(stdout: Pipe, stderr: Pipe) {
        self.stdout = stdout
        self.stderr = stderr
    }

    func readOutput(standardError: Bool) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let handle = (standardError ? stderr : stdout).fileHandleForReading
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}

/// The process can exit before the async caller starts waiting. Retain that event
/// under a lock so either ordering resumes the continuation exactly once.
private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

// MARK: - Thread-safe flag

/// A simple thread-safe boolean flag backed by `os_unfair_lock`. Used to communicate
/// between the timeout timer (GCD queue) and the main process-wait thread without
/// triggering Swift 6 Sendable data-race warnings.
private final class DidTimeout: @unchecked Sendable {
    private var _value = false
    private var _lock = os_unfair_lock()

    var value: Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _value
    }

    func set() {
        os_unfair_lock_lock(&_lock)
        _value = true
        os_unfair_lock_unlock(&_lock)
    }
}
