/*
 *  File: GraphBuilderXcodeTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("GraphBuilder.buildFromXcode")
struct GraphBuilderXcodeTests {

    // MARK: - Happy paths

    @Test("single direct ref with no transitive deps")
    func singleDirectRef() async throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(
            named: "MyApp.xcodeproj",
            refs: [("https://github.com/foo/bar", "bar")]
        )
        let derived = try stage.makeDerivedData(
            named: "MyApp-h1",
            workspacePath: project.path
        )
        try stage.makeCheckout(in: derived, identity: "bar", deps: [])

        let builder = GraphBuilder(manifestLoader: stage.manifestLoader())
        let result = await builder.buildFromXcode(
            projectURL: project,
            locator: XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        )

        let build = try result.get()
        #expect(build.graph.contains("myapp"))
        #expect(build.graph.contains("bar"))
        #expect(build.graph.directDependencies(of: "myapp") == ["bar"])
        #expect(build.hadMissingManifests == false)
    }

    @Test("transitive walk: root → A → B")
    func transitiveWalk() async throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(
            named: "MyApp.xcodeproj",
            refs: [("https://github.com/x/a", "a")]
        )
        let derived = try stage.makeDerivedData(
            named: "MyApp-h1",
            workspacePath: project.path
        )
        // A depends on B; B depends on nothing.
        try stage.makeCheckout(in: derived, identity: "a", deps: ["b"])
        try stage.makeCheckout(in: derived, identity: "b", deps: [])

        let builder = GraphBuilder(manifestLoader: stage.manifestLoader())
        let build = try await builder.buildFromXcode(
            projectURL: project,
            locator: XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        ).get()

        let paths = build.graph.paths(to: "b")
        #expect(paths == [["myapp", "a", "b"]])
    }

    @Test("diamond: root → {A, C} ; A → B ; C → B")
    func diamond() async throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(
            named: "MyApp.xcodeproj",
            refs: [
                ("https://github.com/x/a", "a"),
                ("https://github.com/x/c", "c")
            ]
        )
        let derived = try stage.makeDerivedData(
            named: "MyApp-h1",
            workspacePath: project.path
        )
        try stage.makeCheckout(in: derived, identity: "a", deps: ["b"])
        try stage.makeCheckout(in: derived, identity: "c", deps: ["b"])
        try stage.makeCheckout(in: derived, identity: "b", deps: [])

        let builder = GraphBuilder(manifestLoader: stage.manifestLoader())
        let build = try await builder.buildFromXcode(
            projectURL: project,
            locator: XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        ).get()

        let paths = build.graph.paths(to: "b")
        #expect(paths.count == 2)
        #expect(paths.contains(["myapp", "a", "b"]))
        #expect(paths.contains(["myapp", "c", "b"]))
    }

    // MARK: - Partial-graph cases

    @Test("missing checkout for direct ref is recorded as missing but the edge survives")
    func missingDirectCheckout() async throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let project = try stage.makeProject(
            named: "MyApp.xcodeproj",
            refs: [("https://github.com/x/a", "a")]
        )
        // No DerivedData entry, no checkout — locator returns nil for "a".
        let builder = GraphBuilder(manifestLoader: stage.manifestLoader())
        let build = try await builder.buildFromXcode(
            projectURL: project,
            locator: XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        ).get()

        // Edge is still there: root → a is something we can answer from pbxproj alone.
        #expect(build.graph.directDependencies(of: "myapp") == ["a"])
        #expect(build.hadMissingManifests == true)
        #expect(build.missingIdentities == ["a"])
    }

    // MARK: - Workspace handling

    @Test("workspace merges direct refs from multiple projects, deduped")
    func workspaceMergesProjects() async throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let projA = try stage.makeProject(
            named: "AppA.xcodeproj",
            refs: [
                ("https://github.com/x/shared", "shared"),
                ("https://github.com/x/onlyA", "onlya")
            ]
        )
        let projB = try stage.makeProject(
            named: "AppB.xcodeproj",
            refs: [
                ("https://github.com/x/shared", "shared"),
                ("https://github.com/x/onlyB", "onlyb")
            ]
        )
        let workspace = try stage.makeWorkspace(
            named: "Combined.xcworkspace",
            projects: [projA, projB]
        )
        // DerivedData entry for the workspace itself (Xcode keys by what you opened).
        let derived = try stage.makeDerivedData(
            named: "Combined-h1",
            workspacePath: workspace.path
        )
        try stage.makeCheckout(in: derived, identity: "shared", deps: [])
        try stage.makeCheckout(in: derived, identity: "onlya", deps: [])
        try stage.makeCheckout(in: derived, identity: "onlyb", deps: [])

        let builder = GraphBuilder(manifestLoader: stage.manifestLoader())
        let build = try await builder.buildFromXcode(
            projectURL: workspace,
            locator: XcodeCheckoutLocator(derivedDataRoot: stage.derivedDataRoot)
        ).get()

        let direct = build.graph.directDependencies(of: "combined").sorted()
        #expect(direct == ["onlya", "onlyb", "shared"])
        #expect(build.hadMissingManifests == false)
    }

    // MARK: - Error cases

    @Test("project that doesn't exist returns .projectNotFound")
    func projectNotFound() async throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let bogus = stage.tmp.appendingPathComponent("Nope.xcodeproj")
        let builder = GraphBuilder()
        let result = await builder.buildFromXcode(projectURL: bogus)
        switch result {
        case .success: Issue.record("expected .projectNotFound, got success")
        case .failure(let err):
            switch err {
            case .projectNotFound: break
            default: Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("non-Xcode extension returns .unsupportedExtension")
    func wrongExtension() async throws {
        let stage = try Stage()
        defer { stage.cleanup() }

        let bogus = stage.tmp.appendingPathComponent("MyApp.txt")
        try Data().write(to: bogus)
        let builder = GraphBuilder()
        let result = await builder.buildFromXcode(projectURL: bogus)
        switch result {
        case .success: Issue.record("expected .unsupportedExtension, got success")
        case .failure(let err):
            switch err {
            case .unsupportedExtension: break
            default: Issue.record("wrong error: \(err)")
            }
        }
    }
}

// MARK: - Stage scaffolding

/// Stages a complete fake Xcode + DerivedData + manifest cache layout under tmp.
/// Each test gets its own Stage with a unique temp dir, cleaned up via `defer`.
///
/// The scaffolding has to be more elaborate than `XcodeCheckoutLocatorTests`'s Stage
/// because we now also need to:
///   - Write minimal `Package.swift` files inside checkouts
///   - Wire a `FakeProcessRunner` so `DiskCachedManifestLoader` returns the right
///     `ManifestDump` JSON for each checkout when shelled out
///   - Stage `.xcodeproj` and `.xcworkspace` files with real openStep pbxproj /
///     XML xcworkspacedata content
private final class Stage {
    let fm = FileManager.default
    let tmp: URL
    let derivedDataRoot: URL
    let cacheDir: URL

    /// Canned `swift package dump-package` responses keyed by canonical checkout path.
    /// Mutated by `makeCheckout` during test setup; frozen into the runner via
    /// `manifestLoader()` once setup is complete.
    private var pendingResponses: [String: String] = [:]

    init() throws {
        self.tmp = fm.temporaryDirectory
            .appendingPathComponent("spmx-graphxcode-\(UUID().uuidString)")
        self.derivedDataRoot = tmp.appendingPathComponent("DerivedData")
        self.cacheDir = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: derivedDataRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Materialize a `DiskCachedManifestLoader` whose runner returns the responses
    /// registered so far. Call this *after* all `makeCheckout` calls.
    func manifestLoader() -> DiskCachedManifestLoader {
        DiskCachedManifestLoader(
            runner: CannedDumpRunner(responses: pendingResponses),
            cacheDirectory: cacheDir
        )
    }

    func cleanup() {
        try? fm.removeItem(at: tmp)
    }

    /// Stage an `.xcodeproj` with a `project.pbxproj` that declares the given remote refs.
    /// `refs` is a list of `(repositoryURL, identity)` pairs — the identity isn't read by
    /// the parser (it's derived from the URL), but we keep it in the API for clarity.
    func makeProject(named name: String, refs: [(String, String)]) throws -> URL {
        let projects = tmp.appendingPathComponent("projects")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        let project = projects.appendingPathComponent(name)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        // Build a minimal openStep pbxproj with one XCRemoteSwiftPackageReference per ref.
        var entries = ""
        for (i, (url, _)) in refs.enumerated() {
            entries += """
                R\(i) /* XCRemoteSwiftPackageReference */ = {
                    isa = XCRemoteSwiftPackageReference;
                    repositoryURL = "\(url)";
                    requirement = { kind = upToNextMajorVersion; minimumVersion = 1.0.0; };
                };

            """
        }
        let pbxproj = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {};
            objectVersion = 77;
            objects = {
        \(entries)
            };
            rootObject = ROOT;
        }
        """
        try Data(pbxproj.utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        return project
    }

    /// Stage an `.xcworkspace` whose `contents.xcworkspacedata` references the given
    /// `.xcodeproj` URLs by absolute path.
    func makeWorkspace(named name: String, projects: [URL]) throws -> URL {
        let workspace = tmp.appendingPathComponent(name)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        var fileRefs = ""
        for proj in projects {
            fileRefs += """
                <FileRef location = "absolute:\(proj.path)"></FileRef>

            """
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
        \(fileRefs)
        </Workspace>
        """
        try Data(xml.utf8).write(
            to: workspace.appendingPathComponent("contents.xcworkspacedata")
        )
        return workspace
    }

    /// Stage a DerivedData entry with an info.plist whose `WorkspacePath` matches the
    /// given absolute path.
    func makeDerivedData(named name: String, workspacePath: String) throws -> URL {
        let entry = derivedDataRoot.appendingPathComponent(name)
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "WorkspacePath": workspacePath,
            "LastAccessedDate": Date()
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: entry.appendingPathComponent("info.plist"))
        return entry
    }

    /// Create a checkout dir with a stub `Package.swift` file. The file's contents don't
    /// matter — `swift package dump-package` is stubbed via `FakeProcessRunner` to return
    /// a synthesized `ManifestDump` JSON whose `dependencies` list matches `deps`.
    func makeCheckout(in derivedData: URL, identity: String, deps: [String]) throws {
        let checkouts = derivedData.appendingPathComponent("SourcePackages/checkouts")
        try fm.createDirectory(at: checkouts, withIntermediateDirectories: true)
        let dir = checkouts.appendingPathComponent(identity)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version:5.9\n// stub for \(identity)\n"
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("Package.swift"))

        // Register a fake `swift package dump-package` response keyed by canonical path.
        // The JSON uses the SPM tagged-union shape so we exercise that decode path.
        var depEntries = ""
        for (i, depID) in deps.enumerated() {
            let comma = i < deps.count - 1 ? "," : ""
            depEntries += """
              { "sourceControl": [ { "identity": "\(depID)", "location": { "remote": [{ "urlString": "https://example.com/\(depID)" }] } } ] }\(comma)
            """
        }
        let json = """
        { "name": "\(identity)", "dependencies": [\(depEntries)] }
        """
        pendingResponses[dir.standardizedFileURL.path] = json
    }
}

// MARK: - CannedDumpRunner

/// Test double that returns canned `swift package dump-package` JSON for known
/// directories. The response dictionary is supplied at init and never mutated, so the
/// runner is trivially `Sendable` with no locks or actor.
///
/// Named with an `Xcode`-distinct prefix because there's already a `FakeProcessRunner`
/// in `VersionFetcherTests.swift` and Swift's `private` doesn't always isolate the
/// types as cleanly as you'd expect when both files are compiled into the same module.
private struct CannedDumpRunner: ProcessRunning {
    let responses: [String: String]

    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        // Parse `--package-path <dir>` out of the arguments. The loader always passes it.
        var dirPath: String?
        var i = 0
        while i < arguments.count {
            if arguments[i] == "--package-path", i + 1 < arguments.count {
                dirPath = arguments[i + 1]
                break
            }
            i += 1
        }
        guard let dirPath else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "no --package-path")
        }
        let canonical = URL(fileURLWithPath: dirPath).standardizedFileURL.path
        guard let json = responses[canonical] else {
            return ProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "no canned response for \(canonical)"
            )
        }
        return ProcessResult(exitCode: 0, stdout: json, stderr: "")
    }
}