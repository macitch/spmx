import Foundation
import Testing
@testable import SPMXCore

@Suite("Dependency editing regressions")
struct DependencyRegressionTests {
    @Test("remove unwires explicit aliases for both remote and local packages", arguments: [false, true])
    func removeAlias(local: Bool) throws {
        let location = local ? "path: \"../repo\"" : "url: \"https://example.com/repo.git\", from: \"1.0.0\""
        let source = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "App", dependencies: [
            .package(name: "Alias", \(location)),
            .package(url: "https://example.com/other.git", from: "1.0.0"),
        ], targets: [
            .target(name: "App", dependencies: [
                .product(name: "Lib", package: "Alias"),
                .product(name: "Other", package: "other"),
            ]),
            .testTarget(name: "Tests", dependencies: [.product(name: "Lib", package: "Alias")]),
        ])
        """
        let result = try ManifestEditor.parse(source: source).removingPackageCompletely(identity: "repo")
        #expect(result.affectedTargets == ["App", "Tests"])
        #expect(!result.editor.serialize().contains("Alias"))
        #expect(result.editor.serialize().contains(".product(name: \"Other\", package: \"other\")"))
    }

    @Test("both runners preserve resolution and rollback failures", arguments: [false, true], [false, true])
    func rollbackReporting(remove: Bool, blockRevert: Bool) async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let manifest = directory.appendingPathComponent("Package.swift")
        let source = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", dependencies: [
            .package(url: "https://example.com/repo.git", from: "1.0.0"),
        ], targets: [.target(name: "App", dependencies: [.product(name: "Lib", package: "repo")])])
        """
        try source.write(to: manifest, atomically: true, encoding: .utf8)
        let guard_ = ManifestWriteGuard(runner: FailingResolve(directory: directory, blockRevert: blockRevert))
        do {
            if remove {
                _ = try await RemoveRunner(writeGuard: guard_).run(options: .init(path: directory.path, package: "repo", dryRun: false))
            } else {
                let runner = AddRunner(fetchMetadata: { _, _ in
                    .init(packageName: "DisplayName", products: [.init(name: "NewLib", kind: .library)])
                }, writeGuard: guard_)
                _ = try await runner.run(options: .init(package: "https://example.com/new.git", exact: "1.0.0", path: directory.path))
            }
            Issue.record("Expected resolution failure")
        } catch let error as ManifestWriteGuard.ResolveFailure {
            #expect(error.stderr == "fixture resolution failure")
            #expect((error.revertError != nil) == blockRevert)
            let onDisk = try String(contentsOf: manifest, encoding: .utf8)
            #expect((onDisk == source) == !blockRevert)
            if blockRevert {
                #expect(error.localizedDescription.contains("automatic revert also failed"))
                #expect(!error.localizedDescription.contains("has been restored"))
            } else {
                #expect(error.localizedDescription.contains("has been restored"))
            }
        }
    }

    @Test("metadata is fetched at tags, branches and commits instead of default HEAD")
    func selectedRevisionMetadata() async throws {
        let fixture = try await GitFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fetcher = ManifestFetcher(temporaryDirectory: fixture.root)
        let requirements: [(ManifestEditor.VersionRequirement, String)] = [
            (.exact("1.0.0"), "OldLib"), (.from("1.0.0"), "MinorLib"),
            (.from("1.2.0"), "MinorLib"), (.upToNextMajor("1.0.0"), "MinorLib"),
            (.upToNextMinor("1.0.0"), "OldLib"), (.range(lower: "1.0.0", upper: "2.0.0"), "MinorLib"),
            (.closedRange(lower: "1.0.0", upper: "2.0.0"), "NewLib"),
            (.branch("stable"), "OldLib"), (.revision(fixture.oldRevision), "OldLib"),
        ]
        for (requirement, product) in requirements {
            let metadata = try await fetcher.fetch(url: fixture.repository.absoluteString, requirement: requirement)
            #expect(metadata.packageName == "DisplayName")
            #expect(metadata.products.map(\.name) == [product])
        }
        let head = try await fetcher.fetch(url: fixture.repository.absoluteString, requirement: .branch("main"))
        #expect(head.products.map(\.name) == ["NewLib"])
        do {
            _ = try await fetcher.fetch(url: fixture.repository.absoluteString, requirement: .exact("9.9.9"))
            Issue.record("An absent tag must not fall back to default HEAD")
        } catch let error as ManifestFetcher.Error {
            guard case .referenceNotFound = error else { throw error }
        }
    }

    @Test("add wires the repository identity and SwiftPM accepts the result")
    func addDifferentDisplayName() async throws {
        let fixture = try await GitFixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = fixture.root.appendingPathComponent("client", isDirectory: true)
        try FileManager.default.createDirectory(at: client.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        let manifest = client.appendingPathComponent("Package.swift")
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App")])
        """.write(to: manifest, atomically: true, encoding: .utf8)
        try "public struct App {}".write(to: client.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)

        let output = try await AddRunner().run(options: .init(
            package: fixture.repository.absoluteString, exact: "1.0.0", product: "OldLib", path: client.path
        ))
        let source = try String(contentsOf: manifest, encoding: .utf8)
        #expect(source.contains("package: \"repo\""))
        #expect(output.rendered.contains("package: \"repo\""))
        let validation = try await SystemProcessRunner().run("/usr/bin/env", arguments: [
            "swift", "package", "--disable-sandbox", "--cache-path", fixture.root.appendingPathComponent("cache").path,
            "--package-path", client.path, "describe",
        ])
        #expect(validation.exitCode == 0, Comment(rawValue: validation.stderr))
        #expect(validation.stdout.contains("OldLib"))
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spmx-regression-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct FailingResolve: ProcessRunning {
    let directory: URL
    let blockRevert: Bool
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        if blockRevert {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        }
        return .init(exitCode: 1, stdout: "", stderr: "fixture resolution failure")
    }
}

private struct GitFixture {
    let root: URL
    let repository: URL
    let oldRevision: String

    static func create() async throws -> GitFixture {
        let root = try temporaryDirectory()
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: repository.appendingPathComponent("Sources/Lib"), withIntermediateDirectories: true)
            try "public struct Lib {}".write(to: repository.appendingPathComponent("Sources/Lib/Lib.swift"), atomically: true, encoding: .utf8)
            func writeManifest(product: String) throws {
                try """
                // swift-tools-version: 6.0
                import PackageDescription
                let package = Package(name: "DisplayName", products: [.library(name: "\(product)", targets: ["Lib"])], targets: [.target(name: "Lib")])
                """.write(to: repository.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            }
            func git(_ arguments: [String]) async throws -> String {
                let result = try await SystemProcessRunner().run("/usr/bin/env", arguments: [
                    "git", "-C", repository.path, "-c", "user.name=SPMX Tests", "-c", "user.email=tests@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                ] + arguments)
                guard result.exitCode == 0 else { throw FixtureError.git(result.stderr) }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try writeManifest(product: "OldLib")
            _ = try await git(["init", "--quiet", "-b", "main"])
            _ = try await git(["add", "."])
            _ = try await git(["commit", "--quiet", "-m", "original product"])
            let oldRevision = try await git(["rev-parse", "HEAD"])
            _ = try await git(["tag", "-a", "v1.0.0", "-m", "version 1"])
            _ = try await git(["branch", "stable"])
            try writeManifest(product: "MinorLib")
            _ = try await git(["add", "."])
            _ = try await git(["commit", "--quiet", "-m", "minor release product"])
            _ = try await git(["tag", "1.5.0"])
            try writeManifest(product: "NewLib")
            _ = try await git(["add", "."])
            _ = try await git(["commit", "--quiet", "-m", "renamed product"])
            _ = try await git(["tag", "2.0.0"])
            return GitFixture(root: root, repository: repository, oldRevision: oldRevision)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private enum FixtureError: Swift.Error { case git(String) }
}
