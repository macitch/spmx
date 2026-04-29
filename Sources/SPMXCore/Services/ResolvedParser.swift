/*
 *  File: ResolvedParser.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Parses `Package.resolved` files into a typed `ResolvedFile`.
///
/// We support both v2 and v3 formats. The on-disk shape is identical for the fields we care
/// about, so the same `Codable` model handles both. If a future version of SPM changes the
/// shape in a breaking way, we'll need to branch on `version`.
public struct ResolvedParser: Sendable {
    public init() {}

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible {
        case fileNotFound(URL)
        case unsupportedVersion(Int)
        case decodingFailed(underlying: Swift.Error)

        public var description: String {
            switch self {
            case .fileNotFound(let url):
                return """
                Package.resolved not found at \(url.path). \
                Run `swift package resolve` first to generate it, or pass `--path <dir>` \
                pointing at a package directory.
                """
            case .unsupportedVersion(let v):
                return """
                Unsupported Package.resolved version: \(v). spmx supports versions 2 and 3. \
                If you're on a newer Swift toolchain that ships Package.resolved v\(v), \
                please file an issue at https://github.com/macitch/spmx/issues.
                """
            case .decodingFailed(let err):
                return """
                Failed to decode Package.resolved: \(err.localizedDescription). \
                Re-run `swift package resolve` to regenerate the file. If the error \
                persists, please file an issue at https://github.com/macitch/spmx/issues.
                """
            }
        }

        public var errorDescription: String? { description }
    }

    /// Parses `Package.resolved` from a file URL.
    public func parse(at url: URL) throws -> ResolvedFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parses `Package.resolved` from raw bytes. Useful for tests.
    public func parse(data: Data) throws -> ResolvedFile {
        let decoder = JSONDecoder()
        do {
            let file = try decoder.decode(ResolvedFile.self, from: data)
            guard file.version == 2 || file.version == 3 else {
                throw Error.unsupportedVersion(file.version)
            }
            return file
        } catch let err as Error {
            throw err
        } catch {
            throw Error.decodingFailed(underlying: error)
        }
    }

    /// Locates `Package.resolved` for a given directory, supporting all four layouts spmx
    /// is likely to encounter in the wild:
    ///
    ///   1. **SwiftPM CLI package** — `./Package.resolved` at the directory root.
    ///   2. **Legacy** `swift package generate-xcodeproj` output — `./.swiftpm/xcode/package.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
    ///   3. **Xcode workspace** (highest priority among Xcode layouts because workspaces
    ///      wrap projects) — any `*.xcworkspace/xcshareddata/swiftpm/Package.resolved` in the
    ///      directory.
    ///   4. **Xcode project** — any `*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` in the directory.
    ///
    /// Layout #3 and #4 are the iOS/macOS app cases. They are *the* common shape for the
    /// people spmx is built for; missing them was the first bug the dogfood pass caught.
    ///
    /// Priority order: 1 → 2 → 3 → 4. If multiple `.xcworkspace` or `.xcodeproj` bundles
    /// exist at the same level, they're sorted alphabetically and the first match wins.
    public func locate(in packageDirectory: URL) -> URL? {
        let fm = FileManager.default

        // 1. Plain SwiftPM CLI layout.
        let plain = packageDirectory.appendingPathComponent("Package.resolved")
        if fm.fileExists(atPath: plain.path) { return plain }

        // 2. Legacy generate-xcodeproj layout.
        let legacy = packageDirectory.appendingPathComponent(
            ".swiftpm/xcode/package.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        if fm.fileExists(atPath: legacy.path) { return legacy }

        // 3 & 4. Scan the directory for Xcode bundles. We deliberately do not recurse —
        // that would be expensive and would risk finding the wrong project on big monorepos.
        let contents = (try? fm.contentsOfDirectory(
            at: packageDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let workspaces = contents
            .filter { $0.pathExtension == "xcworkspace" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for ws in workspaces {
            let candidate = ws.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        let projects = contents
            .filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for proj in projects {
            let candidate = proj.appendingPathComponent(
                "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            )
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return nil
    }
}