# Changelog

All notable changes to [`spmx`](https://github.com/macitch/spmx) are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

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
