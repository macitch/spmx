/*
 *  File: ProcessRunnerTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Darwin
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

    @Test("timeout escalates even when the subprocess ignores SIGTERM and closes its pipes", arguments: [false, true])
    func ignoredTermination(closePipes: Bool) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let redirect = closePipes ? "exec >/dev/null 2>&1; " : ""
        let start = ContinuousClock.now
        do {
            _ = try await SystemProcessRunner(timeout: 0.5).run("/bin/sh", arguments: [
                "-c", "trap '' TERM; echo $$ > \"$1\"; \(redirect)exec /bin/sleep 8", "fixture", pidFile.path,
            ])
            Issue.record("Expected ProcessTimedOut")
        } catch let error as ProcessTimedOut {
            #expect(error.timeout == 0.5)
        }
        #expect(start.duration(to: .now) < .seconds(3))
        let pid = try await readPID(at: pidFile)
        expectReaped(pid)
    }

    @Test("cancellation kills the group, including children that closed their output pipes")
    func cancellationCleansUpChildren() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentFile = directory.appendingPathComponent("parent")
        let childFile = directory.appendingPathComponent("child")
        let task = Task {
            try await SystemProcessRunner(timeout: nil).run("/bin/sh", arguments: [
                "-c", """
                trap '' TERM
                /bin/sh -c 'echo $$ > "$1"; exec /bin/sleep 8' child "$2" >/dev/null 2>&1 &
                echo $$ > "$1"
                wait
                """, "fixture", parentFile.path, childFile.path,
            ])
        }
        defer { task.cancel() }
        let parent = try await readPID(at: parentFile)
        let child = try await readPID(at: childFile)
        // The isolated group must never be the test runner's own group.
        #expect(getpgid(parent) == parent)
        #expect(getpgid(child) == parent)
        #expect(parent != getpgrp())
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {}
        #expect(start.duration(to: .now) < .seconds(3))
        expectReaped(parent)
        try await expectGone(child)
    }

    @Test("inherited pipes after parent exit have a deadline even without an execution timeout")
    func inheritedPipes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childFile = directory.appendingPathComponent("child")
        let start = ContinuousClock.now
        do {
            _ = try await SystemProcessRunner(timeout: nil).run("/bin/sh", arguments: [
                "-c", """
                /bin/sh -c 'trap "" TERM; echo $$ > "$1"; exec /bin/sleep 8' child "$1" &
                while [ ! -s "$1" ]; do /bin/sleep 0.01; done
                printf parent-output
                """, "fixture", childFile.path,
            ])
            Issue.record("Expected ProcessOutputTimedOut instead of truncated success")
        } catch is ProcessOutputTimedOut {}
        #expect(start.duration(to: .now) < .seconds(4))
        let child = try await readPID(at: childFile)
        try await expectGone(child)
    }

    @Test("a detached descendant cannot hold the caller in pipe drainage")
    func detachedDescendant() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("detached-child")
        let source = try #require(Bundle.module.url(
            forResource: "detached-child", withExtension: "c", subdirectory: "Fixtures"
        ))
        let compilation = try await SystemProcessRunner().run("/usr/bin/xcrun", arguments: [
            "clang", source.path, "-o", executable.path,
        ])
        try #require(compilation.exitCode == 0, Comment(rawValue: compilation.stderr))
        let childFile = directory.appendingPathComponent("child")
        let task = Task {
            try await SystemProcessRunner(timeout: nil).run(executable.path, arguments: [childFile.path])
        }
        defer { task.cancel() }
        let child = try await readPID(at: childFile)
        defer { kill(child, SIGKILL) }
        #expect(getpgid(child) == child)
        let start = ContinuousClock.now
        do {
            _ = try await task.value
            Issue.record("Expected ProcessOutputTimedOut")
        } catch is ProcessOutputTimedOut {}
        #expect(start.duration(to: .now) < .seconds(4))
        #expect(kill(child, 0) == 0, "The escaped child must still hold its pipes when run returns")
    }

    @Test("cancellation wins while timeout shutdown is already underway")
    func cancellationDuringTimeout() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("terminated")
        let task = Task {
            try await SystemProcessRunner(timeout: 0.5).run("/bin/sh", arguments: [
                "-c", "trap 'echo $$ > \"$1\"' TERM; /bin/sleep 8 & wait; /bin/sleep 8", "fixture", marker.path,
            ])
        }
        defer { task.cancel() }
        _ = try await readPID(at: marker)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {}
    }

    @Test("an already cancelled task does not launch a process")
    func cancelledBeforeLaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SystemProcessRunner().run("/usr/bin/touch", arguments: [marker.path])
        }
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("ordinary failure preserves output, status, argument boundaries, and Git environment")
    func ordinaryFailure() async throws {
        let result = try await SystemProcessRunner(timeout: nil).run("/bin/sh", arguments: [
            "-c", "printf '%s:%s' \"$GIT_TERMINAL_PROMPT\" \"$1\"; printf failure >&2; exit 7",
            "fixture", "argument with spaces; $HOME",
        ])
        #expect(result == ProcessResult(exitCode: 7, stdout: "0:argument with spaces; $HOME", stderr: "failure"))
    }

    @Test("short-lived inherited writers are fully drained after parent exit")
    func delayedOutput() async throws {
        let result = try await SystemProcessRunner(timeout: nil).run("/bin/sh", arguments: [
            "-c", "(/bin/sleep 0.1; printf delayed-out; printf delayed-err >&2) & exit 0",
        ])
        #expect(result == ProcessResult(exitCode: 0, stdout: "delayed-out", stderr: "delayed-err"))
    }

    @Test("signal termination retains Foundation Process exit-code semantics")
    func signalExitCode() async throws {
        let result = try await SystemProcessRunner().run("/bin/sh", arguments: ["-c", "kill -TERM $$"])
        #expect(result.exitCode == SIGTERM)
    }

    @Test("launch failure does not prevent subsequent invocations")
    func launchFailure() async throws {
        for _ in 0..<10 {
            do {
                _ = try await SystemProcessRunner().run("/nonexistent/spmx-test", arguments: [])
                Issue.record("Expected launch failure")
            } catch {
                #expect((error as NSError).domain == NSPOSIXErrorDomain)
                #expect((error as NSError).code == Int(ENOENT))
            }
        }
        let result = try await SystemProcessRunner().run("/bin/echo", arguments: ["still running"])
        #expect(result.stdout == "still running\n")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spmx-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func readPID(at url: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ProcessFixtureNotReady", code: 1)
    }

    private func expectReaped(_ pid: pid_t) {
        let alive = kill(pid, 0)
        let aliveError = errno
        #expect(alive == -1)
        #expect(aliveError == ESRCH)
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        let waitError = errno
        #expect(waited == -1)
        #expect(waitError == ECHILD)
    }

    private func expectGone(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let alive = kill(pid, 0)
        let error = errno
        #expect(alive == -1)
        #expect(error == ESRCH)
    }
}
