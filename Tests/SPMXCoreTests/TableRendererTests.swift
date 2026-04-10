/*
 *  File: TableRendererTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("TableRenderer")
struct TableRendererTests {

    private let row1 = OutdatedRow(
        identity: "alamofire",
        current: "5.8.0",
        latest: "5.9.1",
        status: .behindMinorPatch,
        note: nil
    )
    private let row2 = OutdatedRow(
        identity: "swift-collections",
        current: "1.0.0",
        latest: "2.0.0",
        status: .behindMajor,
        note: nil
    )
    private let upToDateRow = OutdatedRow(
        identity: "swift-log",
        current: "1.5.3",
        latest: "1.5.3",
        status: .upToDate,
        note: nil
    )
    private let failedRow = OutdatedRow(
        identity: "ghost",
        current: "1.0.0",
        latest: nil,
        status: .unknown,
        note: "fetch failed: repository not found"
    )

    @Test("empty input renders the all-clear message")
    func emptyRendersAllClear() {
        let renderer = TableRenderer(colorEnabled: false)
        let out = renderer.render([])
        #expect(out.contains("up to date"))
    }

    @Test("plain rendering contains identities, versions, and status labels")
    func plainRenderingShowsAllColumns() {
        let renderer = TableRenderer(colorEnabled: false)
        let out = renderer.render([row1, row2, upToDateRow])

        for needle in ["alamofire", "5.8.0", "5.9.1", "behind",
                       "swift-collections", "2.0.0", "behind (major)",
                       "swift-log", "up to date"] {
            #expect(out.contains(needle), "missing \(needle) in:\n\(out)")
        }
    }

    @Test("plain rendering emits no ANSI escape sequences")
    func plainRenderingHasNoAnsi() {
        let renderer = TableRenderer(colorEnabled: false)
        let out = renderer.render([row1, row2, upToDateRow, failedRow])
        #expect(!out.contains("\u{001B}["))
    }

    @Test("color rendering wraps each body row in the correct ANSI color")
    func colorRenderingUsesExpectedCodes() {
        let renderer = TableRenderer(colorEnabled: true)
        let out = renderer.render([row1, row2, upToDateRow])

        #expect(out.contains("\u{001B}[33m")) // yellow for behindMinorPatch
        #expect(out.contains("\u{001B}[31m")) // red for behindMajor
        #expect(out.contains("\u{001B}[32m")) // green for upToDate
        #expect(out.contains("\u{001B}[0m"))  // reset
    }

    @Test("notes are appended below the table for rows with a note")
    func notesAppendedBelowTable() {
        let renderer = TableRenderer(colorEnabled: false)
        let out = renderer.render([row1, failedRow])
        #expect(out.contains("Notes:"))
        #expect(out.contains("ghost"))
        #expect(out.contains("repository not found"))
    }

    @Test("rows without notes do not produce a Notes section")
    func noNotesSectionWhenAllRowsClean() {
        let renderer = TableRenderer(colorEnabled: false)
        let out = renderer.render([row1, row2, upToDateRow])
        #expect(!out.contains("Notes:"))
    }

    @Test("autoDetect honours NO_COLOR env var")
    func autoDetectHonoursNoColor() {
        let renderer = TableRenderer.autoDetect(
            environment: ["NO_COLOR": "1"],
            isStdoutTTY: true
        )
        #expect(renderer.colorEnabled == false)
    }

    @Test("autoDetect disables color when stdout is not a TTY")
    func autoDetectDisablesColorOffTTY() {
        let renderer = TableRenderer.autoDetect(
            environment: [:],
            isStdoutTTY: false
        )
        #expect(renderer.colorEnabled == false)
    }

    @Test("autoDetect enables color on a TTY with no NO_COLOR")
    func autoDetectEnablesColorOnTTY() {
        let renderer = TableRenderer.autoDetect(
            environment: [:],
            isStdoutTTY: true
        )
        #expect(renderer.colorEnabled == true)
    }
}