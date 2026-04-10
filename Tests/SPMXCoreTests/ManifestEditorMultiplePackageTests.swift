/*
 *  File: ManifestEditorMultiplePackageTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

// MARK: - Fixtures

/// Two `let package = Package(...)` at the top level — direct duplication.
private let twoPackageCallsManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "First",
    dependencies: [],
    targets: [
        .target(name: "First"),
    ]
)

let package = Package(
    name: "Second",
    dependencies: [],
    targets: [
        .target(name: "Second"),
    ]
)
"""

/// Entire `let package = Package(...)` inside `#if` branches.
private let ifConfigWrappedPackageManifest = """
// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
let package = Package(
    name: "MacApp",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        .target(name: "MacApp"),
    ]
)
#else
let package = Package(
    name: "LinuxApp",
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "LinuxApp"),
    ]
)
#endif
"""

/// Single `let package = Package(...)` inside `#if` — only one branch has it.
private let singleIfConfigPackageManifest = """
// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
let package = Package(
    name: "MacOnly",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        .target(name: "MacOnly"),
    ]
)
#endif
"""

/// Normal manifest — single Package call, no issues.
private let normalManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Normal",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        .target(name: "Normal"),
    ]
)
"""

// MARK: - Tests

@Suite("ManifestEditor.multiplePackageInits")
struct ManifestEditorMultiplePackageTests {

    // MARK: - Detection

    @Test("two top-level Package calls throws multiplePackageInits")
    func twoDirectPackageCalls() throws {
        let editor = try ManifestEditor.parse(source: twoPackageCallsManifest)
        #expect(throws: ManifestEditor.Error.multiplePackageInits) {
            _ = try editor.listDependencyIdentities()
        }
    }

    @Test("#if wrapping entire Package calls in two branches throws multiplePackageInits")
    func ifConfigWrappedPackageCalls() throws {
        let editor = try ManifestEditor.parse(source: ifConfigWrappedPackageManifest)
        #expect(throws: ManifestEditor.Error.multiplePackageInits) {
            _ = try editor.listDependencyIdentities()
        }
    }

    @Test("#if with single branch Package call succeeds")
    func singleIfConfigBranch() throws {
        let editor = try ManifestEditor.parse(source: singleIfConfigPackageManifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids == ["alamofire"])
    }

    @Test("normal single Package call still works")
    func normalManifestWorks() throws {
        let editor = try ManifestEditor.parse(source: normalManifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids == ["alamofire"])
    }

    // MARK: - All mutation paths detect multiple inits

    @Test("multiplePackageInits on addingDependency")
    func addingDependency() throws {
        let editor = try ManifestEditor.parse(source: twoPackageCallsManifest)
        #expect(throws: ManifestEditor.Error.multiplePackageInits) {
            _ = try editor.addingDependency(
                url: "https://github.com/apple/swift-nio.git",
                requirement: .from("2.0.0")
            )
        }
    }

    @Test("multiplePackageInits on removingDependency")
    func removingDependency() throws {
        let editor = try ManifestEditor.parse(source: twoPackageCallsManifest)
        #expect(throws: ManifestEditor.Error.multiplePackageInits) {
            _ = try editor.removingDependency(identity: "first")
        }
    }

    @Test("multiplePackageInits on listNonTestTargets")
    func listNonTestTargets() throws {
        let editor = try ManifestEditor.parse(source: twoPackageCallsManifest)
        #expect(throws: ManifestEditor.Error.multiplePackageInits) {
            _ = try editor.listNonTestTargets()
        }
    }

    @Test("multiplePackageInits on removingPackageCompletely")
    func removingPackageCompletely() throws {
        let editor = try ManifestEditor.parse(source: twoPackageCallsManifest)
        #expect(throws: ManifestEditor.Error.multiplePackageInits) {
            _ = try editor.removingPackageCompletely(identity: "first")
        }
    }

    @Test("multiplePackageInits on containsPackage")
    func containsPackage() throws {
        let editor = try ManifestEditor.parse(source: twoPackageCallsManifest)
        #expect(throws: ManifestEditor.Error.multiplePackageInits) {
            _ = try editor.containsPackage(identity: "first")
        }
    }

    // MARK: - Error description

    @Test("multiplePackageInits error mentions multiple and #if")
    func errorDescription() {
        let err = ManifestEditor.Error.multiplePackageInits
        #expect(err.description.contains("Multiple"))
        #expect(err.description.contains("#if"))
    }
}