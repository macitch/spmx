/*
 *  File: ProjectDetectorTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("ProjectDetector")
struct ProjectDetectorTests {

    private let detector = ProjectDetector()

    // MARK: - SwiftPM detection

    @Test("directory with Package.swift detects as SwiftPM")
    func swiftpmDetection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-detect-spm-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("// stub\n".utf8).write(to: root.appendingPathComponent("Package.swift"))

        let result = try detector.detect(path: root)
        switch result {
        case .swiftpm(let dir):
            #expect(dir.lastPathComponent == root.lastPathComponent)
        case .xcode:
            Issue.record("expected SwiftPM, got Xcode")
        }
    }

    // MARK: - Xcode detection

    @Test("directory with single .xcodeproj detects as Xcode")
    func xcodeprojDetection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-detect-xcode-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let proj = root.appendingPathComponent("MyApp.xcodeproj")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)

        let result = try detector.detect(path: root)
        switch result {
        case .xcode(let url):
            #expect(url.lastPathComponent == "MyApp.xcodeproj")
        case .swiftpm:
            Issue.record("expected Xcode, got SwiftPM")
        }
    }

    @Test("directory with single .xcworkspace detects as Xcode")
    func xcworkspaceDetection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-detect-ws-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let ws = root.appendingPathComponent("MyApp.xcworkspace")
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)

        let result = try detector.detect(path: root)
        switch result {
        case .xcode(let url):
            #expect(url.lastPathComponent == "MyApp.xcworkspace")
        case .swiftpm:
            Issue.record("expected Xcode, got SwiftPM")
        }
    }

    @Test("Package.swift wins over .xcodeproj in same directory")
    func swiftpmWinsOverXcode() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-detect-both-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("// stub\n".utf8).write(to: root.appendingPathComponent("Package.swift"))
        let proj = root.appendingPathComponent("MyApp.xcodeproj")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)

        let result = try detector.detect(path: root)
        switch result {
        case .swiftpm:
            break // expected
        case .xcode:
            Issue.record("expected SwiftPM to win over Xcode")
        }
    }

    // MARK: - Direct bundle paths

    @Test("pointing directly at .xcodeproj detects as Xcode")
    func directXcodeproj() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-detect-direct-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let proj = root.appendingPathComponent("MyApp.xcodeproj")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)

        let result = try detector.detect(path: proj)
        switch result {
        case .xcode(let url):
            #expect(url.lastPathComponent == "MyApp.xcodeproj")
        case .swiftpm:
            Issue.record("expected Xcode")
        }
    }

    // MARK: - Error cases

    @Test("nonexistent path throws pathDoesNotExist")
    func nonexistentPath() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-detect-nope-\(UUID().uuidString)")

        #expect(throws: ProjectDetector.Error.self) {
            try detector.detect(path: bogus)
        }
    }

    @Test("empty directory throws noProjectOrPackage")
    func emptyDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-detect-empty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        do {
            _ = try detector.detect(path: root)
            Issue.record("expected noProjectOrPackage")
        } catch let err as ProjectDetector.Error {
            switch err {
            case .noProjectOrPackage:
                break // expected
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("multiple .xcodeproj without Package.swift throws ambiguous")
    func ambiguousXcodeProjects() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-detect-ambig-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(
            at: root.appendingPathComponent("A.xcodeproj"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: root.appendingPathComponent("B.xcodeproj"),
            withIntermediateDirectories: true
        )

        do {
            _ = try detector.detect(path: root)
            Issue.record("expected ambiguousXcodeProject")
        } catch let err as ProjectDetector.Error {
            switch err {
            case .ambiguousXcodeProject(_, let candidates):
                #expect(candidates.sorted() == ["A.xcodeproj", "B.xcodeproj"])
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }
}