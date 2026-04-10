/*
 *  File: OutdatedCommand.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import ArgumentParser
import Foundation

public struct OutdatedCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "outdated",
        abstract: "List dependencies with newer versions available."
    )

    @Option(name: .shortAndLong, help: "Path to the package directory.")
    public var path: String = "."

    @Flag(help: "Show all dependencies, including those already up to date.")
    public var all: Bool = false

    @Flag(help: "Only show direct dependencies (declared in Package.swift).")
    public var direct: Bool = false

    @Flag(help: "Output as JSON for scripting. Always unfiltered.")
    public var json: Bool = false

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Package identities to exclude from the output. Repeatable."
    )
    public var ignore: [String] = []

    @Flag(help: "Bypass the version cache and re-fetch all tags from remotes.")
    public var refresh: Bool = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color output.")
    public var noColor: Bool = false

    @Flag(name: .customLong("exit-code"), help: "Exit with non-zero status if any dependency is outdated. Useful for CI.")
    public var exitCode: Bool = false

    public init() {}

    public func run() async throws {
        try GitEnvironment.requireGit()

        let colorEnabled: Bool = {
            if noColor || json { return false }
            return TableRenderer
                .autoDetect(isStdoutTTY: TableRenderer.currentStdoutIsTTY())
                .colorEnabled
        }()

        let isTTY = TableRenderer.currentStdoutIsTTY()
        let showProgress = isTTY && !json

        let fetcher: GitVersionFetcher
        if showProgress {
            fetcher = GitVersionFetcher(refresh: refresh, onPinComplete: { completed, total in
                let msg = "\u{1B}[2K\rFetching versions… \(completed)/\(total)"
                FileHandle.standardError.write(Data(msg.utf8))
            })
        } else {
            fetcher = GitVersionFetcher(refresh: refresh)
        }
        let runner = OutdatedRunner(fetcher: fetcher)
        let output = try await runner.run(options: .init(
            path: path,
            showAll: all,
            direct: direct,
            ignore: Set(ignore),
            json: json,
            colorEnabled: colorEnabled
        ))
        // Clear the progress line before printing results.
        if showProgress {
            FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8))
        }
        print(output.rendered, terminator: "")

        if exitCode && output.hasOutdated {
            throw ExitCode(1)
        }
    }
}