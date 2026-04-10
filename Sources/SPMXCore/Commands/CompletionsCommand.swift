/*
 *  File: CompletionsCommand.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import ArgumentParser
import Foundation

/// `spmx completions` — generate shell completion scripts.
///
/// This is a thin wrapper around ArgumentParser's built-in completion
/// generation. It exists so users can discover it via `spmx --help`
/// instead of having to know about `--generate-completion-script`.
///
/// Usage:
///   spmx completions bash
///   spmx completions zsh
///   spmx completions fish
///   spmx completions install bash   # prints install instructions
public struct CompletionsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Generate shell completion scripts (bash, zsh, fish).",
        subcommands: [GenerateSubcommand.self, InstallSubcommand.self],
        defaultSubcommand: GenerateSubcommand.self
    )

    public init() {}
}

// MARK: - Generate

extension CompletionsCommand {
    /// `spmx completions <shell>` — print the completion script to stdout.
    public struct GenerateSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "generate",
            abstract: "Print a completion script to stdout."
        )

        @Argument(help: "Shell to generate completions for (bash, zsh, fish).")
        public var shell: String

        public init() {}

        public func run() throws {
            guard let shellEnum = Shell(rawValue: shell.lowercased()) else {
                throw CompletionsError.unknownShell(shell)
            }
            // ArgumentParser exposes `completionScript(for:)` on the root command type.
            // We need a reference to the root command, but since we're a subcommand we
            // generate it from our knowledge of the tool name.
            let script = try shellEnum.completionScript(toolName: "spmx")
            print(script, terminator: "")
        }
    }
}

// MARK: - Install (instructions)

extension CompletionsCommand {
    /// `spmx completions install <shell>` — print install instructions.
    public struct InstallSubcommand: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Print install instructions for a shell."
        )

        @Argument(help: "Shell to install completions for (bash, zsh, fish).")
        public var shell: String

        public init() {}

        public func run() throws {
            guard let shellEnum = Shell(rawValue: shell.lowercased()) else {
                throw CompletionsError.unknownShell(shell)
            }
            print(shellEnum.installInstructions, terminator: "")
        }
    }
}

// MARK: - Shell enum

extension CompletionsCommand {
    public enum Shell: String, CaseIterable {
        case bash, zsh, fish

        /// Generate completion script content for the given tool name.
        func completionScript(toolName: String) throws -> String {
            switch self {
            case .bash:
                return bashScript(toolName: toolName)
            case .zsh:
                return zshScript(toolName: toolName)
            case .fish:
                return fishScript(toolName: toolName)
            }
        }

        var installInstructions: String {
            switch self {
            case .bash:
                return """
                # Bash completions for spmx
                #
                # Option 1: Source in your profile (works immediately)
                spmx completions bash > ~/.spmx-completion.bash
                echo 'source ~/.spmx-completion.bash' >> ~/.bashrc

                # Option 2: Install to bash-completion directory (if bash-completion is installed)
                spmx completions bash > "$(brew --prefix)/etc/bash_completion.d/spmx"

                # Then reload your shell:
                source ~/.bashrc

                """
            case .zsh:
                return """
                # Zsh completions for spmx
                #
                # Option 1: Add to fpath (recommended)
                spmx completions zsh > ~/.zsh/completion/_spmx
                # Add to your .zshrc (before compinit):
                #   fpath=(~/.zsh/completion $fpath)
                #   autoload -Uz compinit && compinit

                # Option 2: Homebrew site-functions
                spmx completions zsh > "$(brew --prefix)/share/zsh/site-functions/_spmx"

                # Then reload your shell:
                source ~/.zshrc

                """
            case .fish:
                return """
                # Fish completions for spmx
                spmx completions fish > ~/.config/fish/completions/spmx.fish

                # Completions are loaded automatically on next shell start.

                """
            }
        }

        // MARK: - Script generation

        /// Bash completion script using `complete -C` pattern.
        private func bashScript(toolName: String) -> String {
            """
            #!/bin/bash
            # Bash completion for \(toolName)
            # Generated by spmx completions bash

            _\(toolName)_complete() {
                local cur prev words cword
                _init_completion || return

                local commands="add remove outdated why search completions"

                if [[ $cword -eq 1 ]]; then
                    COMPREPLY=($(compgen -W "$commands --help --version" -- "$cur"))
                    return
                fi

                case "${words[1]}" in
                    add)
                        COMPREPLY=($(compgen -W "--url --from --exact --branch --revision --product --target --path --dry-run --no-resolve --refresh-catalog --help" -- "$cur"))
                        ;;
                    remove)
                        COMPREPLY=($(compgen -W "--path --dry-run --no-resolve --help" -- "$cur"))
                        ;;
                    outdated)
                        COMPREPLY=($(compgen -W "--path --all --direct --json --ignore --no-color --exit-code --refresh --help" -- "$cur"))
                        ;;
                    why)
                        COMPREPLY=($(compgen -W "--path --json --no-color --exit-code --help" -- "$cur"))
                        ;;
                    search)
                        COMPREPLY=($(compgen -W "--json --limit --refresh-catalog --help" -- "$cur"))
                        ;;
                    completions)
                        if [[ $cword -eq 2 ]]; then
                            COMPREPLY=($(compgen -W "generate install bash zsh fish --help" -- "$cur"))
                        else
                            COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
                        fi
                        ;;
                esac
            }

            complete -F _\(toolName)_complete \(toolName)

            """
        }

        /// Zsh completion script.
        private func zshScript(toolName: String) -> String {
            """
            #compdef \(toolName)
            # Zsh completion for \(toolName)
            # Generated by spmx completions zsh

            _\(toolName)() {
                local -a commands
                commands=(
                    'add:Add a dependency to Package.swift and wire it into a target'
                    'remove:Remove a dependency from Package.swift'
                    'outdated:List dependencies with newer versions available'
                    'why:Explain why a dependency is included in the graph'
                    'search:Search the Swift Package Index for packages'
                    'completions:Generate shell completion scripts'
                )

                _arguments -C \\
                    '--help[Show help information]' \\
                    '--version[Show the version]' \\
                    '1:command:->command' \\
                    '*::arg:->args'

                case $state in
                    command)
                        _describe 'command' commands
                        ;;
                    args)
                        case $words[1] in
                            add)
                                _arguments \\
                                    '1:package:' \\
                                    '--url[Explicit repository URL]:url:' \\
                                    '--from[Version constraint (from)]:version:' \\
                                    '--exact[Pin to exact version]:version:' \\
                                    '--branch[Track a branch]:branch:' \\
                                    '--revision[Pin to a revision]:sha:' \\
                                    '--product[Library product to wire]:product:' \\
                                    '--target[Target to wire into]:target:' \\
                                    '(-p --path)'{-p,--path}'[Path to the package directory]:path:_directories' \\
                                    '--dry-run[Print planned edits without writing]' \\
                                    '--no-resolve[Skip swift package resolve after editing]' \\
                                    '--refresh-catalog[Bypass catalog cache]' \\
                                    '--help[Show help information]'
                                ;;
                            remove)
                                _arguments \\
                                    '1:package:' \\
                                    '(-p --path)'{-p,--path}'[Path to the package directory]:path:_directories' \\
                                    '--dry-run[Print planned edits without writing]' \\
                                    '--no-resolve[Skip swift package resolve after editing]' \\
                                    '--help[Show help information]'
                                ;;
                            outdated)
                                _arguments \\
                                    '(-p --path)'{-p,--path}'[Path to the package directory]:path:_directories' \\
                                    '--all[Show all dependencies including up to date]' \\
                                    '--direct[Only show direct dependencies]' \\
                                    '--json[Output as JSON]' \\
                                    '*--ignore[Package identities to exclude]:identity:' \\
                                    '--no-color[Disable ANSI color output]' \\
                                    '--exit-code[Exit non-zero if any outdated]' \\
                                    '--refresh[Bypass version cache and re-fetch tags]' \\
                                    '--help[Show help information]'
                                ;;
                            why)
                                _arguments \\
                                    '1:package:' \\
                                    '(-p --path)'{-p,--path}'[Path to the package directory]:path:_directories' \\
                                    '--json[Output as JSON]' \\
                                    '--no-color[Disable ANSI color output]' \\
                                    '--exit-code[Exit non-zero if missing manifests]' \\
                                    '--help[Show help information]'
                                ;;
                            search)
                                _arguments \\
                                    '1:query:' \\
                                    '--json[Output as JSON]' \\
                                    '--limit[Maximum results to display]:count:' \\
                                    '--refresh-catalog[Bypass catalog cache]' \\
                                    '--help[Show help information]'
                                ;;
                            completions)
                                _arguments \\
                                    '1:subcommand:(generate install)' \\
                                    '2:shell:(bash zsh fish)'
                                ;;
                        esac
                        ;;
                esac
            }

            _\(toolName) "$@"

            """
        }

        /// Fish completion script.
        private func fishScript(toolName: String) -> String {
            """
            # Fish completion for \(toolName)
            # Generated by spmx completions fish

            # Disable file completions by default
            complete -c \(toolName) -f

            # Top-level commands
            complete -c \(toolName) -n '__fish_use_subcommand' -a 'add' -d 'Add a dependency to Package.swift'
            complete -c \(toolName) -n '__fish_use_subcommand' -a 'remove' -d 'Remove a dependency from Package.swift'
            complete -c \(toolName) -n '__fish_use_subcommand' -a 'outdated' -d 'List outdated dependencies'
            complete -c \(toolName) -n '__fish_use_subcommand' -a 'why' -d 'Explain why a dependency is included'
            complete -c \(toolName) -n '__fish_use_subcommand' -a 'search' -d 'Search the Swift Package Index'
            complete -c \(toolName) -n '__fish_use_subcommand' -a 'completions' -d 'Generate shell completions'
            complete -c \(toolName) -n '__fish_use_subcommand' -l 'help' -d 'Show help information'
            complete -c \(toolName) -n '__fish_use_subcommand' -l 'version' -d 'Show the version'

            # add
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'url' -d 'Explicit repository URL' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'from' -d 'Version constraint (from)' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'exact' -d 'Pin to exact version' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'branch' -d 'Track a branch' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'revision' -d 'Pin to a revision' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'product' -d 'Library product to wire' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'target' -d 'Target to wire into' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -s 'p' -l 'path' -d 'Path to the package directory' -r -F
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'dry-run' -d 'Print planned edits without writing'
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'no-resolve' -d 'Skip swift package resolve after editing'
            complete -c \(toolName) -n '__fish_seen_subcommand_from add' -l 'refresh-catalog' -d 'Bypass catalog cache'

            # remove
            complete -c \(toolName) -n '__fish_seen_subcommand_from remove' -s 'p' -l 'path' -d 'Path to the package directory' -r -F
            complete -c \(toolName) -n '__fish_seen_subcommand_from remove' -l 'dry-run' -d 'Print planned edits without writing'
            complete -c \(toolName) -n '__fish_seen_subcommand_from remove' -l 'no-resolve' -d 'Skip swift package resolve after editing'

            # outdated
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -s 'p' -l 'path' -d 'Path to the package directory' -r -F
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -l 'all' -d 'Show all dependencies'
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -l 'direct' -d 'Only show direct dependencies'
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -l 'json' -d 'Output as JSON'
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -l 'ignore' -d 'Package identities to exclude' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -l 'no-color' -d 'Disable ANSI color output'
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -l 'exit-code' -d 'Exit non-zero if any outdated'
            complete -c \(toolName) -n '__fish_seen_subcommand_from outdated' -l 'refresh' -d 'Bypass version cache and re-fetch tags'

            # why
            complete -c \(toolName) -n '__fish_seen_subcommand_from why' -s 'p' -l 'path' -d 'Path to the package directory' -r -F
            complete -c \(toolName) -n '__fish_seen_subcommand_from why' -l 'json' -d 'Output as JSON'
            complete -c \(toolName) -n '__fish_seen_subcommand_from why' -l 'no-color' -d 'Disable ANSI color output'
            complete -c \(toolName) -n '__fish_seen_subcommand_from why' -l 'exit-code' -d 'Exit non-zero if missing manifests'

            # search
            complete -c \(toolName) -n '__fish_seen_subcommand_from search' -l 'json' -d 'Output as JSON'
            complete -c \(toolName) -n '__fish_seen_subcommand_from search' -l 'limit' -d 'Maximum results to display' -r
            complete -c \(toolName) -n '__fish_seen_subcommand_from search' -l 'refresh-catalog' -d 'Bypass catalog cache'

            # completions
            complete -c \(toolName) -n '__fish_seen_subcommand_from completions' -a 'generate install bash zsh fish'

            """
        }
    }
}

// MARK: - Errors

public enum CompletionsError: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
    case unknownShell(String)

    public var description: String {
        switch self {
        case .unknownShell(let shell):
            return """
            Unknown shell: "\(shell)". Supported shells: bash, zsh, fish.
            """
        }
    }

    public var errorDescription: String? { description }
}