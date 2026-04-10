/*
 *  File: XcodeCheckoutLocator.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Finds the on-disk source directory for an SPM package that was resolved by Xcode.
///
/// ## Why this exists
///
/// SwiftPM stores its checkouts at `.build/checkouts/<identity>/`, which `GraphBuilder`
/// already knows how to find. Xcode is different: when you open an `.xcodeproj` or
/// `.xcworkspace` and it resolves SPM dependencies, the source code lives inside that
/// project's DerivedData directory at:
///
/// ```
/// ~/Library/Developer/Xcode/DerivedData/<ProjectName>-<hash>/SourcePackages/checkouts/<identity>/
/// ```
///
/// The `<hash>` portion is opaque — it's a hash of the project path, not anything we
/// can compute from the project name alone. So to find the right DerivedData entry for
/// a project, we have to enumerate every directory in DerivedData, read its
/// `info.plist`, and look at the `WorkspacePath` key (an absolute path that points back
/// at the project or workspace it belongs to). The first one that matches our project
/// is the right DerivedData entry, and from there the checkout path is mechanical.
///
/// ## Fallbacks
///
/// We try DerivedData first, then two fallbacks for cases where DerivedData isn't
/// authoritative:
///
/// 1. **Workspace-local SourcePackages.** Some setups configure Xcode to put package
///    sources in `<workspace-dir>/SourcePackages/checkouts/<identity>/` instead of
///    DerivedData. We check for this after DerivedData fails.
///
/// 2. **`.swiftpm/checkouts`.** If someone has run `swift build` against the project
///    directly (e.g. from CI), SwiftPM may have populated this location even though
///    the project isn't a SwiftPM package itself. Last resort.
///
/// ## What we don't handle in v0.1
///
/// - **Custom DerivedData locations.** Xcode lets users move DerivedData via
///   Preferences → Locations → Derived Data. We read the Xcode preferences plist
///   (`com.apple.dt.Xcode.plist`) via `XcodePreferences` and use the custom path
///   when configured with an absolute location. The "relative to workspace" style
///   is handled implicitly by the workspace-local fallback below.
///
/// - **Multiple build configurations.** A project can have multiple DerivedData entries
///   if it was built under different build configurations or workspace contexts. We
///   pick the most recently modified, which is right in practice but is technically a
///   heuristic.
///
/// ## Caching
///
/// `checkoutDirectory` is called once per package in the graph walk, so we cache the
/// resolved DerivedData root per project on first lookup. The cache lives for the
/// lifetime of the locator instance.
public final class XcodeCheckoutLocator: @unchecked Sendable {
    private let derivedDataRoot: URL
    private let fm: FileManager

    /// Per-instance cache: project URL → resolved DerivedData entry, or `nil` if we
    /// looked and there isn't one. The `nil` result is also cached, so we don't
    /// re-enumerate DerivedData on repeated misses for the same project.
    ///
    /// Keyed by canonicalized path string to avoid `/var` vs `/private/var` collisions.
    private var derivedDataCache: [String: URL?] = [:]

    /// - Parameter derivedDataRoot: Override for tests. Defaults to the custom
    ///   DerivedData location from Xcode preferences (if configured), falling back
    ///   to `~/Library/Developer/Xcode/DerivedData`.
    public init(derivedDataRoot: URL? = nil) {
        self.fm = .default
        if let derivedDataRoot {
            self.derivedDataRoot = derivedDataRoot
        } else if let custom = XcodePreferences.customDerivedDataLocation() {
            self.derivedDataRoot = custom
        } else {
            let home = fm.homeDirectoryForCurrentUser
            self.derivedDataRoot = home
                .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        }
    }

    /// Find the source directory for a package, given the project that depends on it.
    ///
    /// ## Case-insensitive lookup
    ///
    /// SPM identities are lowercased per the identity rule (`KeychainAccess` →
    /// `keychainaccess`), but Xcode preserves the original repository case when it
    /// creates checkout directories (`SourcePackages/checkouts/KeychainAccess/`). A
    /// naive `appendingPathComponent(identity)` would look for `keychainaccess` and
    /// miss the actual `KeychainAccess` directory sitting right next to it.
    ///
    /// Verified behavior on macOS: APFS is case-insensitive by default, so on most
    /// users' machines `KeychainAccess` and `keychainaccess` would resolve to the same
    /// directory anyway. But Xcode creates checkouts on case-sensitive volumes too
    /// (CI machines, custom DerivedData on case-sensitive partitions), and we want
    /// `spmx why` to work everywhere — so we do an explicit case-insensitive directory
    /// listing match instead of trusting the filesystem.
    ///
    /// - Parameters:
    ///   - identity: SPM identity (lowercased, no `.git` suffix).
    ///   - projectURL: The `.xcodeproj` or `.xcworkspace` we're walking.
    /// - Returns: The directory containing `Package.swift` for that package, or `nil`
    ///   if we couldn't find it in any of our known locations.
    public func checkoutDirectory(for identity: String, projectURL: URL) -> URL? {
        // 1. DerivedData (the common case).
        if let derivedData = resolveDerivedData(for: projectURL) {
            let checkoutsDir = derivedData
                .appendingPathComponent("SourcePackages/checkouts")
            if let match = caseInsensitiveLookup(in: checkoutsDir, name: identity) {
                return match
            }
        }

        // 2. Workspace-local SourcePackages. If projectURL is a .xcworkspace, the parent
        // is the workspace dir; if it's a .xcodeproj, the parent is the project dir.
        let projectParent = projectURL.deletingLastPathComponent()
        let workspaceLocal = projectParent.appendingPathComponent("SourcePackages/checkouts")
        if let match = caseInsensitiveLookup(in: workspaceLocal, name: identity) {
            return match
        }

        // 3. .swiftpm/checkouts at the project parent.
        let swiftpmLocal = projectParent.appendingPathComponent(".swiftpm/checkouts")
        if let match = caseInsensitiveLookup(in: swiftpmLocal, name: identity) {
            return match
        }

        return nil
    }

    // MARK: - DerivedData resolution

    /// Find the DerivedData entry whose `info.plist > WorkspacePath` matches `projectURL`.
    ///
    /// Returns the most recently modified match if multiple entries match (rare but
    /// possible when the same project has been opened both standalone and inside a
    /// workspace). Returns `nil` if no match exists or DerivedData doesn't exist.
    private func resolveDerivedData(for projectURL: URL) -> URL? {
        let key = canonicalPath(projectURL)
        if let cached = derivedDataCache[key] {
            return cached
        }

        let resolved = enumerateDerivedData(matching: projectURL)
        derivedDataCache[key] = resolved
        return resolved
    }

    private func enumerateDerivedData(matching projectURL: URL) -> URL? {
        guard directoryExists(derivedDataRoot) else { return nil }

        let target = canonicalPath(projectURL)
        guard let entries = try? fm.contentsOfDirectory(
            at: derivedDataRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Collect all matching entries with their mtime, then pick the newest.
        var matches: [(URL, Date)] = []
        for entry in entries {
            // Skip non-directories. DerivedData usually only contains directories plus
            // some logs/cache files at the top level, but we're defensive.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let infoPlist = entry.appendingPathComponent("info.plist")
            guard let workspacePath = readWorkspacePath(at: infoPlist) else { continue }
            if canonicalPath(URL(fileURLWithPath: workspacePath)) == target {
                let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                matches.append((entry, mtime))
            }
        }

        // Newest match wins.
        return matches.max(by: { $0.1 < $1.1 })?.0
    }

    /// Read the `WorkspacePath` string from a DerivedData `info.plist`. Returns nil on
    /// any failure (missing file, parse error, missing key, wrong type) — all of these
    /// just mean "this isn't a match," not "we should crash."
    private func readWorkspacePath(at plistURL: URL) -> String? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }
        return plist["WorkspacePath"] as? String
    }

    // MARK: - Path helpers

    private func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// List `parent`'s contents and return the first child whose lowercased name matches
    /// `name` (which is assumed already lowercased — SPM identities always are).
    /// Returns nil if `parent` doesn't exist, can't be read, or has no matching child.
    ///
    /// We don't try to disambiguate between multiple case-variant matches (e.g. both
    /// `KeychainAccess` and `keychainaccess` somehow existing as siblings). On a
    /// case-insensitive filesystem that's impossible; on a case-sensitive one it would
    /// indicate a corrupt checkout. Returning the first listed child is fine — if
    /// someone hits this in practice, the bug report will tell us how to handle it.
    private func caseInsensitiveLookup(in parent: URL, name: String) -> URL? {
        guard directoryExists(parent) else { return nil }
        guard let children = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for child in children {
            if child.lastPathComponent.lowercased() == name {
                return child
            }
        }
        return nil
    }

    /// Canonicalize a URL to a stable string for equality comparisons. Resolves
    /// symlinks (for `/var` ↔ `/private/var`) and standardizes the path. The repeated
    /// lesson from `ResolvedParserTests`: never compare path strings on macOS without
    /// canonicalizing both sides at the comparison site.
    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}