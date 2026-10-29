import Foundation
import NaturalLanguage

/// A find-and-replace rule applied to every transcript. Plain text matches whole words and ignores
/// case; a pattern is a regular expression whose replacement uses $1 for its groups.
struct Replacement: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var find: String
    var replacement: String
    var isPattern = false

    /// Nil when `find` is empty or not a valid pattern.
    var expression: NSRegularExpression? {
        guard !find.isEmpty else { return nil }
        if isPattern { return try? NSRegularExpression(pattern: find) }
        // Lookarounds instead of \b, so a rule may start or end with a non-word character, as in "co-dex".
        return try? NSRegularExpression(pattern: #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: find) + #"(?!\w)"#,
                                        options: .caseInsensitive)
    }

    var isValid: Bool { expression != nil }
}

/// The steps between recognition and paste. Pure functions, so their rules are tested directly.
enum Transcript {
    static let sampleRate = 16_000

    /// The speech in a recording: leading and trailing silence trimmed, keeping a little margin, then
    /// half a second of silence appended, without which Parakeet can drop a fast final word. Empty
    /// when nothing louder than room noise was recorded.
    static func speech(in samples: [Float]) -> [Float] {
        let frame = sampleRate / 50
        let levels = stride(from: 0, to: samples.count, by: frame).map { start in
            let chunk = samples[start..<min(start + frame, samples.count)]
            return (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        }
        let loudest = levels.max() ?? 0
        let threshold = max(0.004, loudest * 0.05)
        guard loudest >= 0.01, let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold }) else { return [] }
        let start = max(0, first - 10) * frame
        let end = min(samples.count, (last + 16) * frame)
        return Array(samples[start..<end]) + [Float](repeating: 0, count: sampleRate / 2)
    }

    static func applying(_ replacements: [Replacement], to text: String) -> String {
        replacements.reduce(text) { text, rule in
            guard let expression = rule.expression else { return text }
            let template = rule.isPattern ? rule.replacement : NSRegularExpression.escapedTemplate(for: rule.replacement)
            return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
    }

    /// Spells each vocabulary term as it was typed wherever the transcript has it in another case or
    /// with other separators, as in "Pipewire" for "PipeWire" or "grill with docs" for
    /// "grill-with-docs". Where terms start at the same word, the longer one wins.
    static func spelling(_ text: String, as vocabulary: [String]) -> String {
        let isSeparator = { (character: Character) in character == "-" || character == "_" || character.isWhitespace }
        let terms = vocabulary.filter { $0.contains { !isSeparator($0) } }.sorted { $0.count > $1.count }
        // Only separators between words may differ; those at the edges, as in "--verbose", belong to the term.
        let alternatives = terms.map { term in
            let lead = term.prefix(while: isSeparator)
            let trail = term.reversed().prefix(while: isSeparator).count
            let words = term.dropFirst(lead.count).dropLast(trail).split(whereSeparator: isSeparator)
            return "(" + NSRegularExpression.escapedPattern(for: String(lead))
                + words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[-_\s]+"#)
                + NSRegularExpression.escapedPattern(for: String(term.suffix(trail))) + ")"
        }
        guard !terms.isEmpty, let expression = try? NSRegularExpression(
            pattern: #"(?<!\w)(?:"# + alternatives.joined(separator: "|") + #")(?!\w)"#, options: .caseInsensitive) else { return text }
        var result = ""
        var rest = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let term = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }).map({ terms[$0 - 1] })
            else { continue }
            result += text[rest..<range.lowerBound] + term
            rest = range.upperBound
        }
        return result + text[rest...]
    }

    /// Ends a transcript of several sentences with a period when the last one is left open, as Parakeet
    /// does when speech stops without the voice falling. A transcript of one phrase stays open, since
    /// it may be a search, a name, or the middle of a sentence.
    static func closing(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber, sentences(in: text).count > 1 else { return text }
        return text + "."
    }

    /// The sentences of `text`, without the whitespace between them. The tokenizer knows
    /// abbreviations, so "Dr. Smith" is one sentence.
    static func sentences(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) { tokenizer.setLanguage(language) }
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).compactMap { range in
            text[range].lastIndex { !$0.isWhitespace }.map { range.lowerBound..<text.index(after: $0) }
        }
    }

    /// Swaps each recognized phrase for the vocabulary term that replaced it. FluidAudio's rescored
    /// text drops the punctuation after a replaced phrase, as in "speak to, please" becoming
    /// "Speakty please"; this keeps it. FluidAudio replaces a phrase where it was spoken, not where it
    /// appears in the text, so this is nil, and FluidAudio's text is used, unless every occurrence of a
    /// phrase was replaced by the same term.
    static func correcting(_ text: String, _ corrections: [(phrase: String, term: String)]) -> String? {
        var swaps: [(range: Range<String.Index>, term: String)] = []
        let groups = Dictionary(grouping: corrections) { $0.phrase.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
        for (phrase, group) in groups {
            let terms = Set(group.map(\.term))
            guard !phrase.isEmpty, terms.count == 1, let term = terms.first,
                  let expression = try? NSRegularExpression(pattern: #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?!\w)"#)
            else { return nil }
            let ranges = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
            guard ranges.count == group.count else { return nil }
            swaps += ranges.map { ($0, term) }
        }
        swaps.sort { $0.range.lowerBound < $1.range.lowerBound }
        guard zip(swaps, swaps.dropFirst()).allSatisfy({ $0.range.upperBound <= $1.range.lowerBound }) else { return nil }
        var result = ""
        var rest = text.startIndex
        for swap in swaps {
            result += text[rest..<swap.range.lowerBound] + swap.term
            rest = swap.range.upperBound
        }
        return result + text[rest...]
    }

    /// Fits a transcript to the text before the caret. Mid-line it gets a leading space, unless it starts with a line break, and
    /// mid-sentence a capitalized first word is lowercased, unless it's "I", an acronym, or starts a
    /// name from `names`. At the start of a line, or when the text before the caret is unknown, it's unchanged.
    static func fitting(_ text: String, after preceding: String?, keepingCaseOf names: [String]) -> String {
        let line = preceding?.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        guard let before = line.last(where: { !$0.isWhitespace }), let first = text.first else { return text }
        var result = text
        let word = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        let isPlainCapitalized = first.isUppercase && word.count > 1 && word.dropFirst().allSatisfy { !$0.isUppercase }
            && !word.hasPrefix("I'") && !word.hasPrefix("I’") && !names.contains { startsWithName(text, $0) }
        if !".!?:".contains(before), isPlainCapitalized {
            result = first.lowercased() + text.dropFirst()
        }
        if let last = line.last, !last.isWhitespace, !"([{\"'“‘/".contains(last), !",.;:!?)]}…".contains(first), !first.isNewline {
            result = " " + result
        }
        return result
    }

    /// Whether `text` starts with `name`, ignoring case, followed by a word boundary.
    private static func startsWithName(_ text: String, _ name: String) -> Bool {
        guard !name.isEmpty, let range = text.range(of: name, options: [.caseInsensitive, .anchored]) else { return false }
        return text[range.upperBound...].first.map { !$0.isLetter && !$0.isNumber } ?? true
    }
}
