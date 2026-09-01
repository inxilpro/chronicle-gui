import AppKit
import ChronicleKit
import Testing

@testable import Chronicle

struct HandoffRenderingTests {
    private let markdown = """
        # Feature plan

        Intro with **bold**, *italic*, ~~struck~~, `inline code`, and a
        [link](https://example.com).

        ## Decisions

        ### Retry placement
        <!-- chronicle-decision: retry-placement -->
        **Chose:** retries in the job.
        **Touches:** `app/Jobs/SyncRefundsJob.php:14` @a1b2c3d

        - first
          - nested
        - [x] done task
        - [ ] open task

        1. one
        2. two

        > A quoted rationale.

        ```swift
        let x = 1
        ```

        | Name | Value |
        | --- | ---: |
        | a | 1 |

        ---
        """

    private func rendering(scale: Double = 1) -> HandoffRendering {
        HandoffTextBuilder.build(document: HandoffDocument(markdown: markdown), scale: scale)
    }

    @Test @MainActor func rendersEveryBlockShape() {
        let rendered = rendering()
        let text = rendered.text.string
        #expect(text.contains("Feature plan"))
        #expect(text.contains("Intro with bold, italic, struck, inline code, and a link."))
        #expect(text.contains("let x = 1"))
        #expect(text.contains("A quoted rationale."))
        #expect(text.contains("☑\tdone task"))
        #expect(text.contains("☐\topen task"))
        #expect(text.contains("1.\tone"))
        // Table cells render in order.
        #expect(text.contains("Name"))
        #expect(text.contains("Value"))
        // Markdown syntax never leaks through.
        #expect(!text.contains("**"))
        #expect(!text.contains("~~"))
        #expect(!text.contains("| ---"))
        #expect(!text.contains("```"))
        // Decision markers stay invisible.
        #expect(!text.contains("chronicle-decision"))
    }

    @Test @MainActor func headingAnchorsAndAccessibilityLevelsSurvive() {
        let rendered = rendering()
        #expect(rendered.headingAnchors.map(\.anchor) == [
            "feature-plan", "feature-plan--decisions", "feature-plan--decisions--retry-placement",
        ])
        let h1 = rendered.headingAnchors[0].range
        let level = rendered.text.attribute(
            HandoffTextBuilder.axHeadingLevel, at: h1.location, effectiveRange: nil) as? Int
        #expect(level == 1)
    }

    @Test @MainActor func fileReferencesBecomeLinksWithHiddenSHA() {
        let rendered = rendering()
        let text = rendered.text.string
        #expect(text.contains("app/Jobs/SyncRefundsJob.php:14"))
        #expect(!text.contains("@a1b2c3d"))
        let range = (text as NSString).range(of: "app/Jobs/SyncRefundsJob.php:14")
        let url = rendered.text.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        #expect(url != nil)
        #expect(FileLink(url: url!)?.sha == "a1b2c3d")
    }

    @Test @MainActor func snippetResolutionMapsIntoRenderedText() {
        let document = HandoffDocument(markdown: markdown)
        let rendered = HandoffTextBuilder.build(document: document, scale: 1)
        // The suffix-form heading path (no document title) resolves too.
        let location = document.resolve(
            DocumentReference(heading: ["Decisions", "Retry placement"], snippet: "retries in the job"))
        #expect(location != nil)
        if let location {
            let range = rendered.renderedRange(
                forSourceRange: location.snippetRange, snippet: "retries in the job")
            #expect(range != nil)
            if let range {
                let match = (rendered.text.string as NSString).substring(with: range)
                #expect(match == "retries in the job")
            }
        }
    }

    @Test @MainActor func scaleGrowsFonts() {
        let small = rendering(scale: 1)
        let large = rendering(scale: 2)
        func firstFontSize(_ rendering: HandoffRendering) -> CGFloat? {
            (rendering.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        }
        let smallSize = firstFontSize(small)
        let largeSize = firstFontSize(large)
        #expect(smallSize != nil && largeSize != nil)
        if let smallSize, let largeSize {
            #expect(largeSize > smallSize * 1.9)
        }
    }
}
