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
        /// `nil` when the post-failure revert succeeded; a description of why the
        /// revert failed otherwise. When non-nil, `Package.swift` is in the *edited*
        /// (unresolved) state on disk and the user has to restore it themselves.
        public let revertError: String?

        public init(stderr: String, revertError: String? = nil) {
            self.stderr = stderr
            self.revertError = revertError
        }

        public var description: String {
            if let revertError {
                return """
                `swift package resolve` failed after editing Package.swift, AND the \
                automatic revert also failed — Package.swift is currently in the \
                edited (unresolved) state on disk.

                Resolve failure:
                \(stderr)

                Revert failure: \(revertError)

                Restore Package.swift from version control (e.g. `git checkout -- Package.swift`) \
                before re-running spmx.
                """
            }
            return """
            `swift package resolve` failed after editing Package.swift. \
            The original manifest has been restored.

            \(stderr)
            """
        }
        public var errorDescription: String? { description }
    }

    /// Writes the edited manifest, runs `swift package resolve` to validate it, and
    /// attempts to revert to the original on failure.
    ///
    /// ## What "atomic" does and doesn't mean here
    ///
    /// The intent is *best-effort* atomicity at the SPM-resolution boundary: if the
    /// edit produces a manifest SPM can't resolve, the user should not be left with
    /// a broken Package.swift. We read the original first, write the edit, run
    /// resolve, and revert on failure. That covers the common case.
    ///
    /// It does **not** cover:
    /// - **Concurrent editors** modifying Package.swift between our read and write.
    ///   We don't detect this and the last writer wins.
    /// - **Revert-time I/O failure.** If the revert write itself fails (disk full,
    ///   permissions changed, parent directory unwritable), we surface this honestly
    ///   via `ResolveFailure.revertError` rather than silently claiming the manifest
    ///   was restored. The user is then told to restore Package.swift manually.
    ///
    /// - Parameters:
    ///   - editor: The modified manifest editor to write.
    ///   - url: The URL of Package.swift to write to.
    /// - Throws: `ManifestEditor.Error.writeFailed` if the initial write fails;
    ///   `ResolveFailure` if resolve fails (revert state reported via
    ///   `ResolveFailure.revertError`).
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
            let revertError = attemptRevert(originalContents, to: url)
            throw ResolveFailure(
                stderr: error.localizedDescription,
                revertError: revertError
            )
        }

        // 4. If resolution failed, revert to the original manifest.
        if result.exitCode != 0 {
            let revertError = attemptRevert(originalContents, to: url)
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ResolveFailure(stderr: trimmed, revertError: revertError)
        }
    }

    /// Try to restore the original manifest contents at `url`. Returns `nil` on
    /// success, or a human-readable description of the failure on error. We never
    /// throw out of this helper because the caller is already throwing a
    /// `ResolveFailure` and the revert outcome is reported via that error's
    /// `revertError` field.
    private func attemptRevert(_ originalContents: String, to url: URL) -> String? {
        do {
            try originalContents.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}