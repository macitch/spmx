/*
 *  File: WhyRunnerTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("WhyRunner")
struct WhyRunnerTests {

    // MARK: - Stub manifest loader

    /// Minimal in-memory `ManifestLoading` that returns a canned dump for a given directory
    /// path (standardized), throwing for anything else. Same pattern as GraphBuilderTests.
    private actor StubManifestLoader: ManifestLoading {
        private var manifests: [String: ManifestDump] = [:]

        init(manifests: [String: ManifestDump]) {
            self.manifests = manifests
        }

        nonisolated func load(packageDirectory: URL) async throws -> ManifestDump {
            try await self.lookup(path: packageDirectory.standardizedFileURL.path)
        }

        private func lookup(path: String) throws -> ManifestDump {
            guard let dump = manifests[path] else {
                throw ManifestLoaderError.packageSwiftNotFound(URL(fileURLWithPath: path))
            }
            return dump
        }
    }

    // MARK: - On-disk fixture

    /// Builds a temporary directory with:
    ///   - A plain `Package.resolved` at the root so `ResolvedParser.locate` finds it.
    ///   - A stub `Package.swift` at the root so `ManifestLoader.load` passes its file-exists check.
    ///   - Stub `Package.swift` files at `.build/checkouts/<identity>/Package.swift` for each
    ///     named checkout.
    /// Returns the root directory.
    private func stage(
        pins: [ResolvedFile.Pin],
        checkoutIdentities: [String]
    ) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-why-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Package.swift at root (contents irrelevant — loader is stubbed by path).
        try Data("// stub root\n".utf8)
            .write(to: root.appendingPathComponent("Package.swift"))

        // Package.resolved so the locator finds it. Written as v3 shape.
        let resolvedFile = ResolvedFile(version: 3, pins: pins)
        let resolvedData = try JSONEncoder().encode(resolvedFile)
        try resolvedData.write(to: root.appendingPathComponent("Package.resolved"))

        let checkouts = root.appendingPathComponent(".build/checkouts", isDirectory: true)
        try fm.createDirectory(at: checkouts, withIntermediateDirectories: true)
        for id in checkoutIdentities {
            let dir = checkouts.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("// stub\n".utf8)
                .write(to: dir.appendingPathComponent("Package.swift"))
        }
        return root
    }

    private func pin(
        _ identity: String,
        kind: ResolvedFile.Pin.Kind = .remoteSourceControl
    ) -> ResolvedFile.Pin {
        ResolvedFile.Pin(
            identity: identity,
            kind: kind,
            location: "https://example.com/\(identity).git",
            state: .init(revision: "abc123def456", version: "1.0.0", branch: nil)
        )
    }

    private func dump(
        name: String,
        deps: [(String, ManifestDump.Dependency.Kind)] = []
    ) -> ManifestDump {
        ManifestDump(
            name: name,
            dependencies: deps.map { .init(identity: $0.0, kind: $0.1) }
        )
    }

    private func runner(manifests: [URL: ManifestDump]) -> WhyRunner {
        // Convert URL keys to standardized path strings for the stub loader.
        let keyedByPath = Dictionary(
            uniqueKeysWithValues: manifests.map {
                ($0.key.standardizedFileURL.path, $0.value)
            }
        )
        return WhyRunner(
            graphBuilder: GraphBuilder(
                manifestLoader: StubManifestLoader(manifests: keyedByPath)
            )
        )
    }

    // MARK: - Tests

    @Test("direct dependency produces a single two-node path")
    func directDependency() async throws {
        let root = try stage(pins: [pin("alamofire")], checkoutIdentities: ["alamofire"])
        defer { try? FileManager.default.removeItem(at: root) }

        let r = runner(manifests: [
            root: dump(name: "App", deps: [("alamofire", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/alamofire"):
                dump(name: "Alamofire"),
        ])

        let out = try await r.run(options: .init(
            path: root.path,
            target: "alamofire",
            json: false,
            colorEnabled: false
        ))
        #expect(out.paths == [["app", "alamofire"]])
        #expect(out.rendered.contains("alamofire is used by 1 path"))
        #expect(out.rendered.contains("app → alamofire"))
    }

    @Test("transitive dependency walks the full chain")
    func transitiveChain() async throws {
        let root = try stage(
            pins: [pin("a"), pin("b"), pin("c")],
            checkoutIdentities: ["a", "b", "c"]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let r = runner(manifests: [
            root: dump(name: "App", deps: [("a", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/a"):
                dump(name: "A", deps: [("b", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/b"):
                dump(name: "B", deps: [("c", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/c"):
                dump(name: "C"),
        ])

        let out = try await r.run(options: .init(
            path: root.path,
            target: "c",
            json: false,
            colorEnabled: false
        ))
        #expect(out.paths == [["app", "a", "b", "c"]])
        #expect(out.rendered.contains("app → a → b → c"))
    }

    @Test("target not in graph throws with substring suggestions")
    func notInGraphWithSuggestions() async throws {
        let root = try stage(
            pins: [pin("alamofire")],
            checkoutIdentities: ["alamofire"]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let r = runner(manifests: [
            root: dump(name: "App", deps: [("alamofire", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/alamofire"):
                dump(name: "Alamofire"),
        ])

        do {
            _ = try await r.run(options: .init(
                path: root.path,
                target: "alamofir", // typo
                json: false,
                colorEnabled: false
            ))
            Issue.record("expected targetNotInGraph, got success")
        } catch let err as WhyRunner.Error {
            switch err {
            case .targetNotInGraph(_, let suggestions):
                #expect(suggestions.contains("alamofire"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("target not in graph with no close matches throws empty suggestions")
    func notInGraphNoSuggestions() async throws {
        let root = try stage(
            pins: [pin("alamofire")],
            checkoutIdentities: ["alamofire"]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let r = runner(manifests: [
            root: dump(name: "App", deps: [("alamofire", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/alamofire"):
                dump(name: "Alamofire"),
        ])

        do {
            _ = try await r.run(options: .init(
                path: root.path,
                target: "xyzzy",
                json: false,
                colorEnabled: false
            ))
            Issue.record("expected targetNotInGraph, got success")
        } catch let err as WhyRunner.Error {
            switch err {
            case .targetNotInGraph(let target, let suggestions):
                #expect(target == "xyzzy")
                #expect(suggestions.isEmpty, "expected no suggestions, got: \(suggestions)")
                #expect(!err.description.contains("Did you mean"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("JSON output is valid and contains target and paths")
    func jsonOutput() async throws {
        let root = try stage(
            pins: [pin("alamofire")],
            checkoutIdentities: ["alamofire"]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let r = runner(manifests: [
            root: dump(name: "App", deps: [("alamofire", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/alamofire"):
                dump(name: "Alamofire"),
        ])

        let out = try await r.run(options: .init(
            path: root.path,
            target: "alamofire",
            json: true,
            colorEnabled: false
        ))
        let data = Data(out.rendered.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["target"] as? String == "alamofire")
        let paths = obj?["paths"] as? [[String]]
        #expect(paths == [["app", "alamofire"]])
        #expect(obj?["hadMissingManifests"] as? Bool == false)
    }

    @Test("SwiftPM package with no Package.resolved surfaces packageResolvedNotFound")
    func noResolvedFile() async throws {
        // Stage a directory with a Package.swift (so detect() lands on the SwiftPM
        // branch) but no Package.resolved. This is a real case: a freshly cloned
        // package that hasn't been resolved yet. The SwiftPM pipeline should fail at
        // the parser.locate step with `packageResolvedNotFound`.
        //
        // Before the Xcode pivot, the check ran on *any* directory so an empty dir
        // surfaced this same error. Post-pivot, detect() rejects bare directories with
        // `noProjectOrPackage` first, so `packageResolvedNotFound` is now only
        // reachable when a Package.swift exists. That's the more useful semantic.
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-why-unresolved-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Write a minimal Package.swift so detect() picks the SwiftPM path.
        let manifest = "// swift-tools-version:5.9\nimport PackageDescription\n"
        try Data(manifest.utf8).write(to: root.appendingPathComponent("Package.swift"))

        let r = WhyRunner()
        do {
            _ = try await r.run(options: .init(
                path: root.path,
                target: "whatever",
                json: false,
                colorEnabled: false
            ))
            Issue.record("expected packageResolvedNotFound, got success")
        } catch let err as WhyRunner.Error {
            switch err {
            case .packageResolvedNotFound:
                #expect(err.description.contains("No Package.resolved"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("bare directory with no project or package surfaces noProjectOrPackage")
    func noProjectOrPackageIsSpecific() async throws {
        // Stage a directory with nothing but a Package.resolved — no Package.swift, no
        // .xcodeproj, no .xcworkspace. Auto-discovery has no root to work with, so the
        // runner should refuse with `noProjectOrPackage` rather than trying to walk an
        // empty graph and returning a misleading "not a dependency" answer.
        //
        // Before the Xcode pivot this case surfaced as `noRootManifest` with a message
        // about Xcode being unsupported. After the pivot, `noProjectOrPackage` is the
        // correct error — we support Xcode projects now, we just can't find one here.
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("spmx-why-bare-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Write only Package.resolved — no Package.swift, no .xcodeproj, no .xcworkspace.
        let resolvedFile = ResolvedFile(version: 3, pins: [pin("alamofire")])
        let data = try JSONEncoder().encode(resolvedFile)
        try data.write(to: root.appendingPathComponent("Package.resolved"))

        let r = WhyRunner()
        do {
            _ = try await r.run(options: .init(
                path: root.path,
                target: "alamofire",
                json: false,
                colorEnabled: false
            ))
            Issue.record("expected noProjectOrPackage, got success")
        } catch let err as WhyRunner.Error {
            switch err {
            case .noProjectOrPackage(let directory):
                #expect(directory == root.path)
                #expect(err.description.contains("No SwiftPM package or Xcode project"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("nonexistent path surfaces pathDoesNotExist, not noProjectOrPackage")
    func nonexistentPathIsDistinct() async throws {
        // Regression: before this fix, passing a typo'd --path produced
        // `noProjectOrPackage` with a message telling the user "no project found
        // in <dir>" — which is misleading when the real issue is that <dir>
        // doesn't exist at all. The two cases need different errors so the user
        // can act on them differently: "fix your spelling" vs "cd somewhere that
        // has a project".
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmx-why-does-not-exist-\(UUID().uuidString)")
            .path

        let r = WhyRunner()
        do {
            _ = try await r.run(options: .init(
                path: bogus,
                target: "alamofire",
                json: false,
                colorEnabled: false
            ))
            Issue.record("expected pathDoesNotExist, got success")
        } catch let err as WhyRunner.Error {
            switch err {
            case .pathDoesNotExist(let path):
                #expect(path == bogus)
                #expect(err.description.contains("Path does not exist"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("partial graph warning is appended when manifests are missing")
    func partialGraphWarning() async throws {
        // Stage only the root checkout; `a` points to `deep` but `deep`'s checkout directory
        // exists so we try to load it — and the stub has no entry for it, so load fails.
        let root = try stage(
            pins: [pin("a"), pin("deep")],
            checkoutIdentities: ["a", "deep"]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let r = runner(manifests: [
            root: dump(name: "App", deps: [("a", .sourceControl)]),
            root.appendingPathComponent(".build/checkouts/a"):
                dump(name: "A", deps: [("deep", .sourceControl)]),
            // Deliberately no entry for `deep` — its Package.swift exists on disk but the
            // stub loader will throw when asked to load it.
        ])

        let out = try await r.run(options: .init(
            path: root.path,
            target: "deep",
            json: false,
            colorEnabled: false
        ))
        #expect(out.paths == [["app", "a", "deep"]])
        #expect(out.hadMissingManifests)
        #expect(out.missingIdentities.contains("deep"))
        #expect(out.rendered.contains("graph may be incomplete"))
    }
}