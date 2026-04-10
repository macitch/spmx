/*
 *  File: VersionFetcherTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("VersionFetcher")
struct VersionFetcherTests {

    // MARK: - Tag parsing (pure)

    @Test("parses ls-remote output into tag names")
    func parsesLsRemoteOutput() {
        let output = """
        a1b2c3d\trefs/tags/1.0.0
        e4f5g6h\trefs/tags/v1.1.0
        i7j8k9l\trefs/tags/2.0.0-beta.1
        """
        let tags = GitVersionFetcher.parseTags(from: output)
        #expect(tags.count == 3)
        #expect(tags.contains("1.0.0"))
        #expect(tags.contains("v1.1.0"))
        #expect(tags.contains("2.0.0-beta.1"))
    }

    @Test("strips annotated-tag dereference suffix")
    func stripsDereferenceSuffix() {
        let output = """
        aaa\trefs/tags/1.0.0
        bbb\trefs/tags/1.0.0^{}
        """
        let tags = GitVersionFetcher.parseTags(from: output)
        #expect(tags == ["1.0.0"])
    }

    @Test("ignores non-tag refs and malformed lines")
    func ignoresNoise() {
        let output = """
        aaa\trefs/heads/main
        bbb\trefs/tags/1.0.0
        garbage line with no tab
        ccc\trefs/pull/42/head
        """
        let tags = GitVersionFetcher.parseTags(from: output)
        #expect(tags == ["1.0.0"])
    }

    // MARK: - End-to-end with FakeProcessRunner

    @Test("returns the latest stable tag for a remote pin")
    func returnsLatestStable() async {
        let fake = FakeProcessRunner(stdout: """
        aaa\trefs/tags/1.0.0
        bbb\trefs/tags/1.2.0
        ccc\trefs/tags/1.1.5
        ddd\trefs/tags/2.0.0-beta.1
        """)
        let fetcher = GitVersionFetcher(runner: fake, maxConcurrency: 4, cacheTTL: 0)
        let pin = makePin(identity: "alamofire", url: "https://github.com/Alamofire/Alamofire.git")

        let results = await fetcher.latestVersions(for: [pin])

        #expect(results.count == 1)
        #expect(results["alamofire"] == .found(Semver("1.2.0")!))
    }

    @Test("includePrereleases lets prerelease tags win")
    func includesPrereleasesWhenAsked() async {
        let fake = FakeProcessRunner(stdout: """
        aaa\trefs/tags/1.0.0
        bbb\trefs/tags/2.0.0-beta.1
        """)
        let fetcher = GitVersionFetcher(runner: fake, maxConcurrency: 4, includePrereleases: true, cacheTTL: 0)
        let pin = makePin(identity: "lib", url: "https://example.com/lib.git")

        let results = await fetcher.latestVersions(for: [pin])
        #expect(results["lib"] == .found(Semver("2.0.0-beta.1")!))
    }

    @Test("reports noVersionTags when nothing parses as semver")
    func reportsNoVersionTags() async {
        let fake = FakeProcessRunner(stdout: """
        aaa\trefs/tags/release-2024
        bbb\trefs/tags/nightly
        """)
        let fetcher = GitVersionFetcher(runner: fake, cacheTTL: 0)
        let pin = makePin(identity: "lib", url: "https://example.com/lib.git")

        let results = await fetcher.latestVersions(for: [pin])
        #expect(results["lib"] == .noVersionTags)
    }

    @Test("reports fetchFailed on non-zero exit")
    func reportsFetchFailed() async {
        let fake = FakeProcessRunner(
            exitCode: 128,
            stdout: "",
            stderr: "fatal: repository not found"
        )
        let fetcher = GitVersionFetcher(runner: fake, cacheTTL: 0)
        let pin = makePin(identity: "ghost", url: "https://example.com/ghost.git")

        let results = await fetcher.latestVersions(for: [pin])
        if case .fetchFailed(let msg) = results["ghost"] {
            #expect(msg.contains("repository not found"))
        } else {
            Issue.record("expected .fetchFailed, got \(String(describing: results["ghost"]))")
        }
    }

    @Test("skips local pins without shelling out")
    func skipsLocalPins() async {
        let fake = FakeProcessRunner(stdout: "")
        let fetcher = GitVersionFetcher(runner: fake, cacheTTL: 0)
        let pin = ResolvedFile.Pin(
            identity: "local-lib",
            kind: .localSourceControl,
            location: "/Users/me/local-lib",
            state: .init(revision: nil, version: "1.0.0", branch: nil)
        )

        let results = await fetcher.latestVersions(for: [pin])
        if case .skipped = results["local-lib"] {
            // ok
        } else {
            Issue.record("expected .skipped, got \(String(describing: results["local-lib"]))")
        }
        #expect(await fake.callCount == 0)
    }

    @Test("returns a result for every pin even at concurrency boundaries")
    func handlesMoreThanConcurrencyLimit() async {
        let fake = FakeProcessRunner(stdout: "aaa\trefs/tags/1.0.0")
        let fetcher = GitVersionFetcher(runner: fake, maxConcurrency: 3, cacheTTL: 0)

        let pins = (0..<10).map { i in
            makePin(identity: "lib\(i)", url: "https://example.com/lib\(i).git")
        }
        let results = await fetcher.latestVersions(for: pins)
        #expect(results.count == 10)
        for i in 0..<10 {
            #expect(results["lib\(i)"] == .found(Semver("1.0.0")!))
        }
    }

    // MARK: - Caching

    @Test("second call hits the cache and does not shell out")
    func cacheHitSkipsShellOut() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-vf-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let fake = FakeProcessRunner(stdout: "aaa\trefs/tags/1.0.0\nbbb\trefs/tags/2.0.0")
        let fetcher = GitVersionFetcher(
            runner: fake,
            cacheDirectory: cacheDir,
            cacheTTL: 60
        )
        let pin = makePin(identity: "lib", url: "https://example.com/lib.git")

        // First call: shells out.
        let r1 = await fetcher.latestVersions(for: [pin])
        #expect(r1["lib"] == .found(Semver("2.0.0")!))
        #expect(await fake.callCount == 1)

        // Second call: should hit cache, no shell out.
        let r2 = await fetcher.latestVersions(for: [pin])
        #expect(r2["lib"] == .found(Semver("2.0.0")!))
        #expect(await fake.callCount == 1) // still 1
    }

    @Test("expired cache triggers a re-fetch")
    func expiredCacheRefetches() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-vf-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let fake = FakeProcessRunner(stdout: "aaa\trefs/tags/1.0.0")

        // Use a tiny TTL and a now() that's always in the future.
        let fetcher = GitVersionFetcher(
            runner: fake,
            cacheDirectory: cacheDir,
            cacheTTL: 0.001,
            now: { Date().addingTimeInterval(10) }
        )
        let pin = makePin(identity: "lib", url: "https://example.com/lib.git")

        _ = await fetcher.latestVersions(for: [pin])
        _ = await fetcher.latestVersions(for: [pin])

        // Both calls should shell out because cache expires immediately.
        #expect(await fake.callCount == 2)
    }

    @Test("--refresh bypasses the cache")
    func refreshBypassesCache() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-vf-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let fake = FakeProcessRunner(stdout: "aaa\trefs/tags/1.0.0")
        let fetcher = GitVersionFetcher(
            runner: fake,
            cacheDirectory: cacheDir,
            cacheTTL: 3600,
            refresh: true
        )
        let pin = makePin(identity: "lib", url: "https://example.com/lib.git")

        _ = await fetcher.latestVersions(for: [pin])
        _ = await fetcher.latestVersions(for: [pin])

        // Both calls should shell out because refresh is forced.
        #expect(await fake.callCount == 2)
    }

    @Test("cache key is stable for the same URL")
    func cacheKeyStable() {
        let k1 = GitVersionFetcher.cacheKey(for: "https://github.com/Alamofire/Alamofire.git")
        let k2 = GitVersionFetcher.cacheKey(for: "https://github.com/Alamofire/Alamofire.git")
        #expect(k1 == k2)
        #expect(k1.count == 64) // SHA-256 hex
    }

    @Test("different URLs produce different cache keys")
    func cacheKeyDistinct() {
        let k1 = GitVersionFetcher.cacheKey(for: "https://github.com/Alamofire/Alamofire.git")
        let k2 = GitVersionFetcher.cacheKey(for: "https://github.com/apple/swift-nio.git")
        #expect(k1 != k2)
    }

    // MARK: - Progress callback

    @Test("onPinComplete fires once per pin with correct counts")
    func progressCallbackCounts() async {
        let fake = FakeProcessRunner(stdout: "aaa\trefs/tags/1.0.0")
        let collector = ProgressCollector()
        let fetcher = GitVersionFetcher(
            runner: fake,
            maxConcurrency: 2,
            cacheTTL: 0,
            onPinComplete: { completed, total in
                Task { await collector.record(completed: completed, total: total) }
            }
        )
        let pins = (0..<5).map { i in
            makePin(identity: "lib\(i)", url: "https://example.com/lib\(i).git")
        }
        _ = await fetcher.latestVersions(for: pins)

        // Give the Task wrappers a moment to flush.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let entries = await collector.entries
        #expect(entries.count == 5)
        // Every entry should have total == 5.
        #expect(entries.allSatisfy { $0.total == 5 })
        // Completed values should be 1...5 (in order, since drain loop is sequential).
        #expect(entries.map(\.completed) == [1, 2, 3, 4, 5])
    }

    @Test("onPinComplete is not called for empty pins")
    func progressCallbackNotCalledForEmpty() async {
        let collector = ProgressCollector()
        let fetcher = GitVersionFetcher(
            cacheTTL: 0,
            onPinComplete: { completed, total in
                Task { await collector.record(completed: completed, total: total) }
            }
        )
        _ = await fetcher.latestVersions(for: [])

        let entries = await collector.entries
        #expect(entries.isEmpty)
    }

    // MARK: - Helpers

    private func makePin(identity: String, url: String) -> ResolvedFile.Pin {
        ResolvedFile.Pin(
            identity: identity,
            kind: .remoteSourceControl,
            location: url,
            state: .init(revision: "abc1234567", version: "0.9.0", branch: nil)
        )
    }
}

/// Test double for `ProcessRunning`. Returns a fixed result and counts invocations.
///
/// Implemented as an `actor` so call counting is safe across the bounded `TaskGroup` without
/// reaching for `NSLock` (which Swift 6 marks unavailable from async contexts). Actors are
/// implicitly `Sendable`, so the `ProcessRunning: Sendable` requirement is satisfied for free.
actor FakeProcessRunner: ProcessRunning {
    private let result: ProcessResult
    private(set) var callCount = 0

    init(exitCode: Int32 = 0, stdout: String, stderr: String = "") {
        self.result = ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        callCount += 1
        return result
    }
}

/// Collects `(completed, total)` pairs from the progress callback for assertion.
actor ProgressCollector {
    struct Entry: Equatable {
        let completed: Int
        let total: Int
    }
    private(set) var entries: [Entry] = []

    func record(completed: Int, total: Int) {
        entries.append(Entry(completed: completed, total: total))
    }
}