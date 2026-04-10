/*
 *  File: OutdatedRow.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// One row in `spmx outdated` output.
///
/// Pure data — no formatting, no colors. The renderer turns this into a line of text and
/// the JSON encoder turns it into one object in an array. Keeping presentation out of the
/// model means the status-classification logic is testable without asserting on ANSI
/// escape sequences.
public struct OutdatedRow: Sendable, Equatable, Codable {
    public let identity: String
    /// Human-readable current version. May be a semver, a branch name (`branch:main`),
    /// or a short SHA — whatever `Pin.displayVersion` produced.
    public let current: String
    /// Latest available version, if known. `nil` for skipped/failed/branch-pinned rows.
    public let latest: String?
    public let status: Status
    /// Free-form note shown in the rightmost column. Failure messages, skip reasons, etc.
    public let note: String?

    public enum Status: String, Sendable, Equatable, Codable {
        /// Current version equals the latest available. Render green.
        case upToDate
        /// Current version is older but on the same major. Render yellow.
        case behindMinorPatch
        /// Current version is on an older major. Render red.
        case behindMajor
        /// We couldn't classify this row — fetch failed, no semver tags, non-remote pin,
        /// etc. Render dim/gray. Always pair with a `note`.
        case unknown
        /// Pin is tracking a git branch but the remote *does* have semver tags. The user
        /// is on a moving target while a stable line exists — actionable, not unknown.
        /// Render yellow. Note column shows the branch and the latest stable.
        case pinnedToBranch
    }

    public init(
        identity: String,
        current: String,
        latest: String?,
        status: Status,
        note: String?
    ) {
        self.identity = identity
        self.current = current
        self.latest = latest
        self.status = status
        self.note = note
    }

    /// Bridges raw fetcher output into a renderable row.
    ///
    /// This is where all the awkward edge-case logic lives: branch pins, registry pins,
    /// non-semver tags, downgrades (current > latest, which can happen with prerelease
    /// channels), and outright fetch failures. Centralising it here keeps both the
    /// renderer and the JSON encoder dumb.
    public static func from(
        pin: ResolvedFile.Pin,
        fetchResult: VersionFetchResult
    ) -> OutdatedRow {
        let currentDisplay = pin.displayVersion
        let currentSemver = pin.state.version.flatMap(Semver.init)

        switch fetchResult {
        case .skipped(let reason):
            return OutdatedRow(
                identity: pin.identity,
                current: currentDisplay,
                latest: nil,
                status: .unknown,
                note: reason
            )

        case .fetchFailed(let message):
            return OutdatedRow(
                identity: pin.identity,
                current: currentDisplay,
                latest: nil,
                status: .unknown,
                note: "fetch failed: \(message)"
            )

        case .noVersionTags:
            return OutdatedRow(
                identity: pin.identity,
                current: currentDisplay,
                latest: nil,
                status: .unknown,
                note: "no semver tags on remote"
            )

        case .found(let latest):
            // We have a latest, but the current pin may not be a semver (e.g. branch).
            // In that case we can't compute drift — but if the pin is explicitly tracking
            // a branch we can still tell the user something useful: which branch they're
            // on and what the latest stable line looks like.
            guard let current = currentSemver else {
                if let branch = pin.state.branch {
                    return OutdatedRow(
                        identity: pin.identity,
                        current: currentDisplay,
                        latest: latest.description,
                        status: .pinnedToBranch,
                        note: "on branch \(branch) — latest stable is \(latest.description)"
                    )
                }
                return OutdatedRow(
                    identity: pin.identity,
                    current: currentDisplay,
                    latest: latest.description,
                    status: .unknown,
                    note: "non-semver pin"
                )
            }

            if let drift = current.drift(to: latest) {
                let status: Status = (drift == .major) ? .behindMajor : .behindMinorPatch
                return OutdatedRow(
                    identity: pin.identity,
                    current: currentDisplay,
                    latest: latest.description,
                    status: status,
                    note: nil
                )
            } else {
                // No drift means current >= latest. Almost always "up to date", but
                // could also be "ahead" (user pinned a prerelease newer than any
                // released tag). We collapse both to upToDate — the user explicitly
                // chose the version they're on, no warning needed.
                return OutdatedRow(
                    identity: pin.identity,
                    current: currentDisplay,
                    latest: latest.description,
                    status: .upToDate,
                    note: nil
                )
            }
        }
    }
}