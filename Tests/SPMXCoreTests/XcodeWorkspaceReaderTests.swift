/*
 *  File: XcodeWorkspaceReaderTests.swift
 *  Project: spmx
 *  Author: macitch (https://github.com/macitch)
 *  License: MIT - Copyright (c) 2026 macitch
 */

import Foundation
import Testing
@testable import SPMXCore

@Suite("XcodeWorkspaceReader")
struct XcodeWorkspaceReaderTests {

    // MARK: - parse(data:) — raw location extraction

    /// A workspace with a top-level FileRef using `group:`, one using `container:`, one
    /// using `absolute:`, a `self:` reference (which the resolver will drop), a nested
    /// FileRef inside a Group (which we still pick up — we don't honor group nesting),
    /// and an unrelated `.playground` reference (which the resolver will drop).
    private let sampleWorkspace = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <Workspace
       version = "1.0">
       <FileRef
          location = "group:App/MyApp.xcodeproj">
       </FileRef>
       <FileRef
          location = "container:Tools/Helper.xcodeproj">
       </FileRef>
       <FileRef
          location = "absolute:/abs/path/Other.xcodeproj">
       </FileRef>
       <FileRef
          location = "self:">
       </FileRef>
       <Group
          location = "container:Subgroup"
          name = "Subgroup">
          <FileRef
             location = "group:Nested/Nested.xcodeproj">
          </FileRef>
       </Group>
       <FileRef
          location = "group:Notes.playground">
       </FileRef>
    </Workspace>
    """#

    @Test("parse extracts every FileRef location at any depth")
    func parseAllLocations() throws {
        let reader = XcodeWorkspaceReader()
        let locations = try reader.parse(data: Data(sampleWorkspace.utf8))
        #expect(locations == [
            "group:App/MyApp.xcodeproj",
            "container:Tools/Helper.xcodeproj",
            "absolute:/abs/path/Other.xcodeproj",
            "self:",
            "group:Nested/Nested.xcodeproj",
            "group:Notes.playground"
        ])
    }

    @Test("parse on a workspace with no FileRefs returns empty")
    func parseEmpty() throws {
        let empty = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
        </Workspace>
        """#
        let reader = XcodeWorkspaceReader()
        let locations = try reader.parse(data: Data(empty.utf8))
        #expect(locations.isEmpty)
    }

    @Test("parse on malformed XML throws parseFailed")
    func parseMalformed() {
        let garbage = Data("not even slightly XML <<<".utf8)
        let reader = XcodeWorkspaceReader()
        #expect(throws: XcodeWorkspaceReader.Error.self) {
            _ = try reader.parse(data: garbage)
        }
    }

    @Test("parse on well-formed XML without a Workspace root throws unexpectedStructure")
    func parseWrongRoot() {
        // Well-formed XML, but the root element isn't <Workspace>. We expect this to
        // surface as a structural error, not a parse error, because the bytes are valid
        // XML — they just don't describe a workspace.
        let wrongRoot = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <NotAWorkspace>
            <FileRef location="group:Foo.xcodeproj"/>
        </NotAWorkspace>
        """#
        let reader = XcodeWorkspaceReader()
        do {
            _ = try reader.parse(data: Data(wrongRoot.utf8))
            Issue.record("expected unexpectedStructure error")
        } catch let err as XcodeWorkspaceReader.Error {
            switch err {
            case .unexpectedStructure:
                break // expected
            default:
                Issue.record("wrong error case: \(err)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - read(_:) — end-to-end with on-disk fixture

    /// Stage a `.xcworkspace` bundle in tmp, write `contents.xcworkspacedata`, and call
    /// `read(_:)`. This is the test that proves location resolution works end-to-end:
    /// `group:` and `container:` should resolve relative to the workspace's parent dir,
    /// `absolute:` should pass through, `self:` and `.playground` should drop out.
    @Test("read resolves group/container relative to workspace parent")
    func readResolvesPaths() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("spmx-ws-\(UUID().uuidString)")
        let workspace = parent.appendingPathComponent("MyApp.xcworkspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }

        let contents = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:App/MyApp.xcodeproj"/>
           <FileRef location = "container:Tools/Helper.xcodeproj"/>
           <FileRef location = "absolute:/abs/Other.xcodeproj"/>
           <FileRef location = "self:"/>
           <FileRef location = "group:Notes.playground"/>
        </Workspace>
        """#
        try Data(contents.utf8).write(
            to: workspace.appendingPathComponent("contents.xcworkspacedata")
        )

        let urls = try XcodeWorkspaceReader().read(workspace)

        // Three projects expected: App/MyApp, Tools/Helper, /abs/Other.
        // self: and .playground both drop.
        #expect(urls.count == 3)
        #expect(samePath(urls[0], parent.appendingPathComponent("App/MyApp.xcodeproj")))
        #expect(samePath(urls[1], parent.appendingPathComponent("Tools/Helper.xcodeproj")))
        #expect(samePath(urls[2], URL(fileURLWithPath: "/abs/Other.xcodeproj")))
    }

    @Test("read on missing workspace bundle throws workspaceFileNotFound")
    func readMissing() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).xcworkspace")
        let reader = XcodeWorkspaceReader()
        do {
            _ = try reader.read(bogus)
            Issue.record("expected workspaceFileNotFound")
        } catch let err as XcodeWorkspaceReader.Error {
            #expect(err.description.contains("contents.xcworkspacedata"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // Path-equality helper. macOS symlinks /var → /private/var, so any test that compares
    // file URLs has to canonicalize both sides — see the same helper in
    // ResolvedParserTests for the original lesson.
    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}