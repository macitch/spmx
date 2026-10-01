/*
 *  File: ProcessRunner.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Darwin
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

/// Abstraction over running a child process, allowing callers to inject test doubles.
public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult
}

/// Error thrown when a subprocess exceeds its configured timeout.
public struct ProcessTimedOut: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let timeout: TimeInterval
    public var description: String {
        "Process timed out after \(timeout.formatted()) seconds."
    }
    public var errorDescription: String? { description }
}

/// The direct child exited, but an inherited output pipe did not reach EOF in time.
/// Reporting an error avoids returning truncated output as a successful result.
public struct ProcessOutputTimedOut: Error, LocalizedError, CustomStringConvertible, Sendable {
    public var description: String {
        "Process exited, but its output pipes remained open for more than 1 second. Output may be incomplete."
    }
    public var errorDescription: String? { description }
}

/// Runs each invocation in its own process group, inheriting the environment with
/// `GIT_TERMINAL_PROMPT=0` to prevent interactive Git credential prompts.
///
/// A Dispatch worker drains both pipes using nonblocking reads and polls child status.
/// No blocking pipe read or structured child task can keep the async caller waiting.
/// Cancellation and timeout send SIGTERM to the group, then SIGKILL after one second.
/// Pipe drainage after SIGKILL is limited to 250 ms. After a normal child exit, inherited
/// pipes have one second to close before the same shutdown policy runs and throws
/// `ProcessOutputTimedOut`, even when the execution timeout is disabled.
///
/// Descendants that deliberately leave the process group cannot be signalled through
/// it, but their inherited pipes still cannot prevent `run` from returning.
public struct SystemProcessRunner: ProcessRunning {
    /// Metadata lookups use 30 seconds; resolution can fetch large dependency graphs.
    public static let dependencyResolutionTimeout: TimeInterval = 10 * 60

    private let timeout: TimeInterval?

    /// - Parameter timeout: Execution budget in seconds. `nil` disables the execution
    ///   deadline; cancellation and output-drain deadlines remain active.
    public init(timeout: TimeInterval? = 30) {
        precondition(timeout.map { $0.isFinite && $0 >= 0 } ?? true, "timeout must be finite and nonnegative")
        self.timeout = timeout
    }

    public func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        try Task.checkCancellation()
        let cancellation = ProcessCancellation()
        let result: Result<ProcessResult, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result {
                        try execute(executable, arguments: arguments, cancellation: cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        // User cancellation wins if it races with timeout or normal completion.
        try Task.checkCancellation()
        return try result.get()
    }

    private func execute(
        _ executable: String, arguments: [String], cancellation: ProcessCancellation
    ) throws -> ProcessResult {
        if cancellation.isCancelled { throw CancellationError() }
        let stdout = try ProcessPipe()
        let stderr = try ProcessPipe()
        let pid = try spawn(executable, arguments: arguments, stdout: stdout, stderr: stderr)
        stdout.closeWriter()
        stderr.closeWriter()

        // All signals and status checks are owned by this worker. Keep the child
        // waitable until the last signal, so its PID/group ID cannot be reused.
        var childExit: Int32?
        defer {
            if childExit != nil {
                reap(pid)
            } else {
                // Even a kernel-stalled child must not extend the caller's deadline.
                // Reap it once SIGKILL can take effect, without retaining pipes.
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                DispatchQueue.global(qos: .utility).async { reap(pid) }
            }
        }

        let clock = ContinuousClock()
        let executionDeadline = timeout.map { clock.now + .seconds($0) }
        var outputDeadline: ContinuousClock.Instant?
        var forceKillDeadline: ContinuousClock.Instant?
        var drainDeadline: ContinuousClock.Instant?
        var failure: (any Error)?
        var buffer = [UInt8](repeating: 0, count: 65_536)

        func signalGroup(_ signal: Int32) {
            kill(-pid, signal)
            // Also cover a leader that moved to a different process group, without
            // delivering the same signal twice to the ordinary group leader.
            if childExit == nil, getpgid(pid) != pid { kill(pid, signal) }
        }

        func beginShutdown(_ error: any Error, at now: ContinuousClock.Instant) {
            guard failure == nil else { return }
            failure = error
            signalGroup(SIGTERM)
            forceKillDeadline = now + .seconds(1)
        }

        while true {
            let now = clock.now
            if childExit == nil {
                var info = siginfo_t()
                let status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if status == 0, info.si_pid == pid {
                    childExit = info.si_status
                    outputDeadline = now + .seconds(1)
                } else if status != 0, errno != EINTR {
                    // Avoid signalling a stale PID if another waiter took the child.
                    if errno == ECHILD { childExit = -1 }
                    throw posixError(errno)
                }
            }

            if cancellation.isCancelled { beginShutdown(CancellationError(), at: now) }
            if childExit == nil, let deadline = executionDeadline, now >= deadline, let timeout {
                beginShutdown(ProcessTimedOut(timeout: timeout), at: now)
            }

            do {
                try stdout.drain(into: &buffer)
                try stderr.drain(into: &buffer)
            } catch {
                beginShutdown(error, at: now)
            }

            if failure == nil {
                if let exitCode = childExit, stdout.isAtEOF, stderr.isAtEOF {
                    return ProcessResult(
                        exitCode: exitCode,
                        stdout: String(data: stdout.data, encoding: .utf8) ?? "",
                        stderr: String(data: stderr.data, encoding: .utf8) ?? ""
                    )
                }
                if let deadline = outputDeadline, now >= deadline {
                    beginShutdown(ProcessOutputTimedOut(), at: now)
                }
            }

            if let deadline = forceKillDeadline, now >= deadline {
                signalGroup(SIGKILL)
                forceKillDeadline = nil
                drainDeadline = now + .milliseconds(250)
            }
            if let deadline = drainDeadline,
               (childExit != nil && stdout.isAtEOF && stderr.isAtEOF) || now >= deadline {
                throw failure!
            }

            // Poll only open pipes. A bounded read batch above prevents a producer
            // that writes continuously from starving stderr or the shutdown checks.
            var fds = [stdout, stderr].filter { !$0.isAtEOF }.map {
                pollfd(fd: $0.reader, events: Int16(POLLIN), revents: 0)
            }
            // An EOF pipe can make poll return immediately even while the other
            // pipe is open. Closed readers are removed from the next iteration.
            if poll(&fds, nfds_t(fds.count), 20) < 0, errno != EINTR {
                beginShutdown(posixError(errno), at: clock.now)
            }
        }
    }
}

private func spawn(
    _ executable: String, arguments: [String], stdout: ProcessPipe, stderr: ProcessPipe
) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    try checkPOSIX(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO))
    try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, stdout.writer, STDOUT_FILENO))
    try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, stderr.writer, STDERR_FILENO))

    var attributes: posix_spawnattr_t?
    try checkPOSIX(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))
    var signals = sigset_t()
    sigemptyset(&signals)
    try checkPOSIX(posix_spawnattr_setsigmask(&attributes, &signals))
    sigfillset(&signals)
    try checkPOSIX(posix_spawnattr_setsigdefault(&attributes, &signals))
    try checkPOSIX(posix_spawnattr_setflags(&attributes, Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    )))

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    return try withCStringArray([executable] + arguments) { argv in
        try withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
            var pid: pid_t = 0
            try checkPOSIX(posix_spawn(&pid, executable, &actions, &attributes, argv, envp))
            return pid
        }
    }
}

private func withCStringArray<T>(
    _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
) throws -> T {
    guard strings.allSatisfy({ !$0.utf8.contains(0) }) else { throw posixError(EINVAL) }
    var pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    guard pointers.allSatisfy({ $0 != nil }) else { throw posixError(ENOMEM) }
    pointers.append(nil)
    return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
}

/// Owned by one Dispatch worker; readers are nonblocking and every FD closes once.
private final class ProcessPipe {
    let reader: Int32
    private(set) var writer: Int32
    private(set) var isAtEOF = false
    private(set) var data = Data()

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw posixError(errno) }
        if fcntl(fds[0], F_SETFD, FD_CLOEXEC) == -1 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) == -1
            || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1 {
            let error = posixError(errno)
            close(fds[0])
            close(fds[1])
            throw error
        }
        reader = fds[0]
        writer = fds[1]
    }

    deinit {
        close(reader)
        closeWriter()
    }

    func closeWriter() {
        if writer >= 0 {
            close(writer)
            writer = -1
        }
    }

    func drain(into buffer: inout [UInt8]) throws {
        guard !isAtEOF else { return }
        // At most 256 KiB per stream before checking timeouts and the other stream.
        for _ in 0..<4 {
            let count = read(reader, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                isAtEOF = true
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            } else {
                throw posixError(errno)
            }
        }
    }
}

private func reap(_ pid: pid_t) {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
}

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

private func checkPOSIX(_ code: Int32) throws {
    if code != 0 { throw posixError(code) }
}

/// Cancellation never signals directly: the worker owns the PID until it is reaped.
private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
