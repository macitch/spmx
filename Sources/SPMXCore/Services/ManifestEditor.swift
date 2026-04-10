/*
 *  File: ManifestEditor.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder

/// Structured, format-preserving editor for `Package.swift` manifests.
///
/// `ManifestEditor` is the foundation of `spmx add` and `spmx remove`. It parses a
/// Package.swift source file into a SwiftSyntax tree, exposes targeted mutation
/// operations (add/remove a top-level dependency, add/remove a target's product
/// dependency), and renders the tree back to source with every byte of whitespace,
/// comment, and formatting the editor didn't touch preserved exactly.
///
/// ## Why SwiftSyntax, not string manipulation
///
/// Package.swift is real Swift source. String-edit "hacks" that find `dependencies: [`
/// and shove a line in break the moment a user has any of: a comment containing that
/// substring, helper functions that return the dependencies array, conditional
/// compilation, unusual indentation, or a factored-out `let deps: ... = [...]` above
/// the `Package(...)` call. SwiftSyntax parses the file into an AST, we mutate the
/// specific nodes we care about, and the printer round-trips everything else byte-for-
/// byte. Any tool that edits Swift source and isn't built on SwiftSyntax is a time bomb.
///
/// ## Immutability
///
/// Editors are value-semantic. Each mutation method returns a *new* editor. This
/// matches SwiftSyntax's own model — syntax nodes are immutable value types and
/// rewrites produce new trees — and lets `add` chain a package-level add with a
/// target-level product-dependency add in a single expression.
///
/// ## Scope discipline
///
/// v0.1 deliberately refuses to edit manifests with shapes it cannot safely reason
/// about: helper functions returning dependencies, conditional `#if` guards around
/// deps, non-top-level `Package(...)` calls. When ManifestEditor can't be sure, it
/// throws a specific structural error rather than guessing and corrupting the file.
/// This is the right tradeoff — a tool that corrupts Package.swift on edge cases
/// loses user trust forever, and the right answer for those users is "edit by hand."
public struct ManifestEditor: @unchecked Sendable {
    // @unchecked because SwiftSyntax 600's SourceFileSyntax isn't marked
    // Sendable, but ManifestEditor is immutable (a single `let tree`) and the
    // SwiftSyntax tree itself is a persistent value-typed structure — no
    // observable mutation after init. Safe to cross actor boundaries.

    // MARK: - Errors

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        // File I/O.
        case fileNotFound(URL)
        case readFailed(path: String, underlying: String)
        case writeFailed(path: String, underlying: String)

        // Parse-level.
        case parseFailed(String)

        // Structural — manifest shape is too unusual to edit safely.
        /// No top-level `let package = Package(...)` call expression found.
        case noPackageInit
        /// Multiple top-level `let package = Package(...)` calls found (e.g. inside `#if`).
        case multiplePackageInits
        /// `dependencies:` argument is not an array literal (e.g. a helper function call).
        case dependenciesNotArrayLiteral
        /// `targets:` argument is not an array literal.
        case targetsNotArrayLiteral
        /// A specific target's `dependencies:` argument is not an array literal.
        case targetDependenciesNotArrayLiteral(target: String)
        /// User asked to edit a target that doesn't exist in the manifest.
        case targetNotFound(name: String, candidates: [String])

        // Conditional compilation — detected explicitly so we can give clear messages.
        /// The `dependencies:` argument contains `#if` conditional compilation blocks.
        case conditionalDependencies
        /// The `targets:` argument contains `#if` conditional compilation blocks.
        case conditionalTargets
        /// A specific target's `dependencies:` argument contains `#if` blocks.
        case conditionalTargetDependencies(target: String)

        // Operation-level.
        case duplicatePackage(identity: String)
        case packageNotFound(identity: String)
        case duplicateProductDependency(productName: String, target: String)
        case productDependencyNotFound(productName: String, target: String)

        public var description: String {
            switch self {
            case .fileNotFound(let url):
                return "Package.swift not found at \(url.path)."
            case .readFailed(let path, let err):
                return "Failed to read Package.swift at \(path): \(err)"
            case .writeFailed(let path, let err):
                return "Failed to write Package.swift at \(path): \(err)"
            case .parseFailed(let msg):
                return "Failed to parse Package.swift: \(msg)"
            case .noPackageInit:
                return """
                No top-level `let package = Package(...)` call found in Package.swift.
                spmx can only edit standard SwiftPM manifests.
                """
            case .multiplePackageInits:
                return """
                Multiple `let package = Package(...)` declarations found in Package.swift \
                (possibly inside #if conditional compilation blocks). spmx cannot determine \
                which Package(...) to edit. Edit Package.swift by hand.
                """
            case .dependenciesNotArrayLiteral:
                return """
                The `dependencies:` argument of Package(...) is not a plain array literal.
                spmx refuses to edit manifests that build their dependency list via helper
                functions, variables, or conditional compilation — the risk of corruption
                is too high. Edit Package.swift by hand.
                """
            case .targetsNotArrayLiteral:
                return """
                The `targets:` argument of Package(...) is not a plain array literal.
                spmx refuses to edit manifests that build their target list via helper
                functions or variables. Edit Package.swift by hand.
                """
            case .targetDependenciesNotArrayLiteral(let target):
                return """
                The `dependencies:` argument of target '\(target)' is not a plain array
                literal. spmx refuses to edit this target's dependencies. Edit Package.swift
                by hand.
                """
            case .targetNotFound(let name, let candidates):
                if candidates.isEmpty {
                    return "No target named '\(name)' in Package.swift."
                }
                let list = candidates.joined(separator: ", ")
                return "No target named '\(name)' in Package.swift. Found: \(list)."
            case .conditionalDependencies:
                return """
                Package.swift uses #if conditional compilation in its `dependencies:` array.
                spmx cannot safely edit manifests with conditional dependencies — it has no
                way to know which branch is active. Edit Package.swift by hand.
                """
            case .conditionalTargets:
                return """
                Package.swift uses #if conditional compilation in its `targets:` array.
                spmx cannot safely edit manifests with conditional targets — it has no
                way to know which branch is active. Edit Package.swift by hand.
                """
            case .conditionalTargetDependencies(let target):
                return """
                Target '\(target)' uses #if conditional compilation in its `dependencies:` \
                array. spmx cannot safely edit this target's dependencies. Edit Package.swift \
                by hand.
                """
            case .duplicatePackage(let identity):
                return "Package '\(identity)' is already a dependency."
            case .packageNotFound(let identity):
                return "Package '\(identity)' is not a dependency of this package."
            case .duplicateProductDependency(let product, let target):
                return "Target '\(target)' already depends on product '\(product)'."
            case .productDependencyNotFound(let product, let target):
                return "Target '\(target)' does not depend on product '\(product)'."
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - Version requirement

    /// How to pin a newly-added `.package(url:, ...)` entry. Mirrors the shapes SPM
    /// accepts. `AddCommand` decides which one to use based on the SPI metadata and
    /// any user-supplied `--from` / `--exact` / `--branch` flags.
    public enum VersionRequirement: Equatable, Sendable {
        case from(String)
        case upToNextMajor(String)
        case upToNextMinor(String)
        case exact(String)
        /// Half-open range `..<`.
        case range(lower: String, upper: String)
        /// Closed range `...`.
        case closedRange(lower: String, upper: String)
        case branch(String)
        case revision(String)
    }

    // MARK: - Removal result

    /// Result of `removingPackageCompletely`. Bundles the new editor with the list
    /// of target names whose `dependencies:` arrays were modified, so callers
    /// (RemoveCommand) can print a user-facing summary without re-scanning.
    public struct PackageRemoval: Sendable {
        /// The new editor with the package swept from top-level deps and all targets.
        public let editor: ManifestEditor
        /// Names of targets whose `dependencies:` arrays had `.product(package:)`
        /// references removed. Empty if the package was only at the top level.
        /// Order matches source order in `targets:`.
        public let affectedTargets: [String]
    }

    // MARK: - State

    private let tree: SourceFileSyntax

    private init(tree: SourceFileSyntax) {
        self.tree = tree
    }

    // MARK: - Loading

    /// Load and parse a Package.swift file from disk.
    public static func load(from url: URL) throws -> ManifestEditor {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw Error.readFailed(path: url.path, underlying: error.localizedDescription)
        }
        return try parse(source: source)
    }

    /// Parse a Package.swift from an in-memory source string. Useful for tests.
    public static func parse(source: String) throws -> ManifestEditor {
        let parsed = Parser.parse(source: source)
        // SwiftSyntax's parser always produces a SourceFileSyntax even on broken input;
        // it's the responsibility of downstream code to detect malformed manifests.
        // For v0.1 we rely on the structural checks in mutation methods to catch this.
        return ManifestEditor(tree: parsed)
    }

    // MARK: - Inspection

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

    // MARK: - SwiftSyntax helpers

    /// Locate the top-level `let package = Package(...)` call expression.
    ///
    /// Accepts only the canonical shape: a `let` or `var` binding named `package` whose
    /// initializer is a direct call to a `Package`-named identifier. Does *not* accept
    /// `.init(...)`, `PackageDescription.Package(...)`, factory functions that return a
    /// `Package`, or `Package(...)` calls nested inside helpers. If your manifest is
    /// that clever, you're asking spmx to do something it can't safely guarantee and
    /// we throw `.noPackageInit` on principle.
    private func findPackageCall() throws -> FunctionCallExprSyntax {
        var found: [FunctionCallExprSyntax] = []
        collectPackageCalls(from: tree.statements.map { $0.item }, into: &found)

        switch found.count {
        case 0:  throw Error.noPackageInit
        case 1:  return found[0]
        default: throw Error.multiplePackageInits
        }
    }

    /// Extract `Package(...)` calls from a sequence of code block items.
    ///
    /// This checks both direct `let package = Package(...)` variable
    /// declarations and `#if ... #endif` blocks at the top level. If the
    /// manifest wraps the entire `let package = ...` in conditional
    /// compilation, we recurse into every `#if`/`#elseif`/`#else` clause
    /// to find them all. Two or more hits → `.multiplePackageInits`.
    private func collectPackageCalls(
        from items: [CodeBlockItemSyntax.Item],
        into results: inout [FunctionCallExprSyntax]
    ) {
        for item in items {
            // Direct `let package = Package(...)`.
            if let varDecl = item.as(VariableDeclSyntax.self),
               let binding = varDecl.bindings.first,
               let identPattern = binding.pattern.as(IdentifierPatternSyntax.self),
               identPattern.identifier.text == "package",
               let initializer = binding.initializer,
               let call = initializer.value.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               callee.baseName.text == "Package" {
                results.append(call)
            }

            // `#if ... #elseif ... #else ... #endif` at top level.
            if let ifConfig = item.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if let elements = clause.elements?.as(CodeBlockItemListSyntax.self) {
                        collectPackageCalls(from: elements.map { $0.item }, into: &results)
                    }
                }
            }
        }
    }

    /// Find an argument by its label name in a call expression's argument list.
    /// Returns `nil` if not present.
    private static func argument(
        labeled name: String,
        in call: FunctionCallExprSyntax
    ) -> LabeledExprSyntax? {
        for arg in call.arguments {
            if arg.label?.text == name {
                return arg
            }
        }
        return nil
    }

    /// Extract the plain-text content of a string literal expression, returning `nil`
    /// if the literal is interpolated (`"\(foo)/bar"`) or not a string literal at all.
    /// We refuse to reason about interpolated strings because their runtime value is
    /// what SPM cares about, and we can't evaluate them statically.
    private static func plainStringLiteral(_ expr: ExprSyntax) -> String? {
        guard let literal = expr.as(StringLiteralExprSyntax.self) else { return nil }
        // A plain literal has exactly one segment of kind StringSegmentSyntax.
        guard literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self) else {
            return nil
        }
        return segment.content.text
    }

    // MARK: - Conditional compilation detection

    /// Returns `true` if any element inside `array` is an `#if` conditional
    /// compilation block (`IfConfigDeclSyntax`). These show up when a manifest
    /// has shapes like:
    ///
    /// ```swift
    /// dependencies: [
    ///     .package(url: "…", from: "1.0.0"),
    ///     #if os(macOS)
    ///     .package(url: "…", from: "2.0.0"),
    ///     #endif
    /// ]
    /// ```
    ///
    /// SwiftSyntax parses the `#if…#endif` as an `IfConfigDeclSyntax` child of the
    /// `CodeBlockItemSyntax` wrapping the array element. We walk each element's
    /// underlying syntax to detect this, because `ArrayElementSyntax.expression`
    /// won't expose it — the `#if` is at the statement level, not the expression
    /// level, so it appears among the array element's siblings in the raw tree.
    ///
    /// We also check whether the argument value itself is wrapped in an `#if` at
    /// the call-site level (the `IfConfigDeclSyntax` replaces the entire argument
    /// expression rather than living inside an array).
    /// Recursively walk a syntax node looking for any `IfConfigDeclSyntax`
    /// (`#if` / `#elseif` / `#else` / `#endif`). Returns true as soon as one
    /// is found.
    ///
    /// SwiftSyntax 600.x handles `#if` inside array literals by *breaking* the
    /// array representation — the expression is no longer an `ArrayExprSyntax`.
    /// So we must check the raw expression *before* attempting the
    /// `ArrayExprSyntax` cast. This walks the full subtree to cover both
    /// top-level and nested `#if` blocks.
    private static func containsIfConfig(_ node: Syntax) -> Bool {
        if node.as(IfConfigDeclSyntax.self) != nil {
            return true
        }
        for child in node.children(viewMode: .sourceAccurate) {
            if containsIfConfig(child) {
                return true
            }
        }
        return false
    }

    /// Convenience overload that accepts an `ExprSyntax`.
    private static func containsIfConfig(_ expr: ExprSyntax) -> Bool {
        containsIfConfig(Syntax(expr))
    }

    /// Shallow variant: only checks the *immediate* children of `node` for
    /// `IfConfigDeclSyntax`, without recursing into grandchildren.
    ///
    /// Use this for the `targets:` array check, where `#if` might legitimately
    /// exist inside a target's own `dependencies:` argument. A deep recursive
    /// check would incorrectly flag the entire targets array as conditional when
    /// only a nested target-dep array contains `#if`. The per-target check
    /// (which runs later in the iteration loop) handles the nested case.
    private static func containsShallowIfConfig(_ node: Syntax) -> Bool {
        for child in node.children(viewMode: .sourceAccurate) {
            if child.as(IfConfigDeclSyntax.self) != nil {
                return true
            }
        }
        return false
    }

    /// Convenience overload that accepts an `ExprSyntax`.
    private static func containsShallowIfConfig(_ expr: ExprSyntax) -> Bool {
        containsShallowIfConfig(Syntax(expr))
    }

    // MARK: - Array mutation helpers

    /// Append a new element to an array expression, preserving the existing layout.
    ///
    /// Layout strategy:
    /// - If the array already has elements, inherit the leading trivia of the last
    ///   element so the new entry lines up at the same indentation.
    /// - Ensure the previously-last element has a trailing comma (promoting its
    ///   comma-less state to comma-ful so the new element slots in cleanly).
    /// - The new element itself gets a trailing comma too.
    /// - If the array was empty, insert a single element with a trailing comma and
    ///   trust the caller's `[]` whitespace.
    private static func appending(
        elementSource: String,
        to array: ArrayExprSyntax
    ) -> ArrayExprSyntax {
        let newElementExpr = ExprSyntax("\(raw: elementSource)")

        if array.elements.isEmpty {
            let onlyElement = ArrayElementSyntax(
                expression: newElementExpr,
                trailingComma: .commaToken()
            )
            return array.with(\.elements, ArrayElementListSyntax([onlyElement]))
        }

        var mutableElements = Array(array.elements)
        let lastIndex = mutableElements.count - 1
        let lastElement = mutableElements[lastIndex]

        // Promote previously-last element to have a trailing comma if it didn't.
        let promotedLast = lastElement.with(\.trailingComma, .commaToken())
        mutableElements[lastIndex] = promotedLast

        // New element copies the leading trivia of the pre-last element for
        // matching indentation.
        let newElement = ArrayElementSyntax(
            leadingTrivia: lastElement.leadingTrivia,
            expression: newElementExpr,
            trailingComma: .commaToken()
        )
        mutableElements.append(newElement)

        return array.with(\.elements, ArrayElementListSyntax(mutableElements))
    }

    /// Remove the element at the given index from an array expression. Each
    /// `ArrayElementSyntax` owns its own leading trivia, so dropping an element
    /// drops its newline + indent; neighbors keep theirs intact.
    private static func removing(
        elementAt index: Int,
        from array: ArrayExprSyntax
    ) -> ArrayExprSyntax {
        var mutableElements = Array(array.elements)
        mutableElements.remove(at: index)
        return array.with(\.elements, ArrayElementListSyntax(mutableElements))
    }

    /// Remove the `.package(url:, ...)` element whose URL has the given SPM
    /// identity. Returns the original array unchanged if no such element exists
    /// (callers should pre-check presence; this is a helper for the atomic
    /// `removingPackageCompletely` flow which has already validated existence).
    private static func removingPackageElement(
        withIdentity identity: String,
        from array: ArrayExprSyntax
    ) -> ArrayExprSyntax {
        let filtered = array.elements.filter { element in
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "package",
                  let urlArg = Self.argument(labeled: "url", in: call),
                  let url = Self.plainStringLiteral(urlArg.expression) else {
                return true  // keep anything we can't parse
            }
            return XcodePackageReference.identity(forRepositoryURL: url) != identity
        }
        return array.with(\.elements, filtered)
    }

    /// Remove every `.product(name:X, package:Y)` element from a target's dependencies
    /// array whose `package:` label matches the given package name (case-insensitive).
    /// Non-product elements (string literals, `.target(...)`, `.byName(...)`) are
    /// left untouched. Used by `removingPackageCompletely` to sweep all references
    /// from a target in one batched filter pass.
    private static func removingProducts(
        matchingPackage package: String,
        from array: ArrayExprSyntax
    ) -> ArrayExprSyntax {
        let normalizedPkg = package.lowercased()
        let filtered = array.elements.filter { element in
            guard let (_, pkg) = Self.productNameAndPackage(from: element.expression) else {
                return true  // not a .product(...) — keep
            }
            return pkg.lowercased() != normalizedPkg
        }
        return array.with(\.elements, filtered)
    }

    /// Insert a `dependencies: [ <element> ]` argument into a Package(...) argument
    /// list that doesn't yet have one. Position: before `targets:` if it exists,
    /// otherwise at the end. This matches canonical Package(...) ordering.
    private static func insertingDependenciesArgument(
        into arguments: LabeledExprListSyntax,
        withElementSource elementSource: String
    ) -> LabeledExprListSyntax {
        let innerIndent: Trivia = .newline + .spaces(8)
        let arrayCloseIndent: Trivia = .newline + .spaces(4)

        let element = ArrayElementSyntax(
            leadingTrivia: innerIndent,
            expression: ExprSyntax("\(raw: elementSource)"),
            trailingComma: .commaToken()
        )
        let array = ArrayExprSyntax(
            leftSquare: .leftSquareToken(),
            elements: ArrayElementListSyntax([element]),
            rightSquare: .rightSquareToken(leadingTrivia: arrayCloseIndent)
        )

        var mutable = Array(arguments)
        var insertIndex = mutable.count
        for (i, arg) in mutable.enumerated() where arg.label?.text == "targets" {
            insertIndex = i
            break
        }

        let leadingTrivia: Trivia
        if insertIndex < mutable.count {
            leadingTrivia = mutable[insertIndex].leadingTrivia
        } else if let last = mutable.last {
            leadingTrivia = last.leadingTrivia
        } else {
            leadingTrivia = []
        }

        let newArg = LabeledExprSyntax(
            leadingTrivia: leadingTrivia,
            label: .identifier("dependencies"),
            colon: .colonToken(trailingTrivia: .space),
            expression: ExprSyntax(array),
            trailingComma: insertIndex < mutable.count ? .commaToken() : nil
        )

        // When appending at the end, promote the previous last arg to have a
        // trailing comma so the new arg slots in cleanly.
        if insertIndex == mutable.count, !mutable.isEmpty {
            let lastIdx = mutable.count - 1
            if mutable[lastIdx].trailingComma == nil {
                mutable[lastIdx] = mutable[lastIdx].with(\.trailingComma, .commaToken())
            }
        }

        mutable.insert(newArg, at: insertIndex)
        return LabeledExprListSyntax(mutable)
    }

    // MARK: - Requirement rendering

    /// Render a `.package(url:, <requirement>)` call as source text. String form
    /// because SwiftSyntax's builder DSL is verbose for this case and strings
    /// produce output that matches what a human would write.
    private static func renderPackageCall(
        url: String,
        requirement: VersionRequirement
    ) -> String {
        switch requirement {
        case .from(let v):
            return ".package(url: \"\(url)\", from: \"\(v)\")"
        case .upToNextMajor(let v):
            return ".package(url: \"\(url)\", .upToNextMajor(from: \"\(v)\"))"
        case .upToNextMinor(let v):
            return ".package(url: \"\(url)\", .upToNextMinor(from: \"\(v)\"))"
        case .exact(let v):
            return ".package(url: \"\(url)\", exact: \"\(v)\")"
        case .range(let lower, let upper):
            return ".package(url: \"\(url)\", \"\(lower)\"..<\"\(upper)\")"
        case .closedRange(let lower, let upper):
            return ".package(url: \"\(url)\", \"\(lower)\"...\"\(upper)\")"
        case .branch(let name):
            return ".package(url: \"\(url)\", branch: \"\(name)\")"
        case .revision(let sha):
            return ".package(url: \"\(url)\", revision: \"\(sha)\")"
        }
    }

    // MARK: - Mutation

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

    // MARK: - Target lookup helpers

    /// Locate a target by name in the Package's `targets:` array. Returns the
    /// `FunctionCallExprSyntax` for the `.target(name: "X")` / `.executableTarget(...)`
    /// / etc. call, plus the candidate names found (for error reporting).
    ///
    /// - Throws: `.targetsNotArrayLiteral` if targets: is non-literal,
    ///   `.targetNotFound` with the list of candidates if no target matches.
    private func findTargetCall(
        named targetName: String
    ) throws -> (call: FunctionCallExprSyntax, candidates: [String]) {
        let packageCall = try findPackageCall()
        guard let targetsArg = Self.argument(labeled: "targets", in: packageCall) else {
            throw Error.targetNotFound(name: targetName, candidates: [])
        }
        if Self.containsShallowIfConfig(targetsArg.expression) {
            throw Error.conditionalTargets
        }
        guard let array = targetsArg.expression.as(ArrayExprSyntax.self) else {
            throw Error.targetsNotArrayLiteral
        }

        var candidates: [String] = []
        for element in array.elements {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
                continue
            }
            // Accept any target kind: target, executableTarget, testTarget,
            // macro, plugin, systemLibrary, binaryTarget. The caller decides
            // whether touching a testTarget is sensible.
            _ = member.declName.baseName.text
            guard let nameArg = Self.argument(labeled: "name", in: call),
                  let name = Self.plainStringLiteral(nameArg.expression) else {
                continue
            }
            candidates.append(name)
            if name == targetName {
                return (call, candidates)
            }
        }
        throw Error.targetNotFound(name: targetName, candidates: candidates)
    }

    /// Extract `(productName, package)` from a `.product(name: "X", package: "Y")`
    /// expression. Returns nil for any other element shape (string literal,
    /// `.target(...)`, `.byName(...)`, etc.).
    private static func productNameAndPackage(
        from expr: ExprSyntax
    ) -> (product: String, package: String)? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "product",
              let nameArg = Self.argument(labeled: "name", in: call),
              let packageArg = Self.argument(labeled: "package", in: call),
              let name = Self.plainStringLiteral(nameArg.expression),
              let pkg = Self.plainStringLiteral(packageArg.expression) else {
            return nil
        }
        return (name, pkg)
    }

    /// Insert a `dependencies: [ <element> ]` argument into a target call that
    /// doesn't yet have one. Mirrors `insertingDependenciesArgument` but scoped to
    /// target calls — position goes right after the `name:` argument, which is
    /// where target deps canonically live.
    private static func insertingTargetDependenciesArgument(
        into arguments: LabeledExprListSyntax,
        withElementSource elementSource: String
    ) -> LabeledExprListSyntax {
        let innerIndent: Trivia = .newline + .spaces(16)
        let arrayCloseIndent: Trivia = .newline + .spaces(12)

        let element = ArrayElementSyntax(
            leadingTrivia: innerIndent,
            expression: ExprSyntax("\(raw: elementSource)"),
            trailingComma: .commaToken()
        )
        let array = ArrayExprSyntax(
            leftSquare: .leftSquareToken(),
            elements: ArrayElementListSyntax([element]),
            rightSquare: .rightSquareToken(leadingTrivia: arrayCloseIndent)
        )

        var mutable = Array(arguments)

        // Insert right after `name:`. If `name:` doesn't exist (weird), insert at
        // position 0.
        var insertIndex = 0
        for (i, arg) in mutable.enumerated() where arg.label?.text == "name" {
            insertIndex = i + 1
            break
        }

        // Derive leading trivia from an existing arg at or around insertIndex.
        let leadingTrivia: Trivia
        if insertIndex < mutable.count {
            leadingTrivia = mutable[insertIndex].leadingTrivia
        } else if let last = mutable.last {
            leadingTrivia = last.leadingTrivia
        } else {
            leadingTrivia = .newline + .spaces(12)
        }

        let newArg = LabeledExprSyntax(
            leadingTrivia: leadingTrivia,
            label: .identifier("dependencies"),
            colon: .colonToken(trailingTrivia: .space),
            expression: ExprSyntax(array),
            trailingComma: insertIndex < mutable.count ? .commaToken() : nil
        )

        // Promote previous arg to have a trailing comma if we're appending.
        if insertIndex == mutable.count, !mutable.isEmpty {
            let lastIdx = mutable.count - 1
            if mutable[lastIdx].trailingComma == nil {
                mutable[lastIdx] = mutable[lastIdx].with(\.trailingComma, .commaToken())
            }
        } else if insertIndex > 0 {
            // Inserting in the middle — ensure the arg we're inserting after has a
            // trailing comma (it may or may not).
            let prevIdx = insertIndex - 1
            if mutable[prevIdx].trailingComma == nil {
                mutable[prevIdx] = mutable[prevIdx].with(\.trailingComma, .commaToken())
            }
        }

        mutable.insert(newArg, at: insertIndex)
        return LabeledExprListSyntax(mutable)
    }

    // MARK: - Serialization

    /// Render the current tree back to source. Formatting, comments, and whitespace
    /// are preserved exactly for any region the editor didn't touch.
    public func serialize() -> String {
        tree.description
    }

    /// Write the current tree back to disk. Convenience wrapper over `serialize()`.
    public func write(to url: URL) throws {
        let source = serialize()
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Error.writeFailed(path: url.path, underlying: error.localizedDescription)
        }
    }
}

// MARK: - NodeReplacer

/// SyntaxRewriter that replaces exactly one node, identified by its
/// `SyntaxIdentifier`, with a replacement node. This is the cleanest pattern for
/// targeted mutations in SwiftSyntax — the alternative is a cascade of
/// `with(\.foo, ...)` calls up the spine of the tree, which is tedious and fragile.
///
/// Only ArrayExprSyntax and FunctionCallExprSyntax cases are overridden because
/// those are the only node types ManifestEditor ever swaps. If the editor grows
/// to replace other node kinds later, add the corresponding visit override here.
private final class NodeReplacer: SyntaxRewriter {
    let targetID: SyntaxIdentifier
    let replacement: Syntax

    init(targetID: SyntaxIdentifier, replacement: Syntax) {
        self.targetID = targetID
        self.replacement = replacement
        super.init()
    }

    override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {
        if node.id == targetID, let expr = replacement.as(ExprSyntax.self) {
            return expr
        }
        return super.visit(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        if node.id == targetID, let expr = replacement.as(ExprSyntax.self) {
            return expr
        }
        return super.visit(node)
    }
}

// MARK: - BatchNodeReplacer

/// SyntaxRewriter that performs multiple ArrayExprSyntax replacements in a single
/// traversal, keyed on `SyntaxIdentifier`. This is the backbone of atomic multi-
/// node operations like `removingPackageCompletely`, which needs to rewrite the
/// top-level `dependencies:` array AND every affected target's `dependencies:`
/// array without ever leaving the tree in a half-mutated state.
///
/// Why a batch replacer instead of chaining single-node replacements: after each
/// single-node rewrite, the resulting tree has fresh `SyntaxIdentifier`s, so IDs
/// captured against the original tree become stale. Computing all the
/// replacements against the original (whose IDs are still valid) and then doing
/// one pass is both cleaner and O(n) instead of O(n × operations).
private final class BatchNodeReplacer: SyntaxRewriter {
    let replacements: [SyntaxIdentifier: Syntax]

    init(replacements: [SyntaxIdentifier: Syntax]) {
        self.replacements = replacements
        super.init()
    }

    override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {
        if let rep = replacements[node.id], let expr = rep.as(ExprSyntax.self) {
            return expr
        }
        return super.visit(node)
    }
}