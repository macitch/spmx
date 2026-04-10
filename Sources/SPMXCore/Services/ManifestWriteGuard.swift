/*
 *  File: ManifestWriteGuard.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Writes a modified `ManifestEditor` to disk and runs `swift package resolve` to verify the
/// edit doesn't break resolution. If resolution fails, the original manifest is restored
/// automatically so the user never ends up with a corrupted Package.swift.
///
/// Both `AddRunner` and `RemoveRunner` use this to ensure manifest edits are atomic with
/// respect to SPM resolution.
public struct ManifestWriteGuard: Sendable {
    private let runner: any ProcessRunning
    private let envExecutable: String

    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        envExecutable: String = "/usr/bin/env"
    ) {
        self.runner = runner
        self.envExecutable = envExecutable
    }

    public struct ResolveFailure: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
        public let stderr: String

        public var description: String {
            """
            `swift package resolve` failed after editing Package.swift. \
            The original manifest has been restored.

            \(stderr)
            """
        }
        public var errorDescription: String? { description }
    }

    /// Writes the edited manifest, runs resolve, and reverts on failure.
    ///
    /// - Parameters:
    ///   - editor: The modified manifest editor to write.
    ///   - url: The URL of Package.swift to write to.
    /// - Returns: `nil` on success, or a `ResolveFailure` if resolution failed (manifest reverted).
    /// - Throws: `ManifestEditor.Error.writeFailed` if the initial write fails.
    public func writeAndResolve(
        editor: ManifestEditor,
        to url: URL
    ) async throws {
        // 1. Read the original file contents for potential rollback.
        let originalContents = try String(contentsOf: url, encoding: .utf8)

        // 2. Write the edited manifest.
        try editor.write(to: url)

        // 3. Run `swift package resolve` in the package directory.
        let packageDir = url.deletingLastPathComponent().path
        let result: ProcessResult
        do {
            result = try await runner.run(
                envExecutable,
                arguments: ["swift", "package", "--package-path", packageDir, "resolve"]
            )
        } catch {
            // Process launch failure (e.g. timeout) → revert.
            try? originalContents.write(to: url, atomically: true, encoding: .utf8)
            throw ResolveFailure(stderr: error.localizedDescription)
        }

        // 4. If resolution failed, revert to the original manifest.
        if result.exitCode != 0 {
            try? originalContents.write(to: url, atomically: true, encoding: .utf8)
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ResolveFailure(stderr: trimmed)
        }
    }
}