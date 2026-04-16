/*
 *  File: ManifestEditor+Add.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import SwiftSyntax

/// Mutation operations that *add* nodes to a `Package.swift` tree.
///
/// All methods return a new `ManifestEditor` (value semantics) and never write to
/// disk. The atomic `addingPackageWiredToTarget` exists so `spmx add` can declare a
/// package and wire one of its products into a target without ever leaving the
/// in-memory tree in a half-applied state.
extension ManifestEditor {
    /// Add a `.package(url:, ...)` entry to the top-level `dependencies:` array.
    ///
    /// Handles three manifest shapes:
    ///   1. `dependencies: [...]` exists → append to the array.
    ///   2. `dependencies:` is missing → insert the argument before `targets:` (or at
    ///      the end if `targets:` is also missing).
    ///   3. `dependencies:` is a non-literal (variable, helper call) → refuse.
    ///
    /// - Throws: `.duplicatePackage` if a package with the same identity already exists,
    ///   `.dependenciesNotArrayLiteral` if the argument is non-literal,
    ///   `.noPackageInit` if there's no top-level Package init.
    public func addingDependency(
        url: String,
        requirement: VersionRequirement
    ) throws -> ManifestEditor {
        let newIdentity = XcodePackageReference.identity(forRepositoryURL: url)
        if try containsPackage(identity: newIdentity) {
            throw Error.duplicatePackage(identity: newIdentity)
        }

        let packageCall = try findPackageCall()
        let newElementSource = Self.renderPackageCall(url: url, requirement: requirement)

        if let depsArg = Self.argument(labeled: "dependencies", in: packageCall) {
            // Case 1 or 3: dependencies: already exists.
            if Self.containsIfConfig(depsArg.expression) {
                throw Error.conditionalDependencies
            }
            guard let array = depsArg.expression.as(ArrayExprSyntax.self) else {
                throw Error.dependenciesNotArrayLiteral
            }
            let newArray = Self.appending(
                elementSource: newElementSource,
                to: array
            )
            let newTree = NodeReplacer(
                targetID: array.id,
                replacement: Syntax(newArray)
            ).rewrite(tree)
            guard let newSourceFile = newTree.as(SourceFileSyntax.self) else {
                throw Error.parseFailed("rewrite produced non-SourceFileSyntax")
            }
            return ManifestEditor(tree: newSourceFile)
        }

        // Case 2: no dependencies: argument at all. Insert one.
        let newArguments = Self.insertingDependenciesArgument(
            into: packageCall.arguments,
            withElementSource: newElementSource
        )
        let newCall = packageCall.with(\.arguments, newArguments)
        let newTree = NodeReplacer(
            targetID: packageCall.id,
            replacement: Syntax(newCall)
        ).rewrite(tree)
        guard let newSourceFile = newTree.as(SourceFileSyntax.self) else {
            throw Error.parseFailed("rewrite produced non-SourceFileSyntax")
        }
        return ManifestEditor(tree: newSourceFile)
    }

    /// Add a `.product(name:, package:)` entry to the given target's `dependencies:`
    /// array. Does not touch the top-level `dependencies:` — that's a separate call
    /// because the same package can expose multiple products and `add` may want to
    /// wire several of them into the same target.
    ///
    /// Handles two target shapes:
    ///   1. Target already has `dependencies: [...]` → append.
    ///   2. Target is bare (`.target(name: "X")`) → inject `dependencies: [...]`.
    ///
    /// - Throws: `.targetNotFound` if no target matches,
    ///   `.duplicateProductDependency` if the product is already wired to this target,
    ///   `.targetDependenciesNotArrayLiteral` if the target's dependencies: is not
    ///   a plain array, `.targetsNotArrayLiteral` for the same reason at the
    ///   Package(...) level.
    public func addingProductDependency(
        productName: String,
        package: String,
        target: String
    ) throws -> ManifestEditor {
        let (targetCall, _) = try findTargetCall(named: target)
        let elementSource = ".product(name: \"\(productName)\", package: \"\(package)\")"

        if let depsArg = Self.argument(labeled: "dependencies", in: targetCall) {
            // Case 1: target has a dependencies: array.
            if Self.containsIfConfig(depsArg.expression) {
                throw Error.conditionalTargetDependencies(target: target)
            }
            guard let array = depsArg.expression.as(ArrayExprSyntax.self) else {
                throw Error.targetDependenciesNotArrayLiteral(target: target)
            }

            // Duplicate check: iterate existing elements looking for a matching
            // .product(name:, package:) pair. Other element shapes (strings,
            // .target(...), .byName(...)) are skipped.
            for element in array.elements {
                if let (existingProduct, existingPackage) =
                    Self.productNameAndPackage(from: element.expression),
                   existingProduct == productName, existingPackage == package {
                    throw Error.duplicateProductDependency(
                        productName: productName,
                        target: target
                    )
                }
            }

            let newArray = Self.appending(elementSource: elementSource, to: array)
            let newTree = NodeReplacer(
                targetID: array.id,
                replacement: Syntax(newArray)
            ).rewrite(tree)
            guard let newSourceFile = newTree.as(SourceFileSyntax.self) else {
                throw Error.parseFailed("rewrite produced non-SourceFileSyntax")
            }
            return ManifestEditor(tree: newSourceFile)
        }

        // Case 2: target is bare — no dependencies: argument. Inject one.
        let newArguments = Self.insertingTargetDependenciesArgument(
            into: targetCall.arguments,
            withElementSource: elementSource
        )
        let newTargetCall = targetCall.with(\.arguments, newArguments)
        let newTree = NodeReplacer(
            targetID: targetCall.id,
            replacement: Syntax(newTargetCall)
        ).rewrite(tree)
        guard let newSourceFile = newTree.as(SourceFileSyntax.self) else {
            throw Error.parseFailed("rewrite produced non-SourceFileSyntax")
        }
        return ManifestEditor(tree: newSourceFile)
    }

    /// Atomically add a top-level `.package(url:, …)` entry AND wire one of its
    /// products into a specific target's `dependencies:` array.
    ///
    /// This is the operation `spmx add` wants. It's the mirror of
    /// `removingPackageCompletely`: either both edits land on the final serialized
    /// file, or neither does — the caller never observes a half-applied state where
    /// the package is declared but the target doesn't use it (or vice versa).
    ///
    /// ## Atomicity model
    ///
    /// Implemented as a two-step chain rather than a single batch rewrite. This is
    /// sound because `ManifestEditor` is value-semantic and the intermediate tree
    /// lives only in memory — if the second step throws, the whole call throws and
    /// the caller's original editor is unchanged. Nothing is ever written to disk
    /// until the caller explicitly calls `.write(to:)` on a fully-applied result.
    ///
    /// A batch rewrite (like `removingPackageCompletely` uses) would buy nothing
    /// here because the two mutations operate on sub-trees at different depths
    /// (top-level `dependencies:` and a specific target's `dependencies:`), and the
    /// second mutation doesn't depend on the first observing fresh node identities.
    /// Chaining is simpler, keeps `BatchNodeReplacer` focused on the one case it
    /// actually needs, and gives the exact same observable atomicity.
    ///
    /// ## Pre-validation ordering
    ///
    /// `addingDependency` checks for `.duplicatePackage`. `addingProductDependency`
    /// checks for target existence and `.duplicateProductDependency`. They're
    /// chained in the order: package → product. If the package is already present
    /// (e.g. the user adds Alamofire twice), you get `.duplicatePackage` and the
    /// target check never runs. If the package is fresh but the target doesn't
    /// exist, you get `.targetNotFound` and the in-memory package add is discarded.
    ///
    /// - Parameters:
    ///   - url: Repository URL to pin at the top level. Identity is derived via
    ///     `XcodePackageReference.identity(forRepositoryURL:)`.
    ///   - requirement: Version pinning strategy (`.from`, `.exact`, `.branch`, `.upToNextMajor`, etc).
    ///   - productName: The `.product(name:)` value to insert into the target.
    ///   - packageIdentity: The `.product(package:)` value. Usually this is the
    ///     SPM identity of the package being added — passed explicitly so the
    ///     caller can override if a package's manifest declares products under a
    ///     different name (rare but possible).
    ///   - target: Name of the target whose `dependencies:` array should receive
    ///     the new product reference.
    /// - Throws: Anything `addingDependency` or `addingProductDependency` can
    ///   throw. See their docs for the specific cases.
    public func addingPackageWiredToTarget(
        url: String,
        requirement: VersionRequirement,
        productName: String,
        packageIdentity: String,
        target: String
    ) throws -> ManifestEditor {
        let withTopLevel = try addingDependency(url: url, requirement: requirement)
        return try withTopLevel.addingProductDependency(
            productName: productName,
            package: packageIdentity,
            target: target
        )
    }
}
