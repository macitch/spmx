/*
 *  File: GitEnvironment.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Pre-flight check for git availability.
///
/// `spmx add` and `spmx outdated` shell out to `git ls-remote` / `git clone`.
/// If git is not on `PATH`, those commands fail with vague errors ("no semver
/// tags found", "clone failed"). This helper fails fast with a clear message.
public enum GitEnvironment {

    /// Verifies that `git` is reachable via `/usr/bin/env git`.
    /// Throws a descriptive error if it isn't.
    public static func requireGit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitNotFound()
            }
        } catch is GitNotFound {
            throw GitNotFound()
        } catch {
            throw GitNotFound()
        }
    }

    /// Error thrown when git is not found on `PATH`.
    public struct GitNotFound: Error, LocalizedError, CustomStringConvertible, Sendable {
        public var description: String {
            "git is not available on your PATH. spmx requires git for version lookups and cloning. Install git or add it to your PATH."
        }
        public var errorDescription: String? { description }
    }
}