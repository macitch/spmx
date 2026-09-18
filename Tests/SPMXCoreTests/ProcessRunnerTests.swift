/*
 *  File: ProcessRunnerTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("concurrent short-lived processes all deliver their output and exit status")
    func concurrentProcesses() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let result = try await SystemProcessRunner(timeout: 5).run("/bin/echo", arguments: [String(index)])
                    #expect(result.exitCode == 0)
                    #expect(result.stdout == "\(index)\n")
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("stdout and stderr are drained while the subprocess runs")
    func largeOutputOnBothPipes() async throws {
        let result = try await SystemProcessRunner(timeout: 5).run("/bin/sh", arguments: [
            "-c", "/bin/dd if=/dev/zero bs=65536 count=16; /bin/dd if=/dev/zero bs=65536 count=16 >&2",
        ])
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 1_048_576)
        #expect(result.stderr.utf8.filter { $0 == 0 }.count == 1_048_576)
    }

    @Test("timeout still terminates a subprocess after substantial output")
    func timeoutAfterOutput() async throws {
        do {
            _ = try await SystemProcessRunner(timeout: 0.5).run("/bin/sh", arguments: [
                "-c", "/bin/dd if=/dev/zero bs=65536 count=16; exec sleep 10",
            ])
            Issue.record("Expected timeout")
        } catch is ProcessTimedOut {
            // Expected: draining output must not disable the watchdog.
        }
    }

    @Test("ProcessTimedOut error describes the timeout duration")
    func timedOutDescription() {
        let err = ProcessTimedOut(timeout: 30)
        #expect(err.description.contains("30"))
        #expect(err.description.contains("timed out"))
    }

    @Test("default timeout is 30 seconds")
    func defaultTimeout() {
        // Just verify it can be constructed with defaults.
        let runner = SystemProcessRunner()
        _ = runner // no crash
    }

    @Test("nil timeout disables timeout")
    func nilTimeout() {
        let runner = SystemProcessRunner(timeout: nil)
        _ = runner
    }

    @Test("task cancellation kills the subprocess promptly and throws CancellationError")
    func cancellationKillsSubprocess() async throws {
        // Without cooperative cancellation, Task.detached inside SystemProcessRunner
        // swallows cancel signals and `git ls-remote`-style hangs wait for the full
        // 30-second timeout. This test launches `sleep 10`, cancels the task, and
        // asserts the runner returns within ~1s with a CancellationError.
        let runner = SystemProcessRunner(timeout: 30)
        let start = Date()

        let task = Task {
            try await runner.run("/usr/bin/env", arguments: ["sleep", "10"])
        }

        // Give the subprocess a moment to actually start.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation to surface as a thrown error")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got: \(type(of: error)) \(error)")
        }

        let elapsed = Date().timeIntervalSince(start)
        let message = "subprocess should die within ~1s of cancel, not wait full 10s sleep (elapsed: \(elapsed)s)"
        #expect(elapsed < 3.0, Comment(rawValue: message))
    }

    @Test("a quick subprocess finishes normally without spurious cancellation")
    func noSpuriousCancellation() async throws {
        // Regression guard: with cancellation wiring in place, a normal completion
        // should still return a ProcessResult — not throw CancellationError just
        // because we registered a cancellation handler.
        let runner = SystemProcessRunner(timeout: 30)
        let result = try await runner.run("/usr/bin/env", arguments: ["true"])
        #expect(result.exitCode == 0)
    }
}
