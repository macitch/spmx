/*
 *  File: ManifestEditor+Inspection.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import SwiftSyntax

/// Read-only inspection of a parsed `Package.swift` tree.
///
/// These methods never mutate. They power command pre-flight checks (auto-detection
/// of single-product/single-target packages, duplicate-dependency guards) and any
/// caller that wants structured information about the manifest without paying the
/// cost of `swift package dump-package`.
extension ManifestEditor {
    /// Target names defined in the manifest, excluding test targets
    /// (`.testTarget(...)`). Used by `AddCommand` to decide whether it can auto-pick
    /// a target or needs to require `--target`.
    ///
    /// Returns targets in source order. If there's exactly one non-test target, the
    /// command is safe to auto-pick it. Zero or two-plus → require `--target` (zero
    /// means the manifest is a pure test or product bundle; two-plus means ambiguity).
    ///
    /// - Throws: `.noPackageInit`, `.targetsNotArrayLiteral` when the manifest shape
    ///   is too unusual to reason about.
    public func listNonTestTargets() throws -> [String] {
        let packageCall = try findPackageCall()
        guard let targetsArg = Self.argument(labeled: "targets", in: packageCall) else {
            // No `targets:` argument at all — legal SPM, means zero targets. Return [].
            return []
        }
        if Self.containsShallowIfConfig(targetsArg.expression) {
            throw Error.conditionalTargets
        }
        guard let array = targetsArg.expression.as(ArrayExprSyntax.self) else {
            throw Error.targetsNotArrayLiteral
        }

        var names: [String] = []
        for element in array.elements {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
                // Not a `.target(...)`-style call (could be a variable reference, a
                // conditional expression, something weird). Skip it — we can't enumerate
                // it but we don't want to refuse the whole read just because one slot is
                // unusual. listNonTestTargets is an advisory read, not a safety check.
                continue
            }
            let kind = member.declName.baseName.text
            // Non-test target kinds we want to expose: target, executableTarget,
            // macro, plugin, systemLibrary, binaryTarget. testTarget is the only
            // one we deliberately exclude.
            if kind == "testTarget" { continue }

            // Extract the `name:` argument as a plain string literal.
            guard let nameArg = Self.argument(labeled: "name", in: call),
                  let nameValue = Self.plainStringLiteral(nameArg.expression) else {
                continue
            }
            names.append(nameValue)
        }
        return names
    }

    /// Product declarations in the manifest's `products:` array.
    ///
    /// Returns `(name, kind)` pairs in source order. The kind is derived from the
    /// member-access base name: `.library(…)` → `.library`, `.executable(…)` →
    /// `.executable`, `.plugin(…)` → `.plugin`, anything else → `.other`.
    ///
    /// This is the SwiftSyntax-based alternative to `swift package dump-package` for
    /// product discovery. It's faster (no subprocess), never hangs (dump-package can
    /// trigger dependency resolution on packages with macros), and works offline.
    ///
    /// - Throws: `.noPackageInit` if there's no Package call.
    public func listProducts() throws -> [(name: String, kind: ManifestFetcher.Metadata.Product.Kind)] {
        let packageCall = try findPackageCall()
        guard let productsArg = Self.argument(labeled: "products", in: packageCall) else {
            return []
        }
        guard let array = productsArg.expression.as(ArrayExprSyntax.self) else {
            // Non-literal products: — unusual but not something we need to refuse.
            // Return empty; the caller will treat it as "no products found."
            return []
        }

        var products: [(name: String, kind: ManifestFetcher.Metadata.Product.Kind)] = []
        for element in array.elements {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  let nameArg = Self.argument(labeled: "name", in: call),
                  let nameValue = Self.plainStringLiteral(nameArg.expression) else {
                continue
            }
            let kindString = member.declName.baseName.text
            let kind: ManifestFetcher.Metadata.Product.Kind
            switch kindString {
            case "library": kind = .library
            case "executable", "executableProduct": kind = .executable
            case "plugin": kind = .plugin
            default: kind = .other
            }
            products.append((name: nameValue, kind: kind))
        }
        return products
    }

    /// Returns the SPM identity of every package in the top-level `dependencies:` array.
    ///
    /// For `.package(url:)` entries, identity is derived via
    /// `XcodePackageReference.identity(forRepositoryURL:)`. For `.package(path:)` entries,
    /// identity is the last path component, lowercased (matching SPM's convention for
    /// local packages).
    ///
    /// Entries that don't match either shape (e.g. a future `.package(id:)` registry form)
    /// are silently skipped rather than throwing.
    ///
    /// - Throws: `.noPackageInit`, `.dependenciesNotArrayLiteral` when the manifest
    ///   shape is too unusual to reason about.
    public func listDependencyIdentities() throws -> [String] {
        let packageCall = try findPackageCall()
        guard let depsArg = Self.argument(labeled: "dependencies", in: packageCall) else {
            return []
        }
        if Self.containsIfConfig(depsArg.expression) {
            throw Error.conditionalDependencies
        }
        guard let array = depsArg.expression.as(ArrayExprSyntax.self) else {
            throw Error.dependenciesNotArrayLiteral
        }

        var identities: [String] = []
        for element in array.elements {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "package" else {
                continue
            }
            // .package(url: "...", ...)
            if let urlArg = Self.argument(labeled: "url", in: call),
               let urlString = Self.plainStringLiteral(urlArg.expression) {
                identities.append(XcodePackageReference.identity(forRepositoryURL: urlString))
                continue
            }
            // .package(path: "...", ...)
            if let pathArg = Self.argument(labeled: "path", in: call),
               let pathString = Self.plainStringLiteral(pathArg.expression) {
                let lastComponent = (pathString as NSString).lastPathComponent
                identities.append(lastComponent.lowercased())
                continue
            }
        }
        return identities
    }

    /// Whether a package with the given SPM identity is already listed in the top-level
    /// `dependencies:` array. Identity matching follows SPM's rule: URL last path
    /// component, `.git` stripped, lowercased. Matching is done via
    /// `XcodePackageReference.identity(forRepositoryURL:)` so there's only one copy
    /// of the rule in the codebase.
    ///
    /// - Throws: `.noPackageInit`, `.dependenciesNotArrayLiteral` when the manifest
    ///   shape is too unusual to reason about.
    public func containsPackage(identity: String) throws -> Bool {
        return try listDependencyIdentities().contains(identity.lowercased())
    }
}
