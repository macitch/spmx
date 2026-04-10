/*
 *  File: EditDistanceTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Testing
@testable import SPMXCore

@Suite("EditDistance")
struct EditDistanceTests {

    // MARK: - editDistance

    @Test("identical strings have distance 0")
    func identical() {
        #expect(editDistance("alamofire", "alamofire") == 0)
    }

    @Test("empty source returns target length")
    func emptySource() {
        #expect(editDistance("", "abc") == 3)
    }

    @Test("empty target returns source length")
    func emptyTarget() {
        #expect(editDistance("abc", "") == 3)
    }

    @Test("single substitution")
    func singleSub() {
        #expect(editDistance("cat", "car") == 1)
    }

    @Test("single insertion")
    func singleInsertion() {
        #expect(editDistance("cat", "cart") == 1)
    }

    @Test("single deletion")
    func singleDeletion() {
        #expect(editDistance("cart", "cat") == 1)
    }

    @Test("real typo: alamofir → alamofire")
    func realTypo() {
        #expect(editDistance("alamofir", "alamofire") == 1)
    }

    @Test("real typo: swift-collection → swift-collections")
    func missingPlural() {
        #expect(editDistance("swift-collection", "swift-collections") == 1)
    }

    @Test("completely different strings have high distance")
    func completelyDifferent() {
        let d = editDistance("abc", "xyz")
        #expect(d == 3)
    }

    // MARK: - suggestSimilar

    @Test("suggests close matches within threshold")
    func suggestsClose() {
        let candidates = ["alamofire", "swift-collections", "kingfisher", "moya"]
        let results = suggestSimilar(to: "alamofir", from: candidates)
        #expect(results == ["alamofire"])
    }

    @Test("returns empty when nothing is close")
    func noSuggestions() {
        let candidates = ["alamofire", "swift-collections", "kingfisher"]
        let results = suggestSimilar(to: "xyzzy", from: candidates)
        #expect(results.isEmpty)
    }

    @Test("limits to maxResults")
    func maxResults() {
        // All single-char strings are within distance 1 of each other
        let candidates = ["a", "b", "c", "d", "e"]
        let results = suggestSimilar(to: "f", from: candidates, maxResults: 2)
        #expect(results.count == 2)
    }

    @Test("exact match is excluded from suggestions")
    func exactMatchExcluded() {
        let candidates = ["alamofire", "kingfisher"]
        let results = suggestSimilar(to: "alamofire", from: candidates)
        #expect(!results.contains("alamofire"))
    }

    @Test("sorts by distance — closest first")
    func sortedByDistance() {
        let candidates = ["swift-collections", "swift-collection", "swift-collectio"]
        let results = suggestSimilar(to: "swift-collectionz", from: candidates)
        // swift-collections and swift-collection are both distance 1 from swift-collectionz,
        // swift-collectio is distance 2.
        #expect(results.count >= 2)
        // First results should be the closer matches
        if results.count >= 2 {
            let d0 = editDistance("swift-collectionz", results[0])
            let d1 = editDistance("swift-collectionz", results[1])
            #expect(d0 <= d1)
        }
    }
}