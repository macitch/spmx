/*
 *  File: ManifestEditorTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

// MARK: - Fixtures

/// Canonical single-library package: one `.target`, one `.testTarget`, two deps.
/// This is the shape most SPM libraries on GitHub actually have and the shape
/// `spmx add`/`remove` are primarily designed for.
private let canonicalManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyLib",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MyLib", targets: ["MyLib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MyLib",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
            ]
        ),
        .testTarget(
            name: "MyLibTests",
            dependencies: ["MyLib"]
        ),
    ]
)
"""

/// Multi-target package with an executable, a library, a test, and a macro.
/// Exercises the "auto-pick target fails because ambiguous" path.
private let multiTargetManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Multi",
    targets: [
        .executableTarget(name: "multicli"),
        .target(name: "MultiKit"),
        .macro(name: "MultiMacros"),
        .testTarget(name: "MultiKitTests"),
    ]
)
"""

/// No `dependencies:` argument and no `targets:` argument.
private let barePackageManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "Bare")
"""

/// Manifest where `dependencies:` is a variable, not an array literal.
/// spmx should refuse to touch this.
private let nonLiteralDepsManifest = """
// swift-tools-version: 5.9
import PackageDescription

let deps: [Package.Dependency] = [
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
]

let package = Package(
    name: "Sneaky",
    dependencies: deps,
    targets: [.target(name: "Sneaky")]
)
"""

/// Manifest where `targets:` is built by a helper function call.
private let nonLiteralTargetsManifest = """
// swift-tools-version: 5.9
import PackageDescription

func makeTargets() -> [Target] { [.target(name: "Sneaky")] }

let package = Package(
    name: "Sneaky",
    targets: makeTargets()
)
"""

/// Manifest that never initializes a top-level `package` binding.
private let noPackageInitManifest = """
// swift-tools-version: 5.9
import PackageDescription

let notPackage = "Package"
"""

/// Canonical manifest using an SSH-form git URL — must still hash to
/// `swift-collections` as the identity.
private let sshURLManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsingSSH",
    dependencies: [
        .package(url: "git@github.com:apple/swift-collections.git", from: "1.0.0"),
    ],
    targets: [.target(name: "UsingSSH")]
)
"""

/// Canonical manifest mixing a `.package(url:)` with a `.package(path:)` local dep.
/// `containsPackage` should ignore the local and still find the remote.
private let mixedLocalAndRemoteManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mixed",
    dependencies: [
        .package(path: "../SharedLib"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [.target(name: "Mixed")]
)
"""

// MARK: - listNonTestTargets

@Suite("ManifestEditor.listNonTestTargets")
struct ManifestEditorListNonTestTargetsTests {

    @Test("canonical manifest returns its single library target")
    func canonical() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(try editor.listNonTestTargets() == ["MyLib"])
    }

    @Test("multi-target manifest returns executable, target, and macro but not testTarget")
    func multiTarget() throws {
        let editor = try ManifestEditor.parse(source: multiTargetManifest)
        let names = try editor.listNonTestTargets()
        #expect(names == ["multicli", "MultiKit", "MultiMacros"])
    }

    @Test("bare Package(name:) with no targets argument returns empty array")
    func bare() throws {
        let editor = try ManifestEditor.parse(source: barePackageManifest)
        #expect(try editor.listNonTestTargets() == [])
    }

    @Test("targets built by a helper function call throws targetsNotArrayLiteral")
    func nonLiteralTargets() throws {
        let editor = try ManifestEditor.parse(source: nonLiteralTargetsManifest)
        #expect(throws: ManifestEditor.Error.targetsNotArrayLiteral) {
            _ = try editor.listNonTestTargets()
        }
    }

    @Test("no top-level Package init throws noPackageInit")
    func noPackageInit() throws {
        let editor = try ManifestEditor.parse(source: noPackageInitManifest)
        #expect(throws: ManifestEditor.Error.noPackageInit) {
            _ = try editor.listNonTestTargets()
        }
    }
}

// MARK: - containsPackage

@Suite("ManifestEditor.containsPackage")
struct ManifestEditorContainsPackageTests {

    @Test("finds existing package by lowercase identity (alamofire from .git URL)")
    func findsExisting() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(try editor.containsPackage(identity: "alamofire"))
    }

    @Test("identity match is case-insensitive against the caller's input")
    func caseInsensitive() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(try editor.containsPackage(identity: "Alamofire"))
        #expect(try editor.containsPackage(identity: "ALAMOFIRE"))
    }

    @Test("finds package whose URL has no .git suffix")
    func findsWithoutDotGit() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(try editor.containsPackage(identity: "swift-collections"))
    }

    @Test("returns false for a package not in the list")
    func notFound() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(try editor.containsPackage(identity: "nimble") == false)
    }

    @Test("SSH-form git URL resolves to the same identity as HTTPS form")
    func sshURL() throws {
        let editor = try ManifestEditor.parse(source: sshURLManifest)
        #expect(try editor.containsPackage(identity: "swift-collections"))
    }

    @Test("local .package(path:) entries are found by identity (directory name, lowercased)")
    func localPackageFound() throws {
        let editor = try ManifestEditor.parse(source: mixedLocalAndRemoteManifest)
        #expect(try editor.containsPackage(identity: "sharedlib") == true)
        #expect(try editor.containsPackage(identity: "alamofire"))
    }

    @Test("bare package with no dependencies argument returns false")
    func bareNoDeps() throws {
        let editor = try ManifestEditor.parse(source: barePackageManifest)
        #expect(try editor.containsPackage(identity: "alamofire") == false)
    }

    @Test("dependencies built from a variable throws dependenciesNotArrayLiteral")
    func nonLiteralDeps() throws {
        let editor = try ManifestEditor.parse(source: nonLiteralDepsManifest)
        #expect(throws: ManifestEditor.Error.dependenciesNotArrayLiteral) {
            _ = try editor.containsPackage(identity: "alamofire")
        }
    }

    @Test("no top-level Package init throws noPackageInit")
    func noPackageInit() throws {
        let editor = try ManifestEditor.parse(source: noPackageInitManifest)
        #expect(throws: ManifestEditor.Error.noPackageInit) {
            _ = try editor.containsPackage(identity: "alamofire")
        }
    }
}

// MARK: - addingDependency

@Suite("ManifestEditor.addingDependency")
struct ManifestEditorAddingDependencyTests {

    @Test("appending a new dep to an existing dependencies array preserves other deps and ends up in the serialized output")
    func appendToExisting() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
            .addingDependency(
                url: "https://github.com/kishikawakatsumi/KeychainAccess.git",
                requirement: .from("4.2.2")
            )
        let output = editor.serialize()

        // Old deps still present.
        #expect(output.contains("https://github.com/Alamofire/Alamofire.git"))
        #expect(output.contains("https://github.com/apple/swift-collections"))
        // New dep present.
        #expect(output.contains("https://github.com/kishikawakatsumi/KeychainAccess.git"))
        #expect(output.contains("from: \"4.2.2\""))

        // The result must still parse cleanly — regression guard against producing
        // broken Swift source.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("adding to a bare Package(name:) injects a full dependencies: argument")
    func insertIntoBare() throws {
        let editor = try ManifestEditor.parse(source: barePackageManifest)
            .addingDependency(
                url: "https://github.com/Alamofire/Alamofire.git",
                requirement: .from("5.8.0")
            )
        let output = editor.serialize()
        #expect(output.contains("dependencies:"))
        #expect(output.contains("Alamofire.git"))
        // Result parses.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("adding a duplicate throws duplicatePackage")
    func duplicate() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(throws: ManifestEditor.Error.duplicatePackage(identity: "alamofire")) {
            _ = try editor.addingDependency(
                url: "https://github.com/Alamofire/Alamofire.git",
                requirement: .from("5.9.0")
            )
        }
    }

    @Test("adding to a non-literal dependencies: throws dependenciesNotArrayLiteral")
    func nonLiteralDeps() throws {
        let editor = try ManifestEditor.parse(source: nonLiteralDepsManifest)
        #expect(throws: ManifestEditor.Error.dependenciesNotArrayLiteral) {
            _ = try editor.addingDependency(
                url: "https://github.com/nonexistent/Package.git",
                requirement: .from("1.0.0")
            )
        }
    }

    @Test("different version requirement shapes render the expected source")
    func requirementShapes() throws {
        let base = try ManifestEditor.parse(source: barePackageManifest)

        let fromOut = try base.addingDependency(
            url: "https://github.com/a/b.git", requirement: .from("1.0.0")
        ).serialize()
        #expect(fromOut.contains("from: \"1.0.0\""))

        let exactOut = try base.addingDependency(
            url: "https://github.com/a/b.git", requirement: .exact("1.2.3")
        ).serialize()
        #expect(exactOut.contains("exact: \"1.2.3\""))

        let branchOut = try base.addingDependency(
            url: "https://github.com/a/b.git", requirement: .branch("main")
        ).serialize()
        #expect(branchOut.contains("branch: \"main\""))

        let revOut = try base.addingDependency(
            url: "https://github.com/a/b.git", requirement: .revision("abc123")
        ).serialize()
        #expect(revOut.contains("revision: \"abc123\""))

        let minorOut = try base.addingDependency(
            url: "https://github.com/a/b.git", requirement: .upToNextMinor("1.2.0")
        ).serialize()
        #expect(minorOut.contains(".upToNextMinor(from: \"1.2.0\")"))
    }
}

// MARK: - removingDependency

@Suite("ManifestEditor.removingDependency")
struct ManifestEditorRemovingDependencyTests {

    @Test("removing an existing dep drops it from the serialized output")
    func removesExisting() throws {
        let output = try ManifestEditor.parse(source: canonicalManifest)
            .removingDependency(identity: "alamofire")
            .serialize()

        #expect(!output.contains("Alamofire.git"))
        // Other deps untouched.
        #expect(output.contains("swift-collections"))
        // Result parses.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("identity match is case-insensitive")
    func caseInsensitive() throws {
        let output = try ManifestEditor.parse(source: canonicalManifest)
            .removingDependency(identity: "Alamofire")
            .serialize()
        #expect(!output.contains("Alamofire.git"))
    }

    @Test("removing a nonexistent package throws packageNotFound")
    func notFound() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(throws: ManifestEditor.Error.packageNotFound(identity: "nimble")) {
            _ = try editor.removingDependency(identity: "nimble")
        }
    }

    @Test("removing from a bare package (no dependencies:) throws packageNotFound")
    func bareThrows() throws {
        let editor = try ManifestEditor.parse(source: barePackageManifest)
        #expect(throws: ManifestEditor.Error.packageNotFound(identity: "alamofire")) {
            _ = try editor.removingDependency(identity: "alamofire")
        }
    }

    @Test("removing from a non-literal dependencies: throws dependenciesNotArrayLiteral")
    func nonLiteralDeps() throws {
        let editor = try ManifestEditor.parse(source: nonLiteralDepsManifest)
        #expect(throws: ManifestEditor.Error.dependenciesNotArrayLiteral) {
            _ = try editor.removingDependency(identity: "alamofire")
        }
    }
}

// MARK: - removingPackageCompletely

@Suite("ManifestEditor.removingPackageCompletely")
struct ManifestEditorRemovingPackageCompletelyTests {

    @Test("removes top-level dep AND every target product reference in one atomic op")
    func atomic() throws {
        // Manifest where Alamofire is wired into both the library target AND its
        // test target. After removing completely, both should be swept.
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "MyLib",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
                .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
            ],
            targets: [
                .target(
                    name: "MyLib",
                    dependencies: [
                        .product(name: "Alamofire", package: "Alamofire"),
                        .product(name: "Collections", package: "swift-collections"),
                    ]
                ),
                .testTarget(
                    name: "MyLibTests",
                    dependencies: [
                        "MyLib",
                        .product(name: "Alamofire", package: "Alamofire"),
                    ]
                ),
            ]
        )
        """
        let removal = try ManifestEditor.parse(source: src)
            .removingPackageCompletely(identity: "alamofire")
        let output = removal.editor.serialize()

        // Top-level gone.
        #expect(!output.contains("Alamofire.git"))
        // Both target references gone.
        #expect(!output.contains(".product(name: \"Alamofire\""))
        // Other dep and its product reference preserved.
        #expect(output.contains("swift-collections"))
        #expect(output.contains(".product(name: \"Collections\", package: \"swift-collections\")"))
        // The MyLib string reference in the test target's deps is untouched.
        #expect(output.contains("\"MyLib\""))
        // affectedTargets lists both targets in source order.
        #expect(removal.affectedTargets == ["MyLib", "MyLibTests"])
        // Still valid Swift.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("package not present anywhere throws packageNotFound without mutating anything")
    func notFound() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(throws: ManifestEditor.Error.packageNotFound(identity: "nimble")) {
            _ = try editor.removingPackageCompletely(identity: "nimble")
        }
    }

    @Test("non-literal deps in ANY target refuses the whole operation, even if that target has no reference")
    func conservativeRefusal() throws {
        // Two targets. The first (MyLib) has a proper literal deps array referencing
        // Alamofire. The second (Unrelated) has non-literal deps built by a helper.
        // Even though Unrelated doesn't obviously reference Alamofire, the conservative
        // rule says: refuse the whole op because we can't statically know.
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        func helperDeps() -> [Target.Dependency] { [] }

        let package = Package(
            name: "Mixed",
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
                .target(
                    name: "Unrelated",
                    dependencies: helperDeps()
                ),
            ]
        )
        """
        let editor = try ManifestEditor.parse(source: src)
        do {
            _ = try editor.removingPackageCompletely(identity: "alamofire")
            Issue.record("expected targetDependenciesNotArrayLiteral, got success")
        } catch let err as ManifestEditor.Error {
            switch err {
            case .targetDependenciesNotArrayLiteral(let target):
                #expect(target == "Unrelated")
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("top-level dependencies: being non-literal throws dependenciesNotArrayLiteral")
    func topLevelNonLiteral() throws {
        let editor = try ManifestEditor.parse(source: nonLiteralDepsManifest)
        #expect(throws: ManifestEditor.Error.dependenciesNotArrayLiteral) {
            _ = try editor.removingPackageCompletely(identity: "alamofire")
        }
    }

    @Test("package wired only into test target (not main) is still removed from test target")
    func testTargetOnly() throws {
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "TestOnly",
            dependencies: [
                .package(url: "https://github.com/Quick/Nimble.git", from: "13.0.0"),
            ],
            targets: [
                .target(name: "TestOnly"),
                .testTarget(
                    name: "TestOnlyTests",
                    dependencies: [
                        "TestOnly",
                        .product(name: "Nimble", package: "Nimble"),
                    ]
                ),
            ]
        )
        """
        let removal = try ManifestEditor.parse(source: src)
            .removingPackageCompletely(identity: "nimble")
        let output = removal.editor.serialize()

        #expect(!output.contains("Nimble.git"))
        #expect(!output.contains(".product(name: \"Nimble\""))
        #expect(output.contains("\"TestOnly\""))
        #expect(removal.affectedTargets == ["TestOnlyTests"])
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("bare targets with no dependencies: arg are skipped without error")
    func bareTargetsIgnored() throws {
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Bare",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
            ],
            targets: [
                .target(name: "Bare"),
                .target(
                    name: "WithDep",
                    dependencies: [.product(name: "Alamofire", package: "Alamofire")]
                ),
            ]
        )
        """
        let removal = try ManifestEditor.parse(source: src)
            .removingPackageCompletely(identity: "alamofire")
        let output = removal.editor.serialize()

        #expect(!output.contains("Alamofire.git"))
        #expect(!output.contains(".product(name: \"Alamofire\""))
        // Bare target unchanged.
        #expect(output.contains(".target(name: \"Bare\")"))
        // Only WithDep was affected; Bare has no dependencies to sweep.
        #expect(removal.affectedTargets == ["WithDep"])
        _ = try ManifestEditor.parse(source: output)
    }

    // MARK: - Comment preservation

    /// Case A: a leading line comment on its own line directly above a `.package(...)`
    /// element. Our hypothesis: SwiftSyntax attaches the comment as leading trivia to
    /// the element, so `.filter` drops both together. This is the semantically correct
    /// outcome — the comment describes the package, so removing the package removes
    /// the comment.
    @Test("leading line comment above a package element is swept with it")
    func leadingCommentSweptWithElement() throws {
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Commented",
            dependencies: [
                // Networking library, used for HTTP requests
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
                .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
            ],
            targets: [
                .target(name: "Commented"),
            ]
        )
        """
        let output = try ManifestEditor.parse(source: src)
            .removingPackageCompletely(identity: "alamofire")
            .editor.serialize()

        // The package line is gone.
        #expect(!output.contains("Alamofire.git"))
        // And so is its comment — the comment described the package, it goes with it.
        #expect(!output.contains("// Networking library"))
        // Neighbor preserved.
        #expect(output.contains("swift-collections"))
        // Still valid Swift.
        _ = try ManifestEditor.parse(source: output)
    }

    /// Case B: a trailing line comment on the *same* line as `.package(...)`. This
    /// should also be trailing trivia of the element's last token (or of the trailing
    /// comma), which means `.filter` again drops it with the element.
    @Test("trailing same-line comment on a package element is swept with it")
    func trailingCommentSweptWithElement() throws {
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Commented",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"), // pin for HTTP
                .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
            ],
            targets: [
                .target(name: "Commented"),
            ]
        )
        """
        let output = try ManifestEditor.parse(source: src)
            .removingPackageCompletely(identity: "alamofire")
            .editor.serialize()

        #expect(!output.contains("Alamofire.git"))
        // Critical: the trailing comment must NOT end up orphaned on the swift-collections line.
        #expect(!output.contains("// pin for HTTP"))
        #expect(output.contains("swift-collections"))
        _ = try ManifestEditor.parse(source: output)
    }

    /// Case C: a standalone comment floating between two packages, not obviously
    /// attached to either. This is the interesting case — SwiftSyntax may attach it
    /// as leading trivia to the *following* element, which means removing the
    /// following element would sweep this comment away even though it semantically
    /// belonged to the one *above*. This test documents actual behavior so we know
    /// what to tell users in the README.
    ///
    /// What we can assert regardless: the output must still be valid Swift and
    /// SwiftPM-parseable. Whether the comment ends up attached to Alamofire or to
    /// swift-collections is observed behavior, not a correctness requirement for v0.1.
    @Test("standalone comment between two packages — document actual trivia attachment")
    func standaloneCommentBehavior() throws {
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Commented",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
                // --- Apple packages below ---
                .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
            ],
            targets: [
                .target(name: "Commented"),
            ]
        )
        """

        // Remove Alamofire. The section-header comment is between the two packages
        // and SwiftSyntax most likely attaches it as leading trivia of swift-collections,
        // so removing Alamofire should leave the comment intact above swift-collections.
        let removingTop = try ManifestEditor.parse(source: src)
            .removingPackageCompletely(identity: "alamofire")
            .editor.serialize()
        #expect(!removingTop.contains("Alamofire.git"))
        #expect(removingTop.contains("swift-collections"))
        // Hypothesis: comment survives because it's attached to swift-collections.
        #expect(removingTop.contains("--- Apple packages below ---"))
        _ = try ManifestEditor.parse(source: removingTop)

        // Now remove swift-collections instead. Under the same attachment hypothesis,
        // the comment goes with it — which may or may not be what the user wanted.
        // Documenting the behavior is the point of this test.
        let removingBottom = try ManifestEditor.parse(source: src)
            .removingPackageCompletely(identity: "swift-collections")
            .editor.serialize()
        #expect(!removingBottom.contains("swift-collections"))
        #expect(removingBottom.contains("Alamofire"))
        // Under the attachment hypothesis: removing swift-collections takes the
        // section header with it. If this assertion flips, we've learned that
        // SwiftSyntax attaches the comment differently and the README needs a note.
        #expect(!removingBottom.contains("--- Apple packages below ---"))
        _ = try ManifestEditor.parse(source: removingBottom)
    }
}

// MARK: - addingProductDependency

@Suite("ManifestEditor.addingProductDependency")
struct ManifestEditorAddingProductDependencyTests {

    @Test("appends a new .product to an existing target dependencies array")
    func appendToExisting() throws {
        let output = try ManifestEditor.parse(source: canonicalManifest)
            .addingProductDependency(
                productName: "Collections",
                package: "swift-collections",
                target: "MyLib"
            )
            .serialize()

        #expect(output.contains(".product(name: \"Collections\", package: \"swift-collections\")"))
        // Existing .product still present.
        #expect(output.contains(".product(name: \"Alamofire\", package: \"Alamofire\")"))
        // Result parses.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("injects a dependencies: array into a bare target that has none")
    func injectIntoBareTarget() throws {
        let output = try ManifestEditor.parse(source: multiTargetManifest)
            .addingProductDependency(
                productName: "Alamofire",
                package: "alamofire",
                target: "MultiKit"
            )
            .serialize()

        #expect(output.contains(".product(name: \"Alamofire\", package: \"alamofire\")"))
        // Result parses.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("adding a duplicate product to the same target throws duplicateProductDependency")
    func duplicate() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(throws: ManifestEditor.Error.duplicateProductDependency(
            productName: "Alamofire",
            target: "MyLib"
        )) {
            _ = try editor.addingProductDependency(
                productName: "Alamofire",
                package: "Alamofire",
                target: "MyLib"
            )
        }
    }

    @Test("target name that doesn't exist throws targetNotFound with the candidate list")
    func targetNotFound() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        do {
            _ = try editor.addingProductDependency(
                productName: "Alamofire",
                package: "Alamofire",
                target: "NonexistentTarget"
            )
            Issue.record("expected targetNotFound, got success")
        } catch let err as ManifestEditor.Error {
            switch err {
            case .targetNotFound(let name, let candidates):
                #expect(name == "NonexistentTarget")
                #expect(candidates.contains("MyLib"))
                #expect(candidates.contains("MyLibTests"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }
}

// MARK: - addingPackageWiredToTarget

@Suite("ManifestEditor.addingPackageWiredToTarget")
struct ManifestEditorAddingPackageWiredToTargetTests {

    @Test("happy path: adds top-level entry AND wires product into target in one call")
    func happyPath() throws {
        let output = try ManifestEditor.parse(source: canonicalManifest)
            .addingPackageWiredToTarget(
                url: "https://github.com/pointfreeco/swift-snapshot-testing",
                requirement: .from("1.15.0"),
                productName: "SnapshotTesting",
                packageIdentity: "swift-snapshot-testing",
                target: "MyLib"
            )
            .serialize()

        // Top-level dependencies got the new .package(url:, from:) line.
        #expect(output.contains(".package(url: \"https://github.com/pointfreeco/swift-snapshot-testing\", from: \"1.15.0\")"))
        // The target's dependencies array got the .product reference.
        #expect(output.contains(".product(name: \"SnapshotTesting\", package: \"swift-snapshot-testing\")"))
        // Prior .package entries are still there.
        #expect(output.contains("Alamofire"))
        #expect(output.contains("swift-collections"))
        // Prior .product wiring still there.
        #expect(output.contains(".product(name: \"Alamofire\", package: \"Alamofire\")"))
        // Result still parses.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("injects a dependencies: array into a bare target with no prior deps")
    func injectsIntoBareTarget() throws {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "MultiKit",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
            ],
            targets: [
                .target(name: "MultiKit"),
                .testTarget(name: "MultiKitTests", dependencies: ["MultiKit"]),
            ]
        )
        """
        let output = try ManifestEditor.parse(source: manifest)
            .addingPackageWiredToTarget(
                url: "https://github.com/apple/swift-collections",
                requirement: .from("1.0.0"),
                productName: "Collections",
                packageIdentity: "swift-collections",
                target: "MultiKit"
            )
            .serialize()

        #expect(output.contains(".package(url: \"https://github.com/apple/swift-collections\", from: \"1.0.0\")"))
        #expect(output.contains(".product(name: \"Collections\", package: \"swift-collections\")"))
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("pre-existing top-level package throws duplicatePackage and does NOT mutate target")
    func duplicateTopLevelPackageIsAtomic() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)

        #expect(throws: ManifestEditor.Error.duplicatePackage(identity: "alamofire")) {
            _ = try editor.addingPackageWiredToTarget(
                url: "https://github.com/Alamofire/Alamofire.git",
                requirement: .from("5.9.0"),
                productName: "Alamofire",
                packageIdentity: "Alamofire",
                target: "MyLibTests" // target that does NOT currently reference Alamofire
            )
        }

        // Original editor is untouched — the target that did not reference
        // Alamofire still doesn't reference it.
        let roundTripped = editor.serialize()
        // MyLibTests has `dependencies: ["MyLib"]` — no Alamofire product wiring.
        let myLibTestsChunk = roundTripped.range(of: "MyLibTests").flatMap { range -> Substring? in
            let tail = roundTripped[range.lowerBound...]
            return tail.prefix(200)
        }
        #expect(myLibTestsChunk != nil)
        if let chunk = myLibTestsChunk {
            #expect(!chunk.contains("Alamofire"))
        }
    }

    @Test("nonexistent target throws targetNotFound and leaves no observable state")
    func nonexistentTargetIsAtomic() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)

        do {
            _ = try editor.addingPackageWiredToTarget(
                url: "https://github.com/pointfreeco/swift-snapshot-testing",
                requirement: .from("1.15.0"),
                productName: "SnapshotTesting",
                packageIdentity: "swift-snapshot-testing",
                target: "NoSuchTarget"
            )
            Issue.record("expected targetNotFound")
        } catch let err as ManifestEditor.Error {
            if case .targetNotFound(let name, _) = err {
                #expect(name == "NoSuchTarget")
            } else {
                Issue.record("wrong error: \(err)")
            }
        }

        // Original editor is still clean: no swift-snapshot-testing anywhere.
        let output = editor.serialize()
        #expect(!output.contains("swift-snapshot-testing"))
    }

    @Test("duplicate product wiring throws duplicateProductDependency")
    func duplicateProduct() throws {
        // Add Alamofire's same product to the same target that already has it.
        // The top-level duplicate is what fires first here — useful baseline.
        // Then do a genuinely new package whose product wiring is the duplicate.
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "X",
            dependencies: [],
            targets: [
                .target(
                    name: "X",
                    dependencies: [
                        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                    ]
                ),
            ]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)

        #expect(throws: ManifestEditor.Error.duplicateProductDependency(
            productName: "SnapshotTesting",
            target: "X"
        )) {
            _ = try editor.addingPackageWiredToTarget(
                url: "https://github.com/pointfreeco/swift-snapshot-testing",
                requirement: .from("1.15.0"),
                productName: "SnapshotTesting",
                packageIdentity: "swift-snapshot-testing",
                target: "X"
            )
        }
    }

    @Test("version requirement variants (.from / .exact / .branch) round-trip correctly")
    func versionRequirementVariants() throws {
        let base = try ManifestEditor.parse(source: canonicalManifest)

        let fromOut = try base.addingPackageWiredToTarget(
            url: "https://example.com/a.git",
            requirement: .from("1.2.3"),
            productName: "A",
            packageIdentity: "a",
            target: "MyLib"
        ).serialize()
        #expect(fromOut.contains(".package(url: \"https://example.com/a.git\", from: \"1.2.3\")"))

        let exactOut = try base.addingPackageWiredToTarget(
            url: "https://example.com/b.git",
            requirement: .exact("2.0.0"),
            productName: "B",
            packageIdentity: "b",
            target: "MyLib"
        ).serialize()
        #expect(exactOut.contains("exact: \"2.0.0\""))

        let branchOut = try base.addingPackageWiredToTarget(
            url: "https://example.com/c.git",
            requirement: .branch("main"),
            productName: "C",
            packageIdentity: "c",
            target: "MyLib"
        ).serialize()
        #expect(branchOut.contains("branch: \"main\""))
    }
}

// MARK: - removingProductDependency

@Suite("ManifestEditor.removingProductDependency")
struct ManifestEditorRemovingProductDependencyTests {

    @Test("removes an existing .product from the target's dependencies")
    func removeExisting() throws {
        let output = try ManifestEditor.parse(source: canonicalManifest)
            .removingProductDependency(
                productName: "Alamofire",
                package: "Alamofire",
                target: "MyLib"
            )
            .serialize()

        #expect(!output.contains(".product(name: \"Alamofire\""))
        // Result parses.
        _ = try ManifestEditor.parse(source: output)
    }

    @Test("removing a product not wired to the target throws productDependencyNotFound")
    func notFound() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(throws: ManifestEditor.Error.productDependencyNotFound(
            productName: "NotThere",
            target: "MyLib"
        )) {
            _ = try editor.removingProductDependency(
                productName: "NotThere",
                package: "nothere",
                target: "MyLib"
            )
        }
    }

    @Test("removing from a target that has no dependencies: argument throws productDependencyNotFound")
    func bareTarget() throws {
        let editor = try ManifestEditor.parse(source: multiTargetManifest)
        #expect(throws: ManifestEditor.Error.productDependencyNotFound(
            productName: "Alamofire",
            target: "MultiKit"
        )) {
            _ = try editor.removingProductDependency(
                productName: "Alamofire",
                package: "alamofire",
                target: "MultiKit"
            )
        }
    }

    @Test("same product name from a different package is NOT removed — package disambiguation")
    func packageDisambiguation() throws {
        // Build a manifest where two .product entries share the name "Core" but
        // from different packages. Removing one must leave the other intact.
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Disambig",
            dependencies: [
                .package(url: "https://github.com/foo/alpha.git", from: "1.0.0"),
                .package(url: "https://github.com/bar/beta.git", from: "1.0.0"),
            ],
            targets: [
                .target(
                    name: "Disambig",
                    dependencies: [
                        .product(name: "Core", package: "alpha"),
                        .product(name: "Core", package: "beta"),
                    ]
                ),
            ]
        )
        """
        let output = try ManifestEditor.parse(source: src)
            .removingProductDependency(
                productName: "Core",
                package: "alpha",
                target: "Disambig"
            )
            .serialize()

        #expect(output.contains(".product(name: \"Core\", package: \"beta\")"))
        #expect(!output.contains(".product(name: \"Core\", package: \"alpha\")"))
    }
}

// MARK: - Load / parse / serialize round-trip

// MARK: - listProducts

@Suite("ManifestEditor.listProducts")
struct ManifestEditorListProductsTests {

    @Test("canonical manifest returns its single library product")
    func canonical() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        let products = try editor.listProducts()
        #expect(products.count == 1)
        #expect(products[0].name == "MyLib")
        #expect(products[0].kind == .library)
    }

    @Test("multi-product manifest with mixed kinds classifies each correctly")
    func mixedKinds() throws {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Mixed",
            products: [
                .library(name: "MixedLib", targets: ["MixedLib"]),
                .executable(name: "mixedcli", targets: ["MixedCLI"]),
                .plugin(name: "mixedplugin", targets: ["MixedPlugin"]),
            ],
            targets: [
                .target(name: "MixedLib"),
                .executableTarget(name: "MixedCLI"),
                .plugin(name: "MixedPlugin", capability: .buildTool()),
            ]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let products = try editor.listProducts()
        #expect(products.count == 3)
        #expect(products[0].name == "MixedLib")
        #expect(products[0].kind == .library)
        #expect(products[1].name == "mixedcli")
        #expect(products[1].kind == .executable)
        #expect(products[2].name == "mixedplugin")
        #expect(products[2].kind == .plugin)
    }

    @Test("bare Package(name:) with no products argument returns empty array")
    func bare() throws {
        let editor = try ManifestEditor.parse(source: barePackageManifest)
        #expect(try editor.listProducts().isEmpty)
    }

    @Test("non-literal products (variable reference) returns empty array, not error")
    func nonLiteralProducts() throws {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let _products: [Product] = [
            .library(name: "Sneaky", targets: ["Sneaky"]),
        ]

        let package = Package(
            name: "Sneaky",
            products: _products,
            targets: [
                .target(name: "Sneaky"),
            ]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let products = try editor.listProducts()
        #expect(products.isEmpty, "non-literal products should return empty, not throw")
    }

    @Test("no top-level Package init throws noPackageInit")
    func noPackageInit() throws {
        let editor = try ManifestEditor.parse(source: noPackageInitManifest)
        #expect(throws: ManifestEditor.Error.noPackageInit) {
            _ = try editor.listProducts()
        }
    }

    @Test("products with unknown kind are classified as .other")
    func unknownKind() throws {
        // A hypothetical future product kind — listProducts should not crash,
        // just classify as .other.
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Future",
            products: [
                .library(name: "Lib", targets: ["Lib"]),
                .snippet(name: "MySnippet", targets: ["Snip"]),
            ],
            targets: [
                .target(name: "Lib"),
                .target(name: "Snip"),
            ]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let products = try editor.listProducts()
        #expect(products.count == 2)
        #expect(products[0].kind == .library)
        #expect(products[1].kind == .other)
    }
}

@Suite("ManifestEditor.listDependencyIdentities")
struct ManifestEditorListDependencyIdentitiesTests {

    @Test("extracts identities from remote URL dependencies")
    func remoteURLDeps() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids.sorted() == ["alamofire", "swift-collections"])
    }

    @Test("extracts identity from local path dependency")
    func localPathDep() throws {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(path: "../my-local-lib"),
            ],
            targets: [.executableTarget(name: "App")]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids == ["my-local-lib"])
    }

    @Test("mixes remote and local dependencies")
    func mixedDeps() throws {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
                .package(path: "../swift-collections"),
            ],
            targets: [.executableTarget(name: "App")]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids.sorted() == ["alamofire", "swift-collections"])
    }

    @Test("returns empty when no dependencies array")
    func noDeps() throws {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "App",
            targets: [.executableTarget(name: "App")]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids.isEmpty)
    }

    @Test("returns empty for empty dependencies array")
    func emptyDeps() throws {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [],
            targets: [.executableTarget(name: "App")]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids.isEmpty)
    }

    @Test("strips .git suffix from URL for identity")
    func stripsGitSuffix() throws {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
            ],
            targets: [.executableTarget(name: "App")]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids == ["alamofire"])
    }

    @Test("local path identity is lowercased")
    func localPathLowercased() throws {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(path: "../MyLocalLib"),
            ],
            targets: [.executableTarget(name: "App")]
        )
        """
        let editor = try ManifestEditor.parse(source: manifest)
        let ids = try editor.listDependencyIdentities()
        #expect(ids == ["mylocallib"])
    }
}

@Suite("ManifestEditor.load+serialize round-trip")
struct ManifestEditorRoundTripTests {

    @Test("serialize on an unmodified parse returns the original source byte-for-byte")
    func roundTripPreservesExact() throws {
        let editor = try ManifestEditor.parse(source: canonicalManifest)
        #expect(editor.serialize() == canonicalManifest)
    }

    @Test("load on a nonexistent path throws fileNotFound")
    func loadMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-manifest-\(UUID().uuidString)/Package.swift")
        #expect(throws: ManifestEditor.Error.self) {
            _ = try ManifestEditor.load(from: url)
        }
    }

    @Test("load reads a real file and serializes back identically")
    func loadReadsRealFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("spmx-manifest-load-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let url = dir.appendingPathComponent("Package.swift")
        try canonicalManifest.write(to: url, atomically: true, encoding: .utf8)

        let editor = try ManifestEditor.load(from: url)
        #expect(editor.serialize() == canonicalManifest)
    }
}