/*
 *  File: SearchRunnerTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("SearchRunner")
struct SearchRunnerTests {

    // MARK: - Fixture resolver

    /// A PackageListResolver pre-seeded with a small catalog so we don't hit the network.
    private func fixtureResolver() -> PackageListResolver {
        let urls: [String] = [
            "https://github.com/Alamofire/Alamofire.git",
            "https://github.com/apple/swift-collections.git",
            "https://github.com/apple/swift-crypto.git",
            "https://github.com/Quick/Nimble.git",
            "https://github.com/ReactiveX/RxSwift.git",
        ]
        let data = try! JSONEncoder().encode(urls)
        let cacheFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-search-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("packages.json")
        try? FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! data.write(to: cacheFile)
        return PackageListResolver(cacheFile: cacheFile) { _ in
            fatalError("Should not fetch when cache exists")
        }
    }

    // MARK: - Happy path

    @Test("returns matches sorted alphabetically by identity")
    func sortedResults() async throws {
        let runner = SearchRunner(resolver: fixtureResolver())
        let output = try await runner.run(options: .init(
            query: "swift",
            json: false,
            limit: 20,
            refresh: false
        ))

        // swift-collections and swift-crypto should both match.
        #expect(output.matches.count >= 2)
        // Verify sorted order.
        let identities = output.matches.map(\.identity)
        #expect(identities == identities.sorted())
    }

    @Test("single match returns totalCount of 1")
    func singleMatch() async throws {
        let runner = SearchRunner(resolver: fixtureResolver())
        let output = try await runner.run(options: .init(
            query: "alamofire",
            json: false,
            limit: 20,
            refresh: false
        ))

        #expect(output.totalCount == 1)
        #expect(output.matches.count == 1)
        #expect(output.matches[0].identity == "alamofire")
        #expect(output.rendered.contains("1 package matching"))
    }

    // MARK: - Limiting

    @Test("limit truncates results and shows hint")
    func limitTruncatesResults() async throws {
        let runner = SearchRunner(resolver: fixtureResolver())
        let output = try await runner.run(options: .init(
            query: "swift",
            json: false,
            limit: 1,
            refresh: false
        ))

        #expect(output.matches.count == 1)
        #expect(output.totalCount >= 2)
        #expect(output.rendered.contains("--limit 0"))
    }

    @Test("limit 0 means unlimited")
    func unlimitedResults() async throws {
        let runner = SearchRunner(resolver: fixtureResolver())
        let output = try await runner.run(options: .init(
            query: "swift",
            json: false,
            limit: 0,
            refresh: false
        ))

        #expect(output.matches.count == output.totalCount)
        #expect(!output.rendered.contains("--limit 0"))
    }

    // MARK: - JSON

    @Test("JSON output is valid and always untruncated")
    func jsonOutputValid() async throws {
        let runner = SearchRunner(resolver: fixtureResolver())
        let output = try await runner.run(options: .init(
            query: "swift",
            json: true,
            limit: 1,    // limit is ignored for JSON
            refresh: false
        ))

        // JSON should be valid.
        let data = try #require(output.rendered.data(using: .utf8))
        struct Row: Decodable { let identity: String; let url: String }
        let decoded = try JSONDecoder().decode([Row].self, from: data)

        // JSON is always untruncated regardless of limit.
        #expect(decoded.count == output.totalCount)
    }

    // MARK: - Rendering

    @Test("table output contains header and separator")
    func tableHasHeaderAndSeparator() async throws {
        let runner = SearchRunner(resolver: fixtureResolver())
        let output = try await runner.run(options: .init(
            query: "alamofire",
            json: false,
            limit: 20,
            refresh: false
        ))

        #expect(output.rendered.contains("Package"))
        #expect(output.rendered.contains("URL"))
        #expect(output.rendered.contains("─"))
    }

    // MARK: - Error paths

    @Test("throws noResults for a term with zero matches")
    func noResultsError() async throws {
        let runner = SearchRunner(resolver: fixtureResolver())
        await #expect(throws: SearchRunner.Error.self) {
            _ = try await runner.run(options: .init(
                query: "zzzzzzzzzzz_nonexistent",
                json: false,
                limit: 20,
                refresh: false
            ))
        }
    }
}