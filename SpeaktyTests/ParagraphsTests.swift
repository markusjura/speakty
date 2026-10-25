import XCTest
@testable import Speakty

final class ParagraphsTests: XCTestCase {
    /// Sentences of ten words each, with `openings` prefixed by sentence index.
    private func text(_ openings: [Int: String] = [:]) -> String {
        (0..<10).map { (openings[$0] ?? "") + "Sentence \($0) has a few words that make exactly ten." }.joined(separator: " ")
    }

    /// The number of sentences in each paragraph.
    private func shape(_ text: String) -> [Int] {
        text.components(separatedBy: "\n\n").map { $0.components(separatedBy: ". ").count }
    }

    func testShortTextStaysOneParagraph() {
        let short = "Thanks for the update. I'll look at it after lunch. Then I'll get back to you."
        XCTAssertEqual(Transcript.paragraphs(short), short)
    }

    func testLongTextSplitsIntoEvenParagraphs() {
        XCTAssertEqual(shape(Transcript.paragraphs(text())), [5, 5])
        XCTAssertEqual(Transcript.paragraphs(text()).components(separatedBy: "\n\n").first?.hasSuffix("4 has a few words that make exactly ten."), true)
    }

    func testOpeningsMoveTheBreak() {
        XCTAssertEqual(shape(Transcript.paragraphs(text([6: "Also, "]))), [6, 4], "A new topic starts a paragraph")
        XCTAssertEqual(shape(Transcript.paragraphs(text([5: "But "]))), [6, 4], "A continuation doesn't")
        XCTAssertEqual(shape(Transcript.paragraphs(text([4: "Außerdem "]))), [4, 6])
    }

    func testExistingLineBreaksStay() {
        let lines = text().replacingOccurrences(of: "ten. Sentence 1 ", with: "ten.\nSentence 1 ")
        let result = Transcript.paragraphs(lines)
        XCTAssertTrue(result.hasPrefix("Sentence 0 has a few words that make exactly ten.\nSentence 1 "))
        XCTAssertEqual(result.components(separatedBy: "\n\n").count, 2, "The nine sentences after the line break split evenly")
    }

    func testParagraphCommandBreaksWhereItIsSaid() {
        let apply = Transcript.applyingParagraphCommands
        XCTAssertEqual(apply("I'd start with a new paragraph new paragraph like the previous pause."),
                       "I'd start with a new paragraph.\n\nLike the previous pause.")
        XCTAssertEqual(apply("That's it. New paragraph. Next topic."), "That's it.\n\nNext topic.")
        XCTAssertEqual(apply("Is that right, new paragraph, yes it is."), "Is that right.\n\nYes it is.")
        XCTAssertEqual(apply("Is that right? New paragraph. Yes."), "Is that right?\n\nYes.")
        XCTAssertEqual(apply("Are you sure (really)? New paragraph. Yes."), "Are you sure (really)?\n\nYes.")
        XCTAssertEqual(apply("He said \"done.\" New paragraph. Then he left."), "He said \"done.\"\n\nThen he left.")
        XCTAssertEqual(apply("Er sagte „fertig.“ Neuer Absatz. Dann ging er."), "Er sagte „fertig.“\n\nDann ging er.")
        XCTAssertEqual(apply("See the docs (above), new paragraph, then ship."), "See the docs (above).\n\nThen ship.")
        XCTAssertEqual(apply("Das passt. Neuer Absatz. Weiter geht's."), "Das passt.\n\nWeiter geht's.")
        XCTAssertEqual(apply("New paragraph. Hello there."), "\n\nHello there.", "At the start, it breaks from the text before the caret")
        XCTAssertEqual(apply("Done. New paragraph."), "Done.\n\n")
        XCTAssertEqual(apply("Write a new paragraph and some new paragraphs."), "Write a new paragraph and some new paragraphs.")
    }
}
