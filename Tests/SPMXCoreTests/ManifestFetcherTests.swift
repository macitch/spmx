/*
 *  File: ManifestFetcherTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("ManifestFetcher")
struct ManifestFetcherTests {

    // MARK: - Clone-simulating fake runner

    /// A fake `ProcessRunning` that simulates `git clone` by creating a Package.swift
    /// in the target directory. This is necessary because the new `fetch()` reads the
    /// cloned Package.swift from disk (SwiftSyntax parse) rather than parsing JSON
    /// stdout from `swift package dump-package`.
    ///
    /// When the first argument is `"git"` and the arguments contain `"clone"`, the
    /// runner writes `manifestSource` to `<lastArg>/Package.swift`. For any other
    /// command, it returns the canned exitCode/stderr.
    actor CloningFakeRunner: ProcessRunning {
        private let manifestSource: String
        private let cloneExitCode: Int32
        private let cloneStderr: String
        private(set) var invocations: [[String]] = []

        init(
            manifestSource: String,
            cloneExitCode: Int32 = 0,
            cloneStderr: String = ""
        ) {
            self.manifestSource = manifestSource
            self.cloneExitCode = cloneExitCode
            self.cloneStderr = cloneStderr
        }

        nonisolated func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
            try await self.dispatch(arguments: arguments)
        }

        private func dispatch(arguments: [String]) throws -> ProcessResult {
            invocations.append(arguments)
            guard arguments.first == "git", arguments.contains("clone") else {
                throw FakeError.unexpectedCommand(arguments)
            }

            guard cloneExitCode == 0 else {
                return ProcessResult(exitCode: cloneExitCode, stdout: "", stderr: cloneStderr)
            }

            // The last argument to `git clone ... <targetDir>` is the target directory.
            guard let targetDir = arguments.last else {
                throw FakeError.unexpectedCommand(arguments)
            }

            // Write the fixture Package.swift into the clone target.
            let fm = FileManager.default
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            try Data(manifestSource.utf8)
                .write(to: URL(fileURLWithPath: targetDir).appendingPathComponent("Package.swift"))

            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        func callCount() -> Int { invocations.count }
        func allInvocations() -> [[String]] { invocations }
    }

    enum FakeError: Swift.Error, CustomStringConvertible {
        case unexpectedCommand([String])
        var description: String {
            switch self {
            case .unexpectedCommand(let args): return "unexpected command: \(args)"
            }
        }
    }

    // MARK: - Package.swift fixtures (real Swift source, not JSON)

    private static let alamofireManifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Alamofire",
        products: [
            .library(name: "Alamofire", targets: ["Alamofire"]),
        ],
        targets: [
            .target(name: "Alamofire"),
        ]
    )
    """

    private static let multiProductManifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "swift-collections",
        products: [
            .library(name: "Collections", targets: ["Collections"]),
            .library(name: "DequeModule", targets: ["DequeModule"]),
            .library(name: "OrderedCollections", targets: ["OrderedCollections"]),
        ],
        targets: [
            .target(name: "Collections"),
            .target(name: "DequeModule"),
            .target(name: "OrderedCollections"),
        ]
    )
    """

    private static let mixedKindsManifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "mixed",
        products: [
            .library(name: "Lib", targets: ["Lib"]),
            .executable(name: "mytool", targets: ["Tool"]),
            .plugin(name: "myplugin", targets: ["Plugin"]),
        ],
        targets: [
            .target(name: "Lib"),
            .executableTarget(name: "Tool"),
            .plugin(name: "Plugin", capability: .buildTool()),
        ]
    )
    """

    private static let noProductsManifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "empty",
        targets: [
            .target(name: "Empty"),
        ]
    )
    """

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-mf-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Happy path

    @Test("fetch returns metadata after clone + SwiftSyntax parse")
    func happyPath() async throws {
        let runner = CloningFakeRunner(manifestSource: Self.alamofireManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())

        let meta = try await fetcher.fetch(url: "https://github.com/Alamofire/Alamofire.git")

        #expect(meta.packageName == "Alamofire")
        #expect(meta.products.count == 1)
        #expect(meta.products[0].name == "Alamofire")
        #expect(meta.products[0].kind == .library)
        #expect(await runner.callCount() == 1) // only git clone, no dump-package
    }

    @Test("fetch uses git clone --depth 1 with the provided URL")
    func cloneArgumentsAreShallow() async throws {
        let runner = CloningFakeRunner(manifestSource: Self.alamofireManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())
        _ = try await fetcher.fetch(url: "https://github.com/Alamofire/Alamofire.git")

        let calls = await runner.allInvocations()
        let clone = calls.first { $0.contains("clone") }
        #expect(clone != nil)
        #expect(clone?.contains("--depth") == true)
        #expect(clone?.contains("1") == true)
        #expect(clone?.contains("https://github.com/Alamofire/Alamofire.git") == true)
    }

    @Test("no subprocess call to swift package dump-package")
    func noDumpPackageCall() async throws {
        let runner = CloningFakeRunner(manifestSource: Self.alamofireManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())
        _ = try await fetcher.fetch(url: "https://example.com/x.git")

        let calls = await runner.allInvocations()
        let swiftCalls = calls.filter { $0.first == "swift" }
        #expect(swiftCalls.isEmpty, "should not invoke swift subprocess at all")
    }

    @Test("multi-product package preserves order and names")
    func multiProductPackage() async throws {
        let runner = CloningFakeRunner(manifestSource: Self.multiProductManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())
        let meta = try await fetcher.fetch(url: "https://github.com/apple/swift-collections.git")

        #expect(meta.packageName == "swift-collections")
        #expect(meta.products.map(\.name) == ["Collections", "DequeModule", "OrderedCollections"])
        #expect(meta.products.allSatisfy { $0.kind == .library })
    }

    @Test("product kinds are classified correctly from SwiftSyntax AST")
    func productKindClassification() async throws {
        let runner = CloningFakeRunner(manifestSource: Self.mixedKindsManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())
        let meta = try await fetcher.fetch(url: "https://example.com/mixed.git")

        let byName = Dictionary(uniqueKeysWithValues: meta.products.map { ($0.name, $0.kind) })
        #expect(byName["Lib"] == .library)
        #expect(byName["mytool"] == .executable)
        #expect(byName["myplugin"] == .plugin)
    }

    @Test("a package with no products returns empty products array")
    func noProducts() async throws {
        let runner = CloningFakeRunner(manifestSource: Self.noProductsManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())
        let meta = try await fetcher.fetch(url: "https://example.com/empty.git")

        #expect(meta.packageName == "empty")
        #expect(meta.products.isEmpty)
    }

    // MARK: - Error paths

    @Test("non-zero exit from git clone throws cloneFailed with stderr")
    func cloneNonZeroExit() async throws {
        let runner = CloningFakeRunner(
            manifestSource: "",
            cloneExitCode: 128,
            cloneStderr: "fatal: repository 'https://example.com/ghost.git' not found\n"
        )
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())

        do {
            _ = try await fetcher.fetch(url: "https://example.com/ghost.git")
            Issue.record("expected cloneFailed")
        } catch let err as ManifestFetcher.Error {
            switch err {
            case .cloneFailed(let url, let stderr):
                #expect(url == "https://example.com/ghost.git")
                #expect(stderr.contains("repository"))
                #expect(stderr.contains("not found"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("thrown error from git runner becomes cloneFailed")
    func cloneThrowBecomesCloneFailed() async throws {
        struct Boom: Swift.Error, LocalizedError {
            var errorDescription: String? { "simulated clone explosion" }
        }
        let runner = AlwaysThrowingRunner(error: Boom())
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())

        do {
            _ = try await fetcher.fetch(url: "https://example.com/x.git")
            Issue.record("expected cloneFailed")
        } catch let err as ManifestFetcher.Error {
            switch err {
            case .cloneFailed(_, let stderr):
                #expect(stderr.contains("simulated clone explosion"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("malformed Package.swift in clone throws decodeFailed")
    func malformedManifest() async throws {
        // A manifest with no Package(...) call — SwiftSyntax parses it but
        // extractPackageName fails.
        let badManifest = """
        // swift-tools-version: 5.9
        import PackageDescription
        let notPackage = "oops"
        """
        let runner = CloningFakeRunner(manifestSource: badManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: tempDir())

        do {
            _ = try await fetcher.fetch(url: "https://example.com/x.git")
            Issue.record("expected decodeFailed")
        } catch let err as ManifestFetcher.Error {
            if case .decodeFailed = err {
                // expected
            } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - Cleanup

    @Test("tmp clone dir is removed after a successful fetch")
    func cleanupAfterSuccess() async throws {
        let parent = tempDir()
        let runner = CloningFakeRunner(manifestSource: Self.alamofireManifest)
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: parent)
        _ = try await fetcher.fetch(url: "https://example.com/x.git")

        let fm = FileManager.default
        if fm.fileExists(atPath: parent.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
            let leaked = contents.filter { $0.hasPrefix("spmx-fetch-") }
            #expect(leaked.isEmpty, "expected no leaked tmp dirs, got: \(leaked)")
        }
    }

    @Test("tmp clone dir is removed even after a failure")
    func cleanupAfterFailure() async throws {
        let parent = tempDir()
        let runner = CloningFakeRunner(
            manifestSource: "",
            cloneExitCode: 128,
            cloneStderr: "nope"
        )
        let fetcher = ManifestFetcher(runner: runner, temporaryDirectory: parent)

        _ = try? await fetcher.fetch(url: "https://example.com/x.git")

        let fm = FileManager.default
        if fm.fileExists(atPath: parent.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
            let leaked = contents.filter { $0.hasPrefix("spmx-fetch-") }
            #expect(leaked.isEmpty)
        }
    }

    // MARK: - decode (pure JSON path, kept for backwards compat)

    @Suite("ManifestFetcher.decode")
    struct DecodeTests {

        @Test("decode accepts a missing products field")
        func missingProductsField() throws {
            let data = Data(#"{"name":"x"}"#.utf8)
            let meta = try ManifestFetcher.decode(data)
            #expect(meta.packageName == "x")
            #expect(meta.products.isEmpty)
        }

        @Test("decode classifies library/executable/plugin/other")
        func classifiesAllKinds() throws {
            let json = #"""
            {
              "name": "k",
              "products": [
                { "name": "L", "type": { "library": ["automatic"] }, "targets": [] },
                { "name": "E", "type": { "executable": null },       "targets": [] },
                { "name": "P", "type": { "plugin": null },           "targets": [] },
                { "name": "O", "type": { "future": null },           "targets": [] }
              ]
            }
            """#
            let meta = try ManifestFetcher.decode(Data(json.utf8))
            let kinds = meta.products.map(\.kind)
            #expect(kinds == [.library, .executable, .plugin, .other])
        }

        @Test("decode throws decodeFailed on missing name")
        func missingName() {
            let data = Data(#"{"products":[]}"#.utf8)
            #expect(throws: ManifestFetcher.Error.self) {
                try ManifestFetcher.decode(data)
            }
        }

        @Test("decode throws decodeFailed on non-JSON input")
        func invalidJSON() {
            let data = Data("not json".utf8)
            #expect(throws: ManifestFetcher.Error.self) {
                try ManifestFetcher.decode(data)
            }
        }
    }
}

// MARK: - Shared helpers

/// A trivial `ProcessRunning` that always throws — used to simulate a runner-level failure
/// (e.g. the underlying Process.run() itself blowing up, not a non-zero exit).
///
/// `@unchecked Sendable` because the stored `any Swift.Error` isn't statically Sendable, but
/// this is a test-only double whose error is set at init and never mutated.
private struct AlwaysThrowingRunner: ProcessRunning, @unchecked Sendable {
    let error: Swift.Error
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        throw error
    }
}