/*
 *  File: EditDistance.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

/// Levenshtein edit distance between two strings.
///
/// Classic O(m×n) dynamic programming — good enough for the short identity strings we
/// compare (SPM package identities are typically < 40 characters). We use it for
/// "did you mean?" suggestions in `spmx why` when the user misspells a dependency name.
///
/// Returns the minimum number of single-character insertions, deletions, or substitutions
/// required to transform `source` into `target`.
public func editDistance(_ source: String, _ target: String) -> Int {
    let s = Array(source)
    let t = Array(target)
    let m = s.count
    let n = t.count

    if m == 0 { return n }
    if n == 0 { return m }

    // Only keep two rows at a time instead of an m×n matrix.
    var previous = Array(0...n)
    var current = [Int](repeating: 0, count: n + 1)

    for i in 1...m {
        current[0] = i
        for j in 1...n {
            let cost = s[i - 1] == t[j - 1] ? 0 : 1
            current[j] = min(
                previous[j] + 1,      // deletion
                current[j - 1] + 1,   // insertion
                previous[j - 1] + cost // substitution
            )
        }
        swap(&previous, &current)
    }
    return previous[n]
}

/// Suggests similar names for a `needle` from a list of `candidates` using Levenshtein
/// distance. Returns up to `maxResults` candidates sorted by increasing distance, filtered
/// to a maximum normalized distance threshold.
///
/// The threshold is adaptive: for short strings (≤ 5 chars) we allow distance ≤ 2; for
/// longer strings we allow up to 40% of the needle length. This balances between catching
/// real typos and not suggesting unrelated packages.
public func suggestSimilar(
    to needle: String,
    from candidates: [String],
    maxResults: Int = 3
) -> [String] {
    let maxDistance = needle.count <= 5 ? 2 : max(2, needle.count * 2 / 5)

    var scored: [(String, Int)] = []
    for candidate in candidates {
        let d = editDistance(needle, candidate)
        if d <= maxDistance && d > 0 { // d == 0 means exact match, skip
            scored.append((candidate, d))
        }
    }

    scored.sort { $0.1 < $1.1 }
    return Array(scored.prefix(maxResults).map(\.0))
}