/*
 *  File: ManifestEditorConditionalTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

// MARK: - Fixtures

/// Manifest with `#if` inside the top-level `dependencies:` array.
private let conditionalDependenciesManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConditionalDeps",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        #if os(macOS)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        #endif
    ],
    targets: [
        .target(name: "ConditionalDeps"),
    ]
)
"""

/// Manifest with `#if` inside the `targets:` array.
private let conditionalTargetsManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConditionalTargets",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        .target(name: "MyLib"),
        #if os(Linux)
        .target(name: "LinuxSupport"),
        #endif
    ]
)
"""

/// Manifest with `#if` inside a target's `dependencies:` array.
private let conditionalTargetDependenciesManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConditionalTargetDeps",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "MyLib",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
                #if os(macOS)
                .product(name: "Crypto", package: "swift-crypto"),
                #endif
            ]
        ),
    ]
)
"""

/// Manifest with `#if` wrapping the entire `dependencies:` argument value
/// (the whole array, not individual elements).
private let conditionalWholeDepArrayManifest = """
// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
let deps: [Package.Dependency] = [
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
]
#else
let deps: [Package.Dependency] = []
#endif

let package = Package(
    name: "ConditionalWhole",
    dependencies: deps,
    targets: [
        .target(name: "MyLib"),
    ]
)
"""

/// Clean manifest with no conditionals (control case).
private let cleanManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clean",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        .target(
            name: "MyLib",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
            ]
        ),
    ]
)
"""

/// Manifest with `#if` wrapping the entire `targets:` via a variable.
private let conditionalWholeTargetsManifest = """
// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
let myTargets: [Target] = [.target(name: "MyLib")]
#else
let myTargets: [Target] = [.target(name: "MyLibLinux")]
#endif

let package = Package(
    name: "ConditionalWholeTargets",
    dependencies: [],
    targets: myTargets
)
"""

// MARK: - Test suites

@Suite("ManifestEditor.conditionalCompilation")
struct ManifestEditorConditionalTests {

    // MARK: - #if in dependencies

    @Suite("dependencies with #if")
    struct ConditionalDependenciesTests {

        @Test("#if inside dependencies array throws conditionalDependencies on listDependencyIdentities")
        func listDependencyIdentities() throws {
            let editor = try ManifestEditor.parse(source: conditionalDependenciesManifest)
            #expect(throws: ManifestEditor.Error.conditionalDependencies) {
                _ = try editor.listDependencyIdentities()
            }
        }

        @Test("#if inside dependencies array throws conditionalDependencies on containsPackage")
        func containsPackage() throws {
            let editor = try ManifestEditor.parse(source: conditionalDependenciesManifest)
            #expect(throws: ManifestEditor.Error.conditionalDependencies) {
                _ = try editor.containsPackage(identity: "alamofire")
            }
        }

        @Test("#if inside dependencies array throws conditionalDependencies on addingDependency")
        func addingDependency() throws {
            let editor = try ManifestEditor.parse(source: conditionalDependenciesManifest)
            #expect(throws: ManifestEditor.Error.conditionalDependencies) {
                _ = try editor.addingDependency(
                    url: "https://github.com/Quick/Nimble.git",
                    requirement: .from("13.0.0")
                )
            }
        }

        @Test("#if inside dependencies array throws conditionalDependencies on removingDependency")
        func removingDependency() throws {
            let editor = try ManifestEditor.parse(source: conditionalDependenciesManifest)
            #expect(throws: ManifestEditor.Error.conditionalDependencies) {
                _ = try editor.removingDependency(identity: "alamofire")
            }
        }

        @Test("#if inside dependencies array throws conditionalDependencies on removingPackageCompletely")
        func removingPackageCompletely() throws {
            let editor = try ManifestEditor.parse(source: conditionalDependenciesManifest)
            #expect(throws: ManifestEditor.Error.conditionalDependencies) {
                _ = try editor.removingPackageCompletely(identity: "alamofire")
            }
        }

        @Test("non-literal deps (variable) still throws dependenciesNotArrayLiteral, not conditional")
        func variableDeps() throws {
            let editor = try ManifestEditor.parse(source: conditionalWholeDepArrayManifest)
            // `deps` is a variable reference, not an IfConfigDeclSyntax — so this
            // should throw dependenciesNotArrayLiteral, not conditionalDependencies.
            #expect(throws: ManifestEditor.Error.dependenciesNotArrayLiteral) {
                _ = try editor.listDependencyIdentities()
            }
        }
    }

    // MARK: - #if in targets

    @Suite("targets with #if")
    struct ConditionalTargetsTests {

        @Test("#if inside targets array throws conditionalTargets on listNonTestTargets")
        func listNonTestTargets() throws {
            let editor = try ManifestEditor.parse(source: conditionalTargetsManifest)
            #expect(throws: ManifestEditor.Error.conditionalTargets) {
                _ = try editor.listNonTestTargets()
            }
        }

        @Test("#if inside targets array throws conditionalTargets on removingPackageCompletely")
        func removingPackageCompletely() throws {
            let editor = try ManifestEditor.parse(source: conditionalTargetsManifest)
            // removingPackageCompletely scans targets to sweep product references.
            #expect(throws: ManifestEditor.Error.conditionalTargets) {
                _ = try editor.removingPackageCompletely(identity: "alamofire")
            }
        }

        @Test("non-literal targets (variable) throws targetsNotArrayLiteral, not conditional")
        func variableTargets() throws {
            let editor = try ManifestEditor.parse(source: conditionalWholeTargetsManifest)
            #expect(throws: ManifestEditor.Error.targetsNotArrayLiteral) {
                _ = try editor.listNonTestTargets()
            }
        }
    }

    // MARK: - #if in target dependencies

    @Suite("target dependencies with #if")
    struct ConditionalTargetDependenciesTests {

        @Test("#if inside target deps throws conditionalTargetDependencies on addingProductDependency")
        func addingProductDependency() throws {
            let editor = try ManifestEditor.parse(source: conditionalTargetDependenciesManifest)
            #expect {
                try editor.addingProductDependency(
                    productName: "Collections",
                    package: "swift-collections",
                    target: "MyLib"
                )
            } throws: { error in
                guard let editorError = error as? ManifestEditor.Error else { return false }
                if case .conditionalTargetDependencies(let target) = editorError {
                    return target == "MyLib"
                }
                return false
            }
        }

        @Test("#if inside target deps throws conditionalTargetDependencies on removingProductDependency")
        func removingProductDependency() throws {
            let editor = try ManifestEditor.parse(source: conditionalTargetDependenciesManifest)
            #expect {
                try editor.removingProductDependency(
                    productName: "Alamofire",
                    package: "Alamofire",
                    target: "MyLib"
                )
            } throws: { error in
                guard let editorError = error as? ManifestEditor.Error else { return false }
                if case .conditionalTargetDependencies(let target) = editorError {
                    return target == "MyLib"
                }
                return false
            }
        }

        @Test("#if inside target deps throws conditionalTargetDependencies on removingPackageCompletely")
        func removingPackageCompletely() throws {
            let editor = try ManifestEditor.parse(source: conditionalTargetDependenciesManifest)
            #expect {
                try editor.removingPackageCompletely(identity: "alamofire")
            } throws: { error in
                guard let editorError = error as? ManifestEditor.Error else { return false }
                if case .conditionalTargetDependencies(let target) = editorError {
                    return target == "MyLib"
                }
                return false
            }
        }
    }

    // MARK: - Clean manifests still work

    @Suite("no false positives")
    struct NoFalsePositiveTests {

        @Test("clean manifest succeeds for listDependencyIdentities")
        func listDependencyIdentities() throws {
            let editor = try ManifestEditor.parse(source: cleanManifest)
            let identities = try editor.listDependencyIdentities()
            #expect(identities == ["alamofire"])
        }

        @Test("clean manifest succeeds for listNonTestTargets")
        func listNonTestTargets() throws {
            let editor = try ManifestEditor.parse(source: cleanManifest)
            let targets = try editor.listNonTestTargets()
            #expect(targets == ["MyLib"])
        }

        @Test("clean manifest succeeds for addingDependency")
        func addingDependency() throws {
            let editor = try ManifestEditor.parse(source: cleanManifest)
            let newEditor = try editor.addingDependency(
                url: "https://github.com/Quick/Nimble.git",
                requirement: .from("13.0.0")
            )
            #expect(newEditor.serialize().contains("Nimble"))
        }

        @Test("clean manifest succeeds for removingPackageCompletely")
        func removingPackageCompletely() throws {
            let editor = try ManifestEditor.parse(source: cleanManifest)
            let result = try editor.removingPackageCompletely(identity: "alamofire")
            #expect(!result.editor.serialize().contains("Alamofire"))
            #expect(result.affectedTargets == ["MyLib"])
        }
    }

    // MARK: - Error messages

    @Suite("error descriptions")
    struct ErrorDescriptionTests {

        @Test("conditionalDependencies error mentions #if")
        func conditionalDependenciesMessage() {
            let error = ManifestEditor.Error.conditionalDependencies
            #expect(error.description.contains("#if"))
            #expect(error.description.contains("dependencies"))
        }

        @Test("conditionalTargets error mentions #if")
        func conditionalTargetsMessage() {
            let error = ManifestEditor.Error.conditionalTargets
            #expect(error.description.contains("#if"))
            #expect(error.description.contains("targets"))
        }

        @Test("conditionalTargetDependencies error mentions #if and target name")
        func conditionalTargetDependenciesMessage() {
            let error = ManifestEditor.Error.conditionalTargetDependencies(target: "MyLib")
            #expect(error.description.contains("#if"))
            #expect(error.description.contains("MyLib"))
        }
    }
}