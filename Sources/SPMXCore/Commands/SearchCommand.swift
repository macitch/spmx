/*
 *  File: SearchCommand.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import ArgumentParser
import Foundation

public struct SearchCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the Swift Package Index for packages."
    )

    @Argument(help: "Search term to match against package names.")
    public var query: String

    @Flag(help: "Output as JSON for scripting.")
    public var json: Bool = false

    @Option(help: "Maximum number of results to display. Use 0 for unlimited.")
    public var limit: Int = 20

    @Flag(help: "Bypass the 24-hour catalog cache and re-fetch the package list.")
    public var refreshCatalog: Bool = false

    public init() {}

    public func run() async throws {
        let runner = SearchRunner()
        let output = try await runner.run(options: .init(
            query: query,
            json: json,
            limit: limit,
            refresh: refreshCatalog
        ))
        print(output.rendered, terminator: "")
    }
}