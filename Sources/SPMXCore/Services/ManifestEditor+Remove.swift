/*
 *  File: ManifestEditor+Remove.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import SwiftSyntax

/// Mutation operations that *remove* nodes from a `Package.swift` tree.
///
/// All methods return a new `ManifestEditor` (value semantics) and never write to
/// disk. The atomic `removingPackageCompletely` exists so `spmx remove` can sweep
/// a top-level dependency and every transitive `.product(...)` reference in a
/// single batch rewrite — never leaving a half-applied state where the package is
/// gone but orphan target references remain.
extension ManifestEditor {
    /// Atomically remove a package from the top-level `dependencies:` array AND from
    /// every target's `dependencies:` array that references it via `.product(package:)`.
    ///
    /// This is the operation `spmx remove` wants. Doing it as multiple separate
    /// mutations would leave a window where the top-level dep is gone but orphan
    /// `.product(...)` references still exist — a broken Package.swift that won't
    /// compile. This method computes all the changes against the original tree (whose
    /// node identities are still valid) and applies them in a single batch rewrite,
    /// so either everything succeeds or nothing changes.
    ///
    /// ## Conservative rule on non-literal target dependencies
    ///
    /// If **any** target has a non-literal `dependencies:` argument (helper function,
    /// variable, conditional), the entire operation is refused with
    /// `.targetDependenciesNotArrayLiteral(target:)` — even if that target doesn't
    /// obviously reference the package being removed. We can't statically evaluate a
    /// helper function to know whether it produces a reference to the package, so the
    /// only safe default is to refuse and ask the user to make the target's deps a
    /// plain literal before retrying. This avoids silently leaving orphan refs in an
    /// unreadable target.
    ///
    /// - Throws: `.packageNotFound` if no top-level entry matches,
    ///   `.dependenciesNotArrayLiteral` if the top-level `dependencies:` isn't a
    ///   literal, `.targetsNotArrayLiteral` if `targets:` isn't a literal,
    ///   `.targetDependenciesNotArrayLiteral(target:)` if any target's deps aren't
    ///   literal, `.noPackageInit` if no Package call.
    public func removingPackageCompletely(identity: String) throws -> PackageRemoval {
        let normalizedTarget = identity.lowercased()
        let packageCall = try findPackageCall()

        // Top-level deps must exist as a literal and contain the package.
        guard let depsArg = Self.argument(labeled: "dependencies", in: packageCall) else {
            throw Error.packageNotFound(identity: normalizedTarget)
        }
        if Self.containsIfConfig(depsArg.expression) {
            throw Error.conditionalDependencies
        }
        guard let depsArray = depsArg.expression.as(ArrayExprSyntax.self) else {
            throw Error.dependenciesNotArrayLiteral
        }

        var foundInTopLevel = false
        for element in depsArray.elements {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "package",
                  let urlArg = Self.argument(labeled: "url", in: call),
                  let url = Self.plainStringLiteral(urlArg.expression) else {
                continue
            }
            if XcodePackageReference.identity(forRepositoryURL: url) == normalizedTarget {
                foundInTopLevel = true
                break
            }
        }
        guard foundInTopLevel else {
            throw Error.packageNotFound(identity: normalizedTarget)
        }

        // Collect all array replacements. Start with the top-level deps minus the
        // package entry.
        var replacements: [SyntaxIdentifier: Syntax] = [:]
        replacements[depsArray.id] = Syntax(
            Self.removingPackageElement(withIdentity: normalizedTarget, from: depsArray)
        )

        // Pre-scan every target. Enforce the conservative rule: any non-literal
        // target deps → refuse. For literal target deps that reference the package,
        // stage a replacement array with those references filtered out.
        var affectedTargets: [String] = []
        if let targetsArg = Self.argument(labeled: "targets", in: packageCall) {
            if Self.containsShallowIfConfig(targetsArg.expression) {
                throw Error.conditionalTargets
            }
            guard let targetsArray = targetsArg.expression.as(ArrayExprSyntax.self) else {
                throw Error.targetsNotArrayLiteral
            }
            for element in targetsArray.elements {
                guard let call = element.expression.as(FunctionCallExprSyntax.self),
                      call.calledExpression.as(MemberAccessExprSyntax.self) != nil,
                      let nameArg = Self.argument(labeled: "name", in: call),
                      let targetName = Self.plainStringLiteral(nameArg.expression) else {
                    continue
                }

                // Bare target (no dependencies: argument) can't reference anything.
                guard let tDepsArg = Self.argument(labeled: "dependencies", in: call) else {
                    continue
                }

                // Conditional target deps → explicit refusal.
                if Self.containsIfConfig(tDepsArg.expression) {
                    throw Error.conditionalTargetDependencies(target: targetName)
                }
                // Non-literal target deps → conservative refusal.
                guard let tDepsArray = tDepsArg.expression.as(ArrayExprSyntax.self) else {
                    throw Error.targetDependenciesNotArrayLiteral(target: targetName)
                }

                // Does this target reference the package? If so, stage a replacement.
                let hasReference = tDepsArray.elements.contains { el in
                    guard let (_, pkg) = Self.productNameAndPackage(from: el.expression) else {
                        return false
                    }
                    return pkg.lowercased() == normalizedTarget
                }
                if hasReference {
                    let swept = Self.removingProducts(
                        matchingPackage: normalizedTarget,
                        from: tDepsArray
                    )
                    replacements[tDepsArray.id] = Syntax(swept)
                    affectedTargets.append(targetName)
                }
            }
        }

        // Single-pass batch rewrite.
        let newTree = BatchNodeReplacer(replacements: replacements).rewrite(tree)
        guard let newSourceFile = newTree.as(SourceFileSyntax.self) else {
            throw Error.parseFailed("batch rewrite produced non-SourceFileSyntax")
        }
        return PackageRemoval(
            editor: ManifestEditor(tree: newSourceFile),
            affectedTargets: affectedTargets
        )
    }

    /// Remove the `.package(url:, ...)` entry whose URL has the given SPM identity.
    ///
    /// - Throws: `.packageNotFound` if no matching entry exists,
    ///   `.dependenciesNotArrayLiteral` if the manifest shape is unusual,
    ///   `.noPackageInit` if there's no top-level Package init.
    public func removingDependency(identity: String) throws -> ManifestEditor {
        let normalizedTarget = identity.lowercased()
        let packageCall = try findPackageCall()
        guard let depsArg = Self.argument(labeled: "dependencies", in: packageCall) else {
            throw Error.packageNotFound(identity: normalizedTarget)
        }
        if Self.containsIfConfig(depsArg.expression) {
            throw Error.conditionalDependencies
        }
        guard let array = depsArg.expression.as(ArrayExprSyntax.self) else {
            throw Error.dependenciesNotArrayLiteral
        }

        // Find the element to remove by identity.
        var targetIndex: Int? = nil
        for (i, element) in array.elements.enumerated() {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "package",
                  let urlArg = Self.argument(labeled: "url", in: call),
                  let urlString = Self.plainStringLiteral(urlArg.expression) else {
                continue
            }
            if XcodePackageReference.identity(forRepositoryURL: urlString) == normalizedTarget {
                targetIndex = i
                break
            }
        }

        guard let idx = targetIndex else {
            throw Error.packageNotFound(identity: normalizedTarget)
        }

        let newArray = Self.removing(elementAt: idx, from: array)
        let newTree = NodeReplacer(
            targetID: array.id,
            replacement: Syntax(newArray)
        ).rewrite(tree)
        guard let newSourceFile = newTree.as(SourceFileSyntax.self) else {
            throw Error.parseFailed("rewrite produced non-SourceFileSyntax")
        }
        return ManifestEditor(tree: newSourceFile)
    }

    /// Remove a `.product(name:, package:)` entry from the given target's
    /// `dependencies:` array. Matches by product name AND package name so that
    /// two different packages exposing a product with the same name are
    /// disambiguated correctly.
    ///
    /// - Throws: `.targetNotFound` if no target matches,
    ///   `.productDependencyNotFound` if the product isn't wired to this target,
    ///   `.targetDependenciesNotArrayLiteral` if the target's dependencies: is
    ///   not a plain array.
    public func removingProductDependency(
        productName: String,
        package: String,
        target: String
    ) throws -> ManifestEditor {
        let (targetCall, _) = try findTargetCall(named: target)
        guard let depsArg = Self.argument(labeled: "dependencies", in: targetCall) else {
            throw Error.productDependencyNotFound(
                productName: productName,
                target: target
            )
        }
        if Self.containsIfConfig(depsArg.expression) {
            throw Error.conditionalTargetDependencies(target: target)
        }
        guard let array = depsArg.expression.as(ArrayExprSyntax.self) else {
            throw Error.targetDependenciesNotArrayLiteral(target: target)
        }

        var targetIndex: Int? = nil
        for (i, element) in array.elements.enumerated() {
            if let (existingProduct, existingPackage) =
                Self.productNameAndPackage(from: element.expression),
               existingProduct == productName, existingPackage == package {
                targetIndex = i
                break
            }
        }

        guard let idx = targetIndex else {
            throw Error.productDependencyNotFound(
                productName: productName,
                target: target
            )
        }

        let newArray = Self.removing(elementAt: idx, from: array)
        let newTree = NodeReplacer(
            targetID: array.id,
            replacement: Syntax(newArray)
        ).rewrite(tree)
        guard let newSourceFile = newTree.as(SourceFileSyntax.self) else {
            throw Error.parseFailed("rewrite produced non-SourceFileSyntax")
        }
        return ManifestEditor(tree: newSourceFile)
    }
}
