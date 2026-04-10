/*
 *  File: AddCommand.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import ArgumentParser
import Foundation

/// `spmx add` — add a dependency to `Package.swift` and wire it into a target.
///
/// Argument shape:
///   spmx add <package> [--url <url>] [--from <ver>] [--exact <ver>] [--branch <name>]
///                      [--revision <sha>] [--product <name>] [--target <name>]
///                      [--path <dir>] [--dry-run] [--refresh-catalog]
///
/// `<package>` accepts two forms:
///   1. A package **name** (e.g. `Alamofire`) — resolved to a URL via the Swift
///      Package Index catalog.
///   2. A package **URL** (anything containing `://` or starting with `git@`) —
///      used as-is. Equivalent to passing `--url`.
///
/// Version selection (mutually exclusive, default = `--from <latest semver tag>`):
///   --from <v>      `.package(url:, from: "v")`
///   --exact <v>     `.package(url:, exact: "v")`
///   --branch <n>    `.package(url:, branch: "n")`
///   --revision <s>  `.package(url:, revision: "s")`
public struct AddCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a dependency to Package.swift and wire it into a target."
    )

    @Argument(help: "Package name (resolved via catalog) or full git URL.")
    public var package: String

    @Option(help: "Explicit repository URL. Overrides catalog resolution when the name is ambiguous or unlisted.")
    public var url: String?

    @Option(help: "Version constraint: from (up to next major). Default when no other constraint is set.")
    public var from: String?

    @Option(help: "Pin to an exact version.")
    public var exact: String?

    @Option(help: "Track a branch.")
    public var branch: String?

    @Option(help: "Pin to a specific revision (commit SHA).")
    public var revision: String?

    @Option(help: "Library product to wire into the target. Auto-detected when the package exposes exactly one library.")
    public var product: String?

    @Option(help: "Target to wire the product into. Auto-detected when the package has exactly one non-test target.")
    public var target: String?

    @Option(name: .shortAndLong, help: "Path to the package directory.")
    public var path: String = "."

    @Flag(help: "Print the planned edits without writing to disk.")
    public var dryRun: Bool = false

    @Flag(help: "Bypass the 24-hour catalog cache and re-fetch the package list.")
    public var refreshCatalog: Bool = false

    @Flag(name: .customLong("no-resolve"), help: "Skip running `swift package resolve` after editing Package.swift.")
    public var noResolve: Bool = false

    public init() {}

    public func run() async throws {
        try GitEnvironment.requireGit()

        // Provide an interactive picker when stdout is a TTY. In CI / piped mode,
        // ambiguous matches still throw an error with the candidate list.
        let chooser: (@Sendable (String, [PackageListResolver.Match]) async throws -> String)?
        if TableRenderer.currentStdoutIsTTY() {
            chooser = { query, candidates in
                try Self.interactivePick(query: query, candidates: candidates)
            }
        } else {
            chooser = nil
        }

        let guard_ = noResolve ? nil : ManifestWriteGuard()
        let runner = AddRunner(interactiveChooser: chooser, writeGuard: guard_)
        let output = try await runner.run(options: .init(
            package: package,
            url: url,
            from: from,
            exact: exact,
            branch: branch,
            revision: revision,
            product: product,
            target: target,
            path: path,
            dryRun: dryRun,
            refreshCatalog: refreshCatalog
        ))
        print(output.rendered, terminator: "")
    }

    // MARK: - Interactive picker

    /// Prints a numbered list of candidates and reads a choice from stdin.
    /// Throws if the input is invalid or EOF.
    private static func interactivePick(
        query: String,
        candidates: [PackageListResolver.Match]
    ) throws -> String {
        let shown = Array(candidates.prefix(15))
        print("Multiple packages match \"\(query)\":\n")
        for (i, match) in shown.enumerated() {
            print("  \(i + 1)) \(match.identity)  \(match.url)")
        }
        if candidates.count > shown.count {
            print("  ... and \(candidates.count - shown.count) more. Narrow your search or use --url.")
        }
        print("")
        print("Pick a number (1-\(shown.count)), or 0 to cancel: ", terminator: "")

        guard let line = readLine()?.trimmingCharacters(in: .whitespaces),
              let choice = Int(line) else {
            throw AddRunner.Error.resolveFailed("Invalid input. Re-run with --url to specify the package directly.")
        }

        if choice == 0 {
            throw AddRunner.Error.resolveFailed("Cancelled.")
        }

        guard (1...shown.count).contains(choice) else {
            throw AddRunner.Error.resolveFailed("Invalid choice \(choice). Re-run with --url to specify the package directly.")
        }

        return shown[choice - 1].url
    }
}