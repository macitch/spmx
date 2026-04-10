/*
 *  File: ManifestWriteGuardTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("ManifestWriteGuard")
struct ManifestWriteGuardTests {

    // MARK: - Fixture

    private let originalManifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Original",
        dependencies: [],
        targets: [
            .target(name: "Original"),
        ]
    )
    """

    private let editedManifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Original",
        dependencies: [
            .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        ],
        targets: [
            .target(name: "Original"),
        ]
    )
    """

    private func stageManifest(_ source: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-guard-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Package.swift")
        try Data(source.utf8).write(to: url)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Tests

    @Test("successful resolve keeps the edited manifest")
    func successfulResolve() async throws {
        let url = try stageManifest(originalManifest)
        defer { cleanup(url) }

        // Fake runner that always succeeds resolve.
        let fake = FakeGuardRunner(exitCode: 0)
        let guard_ = ManifestWriteGuard(runner: fake)
        let editor = try ManifestEditor.parse(source: editedManifest)

        try await guard_.writeAndResolve(editor: editor, to: url)

        // The file should contain the edited content.
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("Alamofire"))
    }

    @Test("failed resolve reverts to original manifest")
    func failedResolveReverts() async throws {
        let url = try stageManifest(originalManifest)
        defer { cleanup(url) }

        // Fake runner that fails resolve.
        let fake = FakeGuardRunner(exitCode: 1, stderr: "error: dependency resolution failed")
        let guard_ = ManifestWriteGuard(runner: fake)
        let editor = try ManifestEditor.parse(source: editedManifest)

        do {
            try await guard_.writeAndResolve(editor: editor, to: url)
            Issue.record("expected ResolveFailure")
        } catch is ManifestWriteGuard.ResolveFailure {
            // Expected.
        }

        // The file should be reverted to the original.
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("Alamofire"))
        #expect(contents.contains("\"Original\""))
    }

    @Test("ResolveFailure error mentions restoration")
    func resolveFailureMessage() {
        let err = ManifestWriteGuard.ResolveFailure(stderr: "something broke")
        #expect(err.description.contains("restored"))
        #expect(err.description.contains("something broke"))
    }
}

/// Test double for `ProcessRunning` used by ManifestWriteGuard tests.
private actor FakeGuardRunner: ProcessRunning {
    private let result: ProcessResult

    init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.result = ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        result
    }
}