# spmx

[![Release](https://img.shields.io/github/v/release/macitch/spmx?label=release)](https://github.com/macitch/spmx/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://www.apple.com/macos/)

> The dependency commands Swift Package Manager forgot to ship.

Created by [macitch](https://github.com/macitch)

`spmx` is a small CLI that adds the dependency-management commands every other package manager has had for a decade -- `add`, `remove`, `outdated`, `why`, and `search` -- to Swift Package Manager.

```
$ spmx add Alamofire --product Alamofire
Resolving version for alamofire... from: "5.11.2"
Fetching package metadata... 2 product(s) found
Adding: Alamofire (from: "5.11.2")
  Added .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.11.2") to Package.swift
  Wired .product(name: "Alamofire", package: "Alamofire") into target "MyApp"

$ spmx outdated --all
Package                Current  Latest  Status
---------------------  -------  ------  ----------
alamofire              5.8.0    5.11.2  behind (major)
swift-argument-parser  1.7.1    1.7.1   up to date

$ spmx why swift-syntax
swift-syntax is used by 2 paths:
  myapp -> swift-testing -> swift-syntax
  myapp -> swift-macros -> swift-syntax

$ spmx remove Alamofire
Removing: alamofire
  Removed from Package.swift dependencies
  Unwired from targets: MyApp
```

## Why this exists

Swift Package Manager's CLI is missing the four dependency-management verbs that every other ecosystem ships out of the box. In 2026, working with SPM dependencies still looks like this:

- **Adding** a package means hand-editing `Package.swift` and looking up the URL yourself.
- **Removing** a package means hand-editing `Package.swift` *and* hunting down every `.product(...)` reference in your targets -- without leaving a syntactically broken manifest behind.
- **Checking what's outdated** means clicking through GitHub releases, one repo at a time.
- **Asking "why is this transitive package in my graph?"** means staring at `swift package show-dependencies` output and grepping by hand.

`spmx` fills exactly those four gaps. Nothing more.

## Why not just use `swift package ...`?

Honest answer: for some things, you should. Here's what SPM already does well, so you know exactly what `spmx` is and isn't replacing.

| You want to...                               | Use this                                       |
|----------------------------------------------|------------------------------------------------|
| Update one or all packages                   | `swift package update [packages...]` (built-in)|
| Resolve dependencies after editing manifest  | `swift package resolve` (built-in)             |
| See the full forward dependency tree         | `swift package show-dependencies` (built-in)   |
| Dump the parsed manifest                     | `swift package dump-package` (built-in)        |
| Clean build artifacts                        | `swift package clean` (built-in)               |
| **Add a dependency**                         | **`spmx add`** *(SPM has no command)*          |
| **Remove a dependency**                      | **`spmx remove`** *(SPM has no command)*       |
| **List outdated dependencies**               | **`spmx outdated`** *(SPM has no command)*     |
| **Find why a transitive package is here**    | **`spmx why`** *(SPM only shows forward tree)* |
| **Search for a package by name**             | **`spmx search`** *(SPM has no command)*       |

`spmx` deliberately does not wrap the commands SPM already provides. Wrapping `swift package update` would be cosmetic theater -- it exists, it accepts a single package argument, it works.

## Install

### Homebrew

```bash
brew install macitch/spmx/spmx
```

### Mint

```bash
mint install macitch/spmx
```

### From source

```bash
git clone https://github.com/macitch/spmx.git
cd spmx
swift build -c release
cp .build/release/spmx /usr/local/bin/
```

## Commands

### `spmx add <package>`

Adds a dependency to `Package.swift` and wires its library product into a target.

```bash
spmx add Alamofire --product Alamofire    # specify product when there are multiple
spmx add Alamofire --from 5.8.0           # explicit version floor
spmx add Alamofire --exact 5.11.2         # pin exactly
spmx add swift-collections --branch main  # track a branch
spmx add https://github.com/me/fork.git   # use URL directly (bypasses catalog)
spmx add Kingfisher --target MyAppTests   # wire into a specific target
spmx add swift-argument-parser --url https://github.com/apple/swift-argument-parser.git
                                          # disambiguate when multiple repos match
```

**How name resolution works:** `<package>` is a name resolved via the [Swift Package Index](https://swiftpackageindex.com) catalog. Anything containing `://` or starting with `git@` is treated as a URL and used as-is -- that's the escape hatch for private repos, forks, and packages SPI hasn't indexed.

**Auto-detection:**
- If the package exposes exactly one library product, it's picked automatically. Otherwise, use `--product`.
- If the manifest has exactly one non-test target, the product is wired into it automatically. Otherwise, use `--target`.
- If no version flag is given, spmx queries `git ls-remote` for the latest semver tag and uses `from:`.

**Options:**

| Flag | Description |
|------|-------------|
| `--from <version>` | Version constraint: from (up to next major). Default. |
| `--exact <version>` | Pin to an exact version. |
| `--branch <name>` | Track a branch. |
| `--revision <sha>` | Pin to a specific commit. |
| `--product <name>` | Library product to wire. Required when multiple libraries exist. |
| `--target <name>` | Target to wire into. Required when multiple non-test targets exist. |
| `--url <url>` | Explicit repository URL. Overrides catalog resolution. |
| `-p, --path <dir>` | Path to the package directory. Defaults to `.` |
| `--dry-run` | Print planned edits without writing to disk. |
| `--refresh-catalog` | Bypass the 24-hour catalog cache. |

### `spmx remove <package>`

Removes a dependency from `Package.swift` *and* every `.product(...)` reference across all targets. Uses SwiftSyntax for AST-preserving edits -- no regex, no broken manifests.

```bash
spmx remove Alamofire                # by name (case-insensitive)
spmx remove https://github.com/Alamofire/Alamofire.git   # by URL
spmx remove Alamofire --dry-run      # preview without writing
```

**Options:**

| Flag | Description |
|------|-------------|
| `-p, --path <dir>` | Path to the package directory or Package.swift file. |
| `--dry-run` | Print what would change without writing. |

### `spmx outdated`

Lists every dependency with a newer version available. Reads `Package.resolved` and queries `git ls-remote` concurrently for latest tags.

```bash
spmx outdated              # show only outdated packages
spmx outdated --all        # include up-to-date packages
spmx outdated --direct     # only packages declared in Package.swift
spmx outdated --json       # machine-readable output (always unfiltered)
spmx outdated --exit-code  # exit 1 if anything is outdated (for CI)
spmx outdated --ignore swift-syntax --ignore swift-testing  # skip noisy packages
```

Output is color-coded by drift severity: green for up-to-date, yellow for minor/patch behind, red for major behind. Respects the `NO_COLOR` environment variable.

**Options:**

| Flag | Description |
|------|-------------|
| `--all` | Show all dependencies, including up-to-date ones. |
| `--direct` | Only show direct dependencies (declared in Package.swift). |
| `--json` | Output as JSON for scripting. Always unfiltered. |
| `--ignore <identity>` | Package identities to exclude from output. Repeatable. |
| `--exit-code` | Exit with non-zero status if any dependency is outdated. Useful for CI. |
| `--no-color` | Disable ANSI color output. |
| `-p, --path <dir>` | Path to the package directory. |

### `spmx why <package>`

Shows every path from your root package to `<package>`. The inverse of `swift package show-dependencies`: instead of "what does my package depend on," it answers "why is this specific package in my graph?"

```bash
spmx why swift-syntax                 # trace a transitive dependency
spmx why alamofire                    # trace a direct dependency
spmx why alamofire --json             # machine-readable output
spmx why swift-syntax --exit-code     # exit 1 if graph is incomplete (for CI)
```

Works with both SwiftPM packages and Xcode projects (`.xcodeproj` / `.xcworkspace`). Provides did-you-mean suggestions when the package name is close to a graph node but not exact.

**Options:**

| Flag | Description |
|------|-------------|
| `--json` | Output as JSON for scripting. |
| `--exit-code` | Exit with non-zero status if the dependency graph is incomplete. Useful for CI. |
| `--no-color` | Disable ANSI color output. |
| `-p, --path <dir>` | Path to the package or Xcode project directory. |

### `spmx search <term>`

Searches the [Swift Package Index](https://swiftpackageindex.com) catalog for packages matching a name or keyword.

```bash
spmx search alamofire              # find packages by name
spmx search collections --limit 5  # limit results
spmx search http --json            # machine-readable output
spmx search swift --limit 0        # show all matches (no truncation)
```

**Options:**

| Flag | Description |
|------|-------------|
| `--json` | Output as JSON for scripting. |
| `--limit <n>` | Maximum number of results to display. Default 20. Use 0 for unlimited. |
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
# Zsh (recommended)
spmx completions zsh > ~/.zsh/completion/_spmx
# Add to .zshrc (before compinit): fpath=(~/.zsh/completion $fpath)

# Bash
spmx completions bash > ~/.spmx-completion.bash
echo 'source ~/.spmx-completion.bash' >> ~/.bashrc

# Fish
spmx completions fish > ~/.config/fish/completions/spmx.fish
```

## How it works

`spmx` edits `Package.swift` using [SwiftSyntax](https://github.com/swiftlang/swift-syntax) -- the same parser the Swift compiler uses. This means:

- **Formatting is preserved.** Comments, whitespace, trailing commas -- all untouched. spmx only modifies the AST nodes it needs to.
- **No subprocess for manifest parsing.** `swift package dump-package` can hang for 20+ minutes on packages with macros or plugins (it triggers full dependency resolution internally). spmx reads the file and parses it directly.
- **Atomic operations.** `add` inserts the top-level `.package(url:)` entry AND wires `.product(name:)` into the target in a single pass. If either step fails, nothing is written.

Package name resolution uses the [Swift Package Index](https://swiftpackageindex.com) package list, cached locally for 24 hours. Version detection uses `git ls-remote --tags` against the resolved repository URL.

## Caveats

**Manifests that build dependency or target lists dynamically** (via variables, helper functions, or `#if` conditional compilation) cannot be edited by spmx. The tool detects these shapes and refuses with a clear error message rather than risk corrupting your manifest. This affects a small minority of packages -- most use plain array literals.

**Packages with dynamically-defined products** (e.g., `swift-collections` builds its product list via `targets.compactMap { ... }`) can't have their products auto-detected. Use `--product <name>` to specify the product explicitly -- spmx will trust your input and skip validation.

## Requirements

- macOS 13+
- Swift 6.0 toolchain (Xcode 16+)
- `git` on `PATH` (used for version discovery and package metadata fetching)

## Tests

```bash
swift test
```

## Status

`spmx` is **v0.1.1.** It works on the projects I've tested it against, but the edge cases of `Package.swift` are infinite. File an issue if it breaks on yours.

See [ROADMAP.md](./ROADMAP.md) for what's planned through v1.0.

## License

MIT -- see [LICENSE](./LICENSE). Copyright (c) 2026 [macitch](https://github.com/macitch).
