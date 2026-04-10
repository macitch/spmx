/*
 *  File: VersionFetcher.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import CryptoKit

/// Result of a single version-fetch attempt.
///
/// We deliberately model failure as data, not as a thrown error. `OutdatedCommand` needs to
/// render *all* pins in the table even when some failed — one bad git server shouldn't blank
/// out the row for the other 29 dependencies.
public enum VersionFetchResult: Sendable, Equatable {
    /// Latest semver-parseable tag found on the remote.
    case found(Semver)
    /// The remote responded but had no tags that parse as semver.
    case noVersionTags
    /// `git ls-remote` failed; payload is the (truncated) stderr.
    case fetchFailed(String)
    /// Pin was skipped because we don't know how to query it (local, registry, etc.).
    case skipped(reason: String)
}

/// Abstraction over "what's the newest version of each pin?".
///
/// The protocol exists so `OutdatedCommand` and friends can be tested with a fake fetcher,
/// and so we can swap in alternative discovery strategies later (e.g. the SPM registry API)
/// without rewriting callers.
public protocol VersionFetching: Sendable {
    func latestVersions(
        for pins: [ResolvedFile.Pin]
    ) async -> [String: VersionFetchResult]
}

/// `VersionFetching` implementation that shells out to `git ls-remote --tags`.
///
/// Concurrency: pins are fetched in parallel through a `TaskGroup` with bounded in-flight
/// count (`maxConcurrency`, default 8). Sequential is too slow on real projects (50 pins ×
/// ~600ms each = half a minute) and unbounded gets us rate-limited by GitHub.
///
/// ## Caching
///
/// Each URL's `git ls-remote` output is cached to `~/Library/Caches/spmx/versions/<sha>.json`
/// (or the XDG equivalent on Linux). Default TTL is 5 minutes — short enough that `outdated`
/// stays reasonably fresh, long enough that rapid re-runs don't hammer remotes. The TTL is
/// per-URL so a single stale entry doesn't invalidate the whole cache.
///
/// Pass `refresh: true` to bypass the cache entirely (wired to `--refresh` on the CLI).
public struct GitVersionFetcher: VersionFetching {
    private let runner: any ProcessRunning
    private let maxConcurrency: Int
    private let includePrereleases: Bool
    private let envExecutable: String
    private let cacheDirectory: URL
    private let cacheTTL: TimeInterval
    private let refresh: Bool
    private let now: @Sendable () -> Date
    /// Called after each pin completes. Parameters: `(completed, total)`.
    private let onPinComplete: (@Sendable (Int, Int) -> Void)?

    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        maxConcurrency: Int = 8,
        includePrereleases: Bool = false,
        envExecutable: String = "/usr/bin/env",
        cacheDirectory: URL = defaultCacheDirectory(),
        cacheTTL: TimeInterval = 5 * 60,
        refresh: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() },
        onPinComplete: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        precondition(maxConcurrency > 0, "maxConcurrency must be positive")
        self.runner = runner
        self.maxConcurrency = maxConcurrency
        self.includePrereleases = includePrereleases
        self.envExecutable = envExecutable
        self.cacheDirectory = cacheDirectory
        self.cacheTTL = cacheTTL
        self.refresh = refresh
        self.now = now
        self.onPinComplete = onPinComplete
    }

    // MARK: - Default cache location

    /// `~/Library/Caches/spmx/versions/` on macOS, XDG-aware on Linux.
    public static func defaultCacheDirectory() -> URL {
        let fm = FileManager.default
        #if os(macOS)
        if let caches = try? fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            return caches.appendingPathComponent("spmx/versions", isDirectory: true)
        }
        #endif
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("spmx/versions", isDirectory: true)
        }
        let home = fm.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cache/spmx/versions", isDirectory: true)
    }

    // MARK: - VersionFetching

    public func latestVersions(
        for pins: [ResolvedFile.Pin]
    ) async -> [String: VersionFetchResult] {
        guard !pins.isEmpty else { return [:] }

        let total = pins.count
        return await withTaskGroup(of: (String, VersionFetchResult).self) { group in
            var results: [String: VersionFetchResult] = [:]
            results.reserveCapacity(total)
            var iterator = pins.makeIterator()
            var completed = 0

            // Prime the group up to the concurrency cap.
            for _ in 0..<min(maxConcurrency, total) {
                guard let pin = iterator.next() else { break }
                group.addTask { await self.fetchOne(pin) }
            }

            // Drain and refill: every completion frees a slot for the next pin.
            while let (identity, result) = await group.next() {
                results[identity] = result
                completed += 1
                onPinComplete?(completed, total)
                if let pin = iterator.next() {
                    group.addTask { await self.fetchOne(pin) }
                }
            }
            return results
        }
    }

    /// Fetches the latest tagged version for a single pin. Never throws — failures are
    /// returned as `VersionFetchResult` cases so callers can render them.
    func fetchOne(_ pin: ResolvedFile.Pin) async -> (String, VersionFetchResult) {
        guard pin.kind == .remoteSourceControl else {
            return (pin.identity, .skipped(reason: "non-remote pin (\(pin.kind.rawValue))"))
        }

        // Try the cache first (unless refresh is forced).
        if !refresh, let cached = readCache(for: pin.location) {
            return (pin.identity, pickLatest(from: cached))
        }

        do {
            let proc = try await runner.run(
                envExecutable,
                arguments: ["git", "ls-remote", "--tags", "--refs", pin.location]
            )
            guard proc.exitCode == 0 else {
                let trimmed = proc.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return (pin.identity, .fetchFailed(Self.truncate(trimmed)))
            }
            let tags = Self.parseTags(from: proc.stdout)

            // Cache the raw tag list for this URL. Best-effort — don't let cache
            // failures break the user's workflow.
            writeCache(tags: tags, for: pin.location)

            return (pin.identity, pickLatest(from: tags))
        } catch {
            return (pin.identity, .fetchFailed(error.localizedDescription))
        }
    }

    /// Pick the latest semver from a list of tag strings.
    private func pickLatest(from tags: [String]) -> VersionFetchResult {
        let candidates = tags
            .compactMap(Semver.init)
            .filter { includePrereleases || !$0.isPrerelease }
        guard let latest = candidates.max() else {
            return .noVersionTags
        }
        return .found(latest)
    }

    // MARK: - Cache I/O

    /// Cache key: SHA-256 of the URL string. Stable, filesystem-safe, no collisions in
    /// practice for the ~200 distinct git URLs a large project might reference.
    static func cacheKey(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cacheFile(for url: String) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.cacheKey(for: url)).json")
    }

    private func readCache(for url: String) -> [String]? {
        let file = cacheFile(for: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return nil }

        // TTL check.
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let modDate = attrs[.modificationDate] as? Date else { return nil }
        let age = now().timeIntervalSince(modDate)
        guard age < cacheTTL else { return nil }

        // Decode.
        guard let data = try? Data(contentsOf: file),
              let tags = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return tags
    }

    private func writeCache(tags: [String], for url: String) {
        let fm = FileManager.default
        // Ensure the directory exists.
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Atomic write.
        guard let data = try? JSONEncoder().encode(tags) else { return }
        try? data.write(to: cacheFile(for: url), options: .atomic)
    }

    // MARK: - Tag parsing

    /// Parses `git ls-remote --tags` output into a deduped list of tag names.
    ///
    /// Each line is `<sha>\trefs/tags/<name>`. Annotated tags also produce a second line
    /// with the suffix `^{}` pointing at the dereferenced commit. We use `--refs` above to
    /// suppress those, but we also strip the suffix defensively in case an older git omits
    /// the flag.
    static func parseTags(from output: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for line in output.split(separator: "\n") {
            guard let tabIdx = line.firstIndex(of: "\t") else { continue }
            var ref = line[line.index(after: tabIdx)...]
            guard ref.hasPrefix("refs/tags/") else { continue }
            ref = ref.dropFirst("refs/tags/".count)
            if ref.hasSuffix("^{}") { ref = ref.dropLast(3) }
            let name = String(ref)
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    private static func truncate(_ s: String, limit: Int = 200) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }
}