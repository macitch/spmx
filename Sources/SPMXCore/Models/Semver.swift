/*
 *  File: Semver.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// A semantic version (https://semver.org/) value type.
///
/// We model only what `spmx outdated` needs: parse strings of the form `MAJOR.MINOR.PATCH`
/// with optional `-prerelease` and `+build` segments, and compare them per the spec. Build
/// metadata is parsed but ignored for ordering, as required by semver.
///
/// Tag prefixes (`v1.2.3`, `V1.2.3`) are tolerated because they're common in the wild even
/// though they're not technically semver. Anything else returns nil from the failable init.
public struct Semver: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Empty for release versions. Each identifier is one dot-separated segment.
    public let prerelease: [String]
    /// Build metadata. Parsed but ignored for both ordering AND equality, per semver.org §10.
    /// Two versions that differ only in build metadata are considered the same version.
    public let build: [String]

    public static func == (lhs: Semver, rhs: Semver) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    public init(
        major: Int,
        minor: Int,
        patch: Int,
        prerelease: [String] = [],
        build: [String] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        if !build.isEmpty { s += "+" + build.joined(separator: ".") }
        return s
    }

    /// Failable parser. Accepts an optional `v`/`V` prefix.
    public init?(_ raw: String) {
        var s = Substring(raw)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }

        // Build metadata: everything after the first '+'.
        var build: [String] = []
        if let plusIdx = s.firstIndex(of: "+") {
            build = s[s.index(after: plusIdx)...]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            s = s[..<plusIdx]
            if build.contains(where: \.isEmpty) { return nil }
        }

        // Prerelease: everything after the first '-'.
        var prerelease: [String] = []
        if let dashIdx = s.firstIndex(of: "-") {
            prerelease = s[s.index(after: dashIdx)...]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            s = s[..<dashIdx]
            if prerelease.contains(where: \.isEmpty) { return nil }
        }

        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let maj = Int(parts[0]),
              let min = Int(parts[1]),
              let pat = Int(parts[2]),
              maj >= 0, min >= 0, pat >= 0
        else { return nil }

        self.init(major: maj, minor: min, patch: pat, prerelease: prerelease, build: build)
    }

    public static func < (lhs: Semver, rhs: Semver) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Prerelease ordering, per semver.org #11:
        //   1.0.0-alpha  <  1.0.0
        //   1.0.0-alpha  <  1.0.0-alpha.1
        //   numeric identifiers compare numerically
        //   numeric identifiers always have lower precedence than alphanumeric ones
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false   // release > prerelease
        case (false, true): return true    // prerelease < release
        case (false, false):
            for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
                if l == r { continue }
                let lInt = Int(l)
                let rInt = Int(r)
                switch (lInt, rInt) {
                case let (li?, ri?): return li < ri
                case (_?, nil): return true     // numeric < alphanumeric
                case (nil, _?): return false
                case (nil, nil): return l < r
                }
            }
            // All shared identifiers equal: shorter prerelease wins.
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    /// Severity of an upgrade from `self` to `other`. `nil` if `other` is not newer.
    public enum Drift: Sendable, Equatable {
        case major
        case minor
        case patch
        case prerelease
    }

    public func drift(to other: Semver) -> Drift? {
        guard self < other else { return nil }
        if other.major > self.major { return .major }
        if other.minor > self.minor { return .minor }
        if other.patch > self.patch { return .patch }
        return .prerelease
    }
}