/*
 *  File: SemverTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("Semver")
struct SemverTests {

    // MARK: - Parsing

    @Test("parses plain MAJOR.MINOR.PATCH")
    func parsesPlain() throws {
        let v = try #require(Semver("1.2.3"))
        #expect(v.major == 1)
        #expect(v.minor == 2)
        #expect(v.patch == 3)
        #expect(v.prerelease.isEmpty)
        #expect(v.build.isEmpty)
        #expect(!v.isPrerelease)
    }

    @Test("tolerates a v prefix")
    func tolratesVPrefix() throws {
        let lower = try #require(Semver("v1.2.3"))
        let upper = try #require(Semver("V1.2.3"))
        #expect(lower == upper)
        #expect(lower.major == 1)
    }

    @Test("parses prerelease identifiers")
    func parsesPrerelease() throws {
        let v = try #require(Semver("1.0.0-beta.1"))
        #expect(v.prerelease == ["beta", "1"])
        #expect(v.isPrerelease)
    }

    @Test("parses build metadata")
    func parsesBuildMetadata() throws {
        let v = try #require(Semver("1.0.0-rc.2+exp.sha.5114f85"))
        #expect(v.prerelease == ["rc", "2"])
        #expect(v.build == ["exp", "sha", "5114f85"])
    }

    @Test("rejects malformed input", arguments: [
        "1.2",
        "1.2.3.4",
        "abc",
        "",
        "1.2.x",
        "-1.0.0",
        "1.0.0-",
        "1.0.0+",
    ])
    func rejectsMalformed(_ raw: String) {
        #expect(Semver(raw) == nil)
    }

    // MARK: - Ordering

    @Test("major beats minor beats patch")
    func basicOrdering() {
        #expect(Semver("1.0.0")! < Semver("2.0.0")!)
        #expect(Semver("1.1.0")! < Semver("1.2.0")!)
        #expect(Semver("1.0.1")! < Semver("1.0.2")!)
    }

    @Test("a release outranks any prerelease of the same MMP")
    func releaseBeatsPrerelease() {
        #expect(Semver("1.0.0-beta")! < Semver("1.0.0")!)
        #expect(Semver("1.0.0-rc.99")! < Semver("1.0.0")!)
    }

    @Test("prerelease identifier ordering follows semver.org")
    func prereleaseOrdering() {
        // alpha < beta (alphabetical)
        #expect(Semver("1.0.0-alpha")! < Semver("1.0.0-beta")!)
        // numeric < alphanumeric
        #expect(Semver("1.0.0-1")! < Semver("1.0.0-alpha")!)
        // numeric compares numerically, not lexically
        #expect(Semver("1.0.0-alpha.2")! < Semver("1.0.0-alpha.10")!)
        // shorter prerelease wins when prefixes match
        #expect(Semver("1.0.0-alpha")! < Semver("1.0.0-alpha.1")!)
    }

    @Test("build metadata is ignored for ordering and equality")
    func buildMetadataIgnored() {
        let a = Semver("1.0.0+build.1")!
        let b = Semver("1.0.0+build.999")!
        #expect(!(a < b))
        #expect(!(b < a))
        #expect(a == b)            // semver.org §10: build metadata is not part of identity
        #expect(a.hashValue == b.hashValue)
    }

    // MARK: - Drift

    @Test("drift classifies major / minor / patch upgrades")
    func driftClassification() {
        let base = Semver("1.2.3")!
        #expect(base.drift(to: Semver("2.0.0")!) == .major)
        #expect(base.drift(to: Semver("1.3.0")!) == .minor)
        #expect(base.drift(to: Semver("1.2.4")!) == .patch)
        #expect(base.drift(to: Semver("1.2.3")!) == nil)
        #expect(base.drift(to: Semver("1.2.2")!) == nil)
    }
}