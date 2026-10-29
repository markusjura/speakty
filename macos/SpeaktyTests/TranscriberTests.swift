import FluidAudio
import XCTest
@testable import Speakty

final class TranscriberTests: XCTestCase {
    func testKeywordTermsAreScoredAsSpoken() {
        let encode = { (text: String) in text.unicodeScalars.map { Int($0.value) } }

        let hyphenated = Transcriber.keywordTerm("grill-with-docs", encode: encode)
        XCTAssertEqual(hyphenated.text, "grill-with-docs")
        XCTAssertEqual(hyphenated.aliases, ["grill with docs"])
        XCTAssertEqual(hyphenated.ctcTokenIds, encode("grill with docs"))
        XCTAssertEqual(hyphenated.minSimilarity, 0.8)

        let phrase = Transcriber.keywordTerm("Bank of America", encode: encode)
        XCTAssertNil(phrase.aliases)
        XCTAssertEqual(phrase.minSimilarity, 0.8, "Any term of several words needs a close match")

        let name = Transcriber.keywordTerm("CLAUDE.md", encode: encode)
        XCTAssertNil(name.aliases)
        XCTAssertNil(name.ctcTokenIds, "FluidAudio tokenizes single words itself")
        XCTAssertNil(name.minSimilarity)
    }
}
