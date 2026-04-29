/*
 *  File: AddRunner.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// End-to-end orchestration for `spmx add <package>`.
///
/// Pipeline:
///   1. Resolve the user input to a repository URL (catalog lookup or direct URL).
///   2. Check the local manifest doesn't already contain this package.
///   3. Resolve the version (user-supplied or auto-detected from `git ls-remote`).
///   4. Fetch remote manifest metadata (shallow clone + `dump-package`) to discover products.
///   5. Pick a product (auto if exactly one library, or user-supplied `--product`).
///   6. Pick a target (auto if exactly one non-test target, or user-supplied `--target`).
///   7. Atomically add the top-level dependency AND wire the product into the target.
///   8. Write (or dry-run).
///
/// ## Injection model
///
/// Three top-level dependencies are injected as closures rather than protocols:
///   - `resolveURL`: name → URL (wraps `PackageListResolver`)
///   - `fetchMetadata`: URL → `ManifestFetcher.Metadata` (wraps `ManifestFetcher`)
///   - `fetchLatestVersion`: URL → `Semver?` (wraps `git ls-remote --tags` + `parseTags`)
///
/// Closures keep the injection surface razor-thin — tests provide one-liner fakes
/// instead of building full service stubs. The default values wire to the real
/// implementations so production callers pay zero ceremony.
public struct AddRunner: Sendable {

    // MARK: - Options

    public struct Options: Sendable, Equatable {
        /// Raw user input: bare name, URL, or git@ form.
        public let package: String
        /// Explicit URL override (--url). Takes priority over name resolution.
        public let url: String?
        /// Version pinning. Mutually exclusive; nil = auto-detect from tags.
        public let from: String?
        public let exact: String?
        public let branch: String?
        public let revision: String?
        /// Product to wire into the target. nil = auto-pick if unambiguous.
        public let product: String?
        /// Target to wire into. nil = auto-pick if unambiguous.
        public let target: String?
        /// Path to the package directory (or Package.swift).
        public let path: String
        /// Dry-run: compute the change, print it, don't write.
        public let dryRun: Bool
        /// Force a catalog refresh (bypass 24h cache).
        public let refreshCatalog: Bool

        public init(
            package: String,
            url: String? = nil,
            from: String? = nil,
            exact: String? = nil,
            branch: String? = nil,
            revision: String? = nil,
            product: String? = nil,
            target: String? = nil,
            path: String = ".",
            dryRun: Bool = false,
            refreshCatalog: Bool = false
        ) {
            self.package = package
            self.url = url
            self.from = from
            self.exact = exact
            self.branch = branch
            self.revision = revision
            self.product = product
            self.target = target
            self.path = path
            self.dryRun = dryRun
            self.refreshCatalog = refreshCatalog
        }
    }

    // MARK: - Output

    public struct Output: Sendable, Equatable {
        public let resolvedURL: String
        public let packageName: String
        public let productName: String
        public let targetName: String
        public let version: String
        public let wroteChanges: Bool
        public let rendered: String

        public init(
            resolvedURL: String,
            packageName: String,
            productName: String,
            targetName: String,
            version: String,
            wroteChanges: Bool,
            rendered: String
        ) {
            self.resolvedURL = resolvedURL
            self.packageName = packageName
            self.productName = productName
            self.targetName = targetName
            self.version = version
            self.wroteChanges = wroteChanges
            self.rendered = rendered
        }
    }

    // MARK: - Errors

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        case pathDoesNotExist(path: String)
        case noManifest(directory: String)
        case noPackageInit
        case multiplePackageInits
        case dependenciesNotLiteral
        case targetsNotLiteral
        case targetDependenciesNotLiteral(target: String)
        case duplicatePackage(identity: String)
        case versionConflict(String)
        case noVersionTags(url: String)
        case versionFetchFailed(url: String, reason: String)
        case noLibraryProducts(packageName: String, products: [String])
        case ambiguousProducts(packageName: String, libraries: [String])
        case productNotFound(name: String, packageName: String, available: [String])
        case dynamicProducts(packageName: String)
        case ambiguousTargets(targets: [String])
        case noTargets
        case targetNotFound(name: String, candidates: [String])
        case duplicateProductDependency(productName: String, target: String)
        case resolveFailed(String)
        case fetchMetadataFailed(String)
        case parseFailed(String)
        case writeFailed(path: String, reason: String)

        public var description: String {
            switch self {
            case .pathDoesNotExist(let path):
                return """
                Path does not exist: \(path). Check the spelling, or omit `--path` to use \
                the current directory.
                """
            case .noManifest(let dir):
                return """
                No Package.swift found in \(dir). Run spmx from a SwiftPM package directory, \
                or pass `--path <dir>` pointing at one. To create a new package, run \
                `swift package init`.
                """
            case .noPackageInit:
                return """
                Couldn't find `let package = Package(...)` in Package.swift. \
                spmx only edits the canonical manifest shape; if yours constructs the Package \
                call differently, edit Package.swift by hand.
                """
            case .multiplePackageInits:
                return """
                Multiple `let package = Package(...)` declarations found in Package.swift. \
                spmx cannot determine which one to edit. Edit Package.swift by hand.
                """
            case .dependenciesNotLiteral:
                return """
                Package.swift's `dependencies:` is not a plain array literal.
                `spmx add` can't safely insert into a non-literal shape.
                Rewrite it as a literal array and try again.
                """
            case .targetsNotLiteral:
                return """
                Package.swift's `targets:` is not a plain array literal. \
                Rewrite it as a plain `[ ... ]` array of `.target(...)` / `.executableTarget(...)` \
                calls and try again.
                """
            case .targetDependenciesNotLiteral(let target):
                return """
                Target "\(target)" has a non-literal `dependencies:` argument.
                Rewrite it as a literal array and try again.
                """
            case .duplicatePackage(let id):
                return """
                Package "\(id)" is already in Package.swift's dependencies — nothing to add. \
                Run `spmx outdated` to check for newer versions, or `spmx remove \(id)` and \
                re-add to change its version constraint.
                """
            case .versionConflict(let msg):
                return "Conflicting version options: \(msg). Use only one of --from, --exact, --branch, --revision."
            case .noVersionTags(let url):
                return """
                No semver tags found for \(url).
                Specify a version explicitly: --from <version>, --branch <name>, or --revision <sha>.
                """
            case .versionFetchFailed(let url, let reason):
                return """
                Failed to fetch tags for \(url): \(reason)
                Specify a version explicitly: --from <version>, --branch <name>, or --revision <sha>.
                """
            case .noLibraryProducts(let name, let products):
                return """
                Package "\(name)" has no library products.
                Available products: \(products.joined(separator: ", "))
                Use --product <name> to pick a non-library product explicitly.
                """
            case .ambiguousProducts(let name, let libraries):
                return """
                Package "\(name)" has multiple library products:
                \(libraries.map { "  - \($0)" }.joined(separator: "\n"))

                Re-run with --product <name> to pick one. Example:
                  spmx add \(name.lowercased()) --product \(libraries[0])
                """
            case .productNotFound(let name, let pkgName, let available):
                return """
                Product "\(name)" not found in package "\(pkgName)".
                Available products: \(available.joined(separator: ", "))
                Re-run with `--product <name>` using one of those names.
                """
            case .dynamicProducts(let pkgName):
                return """
                Package "\(pkgName)" defines its products dynamically (via a variable
                or helper function), so spmx can't discover product names statically.

                Specify the product explicitly with --product <name>. Check the
                package's documentation or Package.swift for available product names.
                """
            case .ambiguousTargets(let targets):
                return """
                Multiple non-test targets found:
                \(targets.map { "  - \($0)" }.joined(separator: "\n"))

                Re-run with --target <name> to pick one. Example:
                  spmx add <package> --target \(targets[0])
                """
            case .noTargets:
                return """
                Package.swift has no non-test targets to wire the dependency into. \
                Add a `.target(...)` or `.executableTarget(...)` to Package.swift first, \
                then re-run `spmx add`.
                """
            case .targetNotFound(let name, let candidates):
                if candidates.isEmpty {
                    return """
                    Target "\(name)" not found in Package.swift. No targets are defined; \
                    add one to Package.swift first, then re-run `spmx add`.
                    """
                }
                let list = candidates.joined(separator: ", ")
                return """
                Target "\(name)" not found in Package.swift. Available targets: \(list). \
                Re-run with `--target <name>` using one of those names.
                """
            case .duplicateProductDependency(let product, let target):
                return """
                Product "\(product)" is already wired into target "\(target)" — nothing to add. \
                If you wanted a different product from the same package, pass `--product <name>` \
                with the correct product name.
                """
            case .resolveFailed(let msg):
                return """
                Couldn't resolve the package: \(msg). Pass the repository URL directly with \
                `--url <url>` to bypass the catalog, or use `spmx search <term>` to find the \
                right name.
                """
            case .fetchMetadataFailed(let msg):
                return """
                Failed to fetch package metadata: \(msg). Check your network connection. If the \
                package is reachable but the error persists, pass `--product <name>` to skip \
                metadata discovery.
                """
            case .parseFailed(let msg):
                return """
                Failed to parse Package.swift: \(msg). \
                Run `swift package describe` to see the compiler's view; fix any syntax errors and retry.
                """
            case .writeFailed(let path, let reason):
                return """
                Failed to write \(path): \(reason). Check write permissions on the directory \
                and that there's enough disk space; the manifest was not modified.
                """
            }
        }

        /// `LocalizedError` conformance so ArgumentParser (and any NSError bridge)
        /// prints our `description` instead of the opaque default.
        public var errorDescription: String? { description }
    }

    // MARK: - Dependencies

    /// Resolve a package name to a repository URL using the catalog.
    /// Signature: (name, refresh) -> URL string.
    private let resolveURL: @Sendable (String, Bool) async throws -> String

    /// Fetch remote manifest metadata (package name + products).
    /// Signature: (url) -> Metadata.
    private let fetchMetadata: @Sendable (String) async throws -> ManifestFetcher.Metadata

    /// Fetch the latest stable semver tag for a URL.
    /// Signature: (url) -> Semver? (nil = no tags found).
    private let fetchLatestVersion: @Sendable (String) async throws -> Semver?

    /// Optional interactive chooser for ambiguous matches. When non-nil and the
    /// resolver returns multiple candidates, the chooser is called with the
    /// candidates and must return the user's chosen URL. When nil (default),
    /// ambiguous matches throw `resolveFailed` with the candidate list.
    ///
    /// The closure receives `(query, candidates)` and returns the chosen URL string.
    private let interactiveChooser: (@Sendable (String, [PackageListResolver.Match]) async throws -> String)?

    /// Optional write guard that runs `swift package resolve` after writing the
    /// manifest and reverts on failure. When nil (the default in tests), the
    /// manifest is written directly with no resolution check.
    private let writeGuard: ManifestWriteGuard?

    // MARK: - Init

    public init(
        resolveURL: @escaping @Sendable (String, Bool) async throws -> String = defaultResolveURL,
        fetchMetadata: @escaping @Sendable (String) async throws -> ManifestFetcher.Metadata = defaultFetchMetadata,
        fetchLatestVersion: @escaping @Sendable (String) async throws -> Semver? = defaultFetchLatestVersion,
        interactiveChooser: (@Sendable (String, [PackageListResolver.Match]) async throws -> String)? = nil,
        writeGuard: ManifestWriteGuard? = nil
    ) {
        self.resolveURL = resolveURL
        self.fetchMetadata = fetchMetadata
        self.fetchLatestVersion = fetchLatestVersion
        self.interactiveChooser = interactiveChooser
        self.writeGuard = writeGuard
    }

    // MARK: - Default implementations

    /// Wire to real `PackageListResolver.resolve(name:refresh:)`.
    public static let defaultResolveURL: @Sendable (String, Bool) async throws -> String = { name, refresh in
        let match = try await PackageListResolver().resolve(name: name, refresh: refresh)
        return match.url
    }

    /// Wire to real `ManifestFetcher.fetch(url:)`.
    public static let defaultFetchMetadata: @Sendable (String) async throws -> ManifestFetcher.Metadata = { url in
        try await ManifestFetcher().fetch(url: url)
    }

    /// Wire to real `git ls-remote --tags` via `SystemProcessRunner`.
    public static let defaultFetchLatestVersion: @Sendable (String) async throws -> Semver? = { url in
        let runner = SystemProcessRunner()
        let result = try await runner.run("/usr/bin/env", arguments: ["git", "ls-remote", "--tags", "--refs", url])
        guard result.exitCode == 0 else { return nil }
        let tags = GitVersionFetcher.parseTags(from: result.stdout)
        return tags.compactMap(Semver.init).filter { !$0.isPrerelease }.max()
    }

    // MARK: - Run

    public func run(options: Options) async throws -> Output {
        // 1. Resolve URL.
        let resolvedURL: String
        if let explicitURL = options.url {
            resolvedURL = explicitURL
        } else if Self.looksLikeURL(options.package) {
            resolvedURL = options.package
        } else {
            do {
                resolvedURL = try await resolveURL(options.package, options.refreshCatalog)
            } catch let plrError as PackageListResolver.Error {
                // Intercept ambiguous matches for interactive picking.
                if case .ambiguous(let query, let candidates) = plrError,
                   let chooser = interactiveChooser {
                    resolvedURL = try await chooser(query, candidates)
                } else {
                    throw Error.resolveFailed(String(describing: plrError))
                }
            } catch {
                throw Error.resolveFailed(String(describing: error))
            }
        }

        // 2. Locate and load the local manifest.
        let manifestURL = try locateManifest(at: options.path)
        let editor: ManifestEditor
        do {
            editor = try ManifestEditor.load(from: manifestURL)
        } catch let err as ManifestEditor.Error {
            throw Self.mapEditorError(err)
        }

        // 3. Check for duplicate before any network calls.
        let identity = XcodePackageReference.identity(forRepositoryURL: resolvedURL)
        do {
            if try editor.containsPackage(identity: identity) {
                throw Error.duplicatePackage(identity: identity)
            }
        } catch let err as Error {
            throw err
        } catch let err as ManifestEditor.Error {
            throw Self.mapEditorError(err)
        }

        // 4. Resolve version requirement.
        print("Resolving version for \(identity)…", terminator: "")
        let requirement = try await resolveVersion(options: options, url: resolvedURL)
        print(" \(Self.versionLabel(requirement))")

        // 5. Fetch remote metadata (products).
        print("Fetching package metadata…", terminator: "")
        let metadata: ManifestFetcher.Metadata
        do {
            metadata = try await fetchMetadata(resolvedURL)
        } catch {
            print(" failed")
            throw Error.fetchMetadataFailed(String(describing: error))
        }
        print(" \(metadata.products.count) product(s) found")

        // 6. Pick product.
        let chosenProduct = try pickProduct(
            explicit: options.product,
            metadata: metadata
        )

        // 7. Pick target.
        let chosenTarget = try pickTarget(
            explicit: options.target,
            editor: editor
        )

        // 8. Apply the combined edit.
        let edited: ManifestEditor
        do {
            edited = try editor.addingPackageWiredToTarget(
                url: resolvedURL,
                requirement: requirement,
                productName: chosenProduct,
                packageIdentity: metadata.packageName,
                target: chosenTarget
            )
        } catch let err as ManifestEditor.Error {
            throw Self.mapEditorError(err)
        }

        // 9. Write (or dry-run). If a writeGuard is configured, also run
        //    `swift package resolve` and revert on failure.
        if !options.dryRun {
            if let guard_ = writeGuard {
                print("Resolving dependencies…")
                do {
                    try await guard_.writeAndResolve(editor: edited, to: manifestURL)
                } catch let err as ManifestEditor.Error {
                    throw Self.mapEditorError(err)
                } catch let err as ManifestWriteGuard.ResolveFailure {
                    throw Error.resolveFailed(err.stderr)
                }
            } else {
                do {
                    try edited.write(to: manifestURL)
                } catch let err as ManifestEditor.Error {
                    throw Self.mapEditorError(err)
                }
            }
        }

        // 10. Render summary.
        let versionLabel = Self.versionLabel(requirement)
        let rendered = Self.renderSummary(
            url: resolvedURL,
            packageName: metadata.packageName,
            productName: chosenProduct,
            targetName: chosenTarget,
            version: versionLabel,
            dryRun: options.dryRun
        )

        return Output(
            resolvedURL: resolvedURL,
            packageName: metadata.packageName,
            productName: chosenProduct,
            targetName: chosenTarget,
            version: versionLabel,
            wroteChanges: !options.dryRun,
            rendered: rendered
        )
    }

    // MARK: - Helpers

    static func looksLikeURL(_ input: String) -> Bool {
        input.contains("://") || (input.contains("@") && input.contains(":") && !input.hasPrefix("/"))
    }

    private func locateManifest(at rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Error.pathDoesNotExist(path: url.path)
        }

        if isDirectory.boolValue {
            let candidate = url.appendingPathComponent("Package.swift")
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw Error.noManifest(directory: url.path)
            }
            return candidate
        } else {
            guard url.lastPathComponent == "Package.swift" else {
                throw Error.noManifest(directory: url.deletingLastPathComponent().path)
            }
            return url
        }
    }

    private func resolveVersion(
        options: Options,
        url: String
    ) async throws -> ManifestEditor.VersionRequirement {
        // Count explicit version options.
        let explicit: [(String, ManifestEditor.VersionRequirement)] = [
            options.from.map { ("--from", .from($0)) },
            options.exact.map { ("--exact", .exact($0)) },
            options.branch.map { ("--branch", .branch($0)) },
            options.revision.map { ("--revision", .revision($0)) },
        ].compactMap { $0 }

        if explicit.count > 1 {
            let flags = explicit.map(\.0).joined(separator: ", ")
            throw Error.versionConflict(flags)
        }
        if let (_, req) = explicit.first {
            return req
        }

        // Auto-detect: latest stable tag.
        let latest: Semver?
        do {
            latest = try await fetchLatestVersion(url)
        } catch {
            throw Error.versionFetchFailed(url: url, reason: String(describing: error))
        }

        guard let version = latest else {
            throw Error.noVersionTags(url: url)
        }
        return .from(version.description)
    }

    private func pickProduct(
        explicit: String?,
        metadata: ManifestFetcher.Metadata
    ) throws -> String {
        let isDynamic = metadata.products.isEmpty

        if let explicit = explicit {
            if isDynamic {
                // Dynamic products: can't validate — trust the user.
                // The worst case is a broken manifest that `swift package resolve`
                // will catch immediately.
                return explicit
            }
            // Validate it exists.
            guard metadata.products.contains(where: { $0.name == explicit }) else {
                throw Error.productNotFound(
                    name: explicit,
                    packageName: metadata.packageName,
                    available: metadata.products.map(\.name)
                )
            }
            return explicit
        }

        // No --product given. If the products list is empty because the manifest
        // defines them dynamically (via a variable or helper), we can't auto-pick.
        if isDynamic {
            throw Error.dynamicProducts(packageName: metadata.packageName)
        }

        // Auto-pick: exactly one library product.
        let libraries = metadata.products.filter { $0.kind == .library }

        if libraries.count == 1 {
            return libraries[0].name
        }

        if libraries.isEmpty {
            throw Error.noLibraryProducts(
                packageName: metadata.packageName,
                products: metadata.products.map(\.name)
            )
        }

        throw Error.ambiguousProducts(
            packageName: metadata.packageName,
            libraries: libraries.map(\.name)
        )
    }

    private func pickTarget(
        explicit: String?,
        editor: ManifestEditor
    ) throws -> String {
        if let explicit = explicit {
            // Validate via the editor's target list. listNonTestTargets won't
            // include test targets, but --target might reference any target
            // (including tests). Let's trust the combined edit to throw
            // targetNotFound if it doesn't exist — the editor already has that
            // check. But we want a friendly error sooner, so we peek.
            do {
                let all = try editor.listNonTestTargets()
                // Also include test targets — user might explicitly want a test target.
                // Actually, listNonTestTargets only returns non-test. The editor's
                // addingProductDependency will validate existence of any target
                // kind via findTargetCall. So we skip pre-validation here and let
                // the editor handle it.
                _ = all // suppress unused warning; the real check is in step 8
            } catch {
                // If we can't even list targets, let the editor error propagate
                // in the combined edit step. Continue here.
            }
            return explicit
        }

        // Auto-pick: exactly one non-test target.
        let targets: [String]
        do {
            targets = try editor.listNonTestTargets()
        } catch let err as ManifestEditor.Error {
            throw Self.mapEditorError(err)
        }

        switch targets.count {
        case 0:
            throw Error.noTargets
        case 1:
            return targets[0]
        default:
            throw Error.ambiguousTargets(targets: targets)
        }
    }

    // MARK: - Error mapping

    private static func mapEditorError(_ err: ManifestEditor.Error) -> Error {
        switch err {
        case .fileNotFound(let url):
            return .pathDoesNotExist(path: url.path)
        case .readFailed(let path, _):
            return .parseFailed("read failed: \(path)")
        case .writeFailed(let path, let underlying):
            return .writeFailed(path: path, reason: underlying)
        case .parseFailed(let msg):
            return .parseFailed(msg)
        case .noPackageInit:
            return .noPackageInit
        case .multiplePackageInits:
            return .multiplePackageInits
        case .dependenciesNotArrayLiteral, .conditionalDependencies:
            return .dependenciesNotLiteral
        case .targetsNotArrayLiteral, .conditionalTargets:
            return .targetsNotLiteral
        case .targetDependenciesNotArrayLiteral(let target),
             .conditionalTargetDependencies(let target):
            return .targetDependenciesNotLiteral(target: target)
        case .duplicatePackage(let id):
            return .duplicatePackage(identity: id)
        case .duplicateProductDependency(let product, let target):
            return .duplicateProductDependency(productName: product, target: target)
        case .targetNotFound(let name, let candidates):
            return .targetNotFound(name: name, candidates: candidates)
        case .packageNotFound(let id):
            // Shouldn't happen in add flow, but map defensively.
            return .parseFailed("unexpected packageNotFound: \(id)")
        case .productDependencyNotFound(let product, let target):
            return .parseFailed("unexpected productDependencyNotFound: \(product) in \(target)")
        }
    }

    // MARK: - Rendering

    static func versionLabel(_ req: ManifestEditor.VersionRequirement) -> String {
        switch req {
        case .from(let v): return "from: \"\(v)\""
        case .upToNextMajor(let v): return "from: \"\(v)\""
        case .upToNextMinor(let v): return "upToNextMinor: \"\(v)\""
        case .exact(let v): return "exact: \"\(v)\""
        case .range(let lo, let hi): return "\"\(lo)\"..<\"\(hi)\""
        case .closedRange(let lo, let hi): return "\"\(lo)\"...\"\(hi)\""
        case .branch(let b): return "branch: \"\(b)\""
        case .revision(let r): return "revision: \"\(r)\""
        }
    }

    static func renderSummary(
        url: String,
        packageName: String,
        productName: String,
        targetName: String,
        version: String,
        dryRun: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("Adding: \(packageName) (\(version))")
        lines.append("✓ Added .package(url: \"\(url)\", \(version)) to Package.swift")
        lines.append("✓ Wired .product(name: \"\(productName)\", package: \"\(packageName)\") into target \"\(targetName)\"")
        if dryRun {
            lines.append("[dry-run] no files written")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}