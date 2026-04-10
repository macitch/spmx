/*
 *  File: PackageGraphTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("PackageGraph")
struct PackageGraphTests {

    // MARK: - Construction helpers

    /// Convenience factory: build a graph from an `[root: [dep]]`-style edge list.
    /// Nodes are inferred as the union of every key and every value.
    private func graph(
        root: String,
        edges: [String: [String]]
    ) -> PackageGraph {
        var nodeSet: Set<String> = [root]
        var edgeMap: [String: Set<String>] = [:]
        for (src, dsts) in edges {
            nodeSet.insert(src)
            edgeMap[src] = Set(dsts)
            for d in dsts { nodeSet.insert(d) }
        }
        return PackageGraph(root: root, nodes: nodeSet, edges: edgeMap)
    }

    // MARK: - Lookup

    @Test("contains is case-insensitive")
    func containsIsCaseInsensitive() {
        let g = graph(root: "App", edges: ["App": ["Alamofire"]])
        #expect(g.contains("alamofire"))
        #expect(g.contains("ALAMOFIRE"))
        #expect(g.contains("Alamofire"))
        #expect(!g.contains("not-present"))
    }

    @Test("direct dependencies are returned sorted")
    func directDepsSorted() {
        let g = graph(root: "app", edges: ["app": ["charlie", "alpha", "bravo"]])
        #expect(g.directDependencies(of: "app") == ["alpha", "bravo", "charlie"])
    }

    // MARK: - Path finding

    @Test("a direct dependency has a single two-node path")
    func directDependencyPath() {
        let g = graph(root: "app", edges: ["app": ["alamofire"]])
        #expect(g.paths(to: "alamofire") == [["app", "alamofire"]])
    }

    @Test("a transitive dependency walks through every intermediate")
    func transitivePath() {
        let g = graph(root: "app", edges: [
            "app": ["a"],
            "a":   ["b"],
            "b":   ["c"],
        ])
        #expect(g.paths(to: "c") == [["app", "a", "b", "c"]])
    }

    @Test("diamond dependency returns both paths, shortest first")
    func diamondReturnsBothPaths() {
        // app → a → target
        // app → b → c → target
        let g = graph(root: "app", edges: [
            "app":    ["a", "b"],
            "a":      ["target"],
            "b":      ["c"],
            "c":      ["target"],
        ])
        let paths = g.paths(to: "target")
        #expect(paths.count == 2)
        #expect(paths[0] == ["app", "a", "target"])       // shorter first
        #expect(paths[1] == ["app", "b", "c", "target"])
    }

    @Test("multiple same-length paths are ordered lexicographically")
    func sameLengthPathsLexOrdered() {
        let g = graph(root: "app", edges: [
            "app":    ["a", "b"],
            "a":      ["target"],
            "b":      ["target"],
        ])
        let paths = g.paths(to: "target")
        #expect(paths == [
            ["app", "a", "target"],
            ["app", "b", "target"],
        ])
    }

    @Test("path lookup is case-insensitive on both ends")
    func pathLookupIsCaseInsensitive() {
        let g = PackageGraph(
            root: "App",
            nodes: ["App", "Alamofire"],
            edges: ["App": ["Alamofire"]]
        )
        #expect(g.paths(to: "ALAMOFIRE") == [["app", "alamofire"]])
        #expect(g.paths(to: "alamofire") == [["app", "alamofire"]])
    }

    @Test("package not in the graph returns empty")
    func notInGraphReturnsEmpty() {
        let g = graph(root: "app", edges: ["app": ["alamofire"]])
        #expect(g.paths(to: "missing").isEmpty)
    }

    @Test("a node present but unreachable from root returns empty")
    func presentButUnreachable() {
        // `orphan` is a declared node but has no incoming edge from `app`. This is the
        // stale-Package.resolved case: the user ran `remove` via Xcode but the pin stuck.
        let g = PackageGraph(
            root: "app",
            nodes: ["app", "a", "orphan"],
            edges: ["app": ["a"]]
        )
        #expect(g.paths(to: "orphan").isEmpty)
    }

    @Test("root lookup returns the trivial self-path")
    func rootLookup() {
        let g = graph(root: "app", edges: ["app": ["a"]])
        #expect(g.paths(to: "app") == [["app"]])
    }

    @Test("defensive cycle handling: a back-edge is not followed")
    func cycleDefensive() {
        // SPM disallows cycles but the walker should not hang if one slips in (e.g., from
        // a corrupted Package.resolved or a manifest that lies).
        let g = graph(root: "app", edges: [
            "app": ["a"],
            "a":   ["b"],
            "b":   ["a", "target"], // back-edge to a
        ])
        let paths = g.paths(to: "target")
        #expect(paths == [["app", "a", "b", "target"]])
    }
}