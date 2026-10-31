import FluidAudio
import XCTest
@testable import Speakty

final class VocabularyBoostingTests: XCTestCase {
    func testKeywordTermsAreScoredAsSpoken() throws {
        let encode = { (text: String) in text.unicodeScalars.map { Int($0.value) } }

        let hyphenated = try XCTUnwrap(VocabularyBoosting.keywordTerm("grill-with-docs", encode: encode))
        XCTAssertEqual(hyphenated.text, "grill-with-docs")
        XCTAssertEqual(hyphenated.aliases, ["grill with docs"])
        XCTAssertEqual(hyphenated.ctcTokenIds, encode("grill with docs"))
        XCTAssertEqual(hyphenated.minSimilarity, 0.8)

        let phrase = try XCTUnwrap(VocabularyBoosting.keywordTerm("Bank of America", encode: encode))
        XCTAssertNil(phrase.aliases)
        XCTAssertEqual(phrase.minSimilarity, 0.8, "Any term of several words needs a close match")

        let name = try XCTUnwrap(VocabularyBoosting.keywordTerm("CLAUDE.md", encode: encode))
        XCTAssertNil(name.aliases)
        XCTAssertEqual(name.ctcTokenIds, encode("CLAUDE.md"))
        XCTAssertNil(name.minSimilarity)

        XCTAssertNil(VocabularyBoosting.keywordTerm("ü", encode: { _ in [] }), "A term the model can't spell is left out")
    }

    // Scores and confidences are from real candidates: the keyword model's mean log probability per
    // token for the term and for what Parakeet wrote, and Parakeet's confidence in that.

    func testConfidentlyHeardWordsStay() {
        let text = "Push the value onto the stack. Expose the port."
        let candidates = [
            candidate(5..<6, of: text, term: "TanStack", similarity: 0.62, termScore: -5.45, phraseScore: -0.57),
            candidate(6..<7, of: text, term: "Expo", similarity: 0.67, termScore: -2.77, phraseScore: 0),
        ]
        let corrected = VocabularyBoosting.correcting(text, words: words(text), by: candidates, confidences: [1, 1])
        XCTAssertEqual(corrected.text, text, "FluidAudio's own boost of 4.5 put in both terms")
        XCTAssertEqual(corrected.terms, [])
    }

    func testMisheardNamesAreCorrected() {
        let text = "Deploy to Versal, then ask Clod about Hyperland?"
        let candidates = [
            // Parakeet was unsure of "Versal", so the term needs less support from the audio.
            candidate(2..<3, of: text, term: "Vercel", similarity: 0.67, termScore: -4.06, phraseScore: -2.98, tokens: 1..<2),
            // Parakeet was sure of "Hyperland", but it's the term's spelling of the same sound.
            candidate(7..<8, of: text, term: "Hyprland", similarity: 0.89, termScore: -3.85, phraseScore: -1.52),
            // A confident "Clod" with nothing in the audio for "Claude" stays.
            candidate(5..<6, of: text, term: "Claude", similarity: 0.67, termScore: -3.9, phraseScore: -1.2),
        ]
        let corrected = VocabularyBoosting.correcting(text, words: words(text), by: candidates, confidences: [1, 0.38])
        XCTAssertEqual(corrected.text, "Deploy to Vercel, then ask Clod about Hyprland?")
        XCTAssertEqual(corrected.terms, ["Vercel", "Hyprland"])
    }

    func testOnlyTheSpokenPhraseIsReplaced() {
        let text = "Speak to the team about Speak T. Speak up."
        let candidates = [
            candidate(5..<7, of: text, term: "Speakty", similarity: 0.86, termScore: -2.9, phraseScore: -3.3),
            // The same span as a single word: the closer spelling above wins.
            candidate(5..<6, of: text, term: "Speakty", similarity: 0.71, termScore: -2.9, phraseScore: -3.0),
        ]
        XCTAssertEqual(VocabularyBoosting.correcting(text, words: words(text), by: candidates, confidences: []).text,
                       "Speak to the team about Speakty. Speak up.")
    }

    private func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

    /// A candidate for the words in `range` of `text`. Without `tokens`, Parakeet's confidence is unknown and counts as certain.
    private func candidate(_ range: Range<Int>, of text: String, term: String, similarity: Float, termScore: Float, phraseScore: Float,
                           tokens: Range<Int>? = nil) -> VocabularyRescorer.CandidateEvidence {
        .init(candidateID: 0, origin: .termCentricSingleWord, basePhrase: words(text)[range].joined(separator: " "), canonicalTerm: term,
              matchedAlias: nil, similarity: similarity, rawVocabularyCTCScore: termScore, rawOriginalCTCScore: phraseScore,
              effectiveBoost: nil, wordRange: range, tokenRange: tokens, baseTextUTF8Range: nil, startTime: nil, endTime: nil,
              comparisonPassed: false, legacyOutcome: .rejectedByComparison, reason: "")
    }
}
