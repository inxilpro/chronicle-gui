import Foundation
import Testing
import ChronicleKit

struct EditorLinkTests {
    @Test func phpstormURL() {
        let url = EditorLink.url(
            editor: .phpstorm, absolutePath: "/Users/dev/repo/src/App.php", line: 42)
        #expect(url?.absoluteString == "phpstorm://open?file=/Users/dev/repo/src/App.php&line=42")
    }

    @Test func phpstormURLWithoutLine() {
        let url = EditorLink.url(editor: .phpstorm, absolutePath: "/tmp/a.php", line: nil)
        #expect(url?.absoluteString == "phpstorm://open?file=/tmp/a.php")
    }

    @Test func ideaURL() {
        let url = EditorLink.url(editor: .idea, absolutePath: "/repo/Main.kt", line: 7)
        #expect(url?.absoluteString == "idea://open?file=/repo/Main.kt&line=7")
    }

    @Test func vscodeURL() {
        let url = EditorLink.url(editor: .vscode, absolutePath: "/repo/src/main.ts", line: 12)
        #expect(url?.absoluteString == "vscode://file/repo/src/main.ts:12")
    }

    @Test func cursorURLWithoutLine() {
        let url = EditorLink.url(editor: .cursor, absolutePath: "/repo/main.ts", line: nil)
        #expect(url?.absoluteString == "cursor://file/repo/main.ts")
    }

    @Test func vscodeURLEscapesSpaces() {
        let url = EditorLink.url(editor: .vscode, absolutePath: "/repo/My File.ts", line: 3)
        #expect(url?.absoluteString == "vscode://file/repo/My%20File.ts:3")
    }

    @Test func customTemplate() {
        let url = EditorLink.url(
            editor: .custom, absolutePath: "/repo/a.php", line: 9,
            template: "myeditor://open?file={path}&line={line}")
        #expect(url?.absoluteString == "myeditor://open?file=/repo/a.php&line=9")
    }

    @Test func customTemplateDefaultsLineToOne() {
        let url = EditorLink.url(
            editor: .custom, absolutePath: "/repo/a.php", line: nil,
            template: "e://f/{path}:{line}")
        #expect(url?.absoluteString == "e://f//repo/a.php:1")
    }

    @Test func emptyCustomTemplateFails() {
        #expect(EditorLink.url(editor: .custom, absolutePath: "/a", line: 1, template: "") == nil)
    }

    @Test func absolutePathResolution() {
        #expect(
            EditorLink.absolutePath(repoRoot: "/Users/dev/repo", referencePath: "src/App.php")
                == "/Users/dev/repo/src/App.php")
        #expect(EditorLink.absolutePath(repoRoot: nil, referencePath: "src/App.php") == nil)
        #expect(EditorLink.absolutePath(repoRoot: nil, referencePath: "/abs/path.php") == "/abs/path.php")
    }
}

struct FeedFormatTests {
    @Test func unreadLabelCapsAt99() {
        #expect(FeedFormat.unreadLabel(0) == nil)
        #expect(FeedFormat.unreadLabel(1) == "1")
        #expect(FeedFormat.unreadLabel(99) == "99")
        #expect(FeedFormat.unreadLabel(100) == "99+")
    }

    @Test func coalescedBody() {
        #expect(FeedFormat.coalescedMessageBody(1) == "The agent added a new review note.")
        #expect(FeedFormat.coalescedMessageBody(3) == "The agent added 3 new review notes.")
    }

    @Test func decisionTitleReflectsReviewState() {
        #expect(FeedFormat.decisionTitle(.unreviewed) == "Decision requested")
        #expect(FeedFormat.decisionTitle(.approved) == "Decision approved")
        #expect(FeedFormat.decisionTitle(.rejected) == "Decision rejected")
    }

    @Test func referencePasteboardText() {
        let reference = DocumentReference(
            heading: ["Plan", "Rollout"], snippet: "feature flags first")
        #expect(
            FeedFormat.referencePasteboardText(reference)
                == "Plan › Rollout — feature flags first")
    }

    @Test func pathWithLineFormats() {
        #expect(FeedFormat.pathWithLine(FileReference(path: "a/b.php", sha: "abc1")) == "a/b.php")
        #expect(
            FeedFormat.pathWithLine(FileReference(path: "a/b.php", line: 4, sha: "abc1"))
                == "a/b.php:4")
        #expect(
            FeedFormat.pathWithLine(
                FileReference(path: "a/b.php", line: 4, endLine: 9, sha: "abc1"))
                == "a/b.php:4-9")
    }
}

struct FileLinkTests {
    @Test func urlRoundTrip() throws {
        let link = FileLink(path: "src/App.php", line: 10, endLine: 20, sha: "abc123def")
        let url = try #require(link.url)
        let parsed = try #require(FileLink(url: url))
        #expect(parsed == link)
    }

    @Test func helpTextShowsShortCommit() {
        #expect(FileLink(path: "a.php", sha: "abc1234def").helpText == "Open file · commit abc1234")
        #expect(FileLink(path: "a.php").helpText == "Open file")
    }

    @Test func rejectsForeignURL() {
        #expect(FileLink(url: URL(string: "https://example.com")!) == nil)
    }
}
