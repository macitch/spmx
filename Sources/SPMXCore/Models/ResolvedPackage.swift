/*
 *  File: ResolvedPackage.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// A typed representation of `Package.resolved` (v2 and v3 formats).
///
/// SPM has shipped two on-disk formats for `Package.resolved`:
///
/// - **v2** (Swift 5.6+): pins live at `pins[]` with `identity`, `kind`, `location`, `state`.
/// - **v3** (Swift 5.9+): same shape as v2 but with an updated `version` field. We treat them
///   the same after parsing.
///
/// We deliberately model only the fields we need. If Apple adds new fields, ignoring them is
/// safer than failing to decode.
public struct ResolvedFile: Codable, Sendable, Equatable {
    public let version: Int
    public let pins: [Pin]

    public struct Pin: Codable, Sendable, Equatable {
        public let identity: String
        public let kind: Kind
        public let location: String
        public let state: State

        public enum Kind: String, Codable, Sendable {
            case remoteSourceControl
            case localSourceControl
            case registry
        }

        public struct State: Codable, Sendable, Equatable {
            public let revision: String?
            public let version: String?
            public let branch: String?
        }
    }
}

public extension ResolvedFile.Pin {
    /// Human-friendly current version string. Falls back to branch name or short SHA.
    var displayVersion: String {
        if let v = state.version { return v }
        if let b = state.branch { return "branch:\(b)" }
        if let r = state.revision { return String(r.prefix(7)) }
        return "unknown"
    }
}