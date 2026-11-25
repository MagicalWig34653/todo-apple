import XCTest
@testable import TodoCore

/// The plan of a card is Markdown (contract pipeline 1.0.0, card B6FC965A). The detail shows headings, lists, code and paragraphs;
/// inline formatting (bold, links) is left to the system's Markdown parser in the view.
final class PlanMarkdownTests: XCTestCase {
    func testHeadingsListsAndParagraphs() {
        let text = "# Ziel\nEin Satz\nzweite Zeile\n\n## Schritte\n- eins\n- zwei\n  - innen\n1. erst\n2. dann\n\nSchluss"
        XCTAssertEqual(PlanMarkdown.blocks(text), [
            .heading(level: 1, text: "Ziel"),
            .paragraph("Ein Satz zweite Zeile"),
            .heading(level: 2, text: "Schritte"),
            .bullet(text: "eins", indent: 0), .bullet(text: "zwei", indent: 0), .bullet(text: "innen", indent: 1),
            .numbered(number: "1", text: "erst"), .numbered(number: "2", text: "dann"),
            .paragraph("Schluss"),
        ])
    }

    func testCodeFenceKeepsLinesAndIgnoresMarkup() {
        let text = "Vorher\n```swift\n# kein Titel\n- kein Punkt\n```\nNachher"
        XCTAssertEqual(PlanMarkdown.blocks(text), [.paragraph("Vorher"), .code("# kein Titel\n- kein Punkt"), .paragraph("Nachher")])
    }

    func testUnclosedFenceStillEndsTheBlock() {
        XCTAssertEqual(PlanMarkdown.blocks("```\nx = 1"), [.code("x = 1")])
    }

    func testOddInputIsNeverLost() {
        XCTAssertEqual(PlanMarkdown.blocks(""), [])
        XCTAssertEqual(PlanMarkdown.blocks("  \n\n "), [])
        XCTAssertEqual(PlanMarkdown.blocks("#kein Leerzeichen"), [.paragraph("#kein Leerzeichen")])
        XCTAssertEqual(PlanMarkdown.blocks("####### sieben"), [.paragraph("####### sieben")])
        XCTAssertEqual(PlanMarkdown.blocks("-kein Punkt"), [.paragraph("-kein Punkt")])
        XCTAssertEqual(PlanMarkdown.blocks("- [ ] Test schreiben"), [.bullet(text: "[ ] Test schreiben", indent: 0)])
        XCTAssertEqual(PlanMarkdown.blocks("# "), [.paragraph("#")], "an empty heading is not a heading")
    }

    func testWindowsLineEndingsAndTabs() {
        XCTAssertEqual(PlanMarkdown.blocks("# A\r\n- b\r\n\r\nC"), [.heading(level: 1, text: "A"), .bullet(text: "b", indent: 0), .paragraph("C")])
        XCTAssertEqual(PlanMarkdown.blocks("- a\n\t- b"), [.bullet(text: "a", indent: 0), .bullet(text: "b", indent: 1)])
    }

    func testStarAndPlusMarkersAreBullets() {
        XCTAssertEqual(PlanMarkdown.blocks("* a\n+ b"), [.bullet(text: "a", indent: 0), .bullet(text: "b", indent: 0)])
    }
}
