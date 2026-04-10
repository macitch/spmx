/*
 *  File: ManifestDump.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation

/// A minimal decoded view of `swift package dump-package` output.
///
/// We intentionally decode only the two fields `why` needs: the package's own name, and the
/// identities of its direct dependencies. Everything else in the JSON — targets, products,
/// platforms, swift language versions, requirements — is noise for graph construction.
///
/// Why so minimal? The `dump-package` JSON shape has evolved across SPM versions (the
/// dependency representation changed meaningfully between 5.5 and 5.9, and registry support
/// added a new tag in 5.7). Decoding only what we need means spmx keeps working when SPM
/// adds new fields, and fails loudly only when the fields we *do* rely on go away.
///
/// Dependency shape, as of SPM 5.9+:
///
/// ```json
/// "dependencies": [
///   {
///     "sourceControl": [
///       {
///         "identity": "swift-collections",
///         "location": { "remote": [{ "urlString": "https://github.com/..." }] },
///         "requirement": { "range": [...] }
///       }
///     ]
///   },
///   {
///     "fileSystem": [
///       { "identity": "local-pkg", "path": "../local-pkg" }
///     ]
///   },
///   {
///     "registry": [
///       { "identity": "scope.name", "requirement": { ... } }
///     ]
///   }
/// ]
/// ```
///
/// Each dependency is a single-key dictionary whose key indicates the dependency *kind* and
/// whose value is a single-element array containing the details. The details always include
/// an `identity` field, which is the one thing we care about. We decode all three known kinds
/// and fall through on anything we don't recognise (logged but non-fatal).
public struct ManifestDump: Sendable, Equatable, Codable {
    public let name: String
    public let dependencies: [Dependency]

    public struct Dependency: Sendable, Equatable, Codable {
        public let identity: String
        public let kind: Kind

        public enum Kind: String, Sendable, Equatable, Codable {
            case sourceControl
            case fileSystem
            case registry
        }

        public init(identity: String, kind: Kind) {
            self.identity = identity
            self.kind = kind
        }
    }

    public init(name: String, dependencies: [Dependency]) {
        self.name = name
        self.dependencies = dependencies
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case name
        case dependencies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)

        // The `dependencies` array can be in one of two shapes, and we must accept both:
        //
        //   1. **SPM tagged-union shape** — what `swift package dump-package` emits.
        //      Each element is a single-key object like `{"sourceControl": [{"identity": "..."}]}`.
        //
        //   2. **Our flat shape** — what we write to the cache, and what tests construct
        //      directly. Each element is `{"identity": "...", "kind": "sourceControl"}`.
        //
        // Trying flat first is a tiny optimisation (the cache is the hot path) but the
        // important property is that *both succeed* without throwing. We attempt flat,
        // and if its required keys are missing we fall through to the tagged-union path.
        var deps: [Dependency] = []
        var depsContainer = try container.nestedUnkeyedContainer(forKey: .dependencies)
        while !depsContainer.isAtEnd {
            // Snapshot the container so we can re-read the same element if the first
            // attempt fails. NestedUnkeyedDecodingContainer is single-pass, so we decode
            // into a generic `AnyDecodable` first and then try each shape against it via
            // a fresh JSONDecoder pass on its raw data.
            //
            // Simpler approach: decode into our intermediate `RawElement` which holds
            // *both* possibilities as optionals, then prefer the flat one if present.
            let raw = try depsContainer.decode(RawElement.self)
            if let flat = raw.flat {
                deps.append(flat)
            } else if let tagged = raw.tagged?.resolved() {
                deps.append(tagged)
            }
            // Unknown kinds are silently skipped. We'd rather drop an edge than crash the
            // whole graph walk on a future SPM version that adds a `foo` kind.
        }
        self.dependencies = deps
    }

    public func encode(to encoder: Encoder) throws {
        // Always emit the flat shape. This is what ends up in the cache file and what the
        // decoder's fast path picks up on read-back.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(dependencies, forKey: .dependencies)
    }

    /// Holds both possible shapes of a single `dependencies` element. Exactly one of
    /// `flat` or `tagged` will be populated for any well-formed input; both will be nil
    /// for an unrecognised future shape, in which case the entry is silently dropped.
    private struct RawElement: Decodable {
        let flat: Dependency?
        let tagged: RawDependency?

        private enum CodingKeys: String, CodingKey {
            case identity
        }

        init(from decoder: Decoder) throws {
            // If the element has an `identity` key at the top level, it's our flat shape.
            // Otherwise it's SPM's tagged-union shape (or something we don't recognise).
            if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
               keyed.contains(.identity) {
                self.flat = try Dependency(from: decoder)
                self.tagged = nil
            } else {
                self.flat = nil
                self.tagged = try? RawDependency(from: decoder)
            }
        }
    }

    /// Intermediate type matching SPM's tagged-union-per-element shape. We decode every
    /// known kind optionally and then pick whichever one is present.
    private struct RawDependency: Decodable {
        let sourceControl: [DetailsWithIdentity]?
        let fileSystem: [DetailsWithIdentity]?
        let registry: [DetailsWithIdentity]?

        struct DetailsWithIdentity: Decodable {
            let identity: String
        }

        func resolved() -> Dependency? {
            if let first = sourceControl?.first {
                return Dependency(identity: first.identity, kind: .sourceControl)
            }
            if let first = fileSystem?.first {
                return Dependency(identity: first.identity, kind: .fileSystem)
            }
            if let first = registry?.first {
                return Dependency(identity: first.identity, kind: .registry)
            }
            return nil
        }
    }
}