/*
 *  File: ManifestLoaderTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("DiskCachedManifestLoader")
struct ManifestLoaderTests {

    // MARK: - Fake runner

    /// Actor-based fake so we can count calls from concurrent contexts under strict concurrency.
    /// Each call appends to `invocations` and returns a canned result (or throws).
    private actor FakeProcessRunner: ProcessRunning {
        private(set) var invocations: [(executable: String, arguments: [String])] = []
        private let response: Result<ProcessResult, Swift.Error>

        init(response: Result<ProcessResult, Swift.Error>) {
            self.response = response
        }

        nonisolated func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
            await self.record(executable: executable, arguments: arguments)
            switch response {
            case .success(let result): return result
            case .failure(let err): throw err
            }
        }

        private func record(executable: String, arguments: [String]) {
            invocations.append((executable, arguments))
        }

        func callCount() -> Int { invocations.count }
    }

    // MARK: - Fixtures

    private let sampleDumpJSON = #"""
    {
      "name": "Fixture",
      "dependencies": [
        {
          "sourceControl": [
            {"identity": "alpha", "location": {"remote": [{"urlString": "x"}]}}
          ]
        },
        {
          "fileSystem": [
            {"identity": "local", "path": "../local"}
          ]
        }
      ]
    }
    """#

    /// Stages a temporary package directory containing a Package.swift with fixed contents,
    /// plus a sibling cache directory. Returns both URLs.
    private func stage(
        manifestContents: String = "// swift-tools-version:5.9\n// dummy content\n"
    ) throws -> (packageDir: URL, cacheDir: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-loader-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let pkg = root.appendingPathComponent("pkg", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(manifestContents.utf8)
            .write(to: pkg.appendingPathComponent("Package.swift"))
        return (pkg, cache)
    }

    // MARK: - Tests

    @Test("cache miss shells out once and returns the decoded dump")
    func cacheMissShellsOut() async throws {
        let (pkg, cache) = try stage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }

        let runner = FakeProcessRunner(response: .success(
            ProcessResult(exitCode: 0, stdout: sampleDumpJSON, stderr: "")
        ))
        let loader = DiskCachedManifestLoader(
            runner: runner,
            cacheDirectory: cache
        )

        let dump = try await loader.load(packageDirectory: pkg)

        #expect(dump.name == "Fixture")
        #expect(dump.dependencies.map(\.identity) == ["alpha", "local"])
        #expect(await runner.callCount() == 1)
    }

    @Test("second call with unchanged manifest hits the cache and does not shell out")
    func cacheHitSkipsRunner() async throws {
        let (pkg, cache) = try stage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }

        let runner = FakeProcessRunner(response: .success(
            ProcessResult(exitCode: 0, stdout: sampleDumpJSON, stderr: "")
        ))
        let loader = DiskCachedManifestLoader(
            runner: runner,
            cacheDirectory: cache
        )

        // Warm the cache.
        _ = try await loader.load(packageDirectory: pkg)
        // Hit the cache.
        let second = try await loader.load(packageDirectory: pkg)

        #expect(second.name == "Fixture")
        #expect(await runner.callCount() == 1, "cache hit should not invoke the runner again")
    }

    @Test("editing the manifest invalidates the cache")
    func manifestEditInvalidatesCache() async throws {
        let (pkg, cache) = try stage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }

        let runner = FakeProcessRunner(response: .success(
            ProcessResult(exitCode: 0, stdout: sampleDumpJSON, stderr: "")
        ))
        let loader = DiskCachedManifestLoader(
            runner: runner,
            cacheDirectory: cache
        )

        _ = try await loader.load(packageDirectory: pkg)
        // Edit the manifest — new contents means a new SHA means a cache miss.
        try Data("// swift-tools-version:5.9\n// EDITED\n".utf8)
            .write(to: pkg.appendingPathComponent("Package.swift"))
        _ = try await loader.load(packageDirectory: pkg)

        #expect(await runner.callCount() == 2)
    }

    @Test("missing Package.swift throws packageSwiftNotFound")
    func missingManifestThrows() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-loader-empty-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let runner = FakeProcessRunner(response: .success(
            ProcessResult(exitCode: 0, stdout: "", stderr: "")
        ))
        let loader = DiskCachedManifestLoader(runner: runner, cacheDirectory: root)

        await #expect(throws: ManifestLoaderError.self) {
            _ = try await loader.load(packageDirectory: root)
        }
    }

    @Test("non-zero exit from dump-package surfaces as dumpFailed with stderr")
    func nonZeroExitIsSurfaced() async throws {
        let (pkg, cache) = try stage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }

        let runner = FakeProcessRunner(response: .success(
            ProcessResult(exitCode: 1, stdout: "", stderr: "error: malformed manifest\n")
        ))
        let loader = DiskCachedManifestLoader(runner: runner, cacheDirectory: cache)

        do {
            _ = try await loader.load(packageDirectory: pkg)
            Issue.record("expected dumpFailed, got success")
        } catch let err as ManifestLoaderError {
            #expect(err.description.contains("malformed manifest"))
            #expect(err.description.contains("exit 1"))
        }
    }

    @Test("malformed JSON surfaces as decodeFailed")
    func malformedJSONIsSurfaced() async throws {
        let (pkg, cache) = try stage()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }

        let runner = FakeProcessRunner(response: .success(
            ProcessResult(exitCode: 0, stdout: "this is not json", stderr: "")
        ))
        let loader = DiskCachedManifestLoader(runner: runner, cacheDirectory: cache)

        do {
            _ = try await loader.load(packageDirectory: pkg)
            Issue.record("expected decodeFailed, got success")
        } catch let err as ManifestLoaderError {
            #expect(err.description.contains("decode"))
        }
    }
}