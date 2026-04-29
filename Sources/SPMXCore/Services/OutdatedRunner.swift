/*
 *  File: OutdatedRunner.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// End-to-end orchestration for `spmx outdated`.
///
/// Lives outside `OutdatedCommand` so the full pipeline (parse → fetch → bridge → render)
/// is testable with injected fakes. The command itself is a thin shell that builds an
/// `OutdatedRunner` from parsed CLI args and forwards them to `run(options:)`.
public struct OutdatedRunner: Sendable {

    /// Caller-supplied options. Mirrors the CLI flags but is decoupled from `ArgumentParser`
    /// so the runner can be exercised in tests without instantiating a `ParsableCommand`.
    public struct Options: Sendable, Equatable {
        public let path: String
        /// When `true`, include rows that are already up to date in the rendered output.
        public let showAll: Bool
        /// When `true`, only show dependencies declared in Package.swift (not transitive).
        public let direct: Bool
        /// Package identities to suppress from the output. Matched case-insensitively.
        public let ignore: Set<String>
        /// When `true`, render JSON instead of a table. JSON is always unfiltered.
        public let json: Bool
        /// Caller's decision on color. The runner does not touch TTY or env globals itself.
        public let colorEnabled: Bool
        public init(
            path: String,
            showAll: Bool,
            direct: Bool = false,
            ignore: Set<String> = [],
            json: Bool,
            colorEnabled: Bool
        ) {
            self.path = path
            self.showAll = showAll
            self.direct = direct
            self.ignore = Set(ignore.map { $0.lowercased() })
            self.json = json
            self.colorEnabled = colorEnabled
        }
    }

    /// Result of a run. `rows` is the full unfiltered, sorted set so callers (and tests)
    /// can inspect the underlying data; `rendered` is what should go to stdout.
    public struct Output: Sendable, Equatable {
        public let rows: [OutdatedRow]
        public let rendered: String
        /// Whether any row has a non-upToDate status. Used by `--exit-code`.
        public let hasOutdated: Bool

        public init(rows: [OutdatedRow], rendered: String, hasOutdated: Bool = false) {
            self.rows = rows
            self.rendered = rendered
            self.hasOutdated = hasOutdated
        }
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        case packageResolvedNotFound(directory: String)
        case noManifest(directory: String)
        case parseFailed(String)
        case encodingFailed

        public var description: String {
            switch self {
            case .packageResolvedNotFound(let dir):
                return """
                No Package.resolved found in \(dir).
                Run `swift package resolve` first, or pass --path to point at a package directory.
                """
            case .noManifest(let dir):
                return """
                --direct requires a Package.swift, but none was found in \(dir).
                Pass --path to point at a package directory, or drop --direct to show all
                dependencies.
                """
            case .parseFailed(let msg):
                return """
                Failed to parse Package.resolved: \(msg). \
                Re-run `swift package resolve` to regenerate the file, then try again.
                """
            case .encodingFailed:
                return """
                Failed to encode JSON output. This is a spmx bug — please file an issue at \
                https://github.com/macitch/spmx/issues with the command you ran.
                """
            }
        }

        public var errorDescription: String? { description }
    }

    private let parser: ResolvedParser
    private let fetcher: any VersionFetching

    public init(
        parser: ResolvedParser = ResolvedParser(),
        fetcher: any VersionFetching = GitVersionFetcher()
    ) {
        self.parser = parser
        self.fetcher = fetcher
    }

    public func run(options: Options) async throws -> Output {
        let dirURL = URL(fileURLWithPath: options.path)
        guard let resolvedURL = parser.locate(in: dirURL) else {
            throw Error.packageResolvedNotFound(directory: dirURL.path)
        }

        let file: ResolvedFile
        do {
            file = try parser.parse(at: resolvedURL)
        } catch let err as ResolvedParser.Error {
            throw Error.parseFailed(err.description)
        }

        // When --direct is set, load Package.swift to get the set of directly-declared
        // dependency identities and filter resolved pins down to just those.
        let directIdentities: Set<String>?
        if options.direct {
            let manifestURL = resolvedURL
                .deletingLastPathComponent() // go up from Package.resolved
                .appendingPathComponent("Package.swift")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                throw Error.noManifest(directory: dirURL.path)
            }
            let editor = try ManifestEditor.load(from: manifestURL)
            directIdentities = Set(try editor.listDependencyIdentities())
        } else {
            directIdentities = nil
        }

        var pinsToCheck: [ResolvedFile.Pin]
        if let directIdentities {
            pinsToCheck = file.pins.filter { directIdentities.contains($0.identity) }
        } else {
            pinsToCheck = file.pins
        }

        // Apply --ignore filtering.
        if !options.ignore.isEmpty {
            pinsToCheck = pinsToCheck.filter { !options.ignore.contains($0.identity) }
        }

        let fetchResults = await fetcher.latestVersions(for: pinsToCheck)

        let allRows = pinsToCheck
            .map { pin in
                OutdatedRow.from(
                    pin: pin,
                    fetchResult: fetchResults[pin.identity]
                        ?? .fetchFailed("no result returned by fetcher")
                )
            }
            .sorted { $0.identity < $1.identity }

        let hasOutdated = allRows.contains { $0.status != .upToDate }
        let rendered = try renderOutput(rows: allRows, options: options)

        return Output(rows: allRows, rendered: rendered, hasOutdated: hasOutdated)
    }

    // MARK: - Rendering

    private func renderOutput(rows: [OutdatedRow], options: Options) throws -> String {
        if options.json {
            return try jsonString(for: rows)
        }
        let displayRows = options.showAll
            ? rows
            : rows.filter { $0.status != .upToDate }
        let renderer = TableRenderer(colorEnabled: options.colorEnabled)
        return renderer.render(displayRows)
    }

    private func jsonString(for rows: [OutdatedRow]) throws -> String {
        let encoder = JSONEncoder()
        // .withoutEscapingSlashes stops Foundation from emitting `\/` in URLs and notes,
        // which is valid JSON but unusual and looks broken to users who pipe through `jq`.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(rows)
            guard let s = String(data: data, encoding: .utf8) else {
                throw Error.encodingFailed
            }
            return s + "\n"
        } catch is Error {
            throw Error.encodingFailed
        } catch {
            throw Error.encodingFailed
        }
    }
}