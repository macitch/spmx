/*
 *  File: ManifestDumpTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("ManifestDump")
struct ManifestDumpTests {

    /// Representative shape of `swift package dump-package` output as of SPM 5.9+.
    /// Contains one of each known dependency kind (sourceControl, fileSystem, registry)
    /// plus extraneous fields that should be ignored.
    private let sampleJSON = #"""
    {
      "name": "MyPackage",
      "platforms": [{"platformName": "macos", "version": "13.0"}],
      "targets": [
        {"name": "MyPackage", "type": "regular"}
      ],
      "products": [
        {"name": "MyPackage", "type": {"library": ["automatic"]}}
      ],
      "dependencies": [
        {
          "sourceControl": [
            {
              "identity": "swift-collections",
              "location": {"remote": [{"urlString": "https://github.com/apple/swift-collections.git"}]},
              "requirement": {"range": [{"lowerBound": "1.0.0", "upperBound": "2.0.0"}]}
            }
          ]
        },
        {
          "fileSystem": [
            {"identity": "local-pkg", "path": "../local-pkg"}
          ]
        },
        {
          "registry": [
            {
              "identity": "acme.widget",
              "requirement": {"exact": ["2.3.4"]}
            }
          ]
        }
      ]
    }
    """#

    @Test("decodes name and all three dependency kinds")
    func decodesAllKinds() throws {
        let data = Data(sampleJSON.utf8)
        let dump = try JSONDecoder().decode(ManifestDump.self, from: data)

        #expect(dump.name == "MyPackage")
        #expect(dump.dependencies.count == 3)

        let identities = dump.dependencies.map(\.identity)
        #expect(identities == ["swift-collections", "local-pkg", "acme.widget"])

        let kinds = dump.dependencies.map(\.kind)
        #expect(kinds == [.sourceControl, .fileSystem, .registry])
    }

    @Test("ignores unknown top-level fields")
    func ignoresUnknownFields() throws {
        let json = #"""
        {
          "name": "X",
          "dependencies": [],
          "someFutureField": 42,
          "anotherOne": {"nested": "stuff"}
        }
        """#
        let data = Data(json.utf8)
        let dump = try JSONDecoder().decode(ManifestDump.self, from: data)
        #expect(dump.name == "X")
        #expect(dump.dependencies.isEmpty)
    }

    @Test("drops unrecognised dependency kinds instead of crashing")
    func dropsUnknownKinds() throws {
        let json = #"""
        {
          "name": "X",
          "dependencies": [
            {"futureKind": [{"identity": "who-knows"}]},
            {"sourceControl": [{"identity": "real-one"}]}
          ]
        }
        """#
        let data = Data(json.utf8)
        let dump = try JSONDecoder().decode(ManifestDump.self, from: data)
        #expect(dump.dependencies.count == 1)
        #expect(dump.dependencies.first?.identity == "real-one")
    }

    @Test("a manifest with no dependencies decodes cleanly")
    func emptyDependencies() throws {
        let json = #"""
        { "name": "Leaf", "dependencies": [] }
        """#
        let data = Data(json.utf8)
        let dump = try JSONDecoder().decode(ManifestDump.self, from: data)
        #expect(dump.name == "Leaf")
        #expect(dump.dependencies.isEmpty)
    }

    @Test("round-trips through JSON")
    func roundTrips() throws {
        let original = ManifestDump(
            name: "Foo",
            dependencies: [
                .init(identity: "bar", kind: .sourceControl),
                .init(identity: "baz", kind: .registry),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ManifestDump.self, from: data)
        #expect(decoded == original)
    }
}