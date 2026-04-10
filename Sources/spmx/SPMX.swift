/*
 *  File: SPMX.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import ArgumentParser
import SPMXCore

@main
struct SPMX: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spmx",
        abstract: "The commands Swift Package Manager forgot to ship.",
        version: "0.1.0",
        subcommands: [
            AddCommand.self,
            RemoveCommand.self,
            OutdatedCommand.self,
            WhyCommand.self,
            SearchCommand.self,
            CompletionsCommand.self,
        ]
    )
}