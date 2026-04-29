/*
 *  File: GraphBuilder.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Result of building a package graph. The flags exist so callers can decide whether to
/// warn or fail when the on-disk state is incomplete.
public struct GraphBuildResult: Sendable {
    public let graph: PackageGraph

    /// True iff one or more pins in `Package.resolved` did not have a corresponding
    /// `Package.swift` we could load — typically because `.build/checkouts/` is missing
    /// or stale. The graph is still returned, with the missing nodes present but no
    /// outgoing edges from them.
    public let hadMissingManifests: Bool

    /// Identities of pins whose manifests were unreachable. Useful for `--verbose`.
    public let missingIdentities: [String]

    public init(
        graph: PackageGraph,
        hadMissingManifests: Bool,
        missingIdentities: [String]
    ) {
        self.graph = graph
        self.hadMissingManifests = hadMissingManifests
        self.missingIdentities = missingIdentities
    }
}

/// Builds a `PackageGraph` from a root package directory plus its `Package.resolved`.
///
/// The walker is **breadth-first** by package identity, not by directory. We start from
/// the root manifest, queue every direct dependency, then walk into each one's checkout
/// to discover its own dependencies, repeating until every reachable node has been
/// visited or marked as missing.
///
/// ## Where checkouts live
///
/// Modern SwiftPM stores remote dependencies in `<root>/.build/checkouts/<identity>/`.
/// Older SwiftPM used the URL's last path component (without `.git`) as the directory
/// name. We try both, identity first. Local source-control dependencies (`.package(path:)`)
/// have their location resolved relative to the root manifest. Registry dependencies have
/// no checkout at all and are added as edge-less nodes — `why` against a registry dep
/// answers correctly via the root → registry edge.
///
/// ## Why this might return a partial graph
///
/// `GraphBuilder` never throws on a missing manifest. The contract is "give the user the
/// best graph we can build, and tell them what's missing." A user running `spmx why` on
/// a fresh clone before `swift package resolve` should still get a useful answer for any
/// direct dependency, with a clear note that transitive answers may be incomplete.
public struct GraphBuilder: Sendable {
    private let manifestLoader: ManifestLoading
    private let projectReader: XcodeProjectReader
    private let workspaceReader: XcodeWorkspaceReader

    public init(
        manifestLoader: ManifestLoading = DiskCachedManifestLoader(),
        projectReader: XcodeProjectReader = XcodeProjectReader(),
        workspaceReader: XcodeWorkspaceReader = XcodeWorkspaceReader()
    ) {
        self.manifestLoader = manifestLoader
        self.projectReader = projectReader
        self.workspaceReader = workspaceReader
    }

    /// All file existence checks go through `FileManager.default`. We don't store a
    /// `FileManager` instance because `FileManager` isn't `Sendable` (even though its
    /// `default` singleton is documented thread-safe), and storing one would force the
    /// whole builder into `@unchecked Sendable`. Tests stub out behaviour at the
    /// `ManifestLoading` boundary, not the file-system boundary, so this is no real loss.
    private var fm: FileManager { .default }

    public func build(
        rootDirectory: URL,
        resolved: ResolvedFile
    ) async -> GraphBuildResult {
        // 1. Load the root manifest. If this fails, we can't even seed the graph — return
        //    an empty result with the failure recorded.
        let rootDump: ManifestDump
        do {
            rootDump = try await manifestLoader.load(packageDirectory: rootDirectory)
        } catch {
            // Unique sentinel root identity so the empty graph is still well-formed.
            let emptyGraph = PackageGraph(
                root: "<unknown-root>",
                nodes: ["<unknown-root>"],
                edges: [:]
            )
            return GraphBuildResult(
                graph: emptyGraph,
                hadMissingManifests: true,
                missingIdentities: ["<root>"]
            )
        }

        let rootIdentity = rootDump.name.lowercased()

        // 2. Build a fast lookup from pin identity → pin so we can resolve checkout
        //    directories without re-scanning `pins` for each child.
        let pinByIdentity: [String: ResolvedFile.Pin] = Dictionary(
            uniqueKeysWithValues: resolved.pins.map { ($0.identity.lowercased(), $0) }
        )

        // 3. BFS over identities. We track edges and visited separately so a node can
        //    appear before all its incoming edges have been discovered.
        var nodes: Set<String> = [rootIdentity]
        var edges: [String: Set<String>] = [:]
        var visited: Set<String> = []
        var missing: [String] = []

        // Seed the queue with the root and its declared deps. We treat the root specially
        // because its directory is known (passed in by the caller); everything else is
        // resolved through pinByIdentity.
        var queue: [(identity: String, directory: URL?)] = [(rootIdentity, rootDirectory)]

        while !queue.isEmpty {
            let (identity, directory) = queue.removeFirst()
            if visited.contains(identity) { continue }
            visited.insert(identity)

            // Load this node's manifest. If we have no directory (registry pin) or the
            // load fails (missing checkout), we record the node with no outgoing edges
            // and move on.
            guard let dir = directory else {
                nodes.insert(identity)
                continue
            }
            let dump: ManifestDump
            do {
                dump = try await manifestLoader.load(packageDirectory: dir)
            } catch {
                nodes.insert(identity)
                missing.append(identity)
                continue
            }

            nodes.insert(identity)
            var outgoing = Set<String>()
            for dep in dump.dependencies {
                let depIdentity = dep.identity.lowercased()
                outgoing.insert(depIdentity)
                nodes.insert(depIdentity)

                if !visited.contains(depIdentity) {
                    let depDir = checkoutDirectory(
                        for: depIdentity,
                        kind: dep.kind,
                        rootDirectory: rootDirectory,
                        pinByIdentity: pinByIdentity
                    )
                    // A missing source-control checkout is an incomplete-graph warning,
                    // not a silent omission. Registry pins legitimately return nil (no
                    // checkout exists) and are not counted as missing — a registry leaf
                    // with no outgoing edges is a correct graph, not a partial one.
                    if depDir == nil && dep.kind == .sourceControl {
                        missing.append(depIdentity)
                    }
                    queue.append((depIdentity, depDir))
                }
            }
            edges[identity] = outgoing
        }

        // 4. Any pin in resolved that we never visited is an "orphan" — it's pinned but
        //    nothing in the walked manifests references it. We add it as a node with no
        //    edges so `paths(to:)` returns empty (the correct answer: "in your lockfile
        //    but no longer reachable; you should run swift package resolve").
        for pin in resolved.pins {
            let id = pin.identity.lowercased()
            if !nodes.contains(id) {
                nodes.insert(id)
            }
        }

        let graph = PackageGraph(root: rootIdentity, nodes: nodes, edges: edges)
        return GraphBuildResult(
            graph: graph,
            hadMissingManifests: !missing.isEmpty,
            missingIdentities: missing.sorted()
        )
    }

    // MARK: - Xcode entry point

    /// Errors specific to building a graph from an Xcode project or workspace. The
    /// SwiftPM `build()` method never throws — it returns a partial graph with the
    /// failure flagged. Xcode is different because we have to read project files
    /// upfront just to know what to seed the queue with, and a malformed pbxproj is a
    /// hard stop, not a partial-graph situation.
    public enum XcodeBuildError: Swift.Error, CustomStringConvertible {
        case projectNotFound(URL)
        case unsupportedExtension(URL)
        case readFailed(underlying: Error)

        public var description: String {
            switch self {
            case .projectNotFound(let url):
                return """
                No project or workspace at \(url.path). \
                Pass `--path` pointing at a directory that contains a .xcodeproj or .xcworkspace, \
                or at the project/workspace bundle directly.
                """
            case .unsupportedExtension(let url):
                return """
                Expected .xcodeproj or .xcworkspace, got \(url.lastPathComponent). \
                Pass `--path` pointing at an Xcode project bundle, an Xcode workspace bundle, \
                or a SwiftPM package directory.
                """
            case .readFailed(let err):
                return """
                Failed to read Xcode project: \(err). \
                Try opening the project in Xcode to verify it's not corrupted. If Xcode opens \
                it without issue, please file a spmx bug at https://github.com/macitch/spmx/issues.
                """
            }
        }
    }

    /// Build a `PackageGraph` from an Xcode `.xcodeproj` or `.xcworkspace`.
    ///
    /// ## Why this is a separate entry point
    ///
    /// The SwiftPM path (`build(rootDirectory:resolved:)`) seeds the BFS from a
    /// `Package.swift` it can dump. Xcode projects don't have one — the direct
    /// dependencies live in `project.pbxproj` as `XCRemoteSwiftPackageReference` /
    /// `XCLocalSwiftPackageReference` entries. We read those upfront, then walk
    /// transitively the same way the SwiftPM path does, except checkouts are resolved
    /// via `XcodeCheckoutLocator` (DerivedData → workspace-local → `.swiftpm`) instead
    /// of `.build/checkouts`.
    ///
    /// ## Synthesized root identity
    ///
    /// There is no real package corresponding to an Xcode project, so we synthesize a
    /// root identity from the project filename: `VeriGuard.xcodeproj` → `veriguard`.
    /// `WhyRunner` uses this when rendering paths, so the user sees their app name as
    /// the root of the chain rather than `<unknown>`.
    ///
    /// ## Workspace handling
    ///
    /// If `projectURL` points at an `.xcworkspace`, we use `XcodeWorkspaceReader` to
    /// discover all the `.xcodeproj` files inside it, then merge their direct refs
    /// into a single deduplicated set. The synthesized root is named after the
    /// workspace itself.
    ///
    /// ## Limitations
    ///
    /// - Transitive `fileSystem` (local-path) dependencies cannot be located, because
    ///   `ManifestDump` doesn't carry the path. They are recorded as missing. In
    ///   practice this never happens — local-path deps are an in-monorepo authoring
    ///   convenience, not something a published package would expose to consumers.
    /// - Custom DerivedData locations (set in Xcode prefs) are not supported in v0.1.
    ///   See `XcodeCheckoutLocator` for details.
    public func buildFromXcode(
        projectURL: URL,
        locator: XcodeCheckoutLocator = XcodeCheckoutLocator()
    ) async -> Result<GraphBuildResult, XcodeBuildError> {
        // 1. Validate the input.
        guard fm.fileExists(atPath: projectURL.path) else {
            return .failure(.projectNotFound(projectURL))
        }

        // 2. Discover the direct package refs and pick the project URL the locator
        //    should query against. For workspaces, the locator key is the workspace
        //    URL itself (Xcode keys DerivedData by what you opened, not by the
        //    contained projects).
        let directRefs: [XcodePackageReference]
        let locatorProjectURL: URL
        let rootName: String

        switch projectURL.pathExtension {
        case "xcodeproj":
            do {
                directRefs = try projectReader.read(projectURL)
            } catch {
                return .failure(.readFailed(underlying: error))
            }
            locatorProjectURL = projectURL
            rootName = projectURL.deletingPathExtension().lastPathComponent.lowercased()

        case "xcworkspace":
            do {
                let projectURLs = try workspaceReader.read(projectURL)
                var merged: [String: XcodePackageReference] = [:]
                for proj in projectURLs {
                    let refs = (try? projectReader.read(proj)) ?? []
                    for ref in refs where merged[ref.identity] == nil {
                        merged[ref.identity] = ref
                    }
                }
                directRefs = merged.values.sorted { $0.identity < $1.identity }
            } catch {
                return .failure(.readFailed(underlying: error))
            }
            locatorProjectURL = projectURL
            rootName = projectURL.deletingPathExtension().lastPathComponent.lowercased()

        default:
            return .failure(.unsupportedExtension(projectURL))
        }

        // 3. BFS over identities, seeded from the synthesized root.
        let rootIdentity = rootName
        var nodes: Set<String> = [rootIdentity]
        var edges: [String: Set<String>] = [:]
        var visited: Set<String> = [rootIdentity]
        var missing: [String] = []

        // Seed the queue with the direct refs. The root has edges to each of them.
        var rootOutgoing = Set<String>()
        var queue: [(identity: String, directory: URL?)] = []
        for ref in directRefs {
            let id = ref.identity // already lowercased
            rootOutgoing.insert(id)
            nodes.insert(id)
            let dir = locator.checkoutDirectory(for: id, projectURL: locatorProjectURL)
            if dir == nil {
                // A direct ref with no checkout means the user resolved deps in Xcode
                // but the checkout directory isn't where we expected. Most common cause:
                // they've never built the project after adding the dep. Surface as
                // missing — the resulting graph still has the edge, just no transitive
                // info beyond it.
                missing.append(id)
            }
            queue.append((id, dir))
        }
        edges[rootIdentity] = rootOutgoing

        // 4. Walk transitively. Same loop shape as the SwiftPM path, with two
        //    differences: sourceControl deps are resolved via the locator, and
        //    fileSystem deps cannot be resolved at all (see Limitations above).
        while !queue.isEmpty {
            let (identity, directory) = queue.removeFirst()
            if visited.contains(identity) { continue }
            visited.insert(identity)

            guard let dir = directory else {
                nodes.insert(identity)
                continue
            }

            let dump: ManifestDump
            do {
                dump = try await manifestLoader.load(packageDirectory: dir)
            } catch {
                nodes.insert(identity)
                missing.append(identity)
                continue
            }

            nodes.insert(identity)
            var outgoing = Set<String>()
            for dep in dump.dependencies {
                let depIdentity = dep.identity.lowercased()
                outgoing.insert(depIdentity)
                nodes.insert(depIdentity)

                if !visited.contains(depIdentity) {
                    let depDir: URL?
                    switch dep.kind {
                    case .registry:
                        depDir = nil
                    case .fileSystem:
                        // Local-path transitive dep. We have no path to follow — see
                        // the type doc. Mark as missing so the user knows the graph
                        // walk stopped here.
                        depDir = nil
                        missing.append(depIdentity)
                    case .sourceControl:
                        depDir = locator.checkoutDirectory(
                            for: depIdentity,
                            projectURL: locatorProjectURL
                        )
                        if depDir == nil {
                            missing.append(depIdentity)
                        }
                    }
                    queue.append((depIdentity, depDir))
                }
            }
            edges[identity] = outgoing
        }

        let graph = PackageGraph(root: rootIdentity, nodes: nodes, edges: edges)
        return .success(GraphBuildResult(
            graph: graph,
            hadMissingManifests: !missing.isEmpty,
            missingIdentities: missing.sorted()
        ))
    }

    // MARK: - Internals

    /// Resolves the on-disk directory we expect to find a dependency's `Package.swift` in.
    ///
    /// Returns nil for registry pins (no checkout) and for any case where we can't make
    /// an educated guess. The caller treats nil the same as a missing manifest: the node
    /// is added with no outgoing edges.
    private func checkoutDirectory(
        for identity: String,
        kind: ManifestDump.Dependency.Kind,
        rootDirectory: URL,
        pinByIdentity: [String: ResolvedFile.Pin]
    ) -> URL? {
        switch kind {
        case .registry:
            // Registry packages have no `.swift` to load locally. Caller treats nil as
            // "edge-less node", which is correct: a registry leaf with no deps is the
            // common case anyway.
            return nil

        case .fileSystem:
            // Local-path dependency. The pin's `location` is the path on disk (absolute
            // or relative to the root manifest). If we have a pin, use it; otherwise we
            // can't help.
            guard let pin = pinByIdentity[identity] else { return nil }
            let url = URL(fileURLWithPath: pin.location, relativeTo: rootDirectory)
                .standardizedFileURL
            return fm.fileExists(atPath: url.path) ? url : nil

        case .sourceControl:
            // Modern SPM (5.5+) stores checkouts in `.build/checkouts/<identity>/`. Older
            // versions used the last URL path component without `.git`. Try identity first,
            // then fall back.
            let checkouts = rootDirectory
                .appendingPathComponent(".build/checkouts", isDirectory: true)

            let primary = checkouts.appendingPathComponent(identity, isDirectory: true)
            if fm.fileExists(
                atPath: primary.appendingPathComponent("Package.swift").path
            ) {
                return primary
            }

            // Fallback: derive name from the pin's location (URL last component, sans `.git`).
            if let pin = pinByIdentity[identity] {
                let name = pin.location
                    .split(separator: "/").last
                    .map(String.init)?
                    .replacingOccurrences(of: ".git", with: "")
                if let name {
                    let alt = checkouts.appendingPathComponent(name, isDirectory: true)
                    if fm.fileExists(
                        atPath: alt.appendingPathComponent("Package.swift").path
                    ) {
                        return alt
                    }
                }
            }

            return nil
        }
    }
}