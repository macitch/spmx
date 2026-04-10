/*
 *  File: PackageGraph.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// A directed dependency graph of packages in a Swift project.
///
/// `PackageGraph` is a **pure data structure**: no I/O, no caching, no async work. It's
/// built by `GraphBuilder` from a `ResolvedFile` + a set of `ManifestDump`s and then passed
/// to `WhyRunner` for path-finding. Keeping it pure means the graph logic is trivially
/// unit-testable and reusable — a future `spmx tree` command can consume the same type.
///
/// ## Identity
///
/// Nodes are keyed by **lowercased package identity**. SPM's identity computation is
/// case-sensitive in `Package.resolved` but case-insensitive in dependency resolution;
/// lowercasing at ingest means `Alamofire`, `alamofire`, and `ALAMOFIRE` all collapse into
/// one node instead of three phantom siblings. If this oversimplification bites us in
/// practice we can revisit — but the alternative (preserving case and doing fuzzy match at
/// lookup time) triples the code without meaningfully helping 99 % of users.
///
/// ## Edges
///
/// Edges are directed: `A → B` means "package A depends on package B". `edges[A]` returns
/// every package A directly depends on. There is no back-edge table — callers that need
/// reverse edges should compute them at construction time.
///
/// ## Root
///
/// The root package is the one the user is running `spmx why` in. It's stored explicitly
/// so `paths(to:)` knows where to start the walk. The root always appears as a node and
/// its outgoing edges are the user's direct dependencies.
public struct PackageGraph: Sendable, Equatable {
    /// Lowercased identity of the root package.
    public let root: String

    /// All packages in the graph, including the root. Lowercased identities.
    public let nodes: Set<String>

    /// Directed adjacency: `edges[A]` is the set of packages A directly depends on.
    /// Stored as `[String: Set<String>]` — `Set` so duplicate edge insertion is idempotent
    /// and membership checks are O(1).
    public let edges: [String: Set<String>]

    /// Hard cap on the number of paths `paths(to:)` will enumerate. A pathological graph
    /// (long chains with many diamonds) can have exponential simple paths; real-world Swift
    /// projects never come close to 50. When hit, the last element of the returned array
    /// will have a sentinel marker (empty array) so the renderer can say "...and more".
    public static let maxPaths = 50

    public init(
        root: String,
        nodes: Set<String>,
        edges: [String: Set<String>]
    ) {
        self.root = root.lowercased()
        self.nodes = Set(nodes.map { $0.lowercased() })
        self.edges = Dictionary(
            uniqueKeysWithValues: edges.map { key, value in
                (key.lowercased(), Set(value.map { $0.lowercased() }))
            }
        )
    }

    /// True iff `identity` is present as a node in the graph (case-insensitive).
    public func contains(_ identity: String) -> Bool {
        nodes.contains(identity.lowercased())
    }

    /// Every direct dependency of the given package, in deterministic (sorted) order.
    public func directDependencies(of identity: String) -> [String] {
        (edges[identity.lowercased()] ?? []).sorted()
    }

    /// Every simple path (no repeated nodes) from `root` to `target`, shortest first.
    ///
    /// "Simple" means each path never visits a node twice — cycles are impossible in SPM
    /// graphs by contract, but defensive handling is one extra line and costs nothing.
    ///
    /// Paths are returned **sorted first by length**, then **lexicographically** so output
    /// is stable across runs. If the graph has more than `maxPaths` simple paths to the
    /// target, the enumeration stops early and the caller should render a "...and more"
    /// hint. The sentinel for truncation is an empty array appended as the last element.
    ///
    /// Returns an empty array if `target` is not in the graph, or if it is present but
    /// unreachable from root (the stale-resolved-file case).
    public func paths(to target: String) -> [[String]] {
        let target = target.lowercased()
        guard nodes.contains(target) else { return [] }
        if target == root {
            // A user asking "why is my own package in my graph?" gets the trivial answer.
            return [[root]]
        }

        var results: [[String]] = []
        var current: [String] = [root]
        var visited: Set<String> = [root]
        var truncated = false

        dfs(
            from: root,
            to: target,
            current: &current,
            visited: &visited,
            results: &results,
            truncated: &truncated
        )

        // Stable order: shorter paths first, then lex.
        results.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs.lexicographicallyPrecedes(rhs)
        }

        if truncated {
            results.append([]) // sentinel: "...and more"
        }
        return results
    }

    // MARK: - Internals

    private func dfs(
        from node: String,
        to target: String,
        current: inout [String],
        visited: inout Set<String>,
        results: inout [[String]],
        truncated: inout Bool
    ) {
        if results.count >= Self.maxPaths {
            truncated = true
            return
        }
        let children = edges[node] ?? []
        // Sort children so DFS order is deterministic, which in turn makes result order
        // deterministic before the final sort. Makes tests readable.
        for child in children.sorted() {
            if results.count >= Self.maxPaths {
                truncated = true
                return
            }
            if visited.contains(child) { continue }
            current.append(child)
            if child == target {
                results.append(current)
            } else {
                visited.insert(child)
                dfs(
                    from: child,
                    to: target,
                    current: &current,
                    visited: &visited,
                    results: &results,
                    truncated: &truncated
                )
                visited.remove(child)
            }
            current.removeLast()
        }
    }
}