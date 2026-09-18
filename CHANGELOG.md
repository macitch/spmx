# Changelog

All notable changes to [`spmx`](https://github.com/macitch/spmx) are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

## [0.2.0] — 2026-09-18

### Fixed

- Drain subprocess stdout and stderr during execution to prevent pipe-buffer deadlocks; use termination callbacks for asynchronous completion.
- Wire added products with the repository identity, including packages whose manifest name differs from the repository name.
- Discover products at the requested tag, branch, or revision. Version ranges select the newest matching tag, including `v`-prefixed tags.
- Remove product references using explicit package aliases as well as repository identities.
- Follow local dependency paths through SwiftPM and Xcode graphs, report missing local manifests, and support local-only graphs without a lockfile. Refresh older manifest caches that omitted local paths.
- Preserve resolution and rollback failure details in both `add` and `remove` errors.
- Honor subprocess cancellation and stop scheduling version lookups after cancellation.
- Remove local `.package(path:)` dependencies consistently with dependency inspection.
- Synchronize Xcode checkout-cache access for concurrent lookups.

### Changed

- **Breaking (SPMXCore):** `AddRunner`'s injected `fetchMetadata` closure now receives the version requirement as its second argument: `(url, requirement)`. Update custom closures to accept both arguments. CLI flags are unchanged.
- Correct README and CLI help descriptions of native SwiftPM commands, supported flags, JSON filtering, exit statuses, graph limits, and manifest rollback behavior. Make source installation independent of SwiftPM's build-directory layout.

## [0.1.1] — 2026-04-16

### Changed
- Internal refactor: split `ManifestEditor.swift` (1,368 LOC) into focused extension files — `ManifestEditor+Inspection.swift`, `ManifestEditor+Add.swift`, `ManifestEditor+Remove.swift`. Main file reduced 43%. No public API or behavior change; all 360 tests still pass.

## [0.1.0] — 2026-04-10

### Added
- `spmx add <package>` — name resolution via SPI catalog, version auto-detection, product/target auto-pick, SwiftSyntax AST-preserving manifest editing, interactive picker for ambiguous names, `--dry-run`, `--url`, `--from`, `--exact`, `--branch`, `--revision`, `--product`, `--target`, `--no-resolve`
- `spmx remove <package>` — atomic removal from top-level deps and all target product references, identity normalization (URL/SSH/bare name), `--dry-run`, `--no-resolve`
- `spmx outdated` — concurrent `git ls-remote` for latest tags, ANSI table with color, TTY-aware progress indicator, `--json`, `--all`, `--direct`, `--exit-code`, `--ignore`, `--refresh`, `NO_COLOR` support
- `spmx why <package>` — full dependency graph walk, BFS path-finding, Xcode project support (.xcodeproj/.xcworkspace), partial-graph warnings, Levenshtein did-you-mean, `--json`, `--exit-code`
- `spmx search <term>` — search the SPI catalog, `--json`, `--limit`
- `spmx completions <shell>` — bash, zsh, and fish shell completions
- `Package.resolved` parser supporting v2 and v3 formats
- `Semver` value type with full semver.org ordering and `Drift` classifier
- SwiftSyntax 600.x manifest editor — AST-preserving edits, no `swift package dump-package`
- `ProjectDetector` for SwiftPM / Xcode auto-discovery
- Custom DerivedData location support via `XcodePreferences`
- Conditional compilation detection (`#if` around dependency/target arrays)
- Multiple `Package(...)` call detection (refuses cleanly)
- `git ls-remote` caching — SHA-256 keyed, 5-minute TTL, `--refresh` to bypass
- Network timeouts — 30s default per subprocess, 15s/30s on URLSession
- Revert on resolve failure — `add`/`remove` back up manifest, run `swift package resolve`, restore on failure
- Git-on-PATH pre-flight check with clear error message
- 360 tests across 51 suites
- CI via GitHub Actions (macOS 14, Xcode 16)
