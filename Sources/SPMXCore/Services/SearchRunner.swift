/*
 *  File: SearchRunner.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// End-to-end orchestration for `spmx search <term>`.
///
/// Wraps `PackageListResolver.candidates(matching:)` with rendering (table or JSON)
/// and result-count limiting. Kept separate from `SearchCommand` for testability.
public struct SearchRunner: Sendable {

    public struct Options: Sendable, Equatable {
        public let query: String
        /// When true, emit JSON instead of a table.
        public let json: Bool
        /// Maximum number of results to display. 0 = unlimited.
        public let limit: Int
        /// Whether to bypass the catalog cache.
        public let refresh: Bool

        public init(query: String, json: Bool, limit: Int = 20, refresh: Bool = false) {
            self.query = query
            self.json = json
            self.limit = limit
            self.refresh = refresh
        }
    }

    public struct Output: Sendable, Equatable {
        public let matches: [PackageListResolver.Match]
        public let rendered: String
        /// Total count before limiting. Lets callers know if results were truncated.
        public let totalCount: Int

        public init(matches: [PackageListResolver.Match], rendered: String, totalCount: Int) {
            self.matches = matches
            self.rendered = rendered
            self.totalCount = totalCount
        }
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        case noResults(query: String)
        case catalogFailed(String)

        public var description: String {
            switch self {
            case .noResults(let query):
                return """
                No packages matching "\(query)" found in the Swift Package Index.

                Check the spelling, or try a broader search term.
                """
            case .catalogFailed(let msg):
                return """
                Failed to load the package catalog: \(msg). \
                Check your network connection. If you know the package URL already, you can \
                skip search and pass it directly to `spmx add` with `--url <url>`.
                """
            }
        }

        public var errorDescription: String? { description }
    }

    private let resolver: PackageListResolver

    public init(resolver: PackageListResolver = PackageListResolver()) {
        self.resolver = resolver
    }

    public func run(options: Options) async throws -> Output {
        let allMatches: [PackageListResolver.Match]
        do {
            allMatches = try await resolver.candidates(
                matching: options.query,
                refresh: options.refresh
            )
        } catch {
            throw Error.catalogFailed(String(describing: error))
        }

        guard !allMatches.isEmpty else {
            throw Error.noResults(query: options.query)
        }

        // Sort alphabetically by identity for stable output.
        let sorted = allMatches.sorted { $0.identity < $1.identity }
        let totalCount = sorted.count

        let limited: [PackageListResolver.Match]
        if options.limit > 0 && sorted.count > options.limit {
            limited = Array(sorted.prefix(options.limit))
        } else {
            limited = sorted
        }

        let rendered: String
        if options.json {
            rendered = try renderJSON(matches: sorted) // JSON is always untruncated
        } else {
            rendered = renderTable(matches: limited, total: totalCount, query: options.query)
        }

        return Output(matches: limited, rendered: rendered, totalCount: totalCount)
    }

    // MARK: - Rendering

    private func renderTable(
        matches: [PackageListResolver.Match],
        total: Int,
        query: String
    ) -> String {
        var out = ""

        if total == 1 {
            out += "1 package matching \"\(query)\":\n\n"
        } else {
            out += "\(total) packages matching \"\(query)\""
            if matches.count < total {
                out += " (showing first \(matches.count))"
            }
            out += ":\n\n"
        }

        // Column widths.
        let header = ["Package", "URL"]
        let bodyRows: [[String]] = matches.map { [$0.identity, $0.url] }
        let widths = columnWidths(header: header, body: bodyRows)

        out += formatRow(header, widths: widths) + "\n"
        out += widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ") + "\n"
        for row in bodyRows {
            out += formatRow(row, widths: widths) + "\n"
        }

        if matches.count < total {
            out += "\nUse --limit 0 to see all results.\n"
        }

        return out
    }

    private func renderJSON(matches: [PackageListResolver.Match]) throws -> String {
        struct Row: Encodable {
            let identity: String
            let url: String
        }
        let payload = matches.map { Row(identity: $0.identity, url: $0.url) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            throw Error.catalogFailed("Failed to encode JSON output.")
        }
        return str + "\n"
    }

    private func columnWidths(header: [String], body: [[String]]) -> [Int] {
        var widths = header.map { $0.count }
        for row in body {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return widths
    }

    private func formatRow(_ cells: [String], widths: [Int]) -> String {
        zip(cells, widths).map { cell, width in
            cell.padding(toLength: width, withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }
}