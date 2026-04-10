/*
 *  File: PackageListResolver.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Resolves a bare package name (e.g. `"alamofire"`) to a repository URL by matching
/// against the Swift Package Index's public `packages.json` catalog.
///
/// ## Why this exists
///
/// The Swift Package Index hosts a public HTTP API, but every endpoint we'd need for
/// search or metadata is gated behind authenticated tiers (`APITierAuthenticator(tier:
/// .tier1)` for search, tier 3 for package metadata). The only anonymous data source
/// is the `SwiftPackageIndex/PackageList` GitHub repo, which publishes a flat JSON
/// array of every indexed package's Git URL at a stable public URL:
///
/// <https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/packages.json>
///
/// This file is ~400KB, updates roughly daily, and is the source of truth SPI itself
/// feeds off of. Using it directly means spmx never needs an API key and can't be
/// "deprecated" by SPI's tier system changing.
///
/// ## What it does NOT do
///
/// This resolver only answers "what's the URL for this name?". It does *not* know
/// anything about products, versions, targets, or supported platforms — the catalog
/// literally contains none of that. For those, `AddRunner` combines this resolver
/// with `ManifestFetcher` (which shallow-clones the package to read its Package.swift)
/// and `VersionFetcher` (which hits `git ls-remote` for tags).
///
/// ## Resolution rule
///
/// Given a user query like `spmx add collections`, the rule is:
///
/// 1. **Exact identity match wins** — `alamofire` → one entry has SPM identity
///    `alamofire` → use it unconditionally.
/// 2. **Single prefix match wins** — `collectio` → only `swift-collections` starts
///    with it → use it.
/// 3. **Otherwise refuse** and throw `.ambiguous` with the candidate list so the
///    command layer can print a copy-pasteable `--url` suggestion.
///
/// SPM identity is derived from each URL via `XcodePackageReference.identity(forRepositoryURL:)`
/// — the same rule used everywhere else in spmx for URL→identity conversion.
///
/// ## Cache
///
/// The catalog lives at a platform-native cache location:
///   - macOS: `~/Library/Caches/spmx/packages.json`
///   - Linux: `$XDG_CACHE_HOME/spmx/packages.json` or `~/.cache/spmx/packages.json`
///
/// Default TTL is 24 hours. `--refresh` on the command line forces a re-fetch.
/// Corrupt cache files are silently re-fetched; a network failure when the cache is
/// stale-but-present produces an error rather than silently using an expired cache
/// (v0.1 choice — we can soften this later if users complain).
public struct PackageListResolver: Sendable {

    // MARK: - Types

    /// A resolved package: its SPM identity and its repository URL.
    public struct Match: Sendable, Equatable {
        public let identity: String
        public let url: String

        public init(identity: String, url: String) {
            self.identity = identity
            self.url = url
        }
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        /// Network or HTTP error fetching packages.json.
        case fetchFailed(String)
        /// packages.json fetched successfully but didn't parse as [String].
        case parseFailed(String)
        /// Couldn't write the freshly-fetched catalog to the cache location.
        /// Non-fatal for the current call (we still return the parsed data), but
        /// flagged for logging because the next call won't benefit from the cache.
        case cacheWriteFailed(String)
        /// No package in the catalog matched the query.
        case noMatch(query: String)
        /// Query matched multiple packages, none unambiguously — the user must
        /// disambiguate via `--url`. Candidates are included for error rendering.
        case ambiguous(query: String, candidates: [Match])

        public var description: String {
            switch self {
            case .fetchFailed(let msg):
                return """
                Failed to fetch the Swift Package Index catalog: \(msg)

                If you're offline or SPI is down, pass the repository URL directly:
                  spmx add <name> --url <https://…>
                """
            case .parseFailed(let msg):
                return "Failed to parse the Swift Package Index catalog: \(msg)"
            case .cacheWriteFailed(let msg):
                return "Failed to cache the package catalog: \(msg)"
            case .noMatch(let query):
                return """
                No package named "\(query)" found in the Swift Package Index.

                Check the spelling, or if the package is private or not indexed,
                pass the URL directly:
                  spmx add \(query) --url <https://…>
                """
            case .ambiguous(let query, let candidates):
                let lines = candidates.prefix(10).map { "  \($0.identity)    \($0.url)" }
                let more = candidates.count > 10 ? "\n  ... (\(candidates.count - 10) more)" : ""
                return """
                Multiple packages match "\(query)". Specify the URL directly:

                \(lines.joined(separator: "\n"))\(more)

                Re-run with --url:
                  spmx add \(query) --url <one of the URLs above>
                """
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - Configuration

    /// The canonical URL of the SPI package list. Public static JSON hosted by GitHub.
    public static let catalogURL = URL(
        string: "https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/packages.json"
    )!

    /// Default cache TTL: 24 hours. Chosen because SPI updates at most daily and the
    /// downside of a stale cache (missing a brand-new package) is minor and recoverable
    /// via `--refresh`.
    public static let defaultCacheTTL: TimeInterval = 24 * 60 * 60

    // MARK: - State

    private let cacheFile: URL
    private let cacheTTL: TimeInterval
    private let fetcher: @Sendable (URL) async throws -> Data
    private let now: @Sendable () -> Date

    // MARK: - Init

    /// - Parameters:
    ///   - cacheFile: Where to read/write the cached catalog. Tests pass a tmp URL.
    ///   - cacheTTL: How stale the cache can be before it's re-fetched.
    ///   - fetcher: Closure that fetches bytes from a URL. Injectable for tests.
    ///   - now: Clock for TTL evaluation. Injectable for tests.
    public init(
        cacheFile: URL = PackageListResolver.defaultCacheFileURL(),
        cacheTTL: TimeInterval = PackageListResolver.defaultCacheTTL,
        fetcher: @Sendable @escaping (URL) async throws -> Data = PackageListResolver.defaultFetcher,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.cacheFile = cacheFile
        self.cacheTTL = cacheTTL
        self.fetcher = fetcher
        self.now = now
    }

    // MARK: - Default cache location

    /// Platform-native cache directory for spmx.
    ///   - macOS: `~/Library/Caches/spmx/`
    ///   - Linux: `$XDG_CACHE_HOME/spmx/` or `~/.cache/spmx/`
    public static func defaultCacheDirectory() -> URL {
        let fm = FileManager.default

        #if os(macOS)
        if let caches = try? fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            return caches.appendingPathComponent("spmx", isDirectory: true)
        }
        #endif

        // XDG / Linux / fallback
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("spmx", isDirectory: true)
        }
        let home = fm.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("spmx", isDirectory: true)
    }

    /// Default cache file: `<cacheDir>/packages.json`.
    public static func defaultCacheFileURL() -> URL {
        defaultCacheDirectory().appendingPathComponent("packages.json", isDirectory: false)
    }

    /// Default network fetcher using `URLSession.shared`. Tests replace this with a
    /// closure that returns canned bytes so no network call happens.
    @Sendable
    public static func defaultFetcher(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.fetchFailed("HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Public API

    /// Resolve a bare package name to a single `Match`, or throw.
    ///
    /// - Parameters:
    ///   - name: The query. Not case-sensitive.
    ///   - refresh: When true, bypass any cached copy and re-fetch the catalog.
    /// - Returns: Exactly one match when the resolution rule picks a winner.
    /// - Throws: `.noMatch`, `.ambiguous`, `.fetchFailed`, `.parseFailed`.
    public func resolve(name: String, refresh: Bool = false) async throws -> Match {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let catalog = try await loadCatalog(refresh: refresh)

        // 1. Exact identity match.
        let exacts = catalog.filter { $0.identity == query }
        if exacts.count == 1 {
            return exacts[0]
        }
        if exacts.count > 1 {
            // Rare but possible: two different owners publishing a package with
            // the same last-path-component name. The SPM identity rule doesn't
            // discriminate on owner, so we have to refuse.
            throw Error.ambiguous(query: name, candidates: exacts)
        }

        // 2. Single prefix match.
        let prefixes = catalog.filter { $0.identity.hasPrefix(query) }
        if prefixes.count == 1 {
            return prefixes[0]
        }
        if prefixes.count > 1 {
            throw Error.ambiguous(query: name, candidates: prefixes)
        }

        // 3. No hits.
        throw Error.noMatch(query: name)
    }

    /// List all catalog entries whose identity contains the query as a substring.
    /// Useful for future `spmx search <term>` subcommand, not currently wired into
    /// any command. Exposed now because the catalog is already in memory.
    public func candidates(matching name: String, refresh: Bool = false) async throws -> [Match] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let catalog = try await loadCatalog(refresh: refresh)
        return catalog.filter { $0.identity.contains(query) }
    }

    // MARK: - Catalog loading

    /// Return the parsed catalog, using the cache when possible and re-fetching when
    /// it's missing, expired, or corrupt.
    private func loadCatalog(refresh: Bool) async throws -> [Match] {
        if !refresh, let cached = try? readCache() {
            return cached
        }
        let fresh = try await fetchAndParse()
        // Cache write is best-effort: if it fails we still return the parsed data.
        // A caching failure shouldn't break the user's `spmx add` call.
        try? writeCache(fresh)
        return fresh
    }

    /// Read the cache file if present and not expired. Returns nil on any failure
    /// (missing, expired, unreadable, unparseable) — treats those all the same so the
    /// caller just re-fetches.
    private func readCache() throws -> [Match]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheFile.path) else { return nil }

        // TTL check via file modification time.
        let attrs = try fm.attributesOfItem(atPath: cacheFile.path)
        guard let modDate = attrs[.modificationDate] as? Date else { return nil }
        let age = now().timeIntervalSince(modDate)
        guard age < cacheTTL else { return nil }

        // Parse. Corruption → nil so we re-fetch (not an error).
        let data: Data
        do {
            data = try Data(contentsOf: cacheFile)
        } catch {
            return nil
        }
        return (try? Self.parse(data))
    }

    private func fetchAndParse() async throws -> [Match] {
        let data: Data
        do {
            data = try await fetcher(Self.catalogURL)
        } catch let err as Error {
            throw err
        } catch {
            throw Error.fetchFailed(error.localizedDescription)
        }
        do {
            return try Self.parse(data)
        } catch {
            throw Error.parseFailed(error.localizedDescription)
        }
    }

    /// Parse the packages.json payload into `[Match]`.
    ///
    /// The catalog shape is a flat JSON array of strings:
    /// ```json
    /// [
    ///   "https://github.com/Alamofire/Alamofire.git",
    ///   "https://github.com/apple/swift-collections.git",
    ///   ...
    /// ]
    /// ```
    ///
    /// Each URL is converted to a `Match` by computing its SPM identity via
    /// `XcodePackageReference.identity(forRepositoryURL:)`. Entries with empty or
    /// malformed identities are dropped rather than throwing, because one bad URL in
    /// a 10,600-entry catalog shouldn't wedge the whole resolver.
    static func parse(_ data: Data) throws -> [Match] {
        let urls = try JSONDecoder().decode([String].self, from: data)
        var matches: [Match] = []
        matches.reserveCapacity(urls.count)
        for url in urls {
            let identity = XcodePackageReference.identity(forRepositoryURL: url)
            guard !identity.isEmpty else { continue }
            matches.append(Match(identity: identity, url: url))
        }
        return matches
    }

    private func writeCache(_ matches: [Match]) throws {
        let fm = FileManager.default
        let dir = cacheFile.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Re-encode as a flat URL array so the cache file shape matches the source
        // format. That way a user who inspects the cache sees the same shape they'd
        // see from the upstream URL, no surprises.
        let urls = matches.map(\.url)
        let data: Data
        do {
            data = try JSONEncoder().encode(urls)
        } catch {
            throw Error.cacheWriteFailed("encode: \(error.localizedDescription)")
        }
        do {
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            throw Error.cacheWriteFailed(error.localizedDescription)
        }
    }
}