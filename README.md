# spmx

[![Release](https://img.shields.io/github/v/release/macitch/spmx?label=release)](https://github.com/macitch/spmx/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://www.apple.com/macos/)

> Dependency tools for Swift Package Manager.

Created by [macitch](https://github.com/macitch)

`spmx` is a macOS CLI for finding, adding, removing, and inspecting Swift package dependencies. It combines package-name lookup, version selection, and target wiring in one command, and helps you see which dependencies are outdated or why a package is in your graph.

```bash
spmx search alamofire
spmx add Alamofire --product Alamofire
spmx outdated --all
spmx why swift-syntax
spmx remove Alamofire
```

## Why not just use `swift package ...`?

SwiftPM already includes `add-dependency` and [`add-target-dependency`](https://docs.swift.org/latest/documentation/packagemanagerdocs/packageaddtargetdependency/). `spmx add` combines those kinds of edits with catalog lookup and product selection. Keep using SwiftPM for resolving, updating, building, and testing packages.

| You want to...                               | Use this                                       |
|----------------------------------------------|------------------------------------------------|
| Update one or all packages                   | `swift package update [packages...]` (built-in)|
| Resolve dependencies after editing manifest  | `swift package resolve` (built-in)             |
| See the full forward dependency tree         | `swift package show-dependencies` (built-in)   |
| Dump the parsed manifest                     | `swift package dump-package` (built-in)        |
| Clean build artifacts                        | `swift package clean` (built-in)               |
| Add a dependency by URL                      | `swift package add-dependency <url> --from <version>` |
| Wire a product into a target                 | `swift package add-target-dependency <product> <target> --package <identity>` |
| Find a package by name, add it, and wire a product | `spmx add`                                |
| Remove a package and its explicit product references | `spmx remove`                          |
| Compare pinned versions with remote tags     | `spmx outdated`                               |
| Trace paths to a dependency                  | `spmx why`                                    |
| Search the package catalog by name           | `spmx search`                                 |

## Install

Homebrew and Mint install published versions, which may lag behind this README's source branch. Check your installation with `spmx --version` and see the [release notes](https://github.com/macitch/spmx/releases).

### Homebrew

```bash
brew install macitch/spmx/spmx
```

### Mint

```bash
mint install macitch/spmx
```

Requires [Mint](https://github.com/yonaskolb/Mint), with `~/.mint/bin` on your `PATH`.

### From source

```bash
git clone https://github.com/macitch/spmx.git
cd spmx
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 "$(swift build -c release --show-bin-path)/spmx" "$HOME/.local/bin/spmx"
```

Add `~/.local/bin` to your `PATH` if it is not already there.

## Commands

### `spmx add <package>`

Adds a dependency to `Package.swift` and wires its library product into a target.

```bash
spmx add Alamofire --product Alamofire    # specify product when there are multiple
spmx add Alamofire --from 5.8.0 --product Alamofire  # explicit version floor
spmx add Alamofire --exact 5.11.2 --product Alamofire  # pin exactly
spmx add swift-collections --branch main --product Collections  # track a branch
spmx add https://github.com/me/fork.git   # use URL directly (bypasses catalog)
spmx add Kingfisher --target MyAppTests   # wire into a specific target
spmx add swift-argument-parser --url https://github.com/apple/swift-argument-parser.git
                                          # disambiguate when multiple repos match
```

**How name resolution works:** names are matched case-insensitively against repository identities in the [Swift Package Index](https://swiftpackageindex.com) catalog. An unambiguous exact match wins, followed by an unambiguous prefix match. Ambiguous names prompt for a choice in an interactive terminal; use `--url` in scripts. URLs such as `https://host/owner/repo.git` and `git@host:owner/repo.git` bypass the catalog, including for private repositories and forks.

**Auto-detection:**

- If the package exposes exactly one library product, it's picked automatically. Otherwise, use `--product`.
- If the manifest has exactly one non-test target, the product is wired into it automatically. Otherwise, use `--target`.
- If no version flag is given, spmx queries `git ls-remote` for the latest stable semver tag and uses `from:`.

Product discovery reads the requested exact version, branch, or commit. For version ranges such as `--from`, it reads the newest matching tag. SwiftPM still performs final dependency resolution against the full project graph.

The version flags are mutually exclusive. After editing, `add` runs `swift package resolve` by default; see [Editing and resolution](#editing-and-resolution) for rollback behavior.

**Options:**

| Flag | Description |
|------|-------------|
| `--from <version>` | Allow versions from this floor up to the next major version. |
| `--exact <version>` | Pin to an exact version. |
| `--branch <name>` | Track a branch. |
| `--revision <sha>` | Pin to a specific commit. |
| `--product <name>` | Library product to wire. Required when multiple libraries exist. |
| `--target <name>` | Target to wire into. Required when multiple non-test targets exist. |
| `--url <url>` | Explicit repository URL. Overrides catalog resolution. |
| `-p, --path <path>` | Package directory or Package.swift file. Defaults to `.` |
| `--dry-run` | Preview edits without writing Package.swift or resolving. Metadata fetching still uses the network, cache, and temporary files. |
| `--no-resolve` | Write edits without running `swift package resolve`. |
| `--refresh-catalog` | Bypass the 24-hour catalog cache. |

### `spmx remove <package>`

Removes a dependency from `Package.swift` and matching `.product(name: ..., package: ...)` references across targets. Matching uses the repository identity or an explicit package alias. Local `.package(path:)` dependencies can also be removed by their directory name.

String dependencies and `.byName(...)` references are left unchanged because they do not identify the package explicitly. Review these references yourself. `remove` runs `swift package resolve` by default, with the rollback behavior described below.

```bash
spmx remove Alamofire                # by name (case-insensitive)
spmx remove https://github.com/Alamofire/Alamofire.git   # by URL
spmx remove Alamofire --dry-run      # preview without writing
```

**Options:**

| Flag | Description |
|------|-------------|
| `-p, --path <path>` | Package directory or Package.swift file. Defaults to `.` |
| `--dry-run` | Print what would change without writing. |
| `--no-resolve` | Write edits without running `swift package resolve`. |

### `spmx outdated`

Reads pinned dependencies from `Package.resolved` (formats v2 and v3) and queries remote Git tags concurrently. The latest stable semver tag is compared with each pinned version, regardless of the version constraints in your manifest. A newer tag is not necessarily compatible with your project.

```bash
spmx outdated              # hide up-to-date packages; include unknown/branch statuses
spmx outdated --all        # include up-to-date packages
spmx outdated --direct     # only packages declared in Package.swift
spmx outdated --json       # include all statuses, honoring --direct and --ignore
spmx outdated --exit-code  # exit 1 for any status other than up to date
spmx outdated --refresh    # bypass the five-minute version cache
spmx outdated --ignore swift-syntax --ignore swift-testing  # skip noisy packages
```

Output is color-coded by drift severity: green for up-to-date, yellow for minor/patch behind, red for major behind. Respects the `NO_COLOR` environment variable.

`--exit-code` also exits 1 for branch pins and unknown results, including failed version lookups. Filters apply before this check. Other command errors can return non-zero regardless of this flag.

For Xcode projects, run from the directory containing the `.xcodeproj` or `.xcworkspace`, or pass that directory with `--path`. `--direct` requires a statically readable `Package.swift` beside the selected lockfile and is intended for SwiftPM packages.

**Options:**

| Flag | Description |
|------|-------------|
| `--all` | Show all dependencies, including up-to-date ones. |
| `--direct` | Only show direct dependencies (declared in Package.swift). |
| `--json` | Include up-to-date rows as JSON. Honors `--direct` and `--ignore`. |
| `--ignore <identity>` | Package identities to exclude from output. Repeatable. |
| `--exit-code` | Exit 1 if any selected dependency has a status other than up to date. |
| `--refresh` | Bypass the five-minute version cache. |
| `--no-color` | Disable ANSI color output. |
| `-p, --path <dir>` | Package directory or directory containing Xcode bundles. Defaults to `.` |

### `spmx why <package>`

Shows paths from your root package to `<package>`, up to 50 paths per query. It answers "why is this specific package in my graph?" Both text and JSON output have this limit; text output includes an "and more" hint when traversal is truncated.

```bash
spmx why swift-syntax                 # trace a transitive dependency
spmx why alamofire                    # trace a direct dependency
spmx why alamofire --json             # machine-readable output
spmx why swift-syntax --exit-code     # exit 1 if graph is incomplete (for CI)
```

Works with both SwiftPM packages and Xcode projects (`.xcodeproj` / `.xcworkspace`). Provides did-you-mean suggestions when the package name is close to a graph node but not exact.

Local `.package(path:)` dependencies are followed relative to the manifest that declares them. Projects containing only local packages work without a `Package.resolved` file.

Remote dependencies need existing checkouts: resolve the package with SwiftPM or Xcode first. Missing manifests produce a partial graph and warnings. `--exit-code` exits 1 when manifests are missing; a package that cannot be found in the graph is an error even without this flag.

**Options:**

| Flag | Description |
|------|-------------|
| `--json` | Output as JSON for scripting. |
| `--exit-code` | Exit 1 if graph traversal reports missing manifests. |
| `--no-color` | Disable ANSI color output. |
| `-p, --path <path>` | Package directory, Xcode bundle, or directory containing a bundle. Defaults to `.` |

### `spmx search <term>`

Searches the [Swift Package Index](https://swiftpackageindex.com) catalog by case-insensitive substring of the repository identity. It does not search package descriptions.

```bash
spmx search alamofire              # find packages by name
spmx search collections --limit 5  # limit results
spmx search http --json            # machine-readable output
spmx search swift --limit 0        # show all matches (no truncation)
```

**Options:**

| Flag | Description |
|------|-------------|
| `--json` | Output every match as JSON, regardless of `--limit`. |
| `--limit <n>` | Maximum table rows to display. Default 20. Use 0 for unlimited. |
| `--refresh-catalog` | Bypass the 24-hour catalog cache. |

### `spmx completions`

Generates shell completion scripts for bash, zsh, and fish.

```bash
spmx completions bash              # print bash completions to stdout
spmx completions zsh               # print zsh completions to stdout
spmx completions fish              # print fish completions to stdout
spmx completions install zsh       # print install instructions
```

To install completions for your shell:

```bash
# Zsh
mkdir -p ~/.zsh/completion
spmx completions zsh > ~/.zsh/completion/_spmx
# Add to .zshrc (before compinit): fpath=(~/.zsh/completion $fpath)

# Bash
spmx completions bash > ~/.spmx-completion.bash
echo 'source ~/.spmx-completion.bash' >> ~/.bashrc

# Fish
mkdir -p ~/.config/fish/completions
spmx completions fish > ~/.config/fish/completions/spmx.fish
```

## How it works

`add` and `remove` parse and edit `Package.swift` with [SwiftSyntax](https://github.com/swiftlang/swift-syntax), preserving unaffected syntax. Edited arrays may have spacing or comma changes. Product discovery reads the remote manifest statically at the selected Git reference.

`why` uses `swift package dump-package` to evaluate manifests and build a graph, with cached results keyed by manifest content and directory. It reads existing remote checkouts and follows local package paths.

Package name resolution uses the [Swift Package Index](https://swiftpackageindex.com) package list, cached locally for 24 hours. Version detection uses `git ls-remote --tags` against the resolved repository URL.

### Editing and resolution

`add` and `remove` prepare the manifest edits in memory before writing. By default, they then run `swift package resolve`. If resolution fails, spmx attempts to restore the original `Package.swift` and reports any failure to restore it. This rollback covers the manifest only; changes SwiftPM makes to `Package.resolved` or checkouts are not restored. Resolution does not build or test the project.

Use `--dry-run` to preview edits without writing the manifest or resolving, or `--no-resolve` to write the manifest and handle resolution yourself. A dry-run of `add` still fetches metadata and can update caches and create temporary files.

## Caveats

**Manifest editing supports literal declarations.** Dependency and target arrays built with variables, helper functions, or conditional compilation are not supported; detected unsupported shapes are rejected. `add` and `remove` edit `Package.swift`, not Xcode project files.

**Dynamic product lists may need `--product`.** If static discovery finds no products, an explicitly supplied product name is accepted without checking it against the remote product list. Metadata fetching and the default resolution step still run.

**Registry dependencies are not fully supported.** `add` handles Git repositories, `outdated` cannot discover registry versions, and `why` does not traverse registry packages' transitive dependencies. Xcode workspace discovery also does not resolve nested group-relative project paths.

## Requirements

- macOS 13+
- Swift 6.0 or newer to build from source (for example, Xcode 16+)
- `swift` on `PATH` for `why` and the default resolution step in `add` / `remove`
- `git` on `PATH` (used for version discovery and package metadata fetching)

## Tests

```bash
swift test
```

## Status

This source tree targets **v0.2.0**. Published versions are listed on the [releases page](https://github.com/macitch/spmx/releases); see [CHANGELOG.md](./CHANGELOG.md) for changes, including the SPMXCore API migration. Please [report issues](https://github.com/macitch/spmx/issues) with manifests or project layouts that fail.

See [ROADMAP.md](./ROADMAP.md) for what's planned through v1.0.

## License

MIT -- see [LICENSE](./LICENSE). Copyright (c) 2026 [macitch](https://github.com/macitch).
