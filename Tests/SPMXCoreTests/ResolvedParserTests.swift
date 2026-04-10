/*
 *  File: ResolvedParserTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("ResolvedParser")
struct ResolvedParserTests {

    @Test("parses a v3 Package.resolved fixture")
    func parsesV3Fixture() throws {
        let url = Bundle.module.url(
            forResource: "Package.resolved.v3",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
        let unwrappedURL = try #require(url, "Fixture file missing")
        let parser = ResolvedParser()
        let file = try parser.parse(at: unwrappedURL)

        #expect(file.version == 3)
        #expect(file.pins.count == 2)
        #expect(file.pins[0].identity == "alamofire")
        #expect(file.pins[0].displayVersion == "5.8.1")
        #expect(file.pins[1].identity == "swift-collections")
        #expect(file.pins[1].kind == .remoteSourceControl)
    }

    @Test("rejects an unsupported version")
    func rejectsUnsupportedVersion() throws {
        let json = #"{"version": 99, "pins": []}"#.data(using: .utf8)!
        let parser = ResolvedParser()
        #expect(throws: ResolvedParser.Error.self) {
            try parser.parse(data: json)
        }
    }

    @Test("falls back to branch when no version is set")
    func displayVersionFallback() {
        let pin = ResolvedFile.Pin(
            identity: "test",
            kind: .remoteSourceControl,
            location: "https://example.com/test.git",
            state: .init(revision: "abc1234567", version: nil, branch: "main")
        )
        #expect(pin.displayVersion == "branch:main")
    }

    // MARK: - Locator (4 supported layouts)

    /// Two URLs name the same file iff their fully-canonicalized absolute paths match.
    /// `URL.path` alone is not enough on macOS because `/var` is a symlink to `/private/var`,
    /// and `FileManager.contentsOfDirectory(at:)` may return either form depending on the
    /// macOS version. Resolving symlinks on both sides at comparison time is the only
    /// robust approach.
    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Stages a directory tree on disk so we can drive `locate(in:)` against real files.
    /// Returns the temp directory and a closure that creates `Package.resolved` at a
    /// given relative path inside it.
    ///
    /// The temp dir is symlink-resolved up front (`/var/folders/...` → `/private/var/folders/...`)
    /// so paths constructed here line up byte-for-byte with what `FileManager.contentsOfDirectory`
    /// returns, which is also symlink-resolved on macOS. Without this, path-equality assertions
    /// fail with two strings that point at the same file.
    private func makeTempProject() throws -> (root: URL, place: (String) throws -> URL) {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent(
            "spmx-locate-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let root = raw.resolvingSymlinksInPath()
        let place: (String) throws -> URL = { relPath in
            let url = root.appendingPathComponent(relPath)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: url)
            return url
        }
        return (root, place)
    }

    @Test("locator finds plain Package.resolved at the root")
    func locatesPlainSwiftPM() throws {
        let (root, place) = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try place("Package.resolved")

        let parser = ResolvedParser()
        let found = try #require(parser.locate(in: root))
        #expect(samePath(found, expected))
    }

    @Test("locator finds Package.resolved inside an .xcodeproj")
    func locatesInXcodeproj() throws {
        let (root, place) = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try place(
            "MyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )

        let parser = ResolvedParser()
        let found = try #require(parser.locate(in: root))
        #expect(samePath(found, expected))
    }

    @Test("locator finds Package.resolved inside an .xcworkspace")
    func locatesInXcworkspace() throws {
        let (root, place) = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try place(
            "MyApp.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )

        let parser = ResolvedParser()
        let found = try #require(parser.locate(in: root))
        #expect(samePath(found, expected))
    }

    @Test("locator prefers .xcworkspace over .xcodeproj when both exist")
    func workspaceBeatsProject() throws {
        let (root, place) = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try place("MyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let workspaceFile = try place("MyApp.xcworkspace/xcshareddata/swiftpm/Package.resolved")

        let parser = ResolvedParser()
        let found = try #require(parser.locate(in: root))
        // Diagnostic: if this fails, we want to know whether the locator returned the
        // *wrong* bundle or merely a path-string that canonicalizes to the same file.
        #expect(!found.path.contains(".xcodeproj"), "locator returned the project bundle, not the workspace: \(found.path)")
        #expect(samePath(found, workspaceFile))
    }

    @Test("locator prefers root Package.resolved over any Xcode bundle")
    func rootBeatsXcode() throws {
        let (root, place) = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootFile = try place("Package.resolved")
        _ = try place("MyApp.xcworkspace/xcshareddata/swiftpm/Package.resolved")

        let parser = ResolvedParser()
        let found = try #require(parser.locate(in: root))
        #expect(samePath(found, rootFile))
    }

    @Test("locator returns nil when no Package.resolved exists anywhere")
    func locatesNothing() throws {
        let (root, _) = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let parser = ResolvedParser()
        #expect(parser.locate(in: root) == nil)
    }
}