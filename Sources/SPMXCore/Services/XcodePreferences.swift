/*
 *  File: XcodePreferences.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// Reads Xcode's preferences plist (`com.apple.dt.Xcode.plist`) to discover user-configured
/// paths. The only value we read today is the custom DerivedData location.
///
/// ## Why
///
/// Xcode lets users move DerivedData via Preferences → Locations → Derived Data. When this
/// is set, the plist contains a `IDECustomDerivedDataLocation` key with the absolute path.
/// Without reading this, `XcodeCheckoutLocator` silently fails to find checkouts for users
/// who have relocated DerivedData — a v0.1 limitation documented in `ROADMAP.md`.
///
/// ## How Xcode stores the setting
///
/// - **Default location** (`~/Library/Developer/Xcode/DerivedData`): No key in the plist,
///   or `IDEDerivedDataLocationStyle` is `0`.
/// - **Relative to workspace**: `IDEDerivedDataLocationStyle` is `1`, and
///   `IDECustomDerivedDataLocation` contains a relative path. This is applied per-workspace
///   at open time and doesn't help us globally — we fall back to the workspace-local
///   SourcePackages check that `XcodeCheckoutLocator` already does.
/// - **Custom absolute path**: `IDEDerivedDataLocationStyle` is `2`, and
///   `IDECustomDerivedDataLocation` contains the absolute path.
///
/// We only act on style `2` (absolute). Style `1` (relative) is handled implicitly by the
/// workspace-local fallback in `XcodeCheckoutLocator.checkoutDirectory`.
public enum XcodePreferences {

    /// Returns the custom DerivedData directory if Xcode is configured with an absolute
    /// custom path. Returns `nil` if the default location is in use, if the plist can't be
    /// read, or if the style is "relative to workspace" (handled elsewhere).
    public static func customDerivedDataLocation(
        preferencesURL: URL? = nil
    ) -> URL? {
        let url = preferencesURL ?? defaultPreferencesURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }

        // Style 0 = default, 1 = relative to workspace, 2 = absolute custom.
        let style = plist["IDEDerivedDataLocationStyle"] as? Int ?? 0
        guard style == 2 else { return nil }

        guard let custom = plist["IDECustomDerivedDataLocation"] as? String,
              !custom.isEmpty else {
            return nil
        }

        let url2 = URL(fileURLWithPath: custom)
        // Sanity check: if the path doesn't exist, don't return it — we'd just fail
        // later during enumeration and the default fallback is more likely to work.
        guard FileManager.default.fileExists(atPath: url2.path) else { return nil }
        return url2
    }

    private static func defaultPreferencesURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Preferences/com.apple.dt.Xcode.plist"
        )
    }
}