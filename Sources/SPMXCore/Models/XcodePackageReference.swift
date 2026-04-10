/*
 *  File: XcodePackageReference.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// A direct Swift Package Manager dependency declared in an Xcode project file.
///
/// This is what `XcodeProjectReader` returns when it parses a `project.pbxproj`. We model
/// only what `spmx why` needs: the identity (so we can match against `Package.resolved`)
/// and the kind (so the checkout locator knows where to look for the manifest).
///
/// Identity is **always lowercased** to match how `Package.resolved` and `GraphBuilder`
/// represent identities. SPM derives identity from a URL by taking the last path component,
/// stripping `.git`, and lowercasing — `XcodePackageReference.identity(forRepositoryURL:)`
/// implements that rule so callers don't have to reinvent it.
public struct XcodePackageReference: Sendable, Equatable {
    public let identity: String
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        /// A remote package, equivalent to `XCRemoteSwiftPackageReference` in pbxproj.
        case remote(repositoryURL: String)
        /// A local-path package, equivalent to `XCLocalSwiftPackageReference` in pbxproj.
        case local(path: String)
    }

    public init(identity: String, kind: Kind) {
        self.identity = identity.lowercased()
        self.kind = kind
    }

    /// Mirror SPM's identity-from-URL rule: last path component, `.git` stripped, lowercased.
    ///
    /// Examples:
    ///   - `https://github.com/Alamofire/Alamofire.git` → `alamofire`
    ///   - `https://github.com/kishikawakatsumi/KeychainAccess` → `keychainaccess`
    ///   - `git@github.com:apple/swift-collections.git` → `swift-collections`
    ///
    /// This must match what SPM writes into `Package.resolved`. If SPM ever changes its
    /// identity-derivation rule (it has been stable since SwiftPM 5.5) we'll have to track
    /// the change here.
    public static func identity(forRepositoryURL url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Handle both `https://...` and `git@host:owner/repo.git` shapes by splitting on
        // the last `/` regardless of scheme. Foundation's URL parser is too strict for
        // SCP-style git URLs.
        let lastComponent = trimmed
            .split(separator: "/").last
            .map(String.init) ?? trimmed

        let withoutDotGit = lastComponent.hasSuffix(".git")
            ? String(lastComponent.dropLast(4))
            : lastComponent

        return withoutDotGit.lowercased()
    }

    /// Identity for a local-path dependency: the directory name, lowercased. We don't try
    /// to be clever about absolute vs. relative paths — the directory name is always the
    /// last path component, regardless.
    public static func identity(forLocalPath path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed
            .split(separator: "/").last
            .map(String.init) ?? trimmed
        return last.lowercased()
    }
}