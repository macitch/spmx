/*
 *  File: XcodeCheckoutLocatorTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("XcodeCheckoutLocator")
struct XcodeCheckoutLocatorTests {

    // MARK: - DerivedData happy path

    @Test("finds checkout in DerivedData when info.plist WorkspacePath matches project")
    func derivedDataMatch() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")
        let derived = try stage.makeDerivedData(
            named: "MyApp-abc123",
            workspacePath: project.path
        )
        try stage.makeCheckout(in: derived, identity: "alamofire")

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)

        #expect(found != nil)
        #expect(samePath(
            found!,
            derived.appendingPathComponent("SourcePackages/checkouts/alamofire")
        ))
    }

    @Test("returns nil when no DerivedData entry matches the project")
    func derivedDataNoMatch() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")
        let otherProject = try stage.makeProject(named: "OtherApp.xcodeproj")

        // The DerivedData entry exists but it's for a different project.
        let derived = try stage.makeDerivedData(
            named: "OtherApp-xyz789",
            workspacePath: otherProject.path
        )
        try stage.makeCheckout(in: derived, identity: "alamofire")

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)
        #expect(found == nil)
    }

    @Test("when multiple DerivedData entries match, the most recently modified wins")
    func derivedDataMultipleMatches() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")

        // Older entry, set mtime to one hour ago.
        let older = try stage.makeDerivedData(
            named: "MyApp-old",
            workspacePath: project.path
        )
        try stage.makeCheckout(in: older, identity: "alamofire")
        try stage.touch(older, modified: Date(timeIntervalSinceNow: -3600))

        // Newer entry, mtime is now.
        let newer = try stage.makeDerivedData(
            named: "MyApp-new",
            workspacePath: project.path
        )
        try stage.makeCheckout(in: newer, identity: "alamofire")
        try stage.touch(newer, modified: Date())

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)

        #expect(found != nil)
        #expect(samePath(
            found!,
            newer.appendingPathComponent("SourcePackages/checkouts/alamofire")
        ))
    }

    @Test("DerivedData matches but checkout dir doesn't exist — returns nil if no fallback")
    func derivedDataMatchButCheckoutMissing() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")
        _ = try stage.makeDerivedData(
            named: "MyApp-abc123",
            workspacePath: project.path
        )
        // Note: NOT calling makeCheckout. The DerivedData entry exists, but the
        // identity we're looking for has no checkout directory. With no fallbacks,
        // the locator should return nil.

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)
        #expect(found == nil)
    }

    // MARK: - Fallbacks

    @Test("falls back to workspace-local SourcePackages when DerivedData has no match")
    func workspaceLocalFallback() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")

        // No DerivedData entry. Instead, populate <projectParent>/SourcePackages/checkouts/.
        let workspaceLocalCheckout = project
            .deletingLastPathComponent()
            .appendingPathComponent("SourcePackages/checkouts/alamofire")
        try stage.fm.createDirectory(
            at: workspaceLocalCheckout,
            withIntermediateDirectories: true
        )

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)
        #expect(found != nil)
        #expect(samePath(found!, workspaceLocalCheckout))
    }

    @Test("falls back to .swiftpm/checkouts as last resort")
    func swiftpmLocalFallback() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")

        let swiftpmCheckout = project
            .deletingLastPathComponent()
            .appendingPathComponent(".swiftpm/checkouts/alamofire")
        try stage.fm.createDirectory(
            at: swiftpmCheckout,
            withIntermediateDirectories: true
        )

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)
        #expect(found != nil)
        #expect(samePath(found!, swiftpmCheckout))
    }

    // MARK: - Edge cases

    @Test("missing DerivedData root returns nil cleanly without crashing")
    func missingDerivedDataRoot() throws {
        let stage = try Stage()
        defer { stage.cleanup() }
        let project = try stage.makeProject(named: "MyApp.xcodeproj")

        // Point the locator at a directory that doesn't exist.
        let bogusRoot = stage.tmp.appendingPathComponent("does-not-exist-derived-data")
        let locator = XcodeCheckoutLocator(derivedDataRoot: bogusRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)
        #expect(found == nil)
    }

    @Test("repeated lookups for the same project use the cache (consistent results)")
    func cacheConsistency() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")
        let derived = try stage.makeDerivedData(
            named: "MyApp-abc123",
            workspacePath: project.path
        )
        try stage.makeCheckout(in: derived, identity: "alamofire")
        try stage.makeCheckout(in: derived, identity: "swift-collections")

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let first = locator.checkoutDirectory(for: "alamofire", projectURL: project)
        let second = locator.checkoutDirectory(for: "swift-collections", projectURL: project)

        // Both lookups for the same project should land in the same DerivedData entry.
        #expect(first?.deletingLastPathComponent() == second?.deletingLastPathComponent())
    }

    @Test("checkout directory lookup is case-insensitive (matches Xcode's PascalCase dirs)")
    func caseInsensitiveCheckoutLookup() throws {
        // Regression test for the bug found dogfooding against VeriGuard's real
        // DerivedData: SPM identities are lowercased (`keychainaccess`) but Xcode
        // creates checkout directories with the original repo case (`KeychainAccess`).
        // The locator must find the PascalCase directory when given a lowercase identity.
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "VeriGuard.xcodeproj")
        let derived = try stage.makeDerivedData(
            named: "VeriGuard-hebfamajacipuxavsrvdxvuojiwq",
            workspacePath: project.path
        )
        // Create the checkout dir with PascalCase, like Xcode does.
        try stage.makeCheckout(in: derived, identity: "KeychainAccess")

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        // Look it up with the lowercased SPM identity.
        let found = locator.checkoutDirectory(for: "keychainaccess", projectURL: project)

        #expect(found != nil)
        // The returned URL should point at the actual on-disk PascalCase directory,
        // not a synthesized lowercase one.
        #expect(found?.lastPathComponent == "KeychainAccess")
    }

    @Test("info.plist with no WorkspacePath is silently skipped")
    func infoPlistMissingWorkspacePath() throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(named: "MyApp.xcodeproj")

        // Create a DerivedData entry whose info.plist exists but doesn't have the key.
        let entry = stage.derivedDataRoot.appendingPathComponent("Bogus-entry")
        try stage.fm.createDirectory(at: entry, withIntermediateDirectories: true)
        let plist: [String: Any] = ["SomeOtherKey": "value"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: entry.appendingPathComponent("info.plist"))

        // Also create a real matching entry so we can verify the locator skips the bogus
        // one and finds the real one.
        let realEntry = try stage.makeDerivedData(
            named: "MyApp-real",
            workspacePath: project.path
        )
        try stage.makeCheckout(in: realEntry, identity: "alamofire")

        let locator = XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        let found = locator.checkoutDirectory(for: "alamofire", projectURL: project)
        #expect(found != nil)
        #expect(samePath(
            found!,
            realEntry.appendingPathComponent("SourcePackages/checkouts/alamofire")
        ))
    }

    // MARK: - Helpers

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Test scaffolding for staging fake project + DerivedData layouts in tmp.
private struct Stage {
    let fm = FileManager.default
    let tmp: URL
    let derivedDataRoot: URL

    init() throws {
        self.tmp = fm.temporaryDirectory
            .appendingPathComponent("spmx-locator-\(UUID().uuidString)")
        self.derivedDataRoot = tmp.appendingPathComponent("DerivedData")
        try fm.createDirectory(at: derivedDataRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? fm.removeItem(at: tmp)
    }

    /// Create an empty `.xcodeproj` directory at `tmp/projects/<name>` and return its URL.
    /// We don't put a `project.pbxproj` inside — the locator never reads the project's
    /// contents, only its path.
    func makeProject(named name: String) throws -> URL {
        let projects = tmp.appendingPathComponent("projects")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        let project = projects.appendingPathComponent(name)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    /// Create a fake DerivedData entry with an info.plist whose `WorkspacePath` is set
    /// to the given absolute path. Returns the entry URL.
    func makeDerivedData(named name: String, workspacePath: String) throws -> URL {
        let entry = derivedDataRoot.appendingPathComponent(name)
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "WorkspacePath": workspacePath,
            "LastAccessedDate": Date()
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: entry.appendingPathComponent("info.plist"))
        return entry
    }

    /// Create an empty checkout directory for `identity` inside the given DerivedData
    /// entry. Mirrors Xcode's layout exactly.
    func makeCheckout(in derivedData: URL, identity: String) throws {
        let checkout = derivedData
            .appendingPathComponent("SourcePackages/checkouts")
            .appendingPathComponent(identity)
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
    }

    /// Set the modification time of a directory. Used to test the "newest match wins"
    /// behavior when multiple DerivedData entries point at the same project.
    func touch(_ url: URL, modified: Date) throws {
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}

// MARK: - Dogfood (env-gated, real DerivedData)

/// Pointed at a real Xcode project on disk, this test reads its direct SPM refs and then
/// asks the locator to find each one in the user's actual `~/Library/Developer/Xcode/DerivedData`.
/// Skipped unless `SPMX_DOGFOOD_XCODE` is set. Will move to a separate integration target
/// before v0.1 ships — it's machine-specific by nature.
@Suite("XcodeCheckoutLocatorDogfood")
struct XcodeCheckoutLocatorDogfood {
    @Test("locator finds real package checkouts via real DerivedData")
    func real() throws {
        guard let raw = ProcessInfo.processInfo.environment["SPMX_DOGFOOD_XCODE"] else {
            print("SPMX_DOGFOOD_XCODE not set — skipping")
            return
        }
        var expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasSuffix("/project.pbxproj") {
            expanded = (expanded as NSString).deletingLastPathComponent
        }
        let project = URL(fileURLWithPath: expanded)

        // Use the real ~/Library/Developer/Xcode/DerivedData (default init).
        let locator = XcodeCheckoutLocator()

        // First read the project's direct deps so we know what to look up.
        let refs = try XcodeProjectReader().read(project)
        print("---- looking up \(refs.count) refs from \(expanded) ----")

        var foundCount = 0
        for ref in refs {
            let result = locator.checkoutDirectory(for: ref.identity, projectURL: project)
            if let result {
                foundCount += 1
                print("  ✓ \(ref.identity) → \(result.path)")
            } else {
                print("  ✗ \(ref.identity) → not found")
            }
        }
        #expect(foundCount > 0, "expected to find at least one checkout via DerivedData")
    }
}