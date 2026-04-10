/*
 *  File: GraphBuilderTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("GraphBuilder")
struct GraphBuilderTests {

    // MARK: - Stub loader

    /// In-memory `ManifestLoading` keyed by directory path. Tests register the manifests
    /// they expect to be loaded; any directory not in the dictionary throws, simulating
    /// a missing checkout.
    private actor StubManifestLoader: ManifestLoading {
        private var manifests: [String: ManifestDump] = [:]
        private(set) var loadedDirectories: [String] = []

        init(manifests: [String: ManifestDump]) {
            self.manifests = manifests
        }

        nonisolated func load(packageDirectory: URL) async throws -> ManifestDump {
            try await self.lookup(path: packageDirectory.standardizedFileURL.path)
        }

        private func lookup(path: String) throws -> ManifestDump {
            loadedDirectories.append(path)
            guard let dump = manifests[path] else {
                throw ManifestLoaderError.packageSwiftNotFound(URL(fileURLWithPath: path))
            }
            return dump
        }
    }

    // MARK: - On-disk fixture helpers

    /// Stages a temporary directory with a `.build/checkouts/` subtree containing
    /// stub `Package.swift` files for each named dependency. The contents don't matter —
    /// `StubManifestLoader` keys off paths, not file contents — but the files must exist
    /// because `GraphBuilder.checkoutDirectory(for:)` checks `fileExists` before loading.
    private func stageRoot(checkoutNames: [String] = []) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-graph-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Place a Package.swift at the root so the loader path resolves cleanly even
        // though the StubManifestLoader doesn't actually read it.
        try Data("// stub\n".utf8).write(to: root.appendingPathComponent("Package.swift"))

        let checkouts = root.appendingPathComponent(".build/checkouts", isDirectory: true)
        try fm.createDirectory(at: checkouts, withIntermediateDirectories: true)
        for name in checkoutNames {
            let dir = checkouts.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("// stub\n".utf8).write(to: dir.appendingPathComponent("Package.swift"))
        }
        return root
    }

    private func pin(
        _ identity: String,
        kind: ResolvedFile.Pin.Kind = .remoteSourceControl,
        location: String? = nil
    ) -> ResolvedFile.Pin {
        ResolvedFile.Pin(
            identity: identity,
            kind: kind,
            location: location ?? "https://example.com/\(identity).git",
            state: .init(revision: "abc123def456abc123", version: "1.0.0", branch: nil)
        )
    }

    private func dump(name: String, deps: [(String, ManifestDump.Dependency.Kind)] = []) -> ManifestDump {
        ManifestDump(
            name: name,
            dependencies: deps.map { .init(identity: $0.0, kind: $0.1) }
        )
    }

    // MARK: - Tests

    @Test("a simple chain root → a → b → c builds the expected adjacency")
    func simpleChain() async throws {
        let root = try stageRoot(checkoutNames: ["a", "b", "c"])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifests: [String: ManifestDump] = [
            root.standardizedFileURL.path: dump(name: "App", deps: [("a", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/a").standardizedFileURL.path:
                dump(name: "A", deps: [("b", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/b").standardizedFileURL.path:
                dump(name: "B", deps: [("c", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/c").standardizedFileURL.path:
                dump(name: "C", deps: []),
        ]
        let resolved = ResolvedFile(version: 3, pins: [pin("a"), pin("b"), pin("c")])
        let builder = GraphBuilder(manifestLoader: StubManifestLoader(manifests: manifests))

        let result = await builder.build(rootDirectory: root, resolved: resolved)
        #expect(!result.hadMissingManifests)
        #expect(result.graph.paths(to: "c") == [["app", "a", "b", "c"]])
    }

    @Test("diamond dependency yields both paths")
    func diamond() async throws {
        let root = try stageRoot(checkoutNames: ["a", "b", "shared"])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifests: [String: ManifestDump] = [
            root.standardizedFileURL.path:
                dump(name: "App", deps: [("a", .sourceControl), ("b", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/a").standardizedFileURL.path:
                dump(name: "A", deps: [("shared", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/b").standardizedFileURL.path:
                dump(name: "B", deps: [("shared", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/shared").standardizedFileURL.path:
                dump(name: "Shared", deps: []),
        ]
        let resolved = ResolvedFile(version: 3, pins: [pin("a"), pin("b"), pin("shared")])
        let builder = GraphBuilder(manifestLoader: StubManifestLoader(manifests: manifests))

        let result = await builder.build(rootDirectory: root, resolved: resolved)
        let paths = result.graph.paths(to: "shared")
        #expect(paths.count == 2)
        #expect(paths.contains(["app", "a", "shared"]))
        #expect(paths.contains(["app", "b", "shared"]))
    }

    @Test("registry dependencies appear as edge-less leaves")
    func registryLeaf() async throws {
        let root = try stageRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifests: [String: ManifestDump] = [
            root.standardizedFileURL.path:
                dump(name: "App", deps: [("acme.widget", .registry)]),
        ]
        let resolved = ResolvedFile(version: 3, pins: [pin("acme.widget", kind: .registry)])
        let builder = GraphBuilder(manifestLoader: StubManifestLoader(manifests: manifests))

        let result = await builder.build(rootDirectory: root, resolved: resolved)
        #expect(!result.hadMissingManifests)
        #expect(result.graph.paths(to: "acme.widget") == [["app", "acme.widget"]])
        #expect(result.graph.directDependencies(of: "acme.widget").isEmpty)
    }

    @Test("missing checkout becomes a partial graph, not a thrown error")
    func missingCheckoutIsPartial() async throws {
        // Stage the directory but do NOT create the checkout for "deep" — simulating an
        // unresolved transitive dep.
        let root = try stageRoot(checkoutNames: ["a"])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifests: [String: ManifestDump] = [
            root.standardizedFileURL.path:
                dump(name: "App", deps: [("a", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/a").standardizedFileURL.path:
                dump(name: "A", deps: [("deep", .sourceControl)]),
            // No entry for `deep` — its checkout doesn't exist.
        ]
        let resolved = ResolvedFile(version: 3, pins: [pin("a"), pin("deep")])
        let builder = GraphBuilder(manifestLoader: StubManifestLoader(manifests: manifests))

        let result = await builder.build(rootDirectory: root, resolved: resolved)
        // `deep` is reachable in the graph (a → deep edge was recorded), and its own
        // outgoing edges are unknown — so hadMissingManifests MUST be set, and the
        // identity MUST appear in missingIdentities. If the checkout directory lookup
        // silently returned nil without flagging this, downstream commands would show
        // a misleadingly "complete" graph.
        #expect(result.graph.paths(to: "deep") == [["app", "a", "deep"]])
        #expect(result.hadMissingManifests, "source-control dep with no checkout must be flagged")
        #expect(result.missingIdentities.contains("deep"))
    }

    @Test("orphan pin (in resolved but not referenced) is added as an unreachable node")
    func orphanPinIsUnreachable() async throws {
        let root = try stageRoot(checkoutNames: ["a"])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifests: [String: ManifestDump] = [
            root.standardizedFileURL.path:
                dump(name: "App", deps: [("a", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/a").standardizedFileURL.path:
                dump(name: "A", deps: []),
        ]
        // `orphan` is pinned but never referenced from any manifest.
        let resolved = ResolvedFile(version: 3, pins: [pin("a"), pin("orphan")])
        let builder = GraphBuilder(manifestLoader: StubManifestLoader(manifests: manifests))

        let result = await builder.build(rootDirectory: root, resolved: resolved)
        #expect(result.graph.contains("orphan"))
        #expect(result.graph.paths(to: "orphan").isEmpty)
    }

    @Test("root manifest load failure returns an empty graph with the failure flagged")
    func rootLoadFailure() async throws {
        let root = try stageRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Empty manifest dictionary → loader throws on every call, including the root.
        let builder = GraphBuilder(manifestLoader: StubManifestLoader(manifests: [:]))

        let result = await builder.build(
            rootDirectory: root,
            resolved: ResolvedFile(version: 3, pins: [])
        )
        #expect(result.hadMissingManifests)
        #expect(result.missingIdentities == ["<root>"])
        #expect(result.graph.paths(to: "anything").isEmpty)
    }
}