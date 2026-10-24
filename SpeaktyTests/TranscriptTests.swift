import XCTest
@testable import Speakty

final class TranscriptTests: XCTestCase {
    func testPlainReplacementsMatchWholeWordsIgnoringCase() {
        let rules = [Replacement(find: "co-dex", replacement: "Codex"), Replacement(find: "cat", replacement: "$dog")]
        XCTAssertEqual(Transcript.applying(rules, to: "Ask Co-dex about the cat, not the category."),
                       "Ask Codex about the $dog, not the category.")
    }

    func testPatternsRunInOrderWithGroupTemplates() {
        let rules = [
            Replacement(find: #"(?i)slash (\w+)\.?"#, replacement: "/$1", isPattern: true),
            Replacement(find: #"(?i)dollar (\w+)\.?"#, replacement: #"\$$1"#, isPattern: true),
        ]
        XCTAssertEqual(Transcript.applying(rules, to: "Run slash commit, then echo dollar HOME."), "Run /commit, then echo $HOME")
    }

    func testInvalidPatternsAreRejectedAndSkipped() {
        let broken = Replacement(find: "(unclosed", replacement: "x", isPattern: true)
        XCTAssertFalse(broken.isValid)
        XCTAssertFalse(TranscriptPreferences(replacements: [broken]).isValid)
        XCTAssertEqual(Transcript.applying([broken], to: "(unclosed"), "(unclosed")
    }

    func testFittingAddsASpaceAndLowercasesMidSentence() {
        let fit = { Transcript.fitting($0, after: $1, keepingCaseOf: ["Codex", "Visual Studio"]) }
        XCTAssertEqual(fit("Then ship it.", "We test it"), " then ship it.")
        XCTAssertEqual(fit("Then ship it.", "We test it. "), "Then ship it.")
        XCTAssertEqual(fit("Then ship it.", "Done.\n"), "Then ship it.", "A new line starts fresh")
        XCTAssertEqual(fit("Then ship it.", ""), "Then ship it.")
        XCTAssertEqual(fit("Then ship it.", nil), "Then ship it.", "Unknown context leaves the text alone")
        XCTAssertEqual(fit("I think so.", "and"), " I think so.")
        XCTAssertEqual(fit("API keys stay.", "and"), " API keys stay.")
        XCTAssertEqual(fit("Codex fixed it.", "and"), " Codex fixed it.")
        XCTAssertEqual(fit("Visual Studio opens.", "and"), " Visual Studio opens.", "A name protects its first word")
        XCTAssertEqual(fit("Codexes run.", "and"), " codexes run.", "Only whole names count")
        XCTAssertEqual(fit(", right?", "It works"), ", right?")
        XCTAssertEqual(fit("Hello", "say ("), "hello")
    }

    func testSpeechTrimsSilenceAndPadsTheEnd() {
        let rate = Transcript.sampleRate
        let silence = [Float](repeating: 0.0005, count: rate)
        let tone = (0..<rate).map { Float(sin(Double($0) * 0.1)) * 0.3 }
        let speech = Transcript.speech(in: silence + tone + silence)
        // 200 ms of lead-in, the tone, 300 ms of tail, and half a second of padding.
        XCTAssertEqual(speech.count, rate / 5 + rate + rate * 3 / 10 + rate / 2, accuracy: rate / 50)
        XCTAssertEqual(speech.suffix(rate / 2).max(), 0)
        XCTAssertTrue(Transcript.speech(in: silence).isEmpty, "Room noise alone is no speech")
    }

    func testVocabularyCorrectionsKeepTheirPunctuation() {
        let corrections = [(phrase: "speak to", term: "Speakty"), (phrase: "Shoddy,", term: "Shotty")]
        XCTAssertEqual(Transcript.correcting("Shoddy, spotty, and speak to are siblings.", corrections),
                       "Shotty, spotty, and Speakty are siblings.")
        XCTAssertEqual(Transcript.correcting("We shipped it with Shoddy.", [(phrase: "Shoddy.", term: "Shotty")]),
                       "We shipped it with Shotty.")
        XCTAssertNil(Transcript.correcting("Nothing to see.", [(phrase: "Versal", term: "Vercel")]))
        // Which "speak to" was spoken as the name isn't known from the text, so FluidAudio's text is used.
        XCTAssertNil(Transcript.correcting("I will speak to the team about speak to.", [(phrase: "speak to.", term: "Speakty")]))
        XCTAssertEqual(Transcript.correcting("Shoddy and Shoddy.", [(phrase: "Shoddy", term: "Shotty"), (phrase: "Shoddy.", term: "Shotty")]),
                       "Shotty and Shotty.")
    }
}
