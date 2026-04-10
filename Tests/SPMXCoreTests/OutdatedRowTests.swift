/*
 *  File: OutdatedRowTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("OutdatedRow.from")
struct OutdatedRowTests {

    private func makePin(
        identity: String = "lib",
        version: String? = "1.0.0",
        branch: String? = nil,
        kind: ResolvedFile.Pin.Kind = .remoteSourceControl
    ) -> ResolvedFile.Pin {
        ResolvedFile.Pin(
            identity: identity,
            kind: kind,
            location: "https://example.com/\(identity).git",
            state: .init(revision: "abc1234567", version: version, branch: branch)
        )
    }

    @Test("up to date when current equals latest")
    func upToDate() {
        let row = OutdatedRow.from(
            pin: makePin(version: "1.2.3"),
            fetchResult: .found(Semver("1.2.3")!)
        )
        #expect(row.status == .upToDate)
        #expect(row.latest == "1.2.3")
        #expect(row.note == nil)
    }

    @Test("up to date when current is ahead of latest (user on prerelease)")
    func currentAheadCollapsesToUpToDate() {
        let row = OutdatedRow.from(
            pin: makePin(version: "2.0.0"),
            fetchResult: .found(Semver("1.5.0")!)
        )
        #expect(row.status == .upToDate)
    }

    @Test("minor and patch drift both classify as behindMinorPatch")
    func minorAndPatchDriftCollapse() {
        let minor = OutdatedRow.from(
            pin: makePin(version: "1.0.0"),
            fetchResult: .found(Semver("1.5.0")!)
        )
        let patch = OutdatedRow.from(
            pin: makePin(version: "1.0.0"),
            fetchResult: .found(Semver("1.0.5")!)
        )
        #expect(minor.status == .behindMinorPatch)
        #expect(patch.status == .behindMinorPatch)
    }

    @Test("major drift classifies as behindMajor")
    func majorDrift() {
        let row = OutdatedRow.from(
            pin: makePin(version: "1.5.0"),
            fetchResult: .found(Semver("2.0.0")!)
        )
        #expect(row.status == .behindMajor)
        #expect(row.latest == "2.0.0")
    }

    @Test("branch-pinned packages surface as pinnedToBranch with an actionable note")
    func branchPinned() {
        let pin = makePin(version: nil, branch: "main")
        let row = OutdatedRow.from(pin: pin, fetchResult: .found(Semver("1.0.0")!))
        // Branch pins used to collapse into .unknown, which buried them. When the remote
        // has a stable tag we know exactly what to tell the user: which branch they're
        // tracking and what the latest release looks like. See `OutdatedRow.from` for
        // the rationale behind the status promotion.
        #expect(row.status == .pinnedToBranch)
        #expect(row.current == "branch:main")
        #expect(row.latest == "1.0.0")
        #expect(row.note?.contains("main") == true)
        #expect(row.note?.contains("1.0.0") == true)
    }

    @Test("fetch failure is preserved as a note")
    func fetchFailurePropagates() {
        let row = OutdatedRow.from(
            pin: makePin(),
            fetchResult: .fetchFailed("repository not found")
        )
        #expect(row.status == .unknown)
        #expect(row.latest == nil)
        #expect(row.note?.contains("repository not found") == true)
    }

    @Test("no version tags shows the right note")
    func noVersionTags() {
        let row = OutdatedRow.from(pin: makePin(), fetchResult: .noVersionTags)
        #expect(row.status == .unknown)
        #expect(row.note?.contains("no semver tags") == true)
    }

    @Test("skipped pins surface the skip reason")
    func skippedPin() {
        let row = OutdatedRow.from(
            pin: makePin(kind: .localSourceControl),
            fetchResult: .skipped(reason: "non-remote pin (localSourceControl)")
        )
        #expect(row.status == .unknown)
        #expect(row.note?.contains("non-remote") == true)
    }

    @Test("OutdatedRow round-trips through JSON")
    func codableRoundTrip() throws {
        let original = OutdatedRow(
            identity: "alamofire",
            current: "5.8.0",
            latest: "5.9.1",
            status: .behindMinorPatch,
            note: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OutdatedRow.self, from: data)
        #expect(decoded == original)
    }
}