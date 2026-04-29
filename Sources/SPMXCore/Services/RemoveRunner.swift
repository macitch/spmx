/*
 *  File: RemoveRunner.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// End-to-end orchestration for `spmx remove <package>`.
///
/// Pipeline: normalize user input to an SPM identity → locate `Package.swift` →
/// load via `ManifestEditor` → atomically remove the package from top-level deps
/// AND every target product reference → either write the result or (dry-run)
/// print what would change. Kept separate from `RemoveCommand` so the whole
/// thing is testable with in-memory manifests and a `FileManager` that points at
/// a tmp dir.
///
/// ## Design notes
///
/// - Identity normalization lives here, not in `ManifestEditor`. The editor takes
///   a pre-normalized identity string; command-layer input (which may be a URL,
///   a bare name, or `git@github.com:...`) is normalized before the call. This
///   keeps the editor's public surface tight and matches how `XcodeProjectReader`
///   feeds it today.
///
/// - Errors are structured and distinct from `ManifestEditor.Error` so the
///   command layer can produce friendly messages without poking at the editor's
///   private vocabulary (`dependenciesNotArrayLiteral` etc. are surfaced here
///   with human text).
///
/// - No I/O in dry-run mode. `removingPackageCompletely` is pure on the parsed
///   tree, so dry-run is literally "do the work, don't write".
public struct RemoveRunner: Sendable {

    public struct Options: Sendable, Equatable {
        /// Directory (or Package.swift path) the user passed via `--path`.
        public let path: String
        /// Raw user input — bare name, URL, or `git@...:...` form.
        public let package: String
        /// When true, compute the change but don't write to disk.
        public let dryRun: Bool

        public init(path: String, package: String, dryRun: Bool) {
            self.path = path
            self.package = package
            self.dryRun = dryRun
        }
    }

    /// Structured result. `rendered` is the human-facing summary; tests also
    /// assert on the individual fields so they don't have to pattern-match text.
    public struct Output: Sendable, Equatable {
        /// The normalized SPM identity that was removed.
        public let identity: String
        /// Target names whose `dependencies:` were modified. Empty if the
        /// package was only at the top level.
        public let affectedTargets: [String]
        /// Whether the manifest was actually written to disk. `false` for dry-run.
        public let wroteChanges: Bool
        /// Fully-rendered user-facing summary text, newline-terminated.
        public let rendered: String

        public init(
            identity: String,
            affectedTargets: [String],
            wroteChanges: Bool,
            rendered: String
        ) {
            self.identity = identity
            self.affectedTargets = affectedTargets
            self.wroteChanges = wroteChanges
            self.rendered = rendered
        }
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        case pathDoesNotExist(path: String)
        case noManifest(directory: String)
        case packageNotFound(identity: String)
        case topLevelDependenciesNotLiteral
        case targetDependenciesNotLiteral(target: String)
        case targetsNotLiteral
        case noPackageInit
        case multiplePackageInits
        case parseFailed(String)
        case readFailed(path: String, reason: String)
        case writeFailed(path: String, reason: String)

        public var description: String {
            switch self {
            case .pathDoesNotExist(let path):
                return """
                Path does not exist: \(path)

                Check the spelling of --path, or cd into the package directory
                and run `spmx remove` without --path.
                """
            case .noManifest(let dir):
                return """
                No Package.swift found in \(dir).

                `spmx remove` only edits SwiftPM manifests. If this is an Xcode
                project using the package integration UI, remove the package via
                Xcode's "Package Dependencies" tab instead.
                """
            case .packageNotFound(let id):
                return """
                Package "\(id)" is not listed in Package.swift's top-level dependencies — \
                nothing to remove. Check the spelling, or list current dependencies with \
                `swift package show-dependencies`.
                """
            case .topLevelDependenciesNotLiteral:
                return """
                Package.swift's top-level `dependencies:` is not a plain array
                literal (it's built by a helper or variable). `spmx remove`
                refuses to mutate non-literal shapes because it can't
                statically guarantee correctness. Rewrite `dependencies:` as a
                literal array and try again.
                """
            case .targetDependenciesNotLiteral(let target):
                return """
                Target "\(target)" has a non-literal `dependencies:` argument
                (it's built by a helper or variable). `spmx remove` refuses the
                whole operation — even if this target doesn't reference the
                package — because it can't statically verify that no orphan
                reference remains. Rewrite the target's `dependencies:` as a
                literal array and try again.
                """
            case .targetsNotLiteral:
                return """
                Package.swift's `targets:` is not a plain array literal. `spmx
                remove` can't scan targets for references when the list is
                built dynamically. Rewrite `targets:` as a literal array and
                try again.
                """
            case .noPackageInit:
                return """
                Couldn't find a top-level `let package = Package(...)` in
                Package.swift. `spmx remove` only handles the canonical
                manifest shape.
                """
            case .multiplePackageInits:
                return """
                Multiple `let package = Package(...)` declarations found in
                Package.swift. spmx cannot determine which one to edit.
                Edit Package.swift by hand.
                """
            case .parseFailed(let msg):
                return """
                Failed to parse Package.swift: \(msg). \
                Run `swift package describe` to see the compiler's view; fix any syntax errors and retry.
                """
            case .readFailed(let path, let reason):
                return """
                Failed to read \(path): \(reason). \
                Check the file's permissions and that no other process is holding it open.
                """
            case .writeFailed(let path, let reason):
                return """
                Failed to write \(path): \(reason). Check write permissions on the directory \
                and that there's enough disk space; the manifest was not modified.
                """
            }
        }

        public var errorDescription: String? { description }
    }

    private let detector: ProjectDetector

    /// Optional write guard that runs `swift package resolve` after writing the
    /// manifest and reverts on failure. When nil (the default in tests), the
    /// manifest is written directly with no resolution check.
    private let writeGuard: ManifestWriteGuard?

    public init(
        detector: ProjectDetector = ProjectDetector(),
        writeGuard: ManifestWriteGuard? = nil
    ) {
        self.detector = detector
        self.writeGuard = writeGuard
    }

    public func run(options: Options) async throws -> Output {
        // 1. Resolve Package.swift location.
        let manifestURL = try locateManifest(at: options.path)

        // 2. Normalize user input to an SPM identity.
        let identity = Self.normalizeIdentity(options.package)

        // 3. Load + mutate.
        let editor: ManifestEditor
        do {
            editor = try ManifestEditor.load(from: manifestURL)
        } catch let err as ManifestEditor.Error {
            throw Self.mapEditorError(err, path: manifestURL.path)
        }

        let removal: ManifestEditor.PackageRemoval
        do {
            removal = try editor.removingPackageCompletely(identity: identity)
        } catch let err as ManifestEditor.Error {
            throw Self.mapEditorError(err, path: manifestURL.path)
        }

        // 4. Write (unless dry-run). If a writeGuard is configured, also run
        //    `swift package resolve` and revert on failure.
        if !options.dryRun {
            if let guard_ = writeGuard {
                print("Resolving dependencies…")
                do {
                    try await guard_.writeAndResolve(editor: removal.editor, to: manifestURL)
                } catch let err as ManifestEditor.Error {
                    throw Self.mapEditorError(err, path: manifestURL.path)
                } catch let err as ManifestWriteGuard.ResolveFailure {
                    throw Error.parseFailed(err.stderr)
                }
            } else {
                do {
                    try removal.editor.write(to: manifestURL)
                } catch let err as ManifestEditor.Error {
                    throw Self.mapEditorError(err, path: manifestURL.path)
                }
            }
        }

        // 5. Render summary.
        let rendered = Self.renderSummary(
            identity: identity,
            affectedTargets: removal.affectedTargets,
            dryRun: options.dryRun
        )

        return Output(
            identity: identity,
            affectedTargets: removal.affectedTargets,
            wroteChanges: !options.dryRun,
            rendered: rendered
        )
    }

    // MARK: - Manifest location

    /// Resolve `--path` to an absolute `Package.swift` URL.
    ///
    /// Accepts:
    ///   - A directory containing Package.swift
    ///   - A direct path to a Package.swift file
    ///
    /// - Throws: `.pathDoesNotExist` if nothing exists at the path,
    ///   `.noManifest` if the directory has no Package.swift.
    private func locateManifest(at rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Error.pathDoesNotExist(path: url.path)
        }

        if !isDirectory.boolValue {
            // Direct file — must be Package.swift.
            guard url.lastPathComponent == "Package.swift" else {
                throw Error.noManifest(directory: url.deletingLastPathComponent().path)
            }
            return url
        }

        // Directory: first check for Package.swift directly.
        let candidate = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        // No Package.swift — use ProjectDetector to find Xcode project, then look
        // for Package.swift alongside it. This handles the common case where the user
        // is in an Xcode project directory that also uses SPM dependencies.
        if let detected = try? detector.detect(path: url) {
            switch detected {
            case .swiftpm(let rootDirectory):
                let spmCandidate = rootDirectory.appendingPathComponent("Package.swift")
                if FileManager.default.fileExists(atPath: spmCandidate.path) {
                    return spmCandidate
                }
            case .xcode(let projectURL):
                // Look for Package.swift in the project's parent directory.
                let parent = projectURL.deletingLastPathComponent()
                let xcodeCandidate = parent.appendingPathComponent("Package.swift")
                if FileManager.default.fileExists(atPath: xcodeCandidate.path) {
                    return xcodeCandidate
                }
            }
        }

        throw Error.noManifest(directory: url.path)
    }

    // MARK: - Identity normalization

    /// Normalize raw user input to an SPM identity string.
    ///
    /// Rules:
    ///   - URLs (`https://`, `http://`, `git@host:...`, `ssh://`) → last path
    ///     component, `.git` stripped, lowercased. Same as
    ///     `XcodePackageReference.identity(forRepositoryURL:)`.
    ///   - Bare names → lowercased. No other transformation; we trust the user
    ///     typed what they meant.
    ///
    /// This function is exposed as `internal` so tests can verify the rule in
    /// isolation without spinning up a whole manifest.
    static func normalizeIdentity(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // URL heuristic: contains "://" or matches `user@host:path` SSH form.
        let isURL = trimmed.contains("://")
            || (trimmed.contains("@") && trimmed.contains(":") && !trimmed.hasPrefix("/"))
        if isURL {
            return XcodePackageReference.identity(forRepositoryURL: trimmed)
        }
        return trimmed.lowercased()
    }

    // MARK: - Error mapping

    /// Translate a `ManifestEditor.Error` into the runner's structured error
    /// vocabulary. Keeps the editor's private error cases from leaking into
    /// the command layer's output.
    private static func mapEditorError(
        _ err: ManifestEditor.Error,
        path _: String
    ) -> Error {
        switch err {
        case .fileNotFound(let url):
            return .pathDoesNotExist(path: url.path)
        case .readFailed(let p, let underlying):
            return .readFailed(path: p, reason: underlying)
        case .writeFailed(let p, let underlying):
            return .writeFailed(path: p, reason: underlying)
        case .parseFailed(let msg):
            return .parseFailed(msg)
        case .noPackageInit:
            return .noPackageInit
        case .multiplePackageInits:
            return .multiplePackageInits
        case .dependenciesNotArrayLiteral, .conditionalDependencies:
            return .topLevelDependenciesNotLiteral
        case .targetsNotArrayLiteral, .conditionalTargets:
            return .targetsNotLiteral
        case .targetDependenciesNotArrayLiteral(let target),
             .conditionalTargetDependencies(let target):
            return .targetDependenciesNotLiteral(target: target)
        case .packageNotFound(let id):
            return .packageNotFound(identity: id)
        case .targetNotFound(let name, _):
            // Shouldn't reach here for removingPackageCompletely — it doesn't
            // look up targets by name — but map defensively so exhaustivity
            // holds without a fallthrough.
            return .parseFailed("unexpected target lookup failure: \(name)")
        case .duplicatePackage,
             .duplicateProductDependency,
             .productDependencyNotFound:
            // Same — these belong to add/remove-product paths, not atomic
            // removal.
            return .parseFailed("unexpected editor error: \(err)")
        }
    }

    // MARK: - Rendering

    /// Render the user-facing summary. Called by both the runner and the tests
    /// so the format is pinned.
    ///
    /// Format:
    /// ```
    /// Removing: <identity>
    /// ✓ Removed from Package.swift dependencies
    /// ✓ Unwired from targets: MyLib, MyLibTests
    /// ```
    /// or, if the package was only at the top level:
    /// ```
    /// Removing: <identity>
    /// ✓ Removed from Package.swift dependencies
    /// ```
    /// Dry-run prepends a "[dry-run] no files written" footer instead of
    /// silently pretending we did something.
    static func renderSummary(
        identity: String,
        affectedTargets: [String],
        dryRun: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("Removing: \(identity)")
        lines.append("✓ Removed from Package.swift dependencies")
        if !affectedTargets.isEmpty {
            lines.append("✓ Unwired from targets: \(affectedTargets.joined(separator: ", "))")
        }
        if dryRun {
            lines.append("[dry-run] no files written")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}