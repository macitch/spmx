/*
 *  File: XcodeWorkspaceReader.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Reads the list of `.xcodeproj` references from an `.xcworkspace` bundle.
///
/// ## Why this exists
///
/// `XcodeProjectReader` handles a single `.xcodeproj`, but real Xcode setups often use a
/// workspace that contains multiple projects (CocoaPods is the canonical example, but
/// hand-built workspaces grouping a main app with helper tools are common too). When a
/// user runs `spmx why <X>` from a workspace, we need to walk every project inside the
/// workspace and merge their direct SPM dependencies before building the graph.
///
/// This reader does exactly one thing: given a `.xcworkspace`, return the list of
/// `.xcodeproj` URLs it references. The actual SPM dependency extraction is the
/// project reader's job; this layer is purely about workspace → project resolution.
///
/// ## Format
///
/// `.xcworkspace/contents.xcworkspacedata` is a small XML file:
///
/// ```xml
/// <?xml version="1.0" encoding="UTF-8"?>
/// <Workspace version="1.0">
///    <FileRef location="group:Path/To/SomeProject.xcodeproj"/>
///    <FileRef location="container:Other/AnotherProject.xcodeproj"/>
///    <Group location="container:SubGroup">
///       <FileRef location="group:Nested.xcodeproj"/>
///    </Group>
/// </Workspace>
/// ```
///
/// The `location` attribute uses a prefix to indicate how the path is resolved:
///
/// - `group:` — relative to the containing `<Group>`, or to the workspace if at top level
/// - `container:` — relative to the workspace's parent directory
/// - `absolute:` — an absolute filesystem path
/// - `self:` — the workspace itself (used in implicit workspaces inside `.xcodeproj`)
/// - `developer:` — relative to the developer dir (legacy, not seen in modern projects)
///
/// In practice the difference between `group:` and `container:` is semantic-only for our
/// purposes: both resolve relative to the workspace bundle's parent directory when used
/// at top level. We treat them identically. `self:` is filtered out (it points back at
/// the workspace, never at a project). `developer:` is ignored.
///
/// ## What we don't do
///
/// - We don't parse `<Group>` location prefixes for nested groups. Real-world workspaces
///   almost never use deep group nesting, and resolving a group hierarchy into a path
///   stack would add 80 lines of code for a case I have not seen in any project I've
///   inspected. If we hit a workspace where this matters, we'll add it then.
/// - We don't validate that the referenced `.xcodeproj` files exist. That's the caller's
///   responsibility — they may want to surface a clear error rather than silently
///   skipping missing projects.
public struct XcodeWorkspaceReader: Sendable {
    public init() {}

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible {
        case workspaceFileNotFound(URL)
        case parseFailed(underlying: String)
        case unexpectedStructure(String)

        public var description: String {
            switch self {
            case .workspaceFileNotFound(let url):
                return """
                No contents.xcworkspacedata found at \(url.path). \
                Make sure you're pointing at a valid .xcworkspace bundle (e.g. `MyApp.xcworkspace`), \
                not its parent directory.
                """
            case .parseFailed(let err):
                return """
                Failed to parse contents.xcworkspacedata: \(err). \
                The workspace file may be corrupted; try opening it in Xcode to repair. \
                If Xcode opens it without issue, please file a spmx bug at \
                https://github.com/macitch/spmx/issues.
                """
            case .unexpectedStructure(let detail):
                return """
                Unexpected workspace structure: \(detail). \
                spmx may not yet support this workspace's format. Please file an issue at \
                https://github.com/macitch/spmx/issues with your Xcode version.
                """
            }
        }

        public var errorDescription: String? { description }
    }

    /// Read all `.xcodeproj` references from an `.xcworkspace` bundle.
    ///
    /// - Parameter workspaceURL: URL pointing at an `.xcworkspace` directory (the bundle,
    ///   not the inner `contents.xcworkspacedata` file).
    /// - Returns: An array of resolved `.xcodeproj` URLs in the order they appear in the
    ///   workspace file. Order is preserved because Xcode treats the first project as
    ///   the "primary" in some contexts; tests can sort if they need stable output.
    public func read(_ workspaceURL: URL) throws -> [URL] {
        let contentsURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata")
        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            throw Error.workspaceFileNotFound(contentsURL)
        }

        let data = try Data(contentsOf: contentsURL)
        let locations = try parse(data: data)
        let workspaceParent = workspaceURL.deletingLastPathComponent()
        return locations.compactMap { resolve(location: $0, workspaceParent: workspaceParent) }
    }

    /// Parse raw `contents.xcworkspacedata` bytes and return the *unresolved* `location`
    /// strings (with their `group:` / `container:` / etc. prefixes intact). Exposed for
    /// tests so we can drive the parser without staging files on disk.
    public func parse(data: Data) throws -> [String] {
        let parser = XMLParser(data: data)
        let delegate = WorkspaceXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            let err = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw Error.parseFailed(underlying: err)
        }
        if let structuralError = delegate.structuralError {
            throw Error.unexpectedStructure(structuralError)
        }
        return delegate.locations
    }

    // MARK: - Internals

    /// Resolve a raw `location` attribute into an absolute file URL, or return nil if the
    /// location is one we deliberately ignore (`self:`, `developer:`, or anything that
    /// doesn't end in `.xcodeproj`).
    ///
    /// We only resolve top-level paths here. Nested `<Group location="...">` paths are
    /// not stitched into the prefix — see the type doc for the rationale.
    private func resolve(location: String, workspaceParent: URL) -> URL? {
        // Split prefix from path. Format is `<prefix>:<path>`.
        guard let colon = location.firstIndex(of: ":") else {
            return nil
        }
        let prefix = String(location[..<colon])
        let path = String(location[location.index(after: colon)...])

        // Only `.xcodeproj` references are interesting; the workspace may also list
        // `.playground` files, README markdown, etc.
        guard path.hasSuffix(".xcodeproj") else { return nil }

        switch prefix {
        case "group", "container":
            // Both resolve relative to the workspace's parent at top level.
            return workspaceParent.appendingPathComponent(path).standardizedFileURL
        case "absolute":
            return URL(fileURLWithPath: path).standardizedFileURL
        case "self", "developer":
            return nil
        default:
            // Unknown prefix — be conservative and skip.
            return nil
        }
    }
}

// MARK: - XMLParser delegate

/// Collects every `location` attribute from `<FileRef>` elements at any nesting depth.
/// We deliberately do NOT track group nesting — see the type doc on
/// `XcodeWorkspaceReader` for why.
private final class WorkspaceXMLDelegate: NSObject, XMLParserDelegate {
    var locations: [String] = []
    var structuralError: String?
    private var sawWorkspaceRoot = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "Workspace" {
            sawWorkspaceRoot = true
        }
        if elementName == "FileRef", let location = attributeDict["location"] {
            locations.append(location)
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if !sawWorkspaceRoot {
            structuralError = "no <Workspace> root element"
        }
    }
}