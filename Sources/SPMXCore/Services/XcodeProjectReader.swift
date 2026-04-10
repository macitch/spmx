/*
 *  File: XcodeProjectReader.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Reads `XCRemoteSwiftPackageReference` and `XCLocalSwiftPackageReference` entries from
/// an Xcode `project.pbxproj`.
///
/// ## Why this exists
///
/// `Package.resolved` tells us which packages are *pinned* in an Xcode project, but not
/// which of those are *direct* dependencies declared by the user vs. transitive ones
/// pulled in by other packages. For `spmx why <X>` to walk back from a transitive dep to
/// a direct dep, we need the set of direct deps as a starting point — and that lives
/// only in the pbxproj.
///
/// ## Format
///
/// `project.pbxproj` is a NeXTSTEP-style ASCII property list (the "openStep" format).
/// Foundation's `PropertyListSerialization` parses it natively, so we don't need a
/// third-party pbxproj parser. The file's top-level structure is:
///
/// ```
/// {
///   archiveVersion = 1;
///   classes = {};
///   objectVersion = 77;
///   objects = {
///     A7B3C3722D2B5384007064A1 = {
///       isa = XCRemoteSwiftPackageReference;
///       repositoryURL = "https://github.com/foo/bar";
///       requirement = { ... };
///     };
///     ...
///   };
///   rootObject = ABC123 /* Project object */;
/// }
/// ```
///
/// We walk every value in `objects`, filter to those whose `isa` is one of the SPM
/// reference types, and pull out the URL or path. Order doesn't matter — the resulting
/// set is deduplicated by identity at the call site.
///
/// ## What we ignore
///
/// - `requirement` (version constraints) — `Package.resolved` already has the resolved version
/// - `productName` from `XCSwiftPackageProductDependency` — we work at the package level, not product level
/// - Every other pbxproj object type — we only need package references
public struct XcodeProjectReader: Sendable {
    public init() {}

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible {
        case projectFileNotFound(URL)
        case parseFailed(underlying: String)
        case unexpectedStructure(String)

        public var description: String {
            switch self {
            case .projectFileNotFound(let url):
                return "No project.pbxproj found at \(url.path)"
            case .parseFailed(let err):
                return "Failed to parse project.pbxproj: \(err)"
            case .unexpectedStructure(let detail):
                return "Unexpected pbxproj structure: \(detail)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// Read all direct SPM dependencies from an `.xcodeproj` bundle.
    ///
    /// - Parameter projectURL: URL pointing at an `.xcodeproj` directory (the bundle, not
    ///   the inner `project.pbxproj` file). The reader appends `project.pbxproj` itself.
    /// - Returns: A deduplicated array of `XcodePackageReference` values, sorted by
    ///   identity for stable test output.
    public func read(_ projectURL: URL) throws -> [XcodePackageReference] {
        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")
        guard FileManager.default.fileExists(atPath: pbxprojURL.path) else {
            throw Error.projectFileNotFound(pbxprojURL)
        }

        let data = try Data(contentsOf: pbxprojURL)
        return try parse(data: data)
    }

    /// Parse raw pbxproj bytes. Exposed for tests so we can drive the parser without
    /// staging files on disk.
    public func parse(data: Data) throws -> [XcodePackageReference] {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw Error.parseFailed(underlying: error.localizedDescription)
        }

        guard let root = plist as? [String: Any] else {
            throw Error.unexpectedStructure("top level is not a dictionary")
        }
        guard let objects = root["objects"] as? [String: Any] else {
            throw Error.unexpectedStructure("missing 'objects' dictionary")
        }

        // Walk every object. We don't care about the keys (object IDs); we filter by isa.
        var seen: Set<String> = []
        var refs: [XcodePackageReference] = []

        for (_, value) in objects {
            guard let entry = value as? [String: Any] else { continue }
            guard let isa = entry["isa"] as? String else { continue }

            let ref: XcodePackageReference?
            switch isa {
            case "XCRemoteSwiftPackageReference":
                ref = parseRemote(entry)
            case "XCLocalSwiftPackageReference":
                ref = parseLocal(entry)
            default:
                ref = nil
            }
            guard let ref else { continue }
            // Dedupe by identity. Two refs with the same identity from different URLs is
            // a project misconfiguration; we keep the first and silently drop subsequent.
            if seen.insert(ref.identity).inserted {
                refs.append(ref)
            }
        }

        return refs.sorted { $0.identity < $1.identity }
    }

    // MARK: - Internals

    private func parseRemote(_ entry: [String: Any]) -> XcodePackageReference? {
        guard let url = entry["repositoryURL"] as? String, !url.isEmpty else {
            return nil
        }
        let identity = XcodePackageReference.identity(forRepositoryURL: url)
        return XcodePackageReference(identity: identity, kind: .remote(repositoryURL: url))
    }

    private func parseLocal(_ entry: [String: Any]) -> XcodePackageReference? {
        // XCLocalSwiftPackageReference uses `relativePath` (string).
        guard let path = entry["relativePath"] as? String, !path.isEmpty else {
            return nil
        }
        let identity = XcodePackageReference.identity(forLocalPath: path)
        return XcodePackageReference(identity: identity, kind: .local(path: path))
    }
}