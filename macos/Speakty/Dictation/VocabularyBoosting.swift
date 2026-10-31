import FluidAudio
import Foundation

/// Checks a transcript against the vocabulary with FluidAudio's small CTC keyword model, and puts in a
/// term where the audio supports it over what Parakeet wrote.
///
/// FluidAudio finds the candidates: phrases spelled like a term. It scores each one twice on the
/// audio, as the term and as written, and leaves the decision to `correcting`. FluidAudio's own
/// decision adds a flat 4.5 to the term's score, which put "TanStack" in for a clearly spoken "stack".
struct VocabularyBoosting: Sendable {
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer
    private let minSimilarity: Float

    /// Loads the session for `terms`. The models are shared by every vocabulary.
    init(terms: [String], models: CtcModels) async throws {
        let directory = CtcModels.defaultCacheDirectory(for: models.variant)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let vocabulary = CustomVocabularyContext(terms: terms.compactMap { Self.keywordTerm($0, encode: tokenizer.encode) })
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        // FluidAudio recommends turning off its acoustic rescue for short vocabularies of distinctive
        // names, where it finds nothing the text match doesn't.
        rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: vocabulary,
                                                       config: .init(spotterRescueEnabled: false), ctcModelDirectory: directory)
        minSimilarity = max(ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count).minSimilarity,
                            vocabulary.minSimilarity)
    }

    /// `text` with the vocabulary terms the audio supports put in, and those terms, or nil when no
    /// phrase resembles a term. The keyword model only runs when one does.
    func correcting(_ text: String, tokenTimings: [TokenTiming], audio: [Float]) async throws -> (text: String, terms: [String])? {
        guard rescorer.hasCTCRescoringCandidates(transcript: text, tokenTimings: tokenTimings, minSimilarity: minSimilarity) else {
            return nil
        }
        // An empty vocabulary skips keyword detection, which nothing here uses.
        let ctc = try await spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: CustomVocabularyContext(terms: []))
        // The search margin is what VocabularyBoostingSession uses. The weight only feeds FluidAudio's
        // own decision, which `correcting` replaces.
        let evidence = rescorer.ctcTokenEvaluateCandidates(transcript: text, tokenTimings: tokenTimings, logProbs: ctc.logProbs,
                                                           frameDuration: ctc.frameDuration, cbw: 0, marginSeconds: 0.5,
                                                           minSimilarity: minSimilarity)
        return Self.correcting(text, words: evidence.baseWords, by: evidence.candidates, confidences: tokenTimings.map(\.confidence))
    }

    /// `text` with each candidate the audio supports replaced by its term, and the terms put in.
    /// `words` are the words of `text` that the candidates' word ranges count. A replacement keeps the
    /// punctuation around the phrase. Overlapping candidates are resolved as FluidAudio does: the
    /// closest spelling wins, then the shortest phrase. `confidences` are Parakeet's, per token, as
    /// the candidates' token ranges count them.
    nonisolated static func correcting(_ text: String, words: [String], by candidates: [VocabularyRescorer.CandidateEvidence],
                                       confidences: [Float]) -> (text: String, terms: [String]) {
        // FluidAudio has a text range for each candidate too, but none for a phrase before "?", "!", or ":".
        var wordRanges: [Range<String.Index>] = []
        for word in words {
            guard let range = text.range(of: word, range: (wordRanges.last?.upperBound ?? text.startIndex)..<text.endIndex) else {
                return (text, [])
            }
            wordRanges.append(range)
        }
        let bucket = { (similarity: Float) in Int((similarity / 0.05).rounded()) }
        let ranked = candidates.filter { isSupported($0, confidences: confidences) }.sorted { a, b in
            if bucket(a.similarity) != bucket(b.similarity) { return bucket(a.similarity) > bucket(b.similarity) }
            if a.wordRange.count != b.wordRange.count { return a.wordRange.count < b.wordRange.count }
            return a.similarity > b.similarity
        }
        let isLexical = { (character: Character) in character.isLetter || character.isNumber }
        var taken = IndexSet()
        var swaps: [(range: Range<String.Index>, term: String)] = []
        for candidate in ranked where !candidate.wordRange.isEmpty && candidate.wordRange.upperBound <= wordRanges.count
            && !taken.intersects(integersIn: candidate.wordRange) {
            let phrase = text[wordRanges[candidate.wordRange.lowerBound].lowerBound..<wordRanges[candidate.wordRange.upperBound - 1].upperBound]
            guard let first = phrase.firstIndex(where: isLexical), let last = phrase.lastIndex(where: isLexical) else { continue }
            taken.insert(integersIn: candidate.wordRange)
            swaps.append((first..<phrase.index(after: last), candidate.canonicalTerm))
        }
        swaps.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result = text
        for swap in swaps.reversed() { result.replaceSubrange(swap.range, with: swap.term) }
        return (result, swaps.map(\.term))
    }

    /// Whether the audio supports the term over the phrase Parakeet wrote. Scores are mean log
    /// probabilities per token, so they're compared directly, and the term gets a head start for two
    /// reasons:
    /// - Parakeet was unsure of the phrase: up to 2 for a token it gave no confidence at all. A
    ///   misheard name is rarely written with confidence, an ordinary word that was said usually is.
    /// - The phrase is the term with extra letters inside, as in "Hyperland" or "genome" for
    ///   "Hyprland" or "GNOME": 3. The keyword model scores spelling, so it prefers Parakeet's
    ///   spelling of the same sound. Letters added at either end, as in "Expose" for "Expo", make
    ///   another word, so they don't count.
    /// On about 600 recordings, in synthetic voices and Markus's own, FluidAudio's flat 4.5 put in
    /// 252 terms that weren't said for 300 that were; this puts in 35 for 279.
    nonisolated static func isSupported(_ candidate: VocabularyRescorer.CandidateEvidence, confidences: [Float]) -> Bool {
        guard let termScore = candidate.rawVocabularyCTCScore, let phraseScore = candidate.rawOriginalCTCScore else { return false }
        let confidence = candidate.tokenRange.flatMap { $0.upperBound <= confidences.count ? confidences[$0].min() : nil } ?? 1
        let respelling: Float = isRespelling(candidate.canonicalTerm, of: candidate.basePhrase) ? 3 : 0
        return termScore + 2 * (1 - confidence) + respelling > phraseScore
    }

    /// Whether `phrase` spells `term` with extra letters inside it, ignoring case, spaces, and punctuation.
    nonisolated static func isRespelling(_ term: String, of phrase: String) -> Bool {
        let letters = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let term = letters(term), phrase = letters(phrase)
        guard term.first == phrase.first, term.last == phrase.last, !term.isEmpty else { return false }
        var rest = phrase[...]
        for letter in term {
            guard let match = rest.firstIndex(of: letter) else { return false }
            rest = rest[rest.index(after: match)...]
        }
        return true
    }

    /// A vocabulary word as the keyword model hears it, or nil when the model has no tokens for it.
    /// The model can't spell hyphens, so "grill-with-docs" is scored as spoken, "grill with docs",
    /// and matched against that phrase too. A term of several spoken words needs a close match,
    /// since FluidAudio matches phrases without the guard that keeps a phrase with "with" or "the"
    /// from becoming a term. At 0.75, "the GitHub actions" became "GitHub Actions".
    nonisolated static func keywordTerm(_ text: String, encode: (String) -> [Int]) -> CustomVocabularyTerm? {
        let spoken = text.split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace }).joined(separator: " ")
        let tokens = encode(spoken)
        guard !tokens.isEmpty else { return nil }
        guard spoken.contains(" ") else { return CustomVocabularyTerm(text: text, ctcTokenIds: tokens) }
        return CustomVocabularyTerm(text: text, aliases: spoken == text ? nil : [spoken], ctcTokenIds: tokens, minSimilarity: 0.8)
    }
}
