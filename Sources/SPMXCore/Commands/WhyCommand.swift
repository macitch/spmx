/*
 *  File: WhyCommand.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import ArgumentParser
import Foundation

public struct WhyCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "why",
        abstract: "Show why a package is in your dependency graph."
    )

    @Argument(help: "The package identity to trace (e.g. swift-collections).")
    public var package: String

    @Option(name: .shortAndLong, help: "Path to the package directory.")
    public var path: String = "."

    @Flag(help: "Output as JSON for scripting.")
    public var json: Bool = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI color output.")
    public var noColor: Bool = false

    @Flag(name: .customLong("exit-code"), help: "Exit with non-zero status if the dependency graph is incomplete. Useful for CI.")
    public var exitCode: Bool = false

    public init() {}

    public func run() async throws {
        let colorEnabled: Bool = {
            if noColor || json { return false }
            return TableRenderer
                .autoDetect(isStdoutTTY: TableRenderer.currentStdoutIsTTY())
                .colorEnabled
        }()

        let runner = WhyRunner()
        let output = try await runner.run(options: .init(
            path: path,
            target: package,
            json: json,
            colorEnabled: colorEnabled
        ))
        print(output.rendered, terminator: "")

        if exitCode && output.hadMissingManifests {
            throw ExitCode(1)
        }
    }
}