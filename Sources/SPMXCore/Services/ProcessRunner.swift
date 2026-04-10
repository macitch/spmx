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
/// Each call is dispatched onto a detached task so the synchronous `waitUntilExit()` doesn't
/// block one of the cooperative pool's threads. That matters when `VersionFetcher` runs eight
/// of these concurrently inside a `TaskGroup`.
///
/// Inherits the parent environment with one critical override: `GIT_TERMINAL_PROMPT=0`. Without
/// this, an SSH-keyed pin to a private repo without credentials available would cause `git
/// ls-remote` to *prompt* for a password, which from a non-interactive subprocess hangs forever.
/// With the flag set, git fails fast and we surface a clean `.fetchFailed` row instead of
/// burning a `TaskGroup` slot indefinitely.
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
        let exec = executable
        let args = arguments
        let timeoutSeconds = timeout

        return try await Task.detached(priority: .userInitiated) { () throws -> ProcessResult in
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

            try process.run()

            // Set up a timer to kill the process if it exceeds the timeout.
            // We capture the PID (a plain Int32, which is Sendable) and use an
            // OSAtomicFlag to communicate between the timer and the main thread.
            let pid = process.processIdentifier
            let didTimeout = DidTimeout()
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

            process.waitUntilExit()
            timer?.cancel()

            if didTimeout.value, let seconds = timeoutSeconds {
                throw ProcessTimedOut(timeout: seconds)
            }

            let outData = ((try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
            let errData = ((try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
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