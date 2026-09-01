import Foundation
import Testing
@testable import ChronicleKit

@Suite struct HandoffDocumentTests {
    private let sample = """
        # Plan

        Intro paragraph.

        <!-- chronicle-decision: adr-1 -->

        ## Storage

        We keep SQLite. The schema is stable.

        ```sh
        # not a heading, and <!-- not-a-marker --> stays put
        echo done
        ```

        ## Storage

        Second storage section.

        # Rollout

        Ship behind a flag.
        """

    @Test func blocksCarryHeadingPathsAndStableAnchors() {
        let document = HandoffDocument(markdown: sample)
        let headings = document.blocks.filter(\.isHeading)
        #expect(headings.map(\.headingPath) == [
            ["Plan"], ["Plan", "Storage"], ["Plan", "Storage"], ["Rollout"],
        ])
        #expect(headings.map(\.anchor) == ["plan", "plan--storage", "plan--storage-2", "rollout"])
        let intro = document.blocks.first { $0.text.contains("Intro paragraph.") }
        #expect(intro?.headingPath == ["Plan"])
        #expect(intro?.anchor == "plan")
    }

    @Test func commentsAreStrippedOutsideCodeFencesOnly() {
        let document = HandoffDocument(markdown: sample)
        #expect(!document.strippedMarkdown.contains("chronicle-decision"))
        #expect(document.strippedMarkdown.contains("<!-- not-a-marker --> stays put"))
        #expect(document.decisionMarkers.count == 1)
        #expect(document.decisionMarkers[0].id == "adr-1")
        #expect(document.decisionMarkers[0].headingPath == ["Plan"])
    }

    @Test func multilineCommentsAreStripped() {
        let document = HandoffDocument(
            markdown: "# A\n\nkeep <!-- start\nmiddle\nend --> tail\n\n<!-- chronicle-decision: d2 -->\n")
        #expect(document.strippedMarkdown.contains("keep"))
        #expect(document.strippedMarkdown.contains("tail"))
        #expect(!document.strippedMarkdown.contains("middle"))
        #expect(document.decisionMarkers.map(\.id) == ["d2"])
    }

    @Test func resolvesReferencesWithinTheirSection() {
        let document = HandoffDocument(markdown: sample)
        let location = document.resolve(
            DocumentReference(heading: ["Plan", "Storage"], snippet: "SQLite"))
        #expect(location?.anchor == "plan--storage")
        if let location {
            let start = document.strippedMarkdown.utf16Substring(location.snippetRange)
            #expect(start == "SQLite")
        }

        // The snippet only counts before the next same-or-higher heading.
        #expect(
            document.resolve(
                DocumentReference(heading: ["Plan", "Storage"], snippet: "Ship behind a flag.")) == nil)
        // Second sibling section with the same path is still reachable.
        let second = document.resolve(
            DocumentReference(heading: ["Plan", "Storage"], snippet: "Second storage section."))
        #expect(second?.anchor == "plan--storage-2")
        // Wrong heading path does not resolve.
        #expect(document.resolve(DocumentReference(heading: ["Storage"], snippet: "SQLite")) == nil)
        #expect(document.resolve(DocumentReference(heading: ["Plan"], snippet: "missing text")) == nil)
    }

    @Test func detectsInlineFileReferences() {
        let markdown = """
            # Files

            Look at `src/App.swift:40-45` @abcd1234 and `README.md` for context.
            Bare `Makefile` @deadbeef works; bare `makefile` alone does not.
            Skip `/etc/passwd` @abcd1234, `../up.txt` @abcd1234, and `https://x.dev/a`.
            Short hash `a/b.txt` @abc is just text; huge runs are not SHAs.
            """
        let document = HandoffDocument(markdown: markdown)
        let references = document.fileReferences
        #expect(references.map(\.path) == ["src/App.swift", "README.md", "Makefile", "a/b.txt"])
        let first = references[0]
        #expect(first.line == 40)
        #expect(first.endLine == 45)
        #expect(first.sha == "abcd1234")
        #expect(first.headingPath == ["Files"])
        #expect(references[1].sha == nil)
        #expect(references[2].sha == "deadbeef")
        // `a/b.txt` keeps no SHA because "abc" is below the 4-hex minimum.
        #expect(references[3].sha == nil)
    }

    @Test func fileReferenceGuardsRejectBadShapes() {
        #expect(HandoffDocument.parseFileReference(code: "/abs/path.txt", following: " @abcd") == nil)
        #expect(HandoffDocument.parseFileReference(code: "a/../b.txt", following: nil) == nil)
        #expect(HandoffDocument.parseFileReference(code: "has space.txt", following: nil) == nil)
        #expect(HandoffDocument.parseFileReference(code: "https://x.dev/a", following: nil) == nil)
        #expect(HandoffDocument.parseFileReference(code: "bareword", following: nil) == nil)
        #expect(
            HandoffDocument.parseFileReference(code: "bareword", following: " @abcd")
                == HandoffDocument.ParsedFileReference(path: "bareword", sha: "abcd"))
        #expect(HandoffDocument.parseFileReference(code: "a/b.txt:9-3", following: nil) == nil)
        #expect(HandoffDocument.parseFileReference(code: "a/b.txt:0", following: nil) == nil)
        #expect(
            HandoffDocument.parseFileReference(code: "a/b.txt:12", following: nil)
                == HandoffDocument.ParsedFileReference(path: "a/b.txt", line: 12))
        // 65 hex characters is a hash dump, not a SHA reference.
        let tooLong = String(repeating: "a", count: 65)
        #expect(HandoffDocument.parseFileReference(code: "a/b.txt", following: " @\(tooLong)")?.sha == nil)
    }

    @Test func decisionMarkerParsingIsStrict() {
        #expect(HandoffDocument.decisionId(in: " chronicle-decision: adr-7 ") == "adr-7")
        #expect(HandoffDocument.decisionId(in: "chronicle-decision: two words") == nil)
        #expect(HandoffDocument.decisionId(in: "unrelated comment") == nil)
        #expect(HandoffDocument.decisionId(in: "chronicle-decision:") == nil)
    }

    @Test func emptyDocumentIsSafe() {
        let document = HandoffDocument(markdown: "")
        #expect(document.blocks.isEmpty)
        #expect(document.decisionMarkers.isEmpty)
        #expect(document.fileReferences.isEmpty)
        #expect(document.resolve(DocumentReference(heading: ["A"], snippet: "x")) == nil)
    }
}

extension String {
    fileprivate func utf16Substring(_ range: Range<Int>) -> String {
        let utf16View = utf16
        guard
            let start = utf16View.index(
                utf16View.startIndex, offsetBy: range.lowerBound, limitedBy: utf16View.endIndex),
            let end = utf16View.index(
                utf16View.startIndex, offsetBy: range.upperBound, limitedBy: utf16View.endIndex),
            let stringStart = String.Index(start, within: self),
            let stringEnd = String.Index(end, within: self)
        else { return "" }
        return String(self[stringStart..<stringEnd])
    }
}
