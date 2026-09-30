# spmx Roadmap

> Dependency tools for Swift Package Manager.

Keep the five dependency commands focused: `add`, `remove`, `outdated`, `why`, and `search`, with shell completions as supporting tooling. Prioritize safe edits, accurate results, and predictable scripting behavior before adding more commands.

SwiftPM already provides dependency-addition commands, resolution, updates, and dependency-tree output. spmx's value is combining catalog lookup, version and product selection, target wiring, and dependency inspection. See the [README](README.md) for the current command reference and [CHANGELOG](CHANGELOG.md) for implementation history.

This plan was checked against the source and published releases on **2026-09-22**. Future milestones describe intended work, not features already available or release-date commitments.

## Current baseline

| Area | Verified status |
|------|-----------------|
| Published version | [v0.2.0](https://github.com/macitch/spmx/releases/tag/v0.2.0) is published with a universal macOS archive and SHA-256 checksum. |
| Source | The release tag points to `ccd0a756ad272e3652e7134bbc8ff4eb38739383`, containing the fixes merged in [PR #1](https://github.com/macitch/spmx/pull/1). Its CI passed. |
| Installation | The [Homebrew tap](https://github.com/macitch/homebrew-spmx/blob/main/Formula/spmx.rb) now points to 0.2.0. Mint and source installations are also available. |
| CI | [Source CI](.github/workflows/ci.yml) builds and tests on `macos-15` using the runner's selected Swift toolchain. [Tap CI](https://github.com/macitch/homebrew-spmx/blob/main/.github/workflows/test.yml) installs and smoke-tests the packaged executable on Apple Silicon and Intel macOS 15. A broader toolchain/runtime matrix and automated publication remain planned. |

The current source supports:

- `add`: catalog name lookup or an explicit Git URL, version requirements, product/target selection, and edits to literal `Package.swift` declarations. Metadata is read at the selected Git reference.
- `remove`: removal of URL or local-path dependencies and explicit `.product(..., package: ...)` references, including package aliases. String and `.byName(...)` references are left unchanged.
- `outdated`: comparison of lockfile pins with the latest stable remote Git tags, with filtering, caching, table/JSON output, and optional non-zero exit status. It does not calculate the newest version allowed by the full dependency graph.
- `why`: traversal of SwiftPM packages and supported Xcode project/workspace layouts, including local paths. Path output is capped at 50. Registry traversal and some workspace layouts remain incomplete.
- `search`: case-insensitive repository-name substring search of the SPI catalog, returning identities and URLs. It does not return descriptions, versions, or product counts.
- Bash, zsh, and fish completion generation.

Manifest editing and remote product discovery use SwiftSyntax. Graph inspection uses cached `swift package dump-package` results. Default `add`/`remove` resolution has best-effort manifest rollback; it is not a transaction over the lockfile and checkouts.

## v0.2.0 — Deliver the reviewed fixes

**Status: released.**

The merged work fixes subprocess pipe deadlocks, repository-identity wiring, metadata selection at requested references, alias/local-dependency removal, local graph traversal, rollback diagnostics, and concurrent checkout-cache access. It also corrects the README and CLI help. The local validation run passed 380 tests in 52 suites; PR CI passed independently.

Release checklist:

- [x] Build and test the exact release commit: all 380 tests pass in release mode, and the extracted archive passes `--version` and local add/remove/why smoke tests.
- [x] Publish the tag, release notes, universal macOS artifact, and checksum. Verify both architecture slices, the code signature, and the declared macOS 13 deployment target.
- [x] Update the Homebrew tap URL/checksum. Clean Homebrew installations and installed-binary smoke tests pass on Apple Silicon and Intel macOS 15; clean Mint and source installations report 0.2.0.
- [x] Include the SPMXCore migration note: injected `AddRunner.fetchMetadata` closures now receive `(url, requirement)`.

Runtime checks for the release artifact passed on Apple Silicon with macOS 27 and through [Homebrew CI on Apple Silicon and Intel macOS 15](https://github.com/macitch/homebrew-spmx/actions/runs/35542610202). Source CI passed on macOS 15 with Swift 6.1.2. macOS 13 runtime checks remain unverified and are part of the environment-matrix work below. The archive records build-time validation and the dependency lockfile; the binary is ad-hoc signed, not notarized.

The reliability work below remains planned for subsequent 0.x releases.

## Next 0.x milestone — Close reliability gaps

Work in this order; each item needs a regression fixture demonstrating the failure and the corrected behavior.

1. **Bound subprocess shutdown.** The current timeout/cancellation path sends `SIGTERM` and waits for exit and pipe EOF. Add a bounded shutdown policy for processes that ignore termination and descendants that retain output pipes. Distinguish short metadata lookups from potentially slow dependency resolution instead of applying the same default timeout to both. Verify timeout, cancellation, child cleanup, and large stdout/stderr output.
2. **Protect concurrent manifest edits.** Detect changes between reading, writing, and reverting `Package.swift`; a failed resolve must not overwrite another editor's changes. Keep a recoverable copy when restoration cannot complete and make the rollback scope explicit. Verify edits made both before the initial write and while resolution runs.
3. **Report incomplete graphs honestly.** Handle nested workspace group paths and surface unreadable projects instead of silently dropping them. Expose path truncation in `why --json`. Registry edges must be traversed or explicitly reported as unsupported/incomplete, including in exit-status behavior. Test each case alongside missing remote checkouts and local packages.
4. **Match the active manifest and cache context.** Account for SwiftPM's [version-specific manifest selection](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageModel/ToolsVersion.swift) (`Package@swift-*.swift`) in metadata discovery and editing, or reject unsupported variants clearly. Include the active toolchain/selected manifest in graph-cache validity, and define a refresh or bypass policy for manifests whose output depends on environment or other files. Verify changes are visible without manually deleting cache files.
5. **Make project selection consistent.** Align path handling across inspection commands, report ambiguous Xcode lockfiles, and support or explicitly reject `outdated --direct` for Xcode projects. Verify package directories, direct bundle paths, and directories containing multiple projects.

Completion means supported inputs produce correct results or a specific, actionable unsupported/incomplete result, with no known silent overwrite or unbounded shutdown in the covered cases.

## Final 0.x milestone — Settle contracts and release verification

Complete these decisions before promising a stable 1.x interface:

- [ ] **JSON contract:** document schemas, field meanings, nullability, ordering, and a schema-version strategy for `outdated`, `why`, and `search`. Define truncation/completeness fields and keep diagnostics off JSON stdout. Make any necessary shape changes while the project is still 0.x.
- [ ] **Exit-status contract:** define outcomes for outdated versions, branch/revision pins, lookup failures, incomplete graphs, no search matches, and invalid input. Decide whether confirmed outdated results and inability to check should have distinct outcomes. Test combinations with `--json`, `--direct`, and `--ignore`.
- [ ] **Public library contract:** document the supported SPMXCore API and its compatibility policy, including injectable closures and public errors. CLI stability alone does not cover the library product exported by `Package.swift`.
- [ ] **Supported environments:** define a test matrix covering the minimum and a current supported Swift toolchain, the minimum supported macOS runtime, and each advertised CPU architecture. Either verify arm64 and x86_64 artifacts or narrow the published support statement; a universal binary is one packaging option, not evidence of compatibility.
- [ ] **Release verification:** automate tagged builds, artifact checksums, version checks, and installation smoke tests. Document the Homebrew update process and test its source-build path using SwiftPM's reported binary directory.
- [ ] **Contributor and user documentation:** add a contributing guide, document unsupported manifest/project shapes, and remove stale diagnostics that describe parsing or validation steps the code no longer performs.

Acceptance checks should exercise real local Git repositories, SwiftPM resolution, representative Xcode fixtures, and the packaged executable. Live catalog/network smoke checks can supplement these without making every unit-test run depend on external services.

## v1.0 — Stable supported behavior

Release 1.0 when the reliability and contract milestones above are complete for the documented support scope:

- [ ] No known silent manifest-overwrite, unbounded subprocess-shutdown, or falsely complete graph result remains within that scope.
- [ ] CLI arguments, JSON schemas, exit statuses, and the documented SPMXCore API have compatibility tests and migration guidance from the last 0.x release.
- [ ] The exact tagged release artifacts pass the supported environment matrix and clean installation checks before publication.
- [ ] README, help, changelog, support limits, and installation instructions agree with the shipped executable.

Human-readable tables and diagnostic wording may improve without byte-for-byte compatibility. Scripts should use the documented JSON output and exit statuses.

## Deferred work

These are optional follow-ups, not prerequisites for a reliable 1.0:

- Richer catalog search with descriptions, versions, or product counts; evaluate data availability and network cost first.
- Full registry dependency management, arbitrary dynamic-manifest rewriting, dedicated plugin/macro target wiring, and Xcode project-file editing. Basic package inspection must still report unsupported cases accurately.
- Generated man pages and additional packaging convenience. Maintain the existing Homebrew tap; do not assume availability as `brew install spmx` in Homebrew/core.
- `spmx update` for rewriting version constraints, if a concrete workflow warrants it. Continue using `swift package update` for resolution within existing constraints.
- `list`, `tree`, and `init` wrappers, a GUI, or an Xcode extension. These do not currently advance the five-command scope.

## Versioning contract

The project follows [Semantic Versioning](https://semver.org/) for its documented public interface:

- **0.x:** the interface is still being designed. Keep patch releases compatible; group intentional CLI, JSON, exit-status, and library API breaks into minor releases with migration notes.
- **1.x:** preserve documented CLI arguments, JSON semantics, exit statuses, and the supported SPMXCore API within a major version. Compatible additions belong in minor releases; incompatible changes require a new major version. Define allowed JSON extensions explicitly so consumers know which additions to tolerate.
- Internal implementation details and human-readable formatting are not a stable scripting interface. Declared platform/toolchain support changes must be called out explicitly in release notes.
