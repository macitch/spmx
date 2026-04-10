/*
 *  File: XcodePreferencesTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("XcodePreferences")
struct XcodePreferencesTests {

    private func writePlist(_ dict: [String: Any]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-prefs-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
        try data.write(to: tmp)
        return tmp
    }

    @Test("returns nil when plist does not exist")
    func missingPlist() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).plist")
        let result = XcodePreferences.customDerivedDataLocation(preferencesURL: bogus)
        #expect(result == nil)
    }

    @Test("returns nil when style is default (0)")
    func defaultStyle() throws {
        let url = try writePlist([
            "IDEDerivedDataLocationStyle": 0,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = XcodePreferences.customDerivedDataLocation(preferencesURL: url)
        #expect(result == nil)
    }

    @Test("returns nil when style is relative (1)")
    func relativeStyle() throws {
        let url = try writePlist([
            "IDEDerivedDataLocationStyle": 1,
            "IDECustomDerivedDataLocation": "Build/DerivedData",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = XcodePreferences.customDerivedDataLocation(preferencesURL: url)
        #expect(result == nil)
    }

    @Test("returns custom path when style is absolute (2) and directory exists")
    func absoluteStyle() throws {
        let fm = FileManager.default
        let customDir = fm.temporaryDirectory
            .appendingPathComponent("spmx-custom-dd-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: customDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: customDir) }

        let url = try writePlist([
            "IDEDerivedDataLocationStyle": 2,
            "IDECustomDerivedDataLocation": customDir.path,
        ])
        defer { try? fm.removeItem(at: url) }

        let result = XcodePreferences.customDerivedDataLocation(preferencesURL: url)
        #expect(result != nil)
        #expect(result?.path == customDir.path)
    }

    @Test("returns nil when style is absolute but directory does not exist")
    func absoluteStyleMissingDir() throws {
        let bogusDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-no-exist-\(UUID().uuidString)")

        let url = try writePlist([
            "IDEDerivedDataLocationStyle": 2,
            "IDECustomDerivedDataLocation": bogusDir.path,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = XcodePreferences.customDerivedDataLocation(preferencesURL: url)
        #expect(result == nil)
    }

    @Test("returns nil when no style key is present (defaults to 0)")
    func noStyleKey() throws {
        let url = try writePlist([:])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = XcodePreferences.customDerivedDataLocation(preferencesURL: url)
        #expect(result == nil)
    }
}