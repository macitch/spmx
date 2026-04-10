/*
 *  File: ManifestLoader.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import CryptoKit

/// Loads a decoded `ManifestDump` for a given `Package.swift` on disk.
///
/// Abstraction so `GraphBuilder` can be unit-tested against an in-memory stub without
/// shelling out to `swift package dump-package`.
public protocol ManifestLoading: Sendable {
    /// Returns the decoded manifest for the package rooted at `packageDirectory`.
    ///
    /// The directory must contain a `Package.swift`. Throws `ManifestLoaderError` on
    /// failure, never returns a partial result — callers treat a throw as "this node
    /// contributes no edges" and carry on.
    func load(packageDirectory: URL) async throws -> ManifestDump
}

/// Errors surfaced by `DiskCachedManifestLoader`. Cache I/O failures are deliberately
/// *not* modelled here — those are caught internally and logged, because a missing cache
/// directory should never block a successful graph walk.
public enum ManifestLoaderError: Swift.Error, CustomStringConvertible, Equatable {
    case packageSwiftNotFound(URL)
    case dumpFailed(exitCode: Int32, stderr: String)
    case decodeFailed(underlying: String)

    public var description: String {
        switch self {
        case .packageSwiftNotFound(let url):
            return "No Package.swift found at \(url.path)"
        case .dumpFailed(let code, let stderr):
            // Keep the stderr trimmed — SPM is verbose and the useful line is usually first.
            let snippet = stderr
                .split(separator: "\n")
                .prefix(3)
                .joined(separator: "\n")
            return "swift package dump-package failed (exit \(code)):\n\(snippet)"
        case .decodeFailed(let err):
            return "Failed to decode dump-package output: \(err)"
        }
    }

    public static func == (lhs: ManifestLoaderError, rhs: ManifestLoaderError) -> Bool {
        // Equatable is for tests; string-compare the descriptions.
        lhs.description == rhs.description
    }
}

/// `ManifestLoading` backed by `swift package dump-package` with a content-addressed disk cache.
///
/// ## Why file-content SHA and not git revision
///
/// The obvious cache key is the git SHA of the dependency checkout, and that works for
/// `.package(url:)` deps. But spmx also needs to load the *root* package's manifest (which
/// is not a git dependency at all, just whatever directory the user is in), and dependencies
/// can also be `.package(path:)` local references. Neither has a git revision. File-content
/// SHA-256 is the one key that works for all three cases and naturally invalidates on
/// every edit. SHA-256 on a 4 KB Package.swift is sub-millisecond, so the extra hash is
/// noise compared to the savings on subsequent runs.
///
/// ## Cache layout
///
/// Each manifest is serialised to `<cacheDirectory>/<sha256-hex>.json` using `ManifestDump`'s
/// own flat shape (see `ManifestDump.encode(to:)`). On read, we decode directly into
/// `ManifestDump` — no intermediate cache type. Collisions are not a concern because
/// SHA-256 is cryptographically collision-resistant and the corpus is tiny.
///
/// ## Cache write is best-effort
///
/// If the cache directory can't be created, or the write fails (disk full, permissions),
/// we log to stderr once and continue. A missing cache degrades performance; it does not
/// block correctness.
public struct DiskCachedManifestLoader: ManifestLoading {
    private let runner: ProcessRunning
    private let cacheDirectory: URL
    private let swiftExecutable: String

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - runner: Process runner to use for `swift package dump-package`. Tests pass a fake.
    ///   - cacheDirectory: Where to persist cached dumps. Tests pass a temp dir.
    ///   - swiftExecutable: Absolute path to the `swift` binary. Defaults to `/usr/bin/env`
    ///     with a `swift` argument prepended, matching the convention in `GitVersionFetcher`.
    public init(
        runner: ProcessRunning = SystemProcessRunner(),
        cacheDirectory: URL = DiskCachedManifestLoader.defaultCacheDirectory(),
        swiftExecutable: String = "/usr/bin/env"
    ) {
        self.runner = runner
        self.cacheDirectory = cacheDirectory
        self.swiftExecutable = swiftExecutable
    }

    /// Apple-convention cache path: `~/Library/Caches/spmx/manifests/`.
    ///
    /// We deliberately don't fall back to `/tmp` or CWD if `.cachesDirectory` isn't available;
    /// that failure mode only happens on systems where FileManager itself is broken, at which
    /// point the user has bigger problems than a missing cache.
    public static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("spmx/manifests", isDirectory: true)
    }

    public func load(packageDirectory: URL) async throws -> ManifestDump {
        let manifestURL = packageDirectory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ManifestLoaderError.packageSwiftNotFound(manifestURL)
        }

        // 1. Hash the manifest file contents. SHA-256 because CryptoKit ships with the OS
        //    and we don't need to add a dependency for what amounts to a cache key.
        let data = try Data(contentsOf: manifestURL)
        let sha = Self.sha256Hex(of: data)
        let cachedFile = cacheDirectory.appendingPathComponent("\(sha).json")

        // 2. Fast path: cache hit.
        if let cached = try? Data(contentsOf: cachedFile),
           let dump = try? JSONDecoder().decode(ManifestDump.self, from: cached) {
            return dump
        }

        // 3. Cache miss: shell out.
        let result = try await runner.run(
            swiftExecutable,
            arguments: [
                "swift", "package",
                "--package-path", packageDirectory.path,
                "dump-package",
            ]
        )
        guard result.exitCode == 0 else {
            throw ManifestLoaderError.dumpFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        // 4. Decode. `dump-package` only writes JSON to stdout; anything on stderr is noise.
        let dumpData = Data(result.stdout.utf8)
        let dump: ManifestDump
        do {
            dump = try JSONDecoder().decode(ManifestDump.self, from: dumpData)
        } catch {
            throw ManifestLoaderError.decodeFailed(
                underlying: String(describing: error)
            )
        }

        // 5. Best-effort cache write. Any failure here is logged and swallowed.
        writeCache(dump: dump, to: cachedFile)

        return dump
    }

    // MARK: - Internals

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func writeCache(dump: ManifestDump, to cachedFile: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(dump)
            try data.write(to: cachedFile, options: .atomic)
        } catch {
            // A broken cache shouldn't block the user. Warn once and move on.
            FileHandle.standardError.write(
                Data("spmx: warning: failed to write manifest cache at \(cachedFile.path): \(error.localizedDescription)\n".utf8)
            )
        }
    }
}