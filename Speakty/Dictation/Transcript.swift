import Foundation

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

    /// Fits a transcript to the text before the caret. Mid-line it gets a leading space, and
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
        if let last = line.last, !last.isWhitespace, !"([{\"'“‘/".contains(last), !",.;:!?)]}…".contains(first) {
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
