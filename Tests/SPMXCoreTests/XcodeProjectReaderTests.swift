/*
 *  File: XcodeProjectReaderTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("XcodeProjectReader")
struct XcodeProjectReaderTests {

    // MARK: - Identity derivation

    @Suite("identity derivation")
    struct IdentityDerivation {

        @Test("strips .git suffix")
        func stripsDotGit() {
            #expect(
                XcodePackageReference.identity(forRepositoryURL: "https://github.com/Alamofire/Alamofire.git")
                == "alamofire"
            )
        }

        @Test("handles URLs without .git suffix")
        func noDotGit() {
            #expect(
                XcodePackageReference.identity(
                    forRepositoryURL: "https://github.com/kishikawakatsumi/KeychainAccess"
                )
                == "keychainaccess"
            )
        }

        @Test("preserves hyphens and lowercases")
        func preservesHyphens() {
            #expect(
                XcodePackageReference.identity(
                    forRepositoryURL: "https://github.com/apple/swift-collections.git"
                )
                == "swift-collections"
            )
        }

        @Test("handles SCP-style git URLs")
        func scpStyleURL() {
            #expect(
                XcodePackageReference.identity(
                    forRepositoryURL: "git@github.com:apple/swift-collections.git"
                )
                == "swift-collections"
            )
        }

        @Test("local path identity is the directory name")
        func localPath() {
            #expect(
                XcodePackageReference.identity(forLocalPath: "../MyLocalPackage")
                == "mylocalpackage"
            )
            #expect(
                XcodePackageReference.identity(forLocalPath: "/abs/path/to/AnotherPackage")
                == "anotherpackage"
            )
        }
    }

    // MARK: - pbxproj parsing

    /// Minimal openStep-format pbxproj exercising both reference kinds, an irrelevant
    /// object that should be ignored, and a duplicate to verify deduplication.
    private let samplePbxproj = #"""
    // !$*UTF8*$!
    {
        archiveVersion = 1;
        classes = {
        };
        objectVersion = 77;
        objects = {
            A1 /* XCRemoteSwiftPackageReference "Alamofire" */ = {
                isa = XCRemoteSwiftPackageReference;
                repositoryURL = "https://github.com/Alamofire/Alamofire.git";
                requirement = {
                    kind = upToNextMajorVersion;
                    minimumVersion = 5.0.0;
                };
            };
            A2 /* XCRemoteSwiftPackageReference "KeychainAccess" */ = {
                isa = XCRemoteSwiftPackageReference;
                repositoryURL = "https://github.com/kishikawakatsumi/KeychainAccess";
                requirement = {
                    branch = master;
                    kind = branch;
                };
            };
            A3 /* XCLocalSwiftPackageReference */ = {
                isa = XCLocalSwiftPackageReference;
                relativePath = "../LocalPackage";
            };
            A4 /* duplicate of A1 with same identity */ = {
                isa = XCRemoteSwiftPackageReference;
                repositoryURL = "https://github.com/Alamofire/Alamofire.git";
                requirement = {
                    kind = exactVersion;
                    version = 5.8.1;
                };
            };
            B1 /* irrelevant build phase */ = {
                isa = PBXSourcesBuildPhase;
                buildActionMask = 2147483647;
                files = (
                );
                runOnlyForDeploymentPostprocessing = 0;
            };
        };
        rootObject = ROOT /* Project object */;
    }
    """#

    @Test("parses remote, local, and ignores unrelated isa values")
    func parsesAllKinds() throws {
        let reader = XcodeProjectReader()
        let refs = try reader.parse(data: Data(samplePbxproj.utf8))

        // Should be 3 unique entries: alamofire, keychainaccess, localpackage. The duplicate
        // alamofire entry collapses, and the build-phase object is ignored.
        let identities = refs.map(\.identity)
        #expect(identities == ["alamofire", "keychainaccess", "localpackage"])
    }

    @Test("remote refs preserve their repository URL")
    func remoteHasURL() throws {
        let reader = XcodeProjectReader()
        let refs = try reader.parse(data: Data(samplePbxproj.utf8))
        let alamofire = refs.first { $0.identity == "alamofire" }
        guard let alamofire else {
            Issue.record("alamofire not found")
            return
        }
        switch alamofire.kind {
        case .remote(let url):
            #expect(url == "https://github.com/Alamofire/Alamofire.git")
        case .local:
            Issue.record("expected remote, got local")
        }
    }

    @Test("local refs preserve their relative path")
    func localHasPath() throws {
        let reader = XcodeProjectReader()
        let refs = try reader.parse(data: Data(samplePbxproj.utf8))
        let local = refs.first { $0.identity == "localpackage" }
        guard let local else {
            Issue.record("localpackage not found")
            return
        }
        switch local.kind {
        case .local(let path):
            #expect(path == "../LocalPackage")
        case .remote:
            Issue.record("expected local, got remote")
        }
    }

    @Test("a project with no SPM dependencies returns an empty array")
    func noDependencies() throws {
        let empty = #"""
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {
            };
            objectVersion = 77;
            objects = {
                X1 /* irrelevant */ = {
                    isa = PBXSourcesBuildPhase;
                    buildActionMask = 2147483647;
                };
            };
            rootObject = ROOT;
        }
        """#
        let reader = XcodeProjectReader()
        let refs = try reader.parse(data: Data(empty.utf8))
        #expect(refs.isEmpty)
    }

    @Test("malformed pbxproj throws parseFailed")
    func malformedThrows() {
        let garbage = Data("this is definitely not a plist".utf8)
        let reader = XcodeProjectReader()
        #expect(throws: XcodeProjectReader.Error.self) {
            _ = try reader.parse(data: garbage)
        }
    }

    @Test("missing project.pbxproj throws projectFileNotFound")
    func missingFileThrows() {
        let fm = FileManager.default
        let bogus = fm.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).xcodeproj")
        let reader = XcodeProjectReader()
        do {
            _ = try reader.read(bogus)
            Issue.record("expected projectFileNotFound")
        } catch let err as XcodeProjectReader.Error {
            #expect(err.description.contains("No project.pbxproj"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
@Suite("XcodeProjectReaderDogfood")
struct XcodeProjectReaderDogfood {
    @Test("Xcode pbxproj parses and prints discovered refs")
    func dogfood() throws {
        guard let raw = ProcessInfo.processInfo.environment["SPMX_DOGFOOD_XCODE"] else {
            print("SPMX_DOGFOOD_XCODE not set — skipping")
            return
        }
        var expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasSuffix("/project.pbxproj") {
            expanded = (expanded as NSString).deletingLastPathComponent
        }
        let url = URL(fileURLWithPath: expanded)
        let refs = try XcodeProjectReader().read(url)
        print("---- discovered \(refs.count) refs at \(expanded) ----")
        for r in refs { print("  \(r.identity)  \(r.kind)") }
        #expect(refs.count > 0, "expected at least one SPM ref")
    }
}