/*
 *  File: ManifestFetcher.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import SwiftParser
import SwiftSyntax

/// Fetches minimal manifest metadata for a remote package by shallow-cloning it and
/// parsing its `Package.swift` with SwiftSyntax.
///
/// ## Why this exists
///
/// `PackageListResolver` answers "what URL is this name?" — that's enough to write a
/// `.package(url:from:)` line to Package.swift. But to *wire the dependency into a target*
/// we need the product name, and the catalog doesn't carry product info. The only
/// authoritative source is the package's own manifest.
///
/// We deliberately don't reuse `DiskCachedManifestLoader` here:
///   - it loads a **local** package directory (ours), not a remote clone
///   - its cache is keyed to the local file contents and baked into `GraphBuilder`/`WhyRunner`'s
///     flow; extending it would risk cache-shape drift for those callers
///   - `ManifestDump` only decodes `name` and `dependencies`, not `products`
///
/// Instead, `ManifestFetcher` is a narrow, throwaway wrapper that:
///   1. `git clone --depth 1 <url> <tmpDir>` — shallow, fast, ~1-2s for typical repos
///   2. `swift package --package-path <tmpDir> dump-package` — parses the manifest Swift code
///   3. decodes the subset of the JSON we care about (`name` + `products[]`)
///   4. tears down the tmp dir
///
/// No caching: this runs once per `spmx add` invocation (the user is already waiting on
/// network anyway) and the tmp dir is cleaned up on exit.
///
/// ## What it does NOT do
///
/// No version resolution (that's `VersionFetcher`), no target discovery, no transitive
/// dependency walking. Just "what products does this package expose?" so `AddRunner` can
/// pick one to wire into a target.
public struct ManifestFetcher: Sendable {

    // MARK: - Types

    /// Narrow metadata slice needed by `AddRunner` to wire a dependency.
    public struct Metadata: Sendable, Equatable {
        public let packageName: String
        public let products: [Product]

        public init(packageName: String, products: [Product]) {
            self.packageName = packageName
            self.products = products
        }

        public struct Product: Sendable, Equatable {
            public let name: String
            public let kind: Kind

            public init(name: String, kind: Kind) {
                self.name = name
                self.kind = kind
            }

            public enum Kind: String, Sendable, Equatable {
                case library
                case executable
                case plugin
                case other
            }
        }
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        case cloneFailed(url: String, stderr: String)
        case dumpFailed(stderr: String)
        case decodeFailed(String)
        case filesystemFailed(String)

        public var description: String {
            switch self {
            case .cloneFailed(let url, let stderr):
                return """
                Failed to clone \(url):
                \(stderr)

                Check that the URL is correct and reachable, and that you have credentials \
                for private repos. To skip metadata discovery, pass `--product <name>` and \
                spmx will trust your input.
                """
            case .dumpFailed(let stderr):
                return """
                Failed to run `swift package dump-package` on the cloned repo:
                \(stderr)

                The repo may have a Package.swift that depends on macros, plugins, or other \
                packages that fail to resolve. Pass `--product <name>` to skip metadata \
                discovery and wire the product directly.
                """
            case .decodeFailed(let msg):
                return """
                Failed to decode dump-package output: \(msg). \
                This is likely a spmx bug — please file an issue at \
                https://github.com/macitch/spmx/issues with the package URL.
                """
            case .filesystemFailed(let msg):
                return """
                Filesystem error while preparing clone: \(msg). \
                Check `/tmp` is writable and has enough free space.
                """
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - State

    private let runner: any ProcessRunning
    private let temporaryDirectory: URL
    private let envExecutable: String

    // MARK: - Init

    /// - Parameters:
    ///   - runner: Subprocess runner. Tests inject a fake that can distinguish git vs swift calls.
    ///   - temporaryDirectory: Parent dir for the clone's scratch space. Tests pass a custom path
    ///     so they can assert cleanup happens.
    ///   - envExecutable: Path to `/usr/bin/env` (or a test equivalent). Matches VersionFetcher's
    ///     convention — we invoke `env git …` and `env swift …` so PATH resolution Just Works.
    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        envExecutable: String = "/usr/bin/env"
    ) {
        self.runner = runner
        self.temporaryDirectory = temporaryDirectory
        self.envExecutable = envExecutable
    }

    // MARK: - Public API

    /// Clone `url` shallowly and return the minimal metadata needed to wire it into a target.
    ///
    /// The clone happens inside a unique tmp directory which is removed before return (whether
    /// the call succeeds or throws). A failure on cleanup is logged but not surfaced — the user's
    /// add-flow shouldn't break because `/tmp` is full.
    ///
    /// ## Why SwiftSyntax instead of `dump-package`
    ///
    /// The original implementation ran `swift package dump-package` on the clone. That
    /// worked for simple packages but **hangs indefinitely** on packages that use macros
    /// or plugins (e.g. apple/swift-collections) because dump-package triggers
    /// dependency resolution under the hood. SwiftSyntax parsing is instant, offline,
    /// and never blocks on network I/O.
    public func fetch(url: String) async throws -> Metadata {
        let fm = FileManager.default
        let workDir = temporaryDirectory
            .appendingPathComponent("spmx-fetch-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            throw Error.filesystemFailed("create tmp dir: \(error.localizedDescription)")
        }

        // Best-effort cleanup — any failure here is ignorable noise.
        defer { try? fm.removeItem(at: workDir) }

        // 1. Shallow clone.
        let cloneResult: ProcessResult
        do {
            cloneResult = try await runner.run(
                envExecutable,
                arguments: ["git", "clone", "--depth", "1", "--quiet", url, workDir.path]
            )
        } catch {
            throw Error.cloneFailed(url: url, stderr: error.localizedDescription)
        }
        guard cloneResult.exitCode == 0 else {
            throw Error.cloneFailed(
                url: url,
                stderr: cloneResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // 2. Parse Package.swift with SwiftSyntax (no subprocess needed).
        let manifestURL = workDir.appendingPathComponent("Package.swift")
        let editor: ManifestEditor
        do {
            editor = try ManifestEditor.load(from: manifestURL)
        } catch {
            throw Error.decodeFailed("failed to parse cloned Package.swift: \(error)")
        }

        // 3. Extract package name and products from the AST.
        let packageName: String
        do {
            // The package name is embedded in the Package(...) call's `name:` argument.
            // We can read it from the serialized source — but ManifestEditor doesn't
            // expose it directly. Parse it from the source as a lightweight workaround.
            packageName = try Self.extractPackageName(from: editor)
        } catch {
            throw Error.decodeFailed("failed to extract package name: \(error)")
        }

        let rawProducts: [(name: String, kind: Metadata.Product.Kind)]
        do {
            rawProducts = try editor.listProducts()
        } catch {
            throw Error.decodeFailed("failed to list products: \(error)")
        }

        let products = rawProducts.map { Metadata.Product(name: $0.name, kind: $0.kind) }
        return Metadata(packageName: packageName, products: products)
    }

    /// Extract the `name:` argument from the top-level `Package(...)` call.
    ///
    /// Uses the same heuristics as ManifestEditor's `findPackageCall` — walks the
    /// top-level statements looking for `let package = Package(name: "...")`.
    private static func extractPackageName(from editor: ManifestEditor) throws -> String {
        // Re-parse the serialized source to access the raw syntax tree.
        // ManifestEditor doesn't expose the tree publicly, so we go through
        // the serialize → re-parse path. This is cheap (the tree is already in
        // memory; re-parsing a Package.swift is < 1ms).
        let source = editor.serialize()
        let parsed = Parser.parse(source: source)
        for item in parsed.statements {
            guard let varDecl = item.item.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  let identPattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  identPattern.identifier.text == "package",
                  let initializer = binding.initializer,
                  let call = initializer.value.as(FunctionCallExprSyntax.self) else {
                continue
            }
            for arg in call.arguments {
                if arg.label?.text == "name",
                   let literal = arg.expression.as(StringLiteralExprSyntax.self),
                   let segment = literal.segments.first?.as(StringSegmentSyntax.self) {
                    return segment.content.text
                }
            }
        }
        throw Error.decodeFailed("no `name:` argument found in Package(...)")
    }

    // MARK: - Decode

    /// Decode the subset of `swift package dump-package` output we care about.
    ///
    /// The real payload is big; we only look at `name` and `products[]`. Products are shaped as:
    /// ```json
    /// { "name": "Foo", "type": { "library": ["automatic"] }, "targets": [...] }
    /// ```
    /// where `type` is a single-key dict whose key is the product kind (`library`,
    /// `executable`, `plugin`, …). We classify by key and lump anything unknown into `.other`
    /// rather than failing the decode — `swift package dump-package` adds new product kinds
    /// occasionally and spmx shouldn't break when that happens.
    static func decode(_ data: Data) throws -> Metadata {
        struct RawDump: Decodable {
            let name: String
            let products: [RawProduct]?
        }
        struct RawProduct: Decodable {
            let name: String
            let type: [String: AnyDecodable?]
        }
        /// Swallows whatever value sits under each product type key — we only need the key.
        struct AnyDecodable: Decodable {
            init(from decoder: Decoder) throws {
                // Intentionally no-op: discard any value shape.
                _ = try? decoder.singleValueContainer()
            }
        }

        let raw: RawDump
        do {
            raw = try JSONDecoder().decode(RawDump.self, from: data)
        } catch {
            throw Error.decodeFailed(error.localizedDescription)
        }

        let products: [Metadata.Product] = (raw.products ?? []).map { rp in
            let kind: Metadata.Product.Kind
            if rp.type.keys.contains("library") {
                kind = .library
            } else if rp.type.keys.contains("executable") {
                kind = .executable
            } else if rp.type.keys.contains("plugin") {
                kind = .plugin
            } else {
                kind = .other
            }
            return Metadata.Product(name: rp.name, kind: kind)
        }

        return Metadata(packageName: raw.name, products: products)
    }
}