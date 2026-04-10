/*
 *  File: ProjectDetector.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Determines whether a user-supplied path points at a SwiftPM package or an Xcode project.
///
/// Extracted from `WhyRunner` so both `spmx why` and `spmx outdated` can share the same
/// auto-detection logic. The detection priority (Package.swift > .xcworkspace > .xcodeproj)
/// and all error handling are identical regardless of the calling command.
public struct ProjectDetector: Sendable {

    /// What kind of root the detector resolved the path to.
    public enum DetectedRoot: Equatable {
        case swiftpm(rootDirectory: URL)
        case xcode(projectURL: URL)
    }

    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible, Equatable {
        case pathDoesNotExist(path: String)
        case noProjectOrPackage(directory: String)
        case ambiguousXcodeProject(directory: String, candidates: [String])

        public var description: String {
            switch self {
            case .pathDoesNotExist(let path):
                return """
                Path does not exist: \(path)

                Check the spelling of --path, or cd into the project directory and run
                the command without --path.
                """
            case .noProjectOrPackage(let dir):
                return """
                No SwiftPM package or Xcode project found in \(dir).

                Pass --path to point at a directory that contains a Package.swift,
                .xcworkspace, or .xcodeproj.
                """
            case .ambiguousXcodeProject(let dir, let candidates):
                let list = candidates.joined(separator: ", ")
                return """
                Multiple Xcode projects in \(dir): \(list).
                Pass --path to choose one, e.g. `--path \(candidates[0])`.
                """
            }
        }

        public var errorDescription: String? { description }
    }

    public init() {}

    /// Detect the project type at `path`.
    ///
    /// Priority order when auto-discovering from a directory:
    /// 1. `Package.swift` at the root → SwiftPM
    /// 2. A single `.xcworkspace` in the directory → Xcode (workspace)
    /// 3. A single `.xcodeproj` in the directory → Xcode (project)
    ///
    /// Workspaces win over projects because in a typical app layout where both exist,
    /// the workspace is the superset.
    public func detect(path: URL) throws -> DetectedRoot {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path.path) else {
            throw Error.pathDoesNotExist(path: path.path)
        }

        // If the user pointed directly at a bundle, short-circuit.
        switch path.pathExtension {
        case "xcodeproj", "xcworkspace":
            return .xcode(projectURL: path)
        default:
            break
        }

        // Treat as a directory and inspect its immediate children.
        let packageSwift = path.appendingPathComponent("Package.swift")
        if fm.fileExists(atPath: packageSwift.path) {
            return .swiftpm(rootDirectory: path)
        }

        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw Error.noProjectOrPackage(directory: path.path)
        }

        let workspaces = children
            .filter { $0.pathExtension == "xcworkspace" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if workspaces.count == 1 {
            return .xcode(projectURL: workspaces[0])
        }
        if workspaces.count > 1 {
            throw Error.ambiguousXcodeProject(
                directory: path.path,
                candidates: workspaces.map(\.lastPathComponent)
            )
        }

        let projects = children
            .filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if projects.count == 1 {
            return .xcode(projectURL: projects[0])
        }
        if projects.count > 1 {
            throw Error.ambiguousXcodeProject(
                directory: path.path,
                candidates: projects.map(\.lastPathComponent)
            )
        }

        throw Error.noProjectOrPackage(directory: path.path)
    }
}