/*
 *  File: OutdatedRunnerTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("OutdatedRunner")
struct OutdatedRunnerTests {

    // MARK: - Fixture wiring

    /// Resolves the on-disk path of the v3 fixture so we can hand the runner a real
    /// directory containing a real `Package.resolved`.
    private func fixtureDirectory() throws -> URL {
        let url = try #require(
            Bundle.module.url(
                forResource: "Package.resolved.v3",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "v3 fixture missing"
        )
        // Stage the fixture into a temp dir as `Package.resolved` so the runner's locator
        // (which looks for that exact filename) finds it. We deliberately do not mutate
        // the bundle resource path itself.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: url,
            to: tmp.appendingPathComponent("Package.resolved")
        )
        return tmp
    }

    // MARK: - Happy path

    @Test("returns sorted rows for a real fixture using a fake fetcher")
    func happyPath() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.10.2")!),         // behind minor
                "swift-collections": .found(Semver("2.0.0")!),   // behind major
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            json: false,
            colorEnabled: false
        ))

        // Sorted alphabetically by identity
        #expect(output.rows.map(\.identity) == ["alamofire", "swift-collections"])
        #expect(output.rows[0].status == .behindMinorPatch)
        #expect(output.rows[1].status == .behindMajor)
        #expect(output.rendered.contains("alamofire"))
        #expect(output.rendered.contains("swift-collections"))
    }

    // MARK: - Filtering

    @Test("default filter hides up-to-date rows")
    func defaultHidesUpToDate() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.8.1")!),           // current — already at 5.8.1
                "swift-collections": .found(Semver("2.0.0")!),   // behind major
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: false,
            json: false,
            colorEnabled: false
        ))

        // Both rows still present in the data...
        #expect(output.rows.count == 2)
        // ...but only the behind-major one in the rendered table.
        #expect(!output.rendered.contains("alamofire"))
        #expect(output.rendered.contains("swift-collections"))
    }

    @Test("showAll surfaces every row including up-to-date ones")
    func showAllShowsEverything() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.8.1")!),           // exact match with fixture pin
                "swift-collections": .found(Semver("1.0.6")!),   // exact match with fixture pin
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            json: false,
            colorEnabled: false
        ))

        #expect(output.rendered.contains("alamofire"))
        #expect(output.rendered.contains("swift-collections"))
    }

    @Test("when nothing is behind and showAll is false, render the all-clear message")
    func allClearMessageWhenNothingBehind() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.8.1")!),           // exact match
                "swift-collections": .found(Semver("1.0.6")!),   // exact match
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: false,
            json: false,
            colorEnabled: false
        ))

        #expect(output.rendered.contains("up to date"))
    }

    // MARK: - JSON

    @Test("JSON output is valid, unfiltered, and contains all rows")
    func jsonOutputIsValid() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.8.1")!),           // up to date
                "swift-collections": .found(Semver("2.0.0")!),   // behind major
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: false,           // ignored for JSON
            json: true,
            colorEnabled: true        // ignored for JSON
        ))

        // No ANSI escapes in JSON.
        #expect(!output.rendered.contains("\u{001B}["))

        // Decodes back to two rows including the up-to-date one (JSON ignores filter).
        let data = try #require(output.rendered.data(using: .utf8))
        let decoded = try JSONDecoder().decode([OutdatedRow].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded.map(\.identity).sorted() == ["alamofire", "swift-collections"])
    }

    // MARK: - Error paths

    @Test("throws packageResolvedNotFound when the directory has no Package.resolved")
    func missingResolvedFile() async throws {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let runner = OutdatedRunner(fetcher: StubVersionFetcher(map: [:]))
        await #expect(throws: OutdatedRunner.Error.self) {
            _ = try await runner.run(options: .init(
                path: emptyDir.path,
                showAll: false,
                json: false,
                colorEnabled: false
            ))
        }
    }

    // MARK: - hasOutdated flag

    @Test("hasOutdated is true when any row is not up-to-date")
    func hasOutdatedTrue() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.8.1")!),           // up to date
                "swift-collections": .found(Semver("2.0.0")!),   // behind major
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: false,
            json: false,
            colorEnabled: false
        ))

        #expect(output.hasOutdated == true)
    }

    @Test("hasOutdated is false when everything is up-to-date")
    func hasOutdatedFalse() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.8.1")!),
                "swift-collections": .found(Semver("1.0.6")!),
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: false,
            json: false,
            colorEnabled: false
        ))

        #expect(output.hasOutdated == false)
    }

    // MARK: - --direct filtering

    /// Stages a directory with both Package.resolved and a minimal Package.swift that
    /// declares only alamofire as a direct dependency. swift-collections is in
    /// Package.resolved (transitive) but not in Package.swift.
    private func fixtureDirectoryWithManifest() throws -> URL {
        let dir = try fixtureDirectory()
        // Write a Package.swift that declares only alamofire.
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "TestApp",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.1"),
            ],
            targets: [
                .executableTarget(name: "TestApp"),
            ]
        )
        """
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("Package.swift"))
        return dir
    }

    @Test("--direct filters to only dependencies declared in Package.swift")
    func directFiltersToManifestDeps() async throws {
        let dir = try fixtureDirectoryWithManifest()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.10.2")!),
                "swift-collections": .found(Semver("2.0.0")!),
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            direct: true,
            json: false,
            colorEnabled: false
        ))

        // Only alamofire should appear — swift-collections is transitive.
        #expect(output.rows.count == 1)
        #expect(output.rows[0].identity == "alamofire")
    }

    @Test("--direct without Package.swift throws noManifest")
    func directWithoutManifestThrows() async throws {
        // Use the base fixture which has Package.resolved but no Package.swift.
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(fetcher: StubVersionFetcher(map: [:]))
        await #expect(throws: OutdatedRunner.Error.self) {
            _ = try await runner.run(options: .init(
                path: dir.path,
                showAll: false,
                direct: true,
                json: false,
                colorEnabled: false
            ))
        }
    }

    @Test("--direct with local .package(path:) deps includes them correctly")
    func directWithLocalPackage() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Manifest declares alamofire (remote) and a local package whose identity
        // happens to match swift-collections.
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "TestApp",
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.1"),
                .package(path: "../swift-collections"),
            ],
            targets: [
                .executableTarget(name: "TestApp"),
            ]
        )
        """
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("Package.swift"))

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.10.2")!),
                "swift-collections": .found(Semver("2.0.0")!),
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            direct: true,
            json: false,
            colorEnabled: false
        ))

        // Both should appear since both are declared in Package.swift.
        #expect(output.rows.count == 2)
        #expect(output.rows.map(\.identity).sorted() == ["alamofire", "swift-collections"])
    }

    // MARK: - --ignore filtering

    @Test("--ignore excludes matching packages from output")
    func ignoreExcludesPackages() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.10.2")!),
                "swift-collections": .found(Semver("2.0.0")!),
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            ignore: Set(["alamofire"]),
            json: false,
            colorEnabled: false
        ))

        // Only swift-collections should remain.
        #expect(output.rows.count == 1)
        #expect(output.rows[0].identity == "swift-collections")
    }

    @Test("--ignore is case-insensitive")
    func ignoreCaseInsensitive() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.10.2")!),
                "swift-collections": .found(Semver("2.0.0")!),
            ])
        )

        // Pass uppercase — should still match the lowercased identity.
        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            ignore: Set(["Alamofire"]),
            json: false,
            colorEnabled: false
        ))

        #expect(output.rows.count == 1)
        #expect(output.rows[0].identity == "swift-collections")
    }

    @Test("--ignore with non-matching identity has no effect")
    func ignoreNonMatchingIdentity() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.10.2")!),
                "swift-collections": .found(Semver("2.0.0")!),
            ])
        )

        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            ignore: Set(["nonexistent-package"]),
            json: false,
            colorEnabled: false
        ))

        #expect(output.rows.count == 2)
    }

    @Test("--ignore combined with --direct filters both ways")
    func ignoreAndDirectCombined() async throws {
        let dir = try fixtureDirectoryWithManifest()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = OutdatedRunner(
            fetcher: StubVersionFetcher(map: [
                "alamofire": .found(Semver("5.10.2")!),
                "swift-collections": .found(Semver("2.0.0")!),
            ])
        )

        // --direct filters to alamofire only, then --ignore removes it too.
        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            direct: true,
            ignore: Set(["alamofire"]),
            json: false,
            colorEnabled: false
        ))

        #expect(output.rows.isEmpty)
    }

    // MARK: - Error paths

    @Test("missing fetcher result for a pin surfaces as fetchFailed in the row")
    func missingFetcherResultBecomesFailedRow() async throws {
        let dir = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Stub returns no entries — every pin will be marked failed.
        let runner = OutdatedRunner(fetcher: StubVersionFetcher(map: [:]))
        let output = try await runner.run(options: .init(
            path: dir.path,
            showAll: true,
            json: false,
            colorEnabled: false
        ))

        #expect(output.rows.allSatisfy { $0.status == .unknown })
        #expect(output.rendered.contains("Notes:"))
    }
}

/// Sendable test double that hands back a fixed `[identity: VersionFetchResult]` map.
/// Pins not in the map produce no entry, which exercises the runner's "missing result" branch.
struct StubVersionFetcher: VersionFetching {
    let map: [String: VersionFetchResult]

    func latestVersions(
        for pins: [ResolvedFile.Pin]
    ) async -> [String: VersionFetchResult] {
        var out: [String: VersionFetchResult] = [:]
        for pin in pins where map[pin.identity] != nil {
            out[pin.identity] = map[pin.identity]
        }
        return out
    }
}