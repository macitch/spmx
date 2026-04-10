/*
 *  File: PackageListResolverTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("PackageListResolver")
struct PackageListResolverTests {

    // MARK: - Fixtures

    /// A tiny fixture catalog covering the cases we care about:
    ///   - `alamofire` — exact identity match case
    ///   - `swift-collections` — prefix match case for "collectio" / "swift-col"
    ///   - `nimble` — unique, for noMatch tests
    ///   - two packages both mapping to identity `core` for the duplicate-identity case
    ///   - two packages starting with `swift-c` for the ambiguous-prefix case
    private static let fixtureURLs: [String] = [
        "https://github.com/Alamofire/Alamofire.git",
        "https://github.com/apple/swift-collections.git",
        "https://github.com/apple/swift-crypto.git",
        "https://github.com/Quick/Nimble.git",
        "https://github.com/org-a/Core.git",
        "https://github.com/org-b/Core.git",
    ]

    private static func fixtureCatalogData() -> Data {
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(Self.fixtureURLs)
    }

    /// Stage a tmp cache file URL without creating it. Directory is created; file
    /// isn't. Lets each test decide whether to write content or not.
    private func tempCacheFile(_ fn: String = #function) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-plr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("packages.json", isDirectory: false)
    }

    /// A fetcher closure that counts invocations so tests can assert whether the
    /// cache was hit or the network was touched.
    private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    // MARK: - Resolution rule

    @Test("exact identity match wins over prefix matches")
    func exactMatchWins() async throws {
        let counter = FetchCounter()
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in
                counter.increment()
                return Self.fixtureCatalogData()
            }
        )
        let match = try await resolver.resolve(name: "alamofire")
        #expect(match.identity == "alamofire")
        #expect(match.url == "https://github.com/Alamofire/Alamofire.git")
        #expect(counter.count == 1)
    }

    @Test("exact match is case-insensitive")
    func exactMatchCaseInsensitive() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        let match = try await resolver.resolve(name: "Alamofire")
        #expect(match.identity == "alamofire")
    }

    @Test("unique prefix match wins when no exact match exists")
    func uniquePrefixMatch() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        // "swift-col" uniquely prefixes swift-collections.
        let match = try await resolver.resolve(name: "swift-col")
        #expect(match.identity == "swift-collections")
    }

    @Test("ambiguous prefix throws with all candidates")
    func ambiguousPrefix() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        // "swift-c" matches both swift-collections AND swift-crypto.
        do {
            _ = try await resolver.resolve(name: "swift-c")
            Issue.record("expected ambiguous error")
        } catch let err as PackageListResolver.Error {
            switch err {
            case .ambiguous(let query, let candidates):
                #expect(query == "swift-c")
                #expect(candidates.count == 2)
                let identities = candidates.map(\.identity).sorted()
                #expect(identities == ["swift-collections", "swift-crypto"])
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("two packages with the same identity produce ambiguous, not exact")
    func duplicateIdentityIsAmbiguous() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        // "core" is the identity for BOTH github.com/org-a/Core and github.com/org-b/Core.
        do {
            _ = try await resolver.resolve(name: "core")
            Issue.record("expected ambiguous error")
        } catch let err as PackageListResolver.Error {
            switch err {
            case .ambiguous(_, let candidates):
                #expect(candidates.count == 2)
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("no match throws noMatch with the original query")
    func noMatch() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        do {
            _ = try await resolver.resolve(name: "nonexistent-thing")
            Issue.record("expected noMatch")
        } catch let err as PackageListResolver.Error {
            #expect(err == .noMatch(query: "nonexistent-thing"))
        }
    }

    @Test("whitespace around the query is trimmed")
    func whitespaceTrimmed() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        let match = try await resolver.resolve(name: "  alamofire  ")
        #expect(match.identity == "alamofire")
    }

    // MARK: - Cache behavior

    @Test("second call hits the cache and does not re-fetch")
    func cacheHitOnSecondCall() async throws {
        let counter = FetchCounter()
        let cache = tempCacheFile()
        let resolver = PackageListResolver(
            cacheFile: cache,
            fetcher: { _ in
                counter.increment()
                return Self.fixtureCatalogData()
            }
        )
        _ = try await resolver.resolve(name: "alamofire")
        #expect(counter.count == 1)
        _ = try await resolver.resolve(name: "nimble")
        // Second call must not touch the fetcher.
        #expect(counter.count == 1)
    }

    @Test("expired cache triggers a re-fetch")
    func expiredCacheReFetches() async throws {
        let counter = FetchCounter()
        let cache = tempCacheFile()

        // Stage an "expired" cache: write the file, then pretend "now" is 2 days
        // later so the 24-hour TTL is exceeded.
        let pastDate = Date(timeIntervalSinceNow: -2 * 24 * 3600)
        try Self.fixtureCatalogData().write(to: cache, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: cache.path
        )

        let resolver = PackageListResolver(
            cacheFile: cache,
            fetcher: { _ in
                counter.increment()
                return Self.fixtureCatalogData()
            }
        )
        _ = try await resolver.resolve(name: "alamofire")
        #expect(counter.count == 1)  // expired → must re-fetch
    }

    @Test("--refresh bypasses a fresh cache")
    func refreshBypassesCache() async throws {
        let counter = FetchCounter()
        let cache = tempCacheFile()
        // Prewrite a fresh cache.
        try Self.fixtureCatalogData().write(to: cache, options: .atomic)

        let resolver = PackageListResolver(
            cacheFile: cache,
            fetcher: { _ in
                counter.increment()
                return Self.fixtureCatalogData()
            }
        )
        _ = try await resolver.resolve(name: "alamofire", refresh: true)
        #expect(counter.count == 1)
    }

    @Test("corrupt cache is silently re-fetched, not an error")
    func corruptCacheReFetches() async throws {
        let counter = FetchCounter()
        let cache = tempCacheFile()
        // Write garbage that isn't valid JSON.
        try Data("not a json array".utf8).write(to: cache, options: .atomic)

        let resolver = PackageListResolver(
            cacheFile: cache,
            fetcher: { _ in
                counter.increment()
                return Self.fixtureCatalogData()
            }
        )
        let match = try await resolver.resolve(name: "alamofire")
        #expect(match.identity == "alamofire")
        #expect(counter.count == 1)
    }

    @Test("cache is persisted after a successful fetch")
    func cacheWrittenAfterFetch() async throws {
        let cache = tempCacheFile()
        let resolver = PackageListResolver(
            cacheFile: cache,
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        _ = try await resolver.resolve(name: "alamofire")
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    // MARK: - Error paths

    @Test("network failure on first call (no cache) throws fetchFailed")
    func networkFailureNoCache() async throws {
        struct Boom: Swift.Error, LocalizedError {
            var errorDescription: String? { "simulated network down" }
        }
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in throw Boom() }
        )
        do {
            _ = try await resolver.resolve(name: "alamofire")
            Issue.record("expected fetchFailed")
        } catch let err as PackageListResolver.Error {
            switch err {
            case .fetchFailed(let msg):
                #expect(msg.contains("simulated network down"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("invalid JSON payload throws parseFailed")
    func invalidJSONParseFailed() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Data("definitely not json".utf8) }
        )
        do {
            _ = try await resolver.resolve(name: "alamofire")
            Issue.record("expected parseFailed")
        } catch let err as PackageListResolver.Error {
            switch err {
            case .parseFailed:
                break
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("network failure with a valid fresh cache uses the cache")
    func networkFailureWithFreshCacheSucceeds() async throws {
        struct Boom: Swift.Error {}
        let cache = tempCacheFile()
        try Self.fixtureCatalogData().write(to: cache, options: .atomic)

        let resolver = PackageListResolver(
            cacheFile: cache,
            fetcher: { _ in throw Boom() }
        )
        // Cache is fresh → fetcher never runs, resolution succeeds.
        let match = try await resolver.resolve(name: "alamofire")
        #expect(match.identity == "alamofire")
    }

    // MARK: - candidates(matching:)

    @Test("candidates returns all substring matches")
    func candidatesSubstring() async throws {
        let resolver = PackageListResolver(
            cacheFile: tempCacheFile(),
            fetcher: { _ in Self.fixtureCatalogData() }
        )
        let hits = try await resolver.candidates(matching: "swift")
        #expect(hits.count == 2)
        let identities = hits.map(\.identity).sorted()
        #expect(identities == ["swift-collections", "swift-crypto"])
    }

    // MARK: - parse

    @Suite("PackageListResolver.parse")
    struct ParseTests {

        @Test("parses a flat URL array into Match entries")
        func flatURLArray() throws {
            let data = try JSONEncoder().encode([
                "https://github.com/Alamofire/Alamofire.git",
                "https://github.com/apple/swift-collections.git",
            ])
            let matches = try PackageListResolver.parse(data)
            #expect(matches.count == 2)
            #expect(matches[0].identity == "alamofire")
            #expect(matches[1].identity == "swift-collections")
        }

        @Test("empty array parses to empty result")
        func emptyArray() throws {
            let data = try JSONEncoder().encode([String]())
            let matches = try PackageListResolver.parse(data)
            #expect(matches.isEmpty)
        }

        @Test("non-array JSON throws")
        func nonArray() throws {
            let data = Data(#"{"not": "an array"}"#.utf8)
            #expect(throws: (any Swift.Error).self) {
                try PackageListResolver.parse(data)
            }
        }
    }
}