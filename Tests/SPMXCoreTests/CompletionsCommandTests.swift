/*
 *  File: CompletionsCommandTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("CompletionsCommand")
struct CompletionsCommandTests {

    // MARK: - Shell enum

    @Test("Shell enum covers all three shells")
    func allShells() {
        let shells = CompletionsCommand.Shell.allCases.map(\.rawValue)
        #expect(shells.contains("bash"))
        #expect(shells.contains("zsh"))
        #expect(shells.contains("fish"))
        #expect(shells.count == 3)
    }

    // MARK: - Script generation

    @Test("bash script contains spmx commands")
    func bashScript() throws {
        let script = try CompletionsCommand.Shell.bash.completionScript(toolName: "spmx")
        #expect(script.contains("add"))
        #expect(script.contains("remove"))
        #expect(script.contains("outdated"))
        #expect(script.contains("why"))
        #expect(script.contains("search"))
        #expect(script.contains("completions"))
        #expect(script.contains("complete -F"))
    }

    @Test("zsh script contains command descriptions")
    func zshScript() throws {
        let script = try CompletionsCommand.Shell.zsh.completionScript(toolName: "spmx")
        #expect(script.contains("#compdef spmx"))
        #expect(script.contains("add:"))
        #expect(script.contains("remove:"))
        #expect(script.contains("--dry-run"))
    }

    @Test("fish script contains command descriptions")
    func fishScript() throws {
        let script = try CompletionsCommand.Shell.fish.completionScript(toolName: "spmx")
        #expect(script.contains("complete -c spmx"))
        #expect(script.contains("add"))
        #expect(script.contains("remove"))
        #expect(script.contains("outdated"))
    }

    // MARK: - Install instructions

    @Test("bash install instructions reference bashrc")
    func bashInstallInstructions() {
        let instructions = CompletionsCommand.Shell.bash.installInstructions
        #expect(instructions.contains(".bashrc"))
    }

    @Test("zsh install instructions reference zshrc")
    func zshInstallInstructions() {
        let instructions = CompletionsCommand.Shell.zsh.installInstructions
        #expect(instructions.contains(".zshrc"))
    }

    @Test("fish install instructions reference fish completions dir")
    func fishInstallInstructions() {
        let instructions = CompletionsCommand.Shell.fish.installInstructions
        #expect(instructions.contains(".config/fish/completions"))
    }

    // MARK: - Error

    @Test("unknown shell produces descriptive error")
    func unknownShellError() {
        let error = CompletionsError.unknownShell("powershell")
        #expect(error.description.contains("powershell"))
        #expect(error.description.contains("bash, zsh, fish"))
    }
}