/*
 *  File: RemoveRunnerTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("RemoveRunner")
struct RemoveRunnerTests {

    // MARK: - Fixture staging

    /// Stage a tmp directory containing a single `Package.swift` with the given
    /// source. Returns the directory URL so callers can point `--path` at it.
    /// Cleans itself up via the caller's `defer`.
    private func stageManifest(_ source: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-remove-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(source.utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        return root
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Canonical fixture

    /// A manifest with Alamofire wired into both the library target and its
    /// test target. The workhorse fixture for end-to-end tests.
    private let canonicalManifest = """
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

    // MARK: - Identity normalization

    @Suite("normalizeIdentity")
    struct NormalizeIdentityTests {

        @Test("bare name is lowercased")
        func bareName() {
            #expect(RemoveRunner.normalizeIdentity("Alamofire") == "alamofire")
            #expect(RemoveRunner.normalizeIdentity("swift-collections") == "swift-collections")
        }

        @Test("https URL is normalized per SPM rule")
        func httpsURL() {
            #expect(RemoveRunner.normalizeIdentity("https://github.com/Alamofire/Alamofire.git") == "alamofire")
            #expect(RemoveRunner.normalizeIdentity("https://github.com/apple/swift-collections") == "swift-collections")
        }

        @Test("git@ SSH URL is normalized per SPM rule")
        func sshURL() {
            #expect(RemoveRunner.normalizeIdentity("git@github.com:Alamofire/Alamofire.git") == "alamofire")
        }

        @Test("whitespace is trimmed before normalization")
        func trimmed() {
            #expect(RemoveRunner.normalizeIdentity("  Alamofire  ") == "alamofire")
        }
    }

    // MARK: - Happy path

    @Test("removes package from top-level and both targets, writes to disk")
    func atomicWrite() async throws {
        let root = try stageManifest(canonicalManifest)
        defer { cleanup(root) }

        let output = try await RemoveRunner().run(options: .init(
            path: root.path,
            package: "Alamofire",
            dryRun: false
        ))

        #expect(output.identity == "alamofire")
        #expect(output.affectedTargets == ["MyLib", "MyLibTests"])
        #expect(output.wroteChanges == true)

        // File actually changed on disk.
        let onDisk = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(!onDisk.contains("Alamofire.git"))
        #expect(!onDisk.contains(".product(name: \"Alamofire\""))
        #expect(onDisk.contains("swift-collections"))
    }

    @Test("accepts a URL argument and normalizes it")
    func urlArgument() async throws {
        let root = try stageManifest(canonicalManifest)
        defer { cleanup(root) }

        let output = try await RemoveRunner().run(options: .init(
            path: root.path,
            package: "https://github.com/Alamofire/Alamofire.git",
            dryRun: false
        ))

        #expect(output.identity == "alamofire")
        #expect(output.affectedTargets == ["MyLib", "MyLibTests"])
    }

    @Test("package only at top level reports empty affectedTargets")
    func topLevelOnly() async throws {
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Unused",
            dependencies: [
                .package(url: "https://github.com/Quick/Nimble.git", from: "13.0.0"),
            ],
            targets: [
                .target(name: "Unused"),
            ]
        )
        """
        let root = try stageManifest(src)
        defer { cleanup(root) }

        let output = try await RemoveRunner().run(options: .init(
            path: root.path,
            package: "nimble",
            dryRun: false
        ))

        #expect(output.affectedTargets.isEmpty)
        // Summary should NOT mention "Unwired from targets:".
        #expect(!output.rendered.contains("Unwired from targets"))
        #expect(output.rendered.contains("Removing: nimble"))
    }

    // MARK: - Dry run

    @Test("dry run does not write to disk but reports would-be changes")
    func dryRun() async throws {
        let root = try stageManifest(canonicalManifest)
        defer { cleanup(root) }

        let original = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        let output = try await RemoveRunner().run(options: .init(
            path: root.path,
            package: "Alamofire",
            dryRun: true
        ))

        #expect(output.wroteChanges == false)
        #expect(output.affectedTargets == ["MyLib", "MyLibTests"])
        #expect(output.rendered.contains("[dry-run] no files written"))

        // File untouched.
        let after = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(after == original)
    }

    // MARK: - Path resolution

    @Test("nonexistent path throws pathDoesNotExist")
    func nonexistentPath() async throws {
        let bogus = "/tmp/spmx-nonexistent-\(UUID().uuidString)"
        do {
            _ = try await RemoveRunner().run(options: .init(
                path: bogus,
                package: "Alamofire",
                dryRun: false
            ))
            Issue.record("expected pathDoesNotExist")
        } catch let err as RemoveRunner.Error {
            switch err {
            case .pathDoesNotExist(let p):
                #expect(p == bogus)
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("empty directory throws noManifest")
    func emptyDirectory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-empty-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanup(root) }

        do {
            _ = try await RemoveRunner().run(options: .init(
                path: root.path,
                package: "Alamofire",
                dryRun: false
            ))
            Issue.record("expected noManifest")
        } catch let err as RemoveRunner.Error {
            switch err {
            case .noManifest:
                break
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("direct path to Package.swift is accepted")
    func directFilePath() async throws {
        let root = try stageManifest(canonicalManifest)
        defer { cleanup(root) }

        let manifestPath = root.appendingPathComponent("Package.swift").path
        let output = try await RemoveRunner().run(options: .init(
            path: manifestPath,
            package: "Alamofire",
            dryRun: false
        ))
        #expect(output.wroteChanges == true)
    }

    // MARK: - Error mapping

    @Test("missing package throws packageNotFound with normalized identity")
    func packageNotFound() async throws {
        let root = try stageManifest(canonicalManifest)
        defer { cleanup(root) }

        do {
            _ = try await RemoveRunner().run(options: .init(
                path: root.path,
                package: "Nimble",
                dryRun: false
            ))
            Issue.record("expected packageNotFound")
        } catch let err as RemoveRunner.Error {
            switch err {
            case .packageNotFound(let id):
                #expect(id == "nimble")
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("non-literal top-level deps throws topLevelDependenciesNotLiteral")
    func topLevelNonLiteral() async throws {
        let src = """
        // swift-tools-version: 5.9
        import PackageDescription

        func deps() -> [Package.Dependency] { [] }

        let package = Package(
            name: "Dynamic",
            dependencies: deps(),
            targets: [.target(name: "Dynamic")]
        )
        """
        let root = try stageManifest(src)
        defer { cleanup(root) }

        do {
            _ = try await RemoveRunner().run(options: .init(
                path: root.path,
                package: "Alamofire",
                dryRun: false
            ))
            Issue.record("expected topLevelDependenciesNotLiteral")
        } catch let err as RemoveRunner.Error {
            #expect(err == .topLevelDependenciesNotLiteral)
        }
    }

    @Test("non-literal target deps throws targetDependenciesNotLiteral with target name")
    func targetNonLiteral() async throws {
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
        let root = try stageManifest(src)
        defer { cleanup(root) }

        do {
            _ = try await RemoveRunner().run(options: .init(
                path: root.path,
                package: "Alamofire",
                dryRun: false
            ))
            Issue.record("expected targetDependenciesNotLiteral")
        } catch let err as RemoveRunner.Error {
            switch err {
            case .targetDependenciesNotLiteral(let target):
                #expect(target == "Unrelated")
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - Xcode project detection fallback

    @Test("finds Package.swift alongside .xcodeproj when path points at Xcode project dir")
    func xcodeProjectDetection() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-xcode-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanup(root) }

        // Create an .xcodeproj directory and a Package.swift alongside it.
        let xcodeproj = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
        try fm.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        // Write a minimal pbxproj so ProjectDetector recognizes it.
        try Data("{}".utf8).write(to: xcodeproj.appendingPathComponent("project.pbxproj"))

        try Data(canonicalManifest.utf8).write(to: root.appendingPathComponent("Package.swift"))

        let output = try await RemoveRunner().run(options: .init(
            path: root.path,
            package: "Alamofire",
            dryRun: true
        ))

        #expect(output.identity == "alamofire")
        #expect(output.affectedTargets == ["MyLib", "MyLibTests"])
    }

    // MARK: - Rendering

    @Suite("renderSummary")
    struct RenderSummaryTests {

        @Test("includes Unwired line when targets are affected")
        func withTargets() {
            let rendered = RemoveRunner.renderSummary(
                identity: "alamofire",
                affectedTargets: ["MyLib", "MyLibTests"],
                dryRun: false
            )
            #expect(rendered == """
            Removing: alamofire
            ✓ Removed from Package.swift dependencies
            ✓ Unwired from targets: MyLib, MyLibTests

            """)
        }

        @Test("omits Unwired line when no targets affected")
        func withoutTargets() {
            let rendered = RemoveRunner.renderSummary(
                identity: "nimble",
                affectedTargets: [],
                dryRun: false
            )
            #expect(rendered == """
            Removing: nimble
            ✓ Removed from Package.swift dependencies

            """)
        }

        @Test("dry run appends footer")
        func dryRunFooter() {
            let rendered = RemoveRunner.renderSummary(
                identity: "alamofire",
                affectedTargets: ["MyLib"],
                dryRun: true
            )
            #expect(rendered.contains("[dry-run] no files written"))
        }
    }
}