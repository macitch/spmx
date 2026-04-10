/*
 *  File: RemoveCommand.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import ArgumentParser
import Foundation

public struct RemoveCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a dependency from Package.swift and all target product references."
    )

    @Argument(help: "The package to remove (name, URL, or git@host:path).")
    public var package: String

    @Option(name: .shortAndLong, help: "Path to the package directory or Package.swift file.")
    public var path: String = "."

    @Flag(help: "Print changes without writing them.")
    public var dryRun: Bool = false

    @Flag(name: .customLong("no-resolve"), help: "Skip running `swift package resolve` after editing Package.swift.")
    public var noResolve: Bool = false

    public init() {}

    public func run() async throws {
        let guard_ = noResolve ? nil : ManifestWriteGuard()
        let runner = RemoveRunner(writeGuard: guard_)
        let output = try await runner.run(options: .init(
            path: path,
            package: package,
            dryRun: dryRun
        ))
        print(output.rendered, terminator: "")
    }
}