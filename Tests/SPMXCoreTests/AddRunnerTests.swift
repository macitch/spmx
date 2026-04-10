/*
 *  File: AddRunnerTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

// MARK: - Fixtures

/// Minimal manifest with one library target and one existing dependency.
private let singleTargetManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyApp",
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
            ]
        ),
        .testTarget(
            name: "MyAppTests",
            dependencies: ["MyApp"]
        ),
    ]
)
"""

/// Multi-target manifest (library + executable + test).
private let multiTargetManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Multi",
    dependencies: [],
    targets: [
        .target(name: "MultiKit"),
        .executableTarget(name: "multi-cli"),
        .testTarget(name: "MultiKitTests"),
    ]
)
"""

/// Bare manifest with no dependencies or targets.
private let bareManifest = """
// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "Bare")
"""

// MARK: - Call tracker

/// Actor-based flag so `@Sendable` closures can record whether they were called
/// without violating strict concurrency. Matches the `FetchCounter` pattern in
/// `PackageListResolverTests`.
private actor CallTracker {
    private(set) var called = false
    func markCalled() { called = true }
}

// MARK: - Fakes

/// Canned metadata for a single-library-product package (Alamofire shape).
private let singleLibraryMetadata = ManifestFetcher.Metadata(
    packageName: "swift-snapshot-testing",
    products: [
        .init(name: "SnapshotTesting", kind: .library),
    ]
)

/// Canned metadata for a multi-library-product package (swift-collections shape).
private let multiLibraryMetadata = ManifestFetcher.Metadata(
    packageName: "swift-collections",
    products: [
        .init(name: "Collections", kind: .library),
        .init(name: "DequeModule", kind: .library),
        .init(name: "OrderedCollections", kind: .library),
    ]
)

/// Canned metadata for a package with dynamic products (empty — e.g. swift-collections
/// whose products array is built via a variable `let _products = targets.compactMap { ... }`).
private let dynamicProductsMetadata = ManifestFetcher.Metadata(
    packageName: "swift-collections",
    products: []
)

/// Canned metadata with no library products.
private let noLibraryMetadata = ManifestFetcher.Metadata(
    packageName: "swift-format",
    products: [
        .init(name: "swift-format", kind: .executable),
        .init(name: "SwiftFormatPlugin", kind: .plugin),
    ]
)

/// Stage a temporary directory containing a Package.swift with the given source.
/// Returns the directory URL.
private func stageManifest(_ source: String) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
        .appendingPathComponent("spmx-add-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(source.utf8).write(to: dir.appendingPathComponent("Package.swift"))
    return dir
}

/// Read the staged Package.swift back as a string.
private func readManifest(at dir: URL) throws -> String {
    try String(contentsOf: dir.appendingPathComponent("Package.swift"), encoding: .utf8)
}

/// Build an AddRunner with fully canned dependencies.
private func makeRunner(
    resolvedURL: String = "https://github.com/pointfreeco/swift-snapshot-testing",
    metadata: ManifestFetcher.Metadata = singleLibraryMetadata,
    latestVersion: Semver? = Semver("1.15.0")
) -> AddRunner {
    AddRunner(
        resolveURL: { _, _ in resolvedURL },
        fetchMetadata: { _ in metadata },
        fetchLatestVersion: { _ in latestVersion }
    )
}

// MARK: - Happy path

@Suite("AddRunner")
struct AddRunnerTests {

    @Test("happy path: resolves name, auto-picks product and target, writes manifest")
    func happyPath() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner()
        let output = try await runner.run(options: .init(
            package: "swift-snapshot-testing",
            path: dir.path
        ))

        #expect(output.resolvedURL == "https://github.com/pointfreeco/swift-snapshot-testing")
        #expect(output.packageName == "swift-snapshot-testing")
        #expect(output.productName == "SnapshotTesting")
        #expect(output.targetName == "MyApp")
        #expect(output.version.contains("1.15.0"))
        #expect(output.wroteChanges == true)

        // Verify the file was actually written.
        let written = try readManifest(at: dir)
        #expect(written.contains("swift-snapshot-testing"))
        #expect(written.contains("SnapshotTesting"))
    }

    @Test("dry-run computes the change but does not write")
    func dryRun() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner()
        let output = try await runner.run(options: .init(
            package: "swift-snapshot-testing",
            path: dir.path,
            dryRun: true
        ))

        #expect(output.wroteChanges == false)
        #expect(output.rendered.contains("[dry-run]"))

        // File should be unchanged.
        let contents = try readManifest(at: dir)
        #expect(!contents.contains("swift-snapshot-testing"))
    }

    @Test("explicit --url bypasses name resolution")
    func explicitURL() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = CallTracker()
        let runner = AddRunner(
            resolveURL: { _, _ in
                await tracker.markCalled()
                return "should not be called"
            },
            fetchMetadata: { _ in singleLibraryMetadata },
            fetchLatestVersion: { _ in Semver("1.0.0") }
        )
        let output = try await runner.run(options: .init(
            package: "snapshot-testing",
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            path: dir.path
        ))

        #expect(await !tracker.called)
        #expect(output.resolvedURL == "https://github.com/pointfreeco/swift-snapshot-testing")
    }

    @Test("URL-looking package argument bypasses name resolution")
    func urlAsPackageArg() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = CallTracker()
        let runner = AddRunner(
            resolveURL: { _, _ in
                await tracker.markCalled()
                return "should not be called"
            },
            fetchMetadata: { _ in singleLibraryMetadata },
            fetchLatestVersion: { _ in Semver("1.0.0") }
        )
        let output = try await runner.run(options: .init(
            package: "https://github.com/pointfreeco/swift-snapshot-testing",
            path: dir.path
        ))

        #expect(await !tracker.called)
        #expect(output.resolvedURL == "https://github.com/pointfreeco/swift-snapshot-testing")
    }

    // MARK: - Version resolution

    @Test("explicit --from overrides auto-detection")
    func explicitFrom() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = CallTracker()
        let runner = AddRunner(
            resolveURL: { _, _ in "https://github.com/pointfreeco/swift-snapshot-testing" },
            fetchMetadata: { _ in singleLibraryMetadata },
            fetchLatestVersion: { _ in
                await tracker.markCalled()
                return Semver("99.0.0")
            }
        )
        let output = try await runner.run(options: .init(
            package: "swift-snapshot-testing",
            from: "1.12.0",
            path: dir.path
        ))

        #expect(await !tracker.called)
        #expect(output.version.contains("1.12.0"))
    }

    @Test("explicit --exact uses exact version pinning")
    func explicitExact() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner()
        let output = try await runner.run(options: .init(
            package: "swift-snapshot-testing",
            exact: "1.14.2",
            path: dir.path
        ))

        #expect(output.version.contains("exact"))
        #expect(output.version.contains("1.14.2"))
    }

    @Test("explicit --branch uses branch pinning")
    func explicitBranch() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner()
        let output = try await runner.run(options: .init(
            package: "swift-snapshot-testing",
            branch: "main",
            path: dir.path
        ))

        #expect(output.version.contains("branch"))
        #expect(output.version.contains("main"))
    }

    @Test("multiple version flags throw versionConflict")
    func conflictingVersionFlags() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner()
        do {
            _ = try await runner.run(options: .init(
                package: "swift-snapshot-testing",
                from: "1.0.0",
                exact: "1.0.0",
                path: dir.path
            ))
            Issue.record("expected versionConflict")
        } catch let err as AddRunner.Error {
            if case .versionConflict = err {
                // expected
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("no version tags throws noVersionTags")
    func noVersionTags() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = AddRunner(
            resolveURL: { _, _ in "https://github.com/example/x" },
            fetchMetadata: { _ in singleLibraryMetadata },
            fetchLatestVersion: { _ in nil }
        )

        do {
            _ = try await runner.run(options: .init(package: "x", path: dir.path))
            Issue.record("expected noVersionTags")
        } catch let err as AddRunner.Error {
            if case .noVersionTags = err {
                // expected
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - Product picking

    @Test("explicit --product overrides auto-pick")
    func explicitProduct() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(
            metadata: multiLibraryMetadata,
            latestVersion: Semver("1.0.0")
        )
        let output = try await runner.run(options: .init(
            package: "swift-collections",
            product: "DequeModule",
            path: dir.path
        ))

        #expect(output.productName == "DequeModule")
    }

    @Test("ambiguous products (multiple libraries) throws ambiguousProducts")
    func ambiguousProducts() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(
            metadata: multiLibraryMetadata,
            latestVersion: Semver("1.0.0")
        )

        do {
            _ = try await runner.run(options: .init(
                package: "swift-collections",
                path: dir.path
            ))
            Issue.record("expected ambiguousProducts")
        } catch let err as AddRunner.Error {
            if case .ambiguousProducts(_, let libs) = err {
                #expect(libs == ["Collections", "DequeModule", "OrderedCollections"])
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("no library products throws noLibraryProducts")
    func noLibraryProducts() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(
            metadata: noLibraryMetadata,
            latestVersion: Semver("1.0.0")
        )

        do {
            _ = try await runner.run(options: .init(
                package: "swift-format",
                path: dir.path
            ))
            Issue.record("expected noLibraryProducts")
        } catch let err as AddRunner.Error {
            if case .noLibraryProducts(_, let products) = err {
                #expect(products.contains("swift-format"))
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("explicit --product that doesn't exist throws productNotFound")
    func productNotFound() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner()

        do {
            _ = try await runner.run(options: .init(
                package: "swift-snapshot-testing",
                product: "NoSuchProduct",
                path: dir.path
            ))
            Issue.record("expected productNotFound")
        } catch let err as AddRunner.Error {
            if case .productNotFound(let name, _, _) = err {
                #expect(name == "NoSuchProduct")
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - Target picking

    @Test("explicit --target overrides auto-pick")
    func explicitTarget() async throws {
        let dir = try stageManifest(multiTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(latestVersion: Semver("1.0.0"))
        let output = try await runner.run(options: .init(
            package: "swift-snapshot-testing",
            target: "MultiKit",
            path: dir.path
        ))

        #expect(output.targetName == "MultiKit")
    }

    @Test("ambiguous targets (multiple non-test) throws ambiguousTargets")
    func ambiguousTargets() async throws {
        let dir = try stageManifest(multiTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(latestVersion: Semver("1.0.0"))

        do {
            _ = try await runner.run(options: .init(
                package: "swift-snapshot-testing",
                path: dir.path
            ))
            Issue.record("expected ambiguousTargets")
        } catch let err as AddRunner.Error {
            if case .ambiguousTargets(let targets) = err {
                #expect(targets.contains("MultiKit"))
                #expect(targets.contains("multi-cli"))
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - Duplicate detection

    @Test("adding an already-present package throws duplicatePackage early")
    func duplicatePackage() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Alamofire is already in the manifest.
        let metadataTracker = CallTracker()
        let versionTracker = CallTracker()
        let runner = AddRunner(
            resolveURL: { _, _ in "https://github.com/Alamofire/Alamofire.git" },
            fetchMetadata: { _ in
                await metadataTracker.markCalled()
                return singleLibraryMetadata
            },
            fetchLatestVersion: { _ in
                await versionTracker.markCalled()
                return Semver("5.9.0")
            }
        )

        do {
            _ = try await runner.run(options: .init(
                package: "alamofire",
                path: dir.path
            ))
            Issue.record("expected duplicatePackage")
        } catch let err as AddRunner.Error {
            if case .duplicatePackage(let id) = err {
                #expect(id == "alamofire")
            } else {
                Issue.record("wrong error: \(err)")
            }
        }

        // Neither metadata nor version fetch should have been called.
        #expect(await !metadataTracker.called, "fetchMetadata should not be called for a duplicate")
        #expect(await !versionTracker.called, "fetchLatestVersion should not be called for a duplicate")
    }

    // MARK: - Path errors

    @Test("nonexistent path throws pathDoesNotExist")
    func nonexistentPath() async throws {
        let runner = makeRunner()

        do {
            _ = try await runner.run(options: .init(
                package: "x",
                path: "/nonexistent/path/to/nowhere"
            ))
            Issue.record("expected pathDoesNotExist")
        } catch let err as AddRunner.Error {
            if case .pathDoesNotExist = err {
                // expected
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("directory without Package.swift throws noManifest")
    func noManifest() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-add-empty-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner()

        do {
            _ = try await runner.run(options: .init(
                package: "x",
                path: dir.path
            ))
            Issue.record("expected noManifest")
        } catch let err as AddRunner.Error {
            if case .noManifest = err {
                // expected
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - Rendering

    @Test("renderSummary includes all key fields")
    func renderSummary() {
        let rendered = AddRunner.renderSummary(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            packageName: "swift-snapshot-testing",
            productName: "SnapshotTesting",
            targetName: "MyApp",
            version: "from: \"1.15.0\"",
            dryRun: false
        )

        #expect(rendered.contains("Adding: swift-snapshot-testing"))
        #expect(rendered.contains("1.15.0"))
        #expect(rendered.contains("SnapshotTesting"))
        #expect(rendered.contains("MyApp"))
        #expect(!rendered.contains("[dry-run]"))
    }

    @Test("renderSummary dry-run includes footer")
    func renderSummaryDryRun() {
        let rendered = AddRunner.renderSummary(
            url: "https://example.com/x",
            packageName: "X",
            productName: "X",
            targetName: "Y",
            version: "from: \"1.0.0\"",
            dryRun: true
        )

        #expect(rendered.contains("[dry-run] no files written"))
    }

    // MARK: - looksLikeURL

    // MARK: - Dynamic products

    @Test("empty products without --product throws dynamicProducts")
    func dynamicProductsNoExplicit() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(metadata: dynamicProductsMetadata)
        do {
            _ = try await runner.run(options: .init(
                package: "swift-collections",
                url: nil,
                from: "1.0.0",
                exact: nil,
                branch: nil,
                revision: nil,
                product: nil,
                target: nil,
                path: dir.path,
                dryRun: true,
                refreshCatalog: false
            ))
            Issue.record("expected dynamicProducts error")
        } catch let err as AddRunner.Error {
            if case .dynamicProducts(let name) = err {
                #expect(name == "swift-collections")
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("empty products with explicit --product trusts user and succeeds")
    func dynamicProductsWithExplicit() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = makeRunner(metadata: dynamicProductsMetadata)
        let output = try await runner.run(options: .init(
            package: "swift-collections",
            url: nil,
            from: "1.0.0",
            exact: nil,
            branch: nil,
            revision: nil,
            product: "Collections",
            target: nil,
            path: dir.path,
            dryRun: false,
            refreshCatalog: false
        ))

        #expect(output.productName == "Collections")
        #expect(output.wroteChanges == true)
        // Verify the product dependency was actually wired in.
        let written = try readManifest(at: dir)
        #expect(written.contains("Collections"))
    }

    @Test("looksLikeURL detects HTTPS, SSH, and rejects bare names")
    func looksLikeURL() {
        #expect(AddRunner.looksLikeURL("https://github.com/x/y.git") == true)
        #expect(AddRunner.looksLikeURL("git@github.com:x/y.git") == true)
        #expect(AddRunner.looksLikeURL("ssh://git@github.com/x/y") == true)
        #expect(AddRunner.looksLikeURL("alamofire") == false)
        #expect(AddRunner.looksLikeURL("swift-syntax") == false)
    }

    // MARK: - Interactive chooser

    @Test("interactive chooser is called on ambiguous resolution")
    func interactiveChooserCalledOnAmbiguous() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let chosenURL = "https://github.com/pointfreeco/swift-snapshot-testing"
        let chooserCalled = CallTracker()

        let runner = AddRunner(
            resolveURL: { name, _ in
                // Simulate ambiguous resolution.
                throw PackageListResolver.Error.ambiguous(
                    query: name,
                    candidates: [
                        .init(identity: "swift-snapshot-testing", url: chosenURL),
                        .init(identity: "swift-snapshot-testing", url: "https://github.com/other/swift-snapshot-testing"),
                    ]
                )
            },
            fetchMetadata: { _ in singleLibraryMetadata },
            fetchLatestVersion: { _ in Semver("1.15.0") },
            interactiveChooser: { _, _ in
                await chooserCalled.markCalled()
                return chosenURL
            }
        )

        let output = try await runner.run(options: .init(
            package: "swift-snapshot-testing",
            path: dir.path
        ))

        let wasCalled = await chooserCalled.called
        #expect(wasCalled == true)
        #expect(output.resolvedURL == chosenURL)
    }

    @Test("ambiguous resolution without chooser throws resolveFailed")
    func ambiguousWithoutChooserThrows() async throws {
        let dir = try stageManifest(singleTargetManifest)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = AddRunner(
            resolveURL: { name, _ in
                throw PackageListResolver.Error.ambiguous(
                    query: name,
                    candidates: [
                        .init(identity: "core", url: "https://github.com/a/Core"),
                        .init(identity: "core", url: "https://github.com/b/Core"),
                    ]
                )
            },
            fetchMetadata: { _ in singleLibraryMetadata },
            fetchLatestVersion: { _ in Semver("1.0.0") }
            // No interactiveChooser — default nil.
        )

        await #expect(throws: AddRunner.Error.self) {
            _ = try await runner.run(options: .init(
                package: "core",
                path: dir.path
            ))
        }
    }
}