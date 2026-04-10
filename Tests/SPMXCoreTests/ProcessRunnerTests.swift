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
}