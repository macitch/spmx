/*
 *  File: WhyRunner.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// End-to-end orchestration for `spmx why <package>`.
///
/// Pipeline: locate `Package.resolved` → parse → build the graph via `GraphBuilder` →
/// find all paths from root to the target → render. Kept separate from `WhyCommand` so the
/// whole thing is testable with injected fakes.
public struct WhyRunner: Sendable {

    public struct Options: Sendable, Equatable {
        public let path: String
        /// Identity (or display name) of the package the user wants to trace. Matched
        /// case-insensitively against the graph nodes.
        public let target: String
        /// When true, emit JSON instead of a text rendering.
        public let json: Bool
        /// Caller's decision on color. Runner never touches TTY/env.
        public let colorEnabled: Bool

        public init(path: String, target: String, json: Bool, colorEnabled: Bool) {
            self.path = path
            self.target = target
            self.json = json
            self.colorEnabled = colorEnabled
        }
    }

    /// Structured result. `paths` and `rendered` are both always populated; JSON-mode
    /// callers want `rendered`, tests want `paths`.
    public struct Output: Sendable, Equatable {
        public let target: String
        public let paths: [[String]]
        public let rendered: String
        public let hadMissingManifests: Bool
        public let missingIdentities: [String]

        public init(
            target: String,
            paths: [[String]],
            rendered: String,
            hadMissingManifests: Bool,
            missingIdentities: [String]
        ) {
            self.target = target
            self.paths = paths
            self.rendered = rendered
            self.hadMissingManifests = hadMissingManifests
            self.missingIdentities = missingIdentities
        }
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        case packageResolvedNotFound(directory: String)
        case parseFailed(String)
        case pathDoesNotExist(path: String)
        case noProjectOrPackage(directory: String)
        case ambiguousXcodeProject(directory: String, candidates: [String])
        case xcodeReadFailed(String)
        case targetNotInGraph(target: String, suggestions: [String])
        case encodingFailed

        public var description: String {
            switch self {
            case .packageResolvedNotFound(let dir):
                return """
                No Package.resolved found in \(dir).
                Run `swift package resolve` first, or pass --path to point at a package directory.
                """
            case .parseFailed(let msg):
                return "Failed to parse Package.resolved: \(msg)"
            case .pathDoesNotExist(let path):
                return """
                Path does not exist: \(path)

                Check the spelling of --path, or cd into the project directory and run
                `spmx why` without --path.
                """
            case .noProjectOrPackage(let dir):
                return """
                No SwiftPM package or Xcode project found in \(dir).

                `spmx why` looks for (in order) Package.swift, *.xcworkspace, *.xcodeproj.
                Pass --path to point at a directory that contains one, or at the .xcodeproj
                / .xcworkspace / Package.swift directly.
                """
            case .ambiguousXcodeProject(let dir, let candidates):
                let list = candidates.joined(separator: ", ")
                return """
                Multiple Xcode projects in \(dir): \(list).
                Pass --path to choose one, e.g. `spmx why <pkg> --path \(candidates[0])`.
                """
            case .xcodeReadFailed(let msg):
                return "Failed to read Xcode project: \(msg)"
            case .targetNotInGraph(let target, let suggestions):
                if suggestions.isEmpty {
                    return "'\(target)' is not a dependency of this package."
                }
                let hint = suggestions.joined(separator: ", ")
                return "'\(target)' is not a dependency of this package. Did you mean: \(hint)?"
            case .encodingFailed:
                return "Failed to encode JSON output."
            }
        }

        public var errorDescription: String? { description }
    }

    private let detector: ProjectDetector
    private let parser: ResolvedParser
    private let graphBuilder: GraphBuilder
    private let checkoutLocator: XcodeCheckoutLocator

    public init(
        detector: ProjectDetector = ProjectDetector(),
        parser: ResolvedParser = ResolvedParser(),
        graphBuilder: GraphBuilder = GraphBuilder(),
        checkoutLocator: XcodeCheckoutLocator = XcodeCheckoutLocator()
    ) {
        self.detector = detector
        self.parser = parser
        self.graphBuilder = graphBuilder
        self.checkoutLocator = checkoutLocator
    }

    public func run(options: Options) async throws -> Output {
        let inputURL = URL(fileURLWithPath: options.path)
        let detected: ProjectDetector.DetectedRoot
        do {
            detected = try detector.detect(path: inputURL)
        } catch let err as ProjectDetector.Error {
            // Re-wrap into WhyRunner.Error so existing callers and tests that match on
            // WhyRunner.Error cases continue to work.
            switch err {
            case .pathDoesNotExist(let path):
                throw Error.pathDoesNotExist(path: path)
            case .noProjectOrPackage(let dir):
                throw Error.noProjectOrPackage(directory: dir)
            case .ambiguousXcodeProject(let dir, let candidates):
                throw Error.ambiguousXcodeProject(directory: dir, candidates: candidates)
            }
        }

        let built: GraphBuildResult
        switch detected {
        case .swiftpm(let rootDirectory):
            built = try await runSwiftPM(rootDirectory: rootDirectory)
        case .xcode(let projectURL):
            built = try await runXcode(projectURL: projectURL)
        }

        let graph = built.graph

        // Path-find.
        let paths = graph.paths(to: options.target)
        if paths.isEmpty {
            let suggestions = suggestSimilarNames(for: options.target, in: graph)
            throw Error.targetNotInGraph(
                target: options.target,
                suggestions: suggestions
            )
        }

        // Render.
        let rendered = try render(
            paths: paths,
            target: options.target,
            missingIdentities: built.missingIdentities,
            hadMissingManifests: built.hadMissingManifests,
            options: options
        )

        return Output(
            target: options.target.lowercased(),
            paths: paths,
            rendered: rendered,
            hadMissingManifests: built.hadMissingManifests,
            missingIdentities: built.missingIdentities
        )
    }

    // MARK: - Pipelines

    /// SwiftPM pipeline: locate & parse `Package.resolved`, then build the graph from
    /// the root `Package.swift` walked via `.build/checkouts`. Identical to the original
    /// `WhyRunner.run` behaviour before the Xcode pivot.
    private func runSwiftPM(rootDirectory: URL) async throws -> GraphBuildResult {
        guard let resolvedURL = parser.locate(in: rootDirectory) else {
            throw Error.packageResolvedNotFound(directory: rootDirectory.path)
        }
        let file: ResolvedFile
        do {
            file = try parser.parse(at: resolvedURL)
        } catch let err as ResolvedParser.Error {
            throw Error.parseFailed(err.description)
        }
        return await graphBuilder.build(rootDirectory: rootDirectory, resolved: file)
    }

    /// Xcode pipeline: hand the project or workspace URL to `GraphBuilder.buildFromXcode`,
    /// which reads pbxproj(s), seeds the walk from the direct refs, and resolves checkouts
    /// via `XcodeCheckoutLocator`. The result shape is identical to the SwiftPM path so
    /// `run()` can treat them uniformly downstream.
    private func runXcode(projectURL: URL) async throws -> GraphBuildResult {
        let result = await graphBuilder.buildFromXcode(
            projectURL: projectURL,
            locator: checkoutLocator
        )
        switch result {
        case .success(let built):
            return built
        case .failure(let err):
            throw Error.xcodeReadFailed(err.description)
        }
    }

    // MARK: - Rendering

    private func render(
        paths: [[String]],
        target: String,
        missingIdentities: [String],
        hadMissingManifests: Bool,
        options: Options
    ) throws -> String {
        if options.json {
            return try jsonString(
                target: target,
                paths: paths,
                missingIdentities: missingIdentities,
                hadMissingManifests: hadMissingManifests
            )
        }

        var out = ""
        let arrow = " → "
        let headline: String
        if paths.count == 1, let only = paths.first, only.count == 1 {
            // Trivial self-path: the user asked about the root package itself.
            headline = "\(only[0]) is the root of this package."
            out += headline + "\n"
            return out
        }

        if paths.count == 1 {
            headline = "\(target.lowercased()) is used by 1 path:"
        } else {
            headline = "\(target.lowercased()) is used by \(paths.count) paths:"
        }
        out += headline + "\n"

        // Color decision: highlight the target in each path so the eye finds it fast.
        let ansiTarget: (open: String, close: String)? =
            options.colorEnabled ? ("\u{001B}[33m", "\u{001B}[0m") : nil

        for path in paths {
            if path.isEmpty {
                // Truncation sentinel from PackageGraph.paths.
                out += "  …and more.\n"
                continue
            }
            let decorated = path.map { node -> String in
                if node == target.lowercased(), let ansi = ansiTarget {
                    return ansi.open + node + ansi.close
                }
                return node
            }
            out += "  " + decorated.joined(separator: arrow) + "\n"
        }

        // Warning footer if the graph was partial. Never blocks the answer; the user
        // should see the path(s) they asked for regardless.
        if hadMissingManifests {
            out += "\n"
            out += "Note: one or more dependency manifests could not be loaded;\n"
            out += "      the graph may be incomplete. Run `swift package resolve`\n"
            out += "      to refresh checkouts, then try again.\n"
            if !missingIdentities.isEmpty {
                out += "      Missing: \(missingIdentities.joined(separator: ", "))\n"
            }
        }

        return out
    }

    private func jsonString(
        target: String,
        paths: [[String]],
        missingIdentities: [String],
        hadMissingManifests: Bool
    ) throws -> String {
        struct Payload: Encodable {
            let target: String
            let paths: [[String]]
            let hadMissingManifests: Bool
            let missingIdentities: [String]
        }
        let payload = Payload(
            target: target.lowercased(),
            // Filter out the truncation sentinel — empty arrays in JSON output would be
            // confusing and not machine-useful.
            paths: paths.filter { !$0.isEmpty },
            hadMissingManifests: hadMissingManifests,
            missingIdentities: missingIdentities
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(payload)
            guard let s = String(data: data, encoding: .utf8) else {
                throw Error.encodingFailed
            }
            return s + "\n"
        } catch {
            throw Error.encodingFailed
        }
    }

    // MARK: - Did-you-mean

    /// Suggests similar dependency names using Levenshtein edit distance. Catches typos
    /// like `alamofir` → `alamofire` or `swift-collection` → `swift-collections` that a
    /// simple substring check would miss (`swift-collection` does not contain nor is
    /// contained by `swift-collections`). Falls back to substring matching if Levenshtein
    /// returns nothing — belt and suspenders.
    private func suggestSimilarNames(for target: String, in graph: PackageGraph) -> [String] {
        let needle = target.lowercased()
        let candidates = Array(graph.nodes.filter { $0 != graph.root })

        // Primary: Levenshtein-based fuzzy matching.
        let levenshteinResults = suggestSimilar(to: needle, from: candidates, maxResults: 3)
        if !levenshteinResults.isEmpty {
            return levenshteinResults
        }

        // Fallback: substring containment for cases where the needle is very different
        // in length (e.g. user typed an abbreviation).
        let substringResults = candidates
            .filter { node in node.contains(needle) || needle.contains(node) }
            .sorted()
        return Array(substringResults.prefix(3))
    }
}