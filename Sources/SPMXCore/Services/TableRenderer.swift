/*
 *  File: TableRenderer.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Renders `[OutdatedRow]` as a human-readable table with optional ANSI color.
///
/// Pure function: rows in, string out. No file I/O, no environment lookups, no global state.
/// Color decisions are made by the *caller* (which knows whether stdout is a TTY, whether
/// `NO_COLOR` is set, and whether the user passed `--no-color`) and passed in via
/// `colorEnabled`. That keeps the renderer trivially testable.
public struct TableRenderer: Sendable {
    public let colorEnabled: Bool

    public init(colorEnabled: Bool) {
        self.colorEnabled = colorEnabled
    }

    /// Convenience: decide color based on the standard `NO_COLOR` env var and stdout TTY.
    /// Callers that need finer control should construct directly with `init(colorEnabled:)`.
    ///
    /// The TTY check is passed in rather than computed as a default argument because
    /// `stdout` is a C global mutable pointer that strict concurrency dislikes seeing in
    /// default-arg position. Production callers pass `currentStdoutIsTTY()`; tests pass a
    /// fixed Bool.
    public static func autoDetect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isStdoutTTY: Bool
    ) -> TableRenderer {
        // https://no-color.org — presence of NO_COLOR with any non-empty value disables color.
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty {
            return TableRenderer(colorEnabled: false)
        }
        return TableRenderer(colorEnabled: isStdoutTTY)
    }

    /// Standalone helper so callers don't have to import `Darwin` themselves.
    ///
    /// The actual `isatty`/`fileno` C call is confined to this single function — the rest
    /// of `SPMXCore` doesn't touch C globals. Marked `nonisolated` (implicitly) and
    /// computed at call time.
    public static func currentStdoutIsTTY() -> Bool {
        isatty(fileno(stdout)) != 0
    }

    public func render(_ rows: [OutdatedRow]) -> String {
        guard !rows.isEmpty else {
            return "All dependencies are up to date.\n"
        }

        let header = ["Package", "Current", "Latest", "Status"]
        let bodyRows: [[String]] = rows.map { row in
            [
                row.identity,
                row.current,
                row.latest ?? "—",
                statusLabel(for: row),
            ]
        }
        let widths = columnWidths(header: header, body: bodyRows)

        var out = ""
        out += formatRow(header, widths: widths, ansi: nil) + "\n"
        out += separatorRow(widths: widths) + "\n"
        for (row, cells) in zip(rows, bodyRows) {
            out += formatRow(cells, widths: widths, ansi: ansi(for: row.status)) + "\n"
        }

        // Append any notes (failures, skip reasons) below the table so they don't bloat
        // the columns. Most rows won't have notes, so this section is often empty.
        let noted = rows.filter { $0.note != nil }
        if !noted.isEmpty {
            out += "\nNotes:\n"
            for row in noted {
                out += "  \(row.identity): \(row.note ?? "")\n"
            }
        }

        return out
    }

    // MARK: - Internals

    private func statusLabel(for row: OutdatedRow) -> String {
        switch row.status {
        case .upToDate:         return "up to date"
        case .behindMinorPatch: return "behind"
        case .behindMajor:      return "behind (major)"
        case .pinnedToBranch:   return "on branch"
        case .unknown:          return "unknown"
        }
    }

    /// Returns the ANSI escape pair for a row's status, or nil if color is disabled.
    private func ansi(for status: OutdatedRow.Status) -> (open: String, close: String)? {
        guard colorEnabled else { return nil }
        let reset = "\u{001B}[0m"
        switch status {
        case .upToDate:         return ("\u{001B}[32m", reset) // green
        case .behindMinorPatch: return ("\u{001B}[33m", reset) // yellow
        case .behindMajor:      return ("\u{001B}[31m", reset) // red
        case .pinnedToBranch:   return ("\u{001B}[33m", reset) // yellow — actionable
        case .unknown:          return ("\u{001B}[2m", reset)  // dim
        }
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

    private func formatRow(
        _ cells: [String],
        widths: [Int],
        ansi: (open: String, close: String)?
    ) -> String {
        let padded = zip(cells, widths).map { cell, width in
            cell.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        let line = padded.joined(separator: "  ")
        if let ansi { return ansi.open + line + ansi.close }
        return line
    }

    private func separatorRow(widths: [Int]) -> String {
        widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")
    }
}