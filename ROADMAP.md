# spmx Roadmap

> The commands Swift Package Manager forgot to ship.

Five commands: `add`, `remove`, `outdated`, `why`, `search`. Each version makes them more reliable, not wider.

---

## v0.1 — First Release

**Theme:** Ship it. Everything works, edge cases handled, distribution ready.

**Commands:**
- `spmx add <package>` — name resolution via SPI catalog, version auto-detection, product/target auto-pick, SwiftSyntax AST-preserving manifest editing, `--dry-run`, `--url`, `--from`, `--exact`, `--branch`, `--revision`, `--product`, `--target`, `--no-resolve`
- `spmx remove <package>` — atomic removal from top-level deps + all target product references, identity normalization (URL/SSH/bare name), `--dry-run`, `--no-resolve`, Xcode project detection
- `spmx outdated` — parses Package.resolved, concurrent `git ls-remote` for latest tags, table rendering with ANSI color, `--json`, `--all`, `--direct`, `--exit-code`, `--ignore`, `--refresh`, `NO_COLOR` support, TTY-aware progress indicator
- `spmx why <package>` — full dependency graph walk, BFS path-finding, Xcode project support (.xcodeproj/.xcworkspace), partial-graph warnings, Levenshtein did-you-mean, `--json`, `--exit-code`
- `spmx search <term>` — search the SPI catalog by name/keyword, show matching packages with URL, latest version, product count, `--json`

**Infrastructure:**
- Swift 6 strict concurrency throughout
- SwiftSyntax 600.x for manifest editing (no `swift package dump-package` — it hangs on packages with macros)
- Shared `ProjectDetector` for SwiftPM / Xcode auto-discovery
- `ManifestEditor.listDependencyIdentities()` handles both `.package(url:)` and `.package(path:)` dependencies
- Custom DerivedData location support via `XcodePreferences`
- Levenshtein fuzzy matching for did-you-mean suggestions
- `add` shows a numbered picker when the search term is ambiguous (error in non-interactive/CI mode)
- Shell completions for bash, zsh, and fish

**Resilience (shipped):**
- Conditional compilation detection — `#if` around dependency/target arrays surfaces a clear "spmx can't edit conditional manifests" message
- Multiple `Package(...)` calls — `#if swift(>=5.9)` branches with separate Package inits detected and refused cleanly
- `git ls-remote` caching — SHA-256 keyed, 5-minute TTL, `--refresh` to bypass
- Network timeouts — 30s default per subprocess (`git ls-remote`, `git clone`), 15s/30s on URLSession
- Revert on resolve failure — `add`/`remove` back up the manifest, run `swift package resolve`, restore on failure (`--no-resolve` to skip)
- Progress indicator — TTY-aware `Fetching versions… N/M` on stderr for `outdated`, `Resolving dependencies…` for `add`/`remove`

**Quality:**
- 360 tests across 51 suites
- README with installation, quickstart, and command reference
- CI via GitHub Actions (macOS 14, Xcode 16, `swift test --parallel`)
- Dogfooded against real-world projects

**Distribution:**
- Mint support (`mint install macitch/spmx`)
- Source build (`swift build -c release`)

---

## v1.0 — Stable

**Theme:** Trust it. Ship it. Forget about it.

**What v1.0 means:**
- The five commands have a stable CLI surface — flags, options, output format, and exit codes won't change without a major version bump
- JSON output schemas are documented and versioned
- Error messages are actionable (every error tells you what to do, not just what went wrong)

**Distribution:**
- Homebrew formula (`brew install spmx`)
- Pre-built universal binary (arm64 + x86_64) via GitHub Releases
- Man page (`spmx.1`) generated from ArgumentParser metadata

**Documentation:**
- `CHANGELOG.md` covering every version
- Contributing guide

**What v1.0 explicitly does NOT include:**
- `spmx update` — updating version constraints is a different beast and belongs post-1.0 if at all
- `spmx list` / `spmx tree` — `swift package show-dependencies` already does this
- `spmx init` — `swift package init` exists; wrapping it adds no value
- Plugin/macro support in manifest editing — macro-expanded manifests are a moving target in Swift evolution
- GUI / Xcode extension — spmx is a CLI tool; Xcode integration is a different product

---

## Versioning contract

- **0.x releases:** CLI surface may change between minors. Flags can be added, renamed, or removed. JSON output shape can change.
- **1.x releases:** Stable CLI surface. New flags/commands are additive only. JSON output is backward-compatible. Safe for CI scripts.
