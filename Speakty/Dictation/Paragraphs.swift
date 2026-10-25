import Foundation

/// Smart paragraphs: a long transcript is split at the sentence boundaries that read best as
/// paragraph breaks, and a spoken "new paragraph" breaks exactly where it was said. Pure functions,
/// like the rest of `Transcript`.
extension Transcript {
    /// Below this, a transcript is a message, not a text with paragraphs, and stays one paragraph.
    static let paragraphMinimumWords = 50
    /// The paragraph length, in words, that costs nothing. Longer and shorter ones cost more the
    /// further they're off, so a long text splits into even paragraphs instead of full ones and a stub.
    static let paragraphTargetWords = 50.0

    /// `text` with blank lines between paragraphs. Breaks go between sentences, where they minimize
    /// the paragraphs' length costs less each break's strength. An opening that changes the topic,
    /// such as "Also," or "Außerdem", strengthens a break; one that continues, such as "But" or
    /// "Weil", weakens it. Line breaks already in the text, such as from "new paragraph", stay and
    /// always end a paragraph. Pauses aren't used: a pause to think is as long as a pause between
    /// topics, and Parakeet often ends a sentence at either.
    static func paragraphs(_ text: String) -> String {
        let sentences = sentences(in: text)
        let words = sentences.map { wordCount(text[$0]) }
        guard sentences.count > 1, words.reduce(0, +) >= paragraphMinimumWords else { return text }
        let gaps = zip(sentences, sentences.dropFirst()).map { text[$0.upperBound..<$1.lowerBound] }
        let isKept = gaps.map { $0.contains(where: \.isNewline) }
        // strength[k] is how well gap k, before sentence k + 1, reads as a paragraph break.
        let strength = gaps.indices.map { openingStrength(text[sentences[$0 + 1]]) }

        // best[i] is the lowest cost of sentences 0..<i, and start[i] where its last paragraph starts.
        var best = [0.0] + Array(repeating: Double.infinity, count: sentences.count)
        var start = Array(repeating: 0, count: sentences.count + 1)
        for end in 1...sentences.count {
            var length = 0
            for first in stride(from: end - 1, through: 0, by: -1) {
                length += words[first]
                let lengthCost = pow((Double(length) - paragraphTargetWords) / paragraphTargetWords, 2)
                let breakBonus = first > 0 && !isKept[first - 1] ? strength[first - 1] : 0
                let cost = best[first] + lengthCost - breakBonus
                if cost < best[end] { best[end] = cost; start[end] = first }
                // A paragraph doesn't reach across a line break that's already there.
                if first > 0, isKept[first - 1] { break }
            }
        }
        var breaks = Set<Int>()
        var end = sentences.count
        while end > 0 { end = start[end]; if end > 0 { breaks.insert(end - 1) } }

        var result = String(text[..<sentences[0].lowerBound])
        for (index, sentence) in sentences.enumerated() {
            result += text[sentence]
            if index < gaps.count { result += breaks.contains(index) && !isKept[index] ? "\n\n" : String(gaps[index]) }
        }
        return result + text[sentences[sentences.count - 1].upperBound...]
    }

    /// Replaces each spoken "new paragraph" or "neuer Absatz" with a blank line. The sentence before
    /// it is ended with a period, keeping a "?" or "!" Parakeet put there, and the next one is
    /// capitalized, so the command may interrupt a sentence. After a word such as "a" or "ein", as in
    /// "start a new paragraph", the phrase is meant literally and stays.
    static func applyingParagraphCommands(to text: String) -> String {
        var result = ""
        var rest = text[...]
        // 1 is the punctuation and spaces before the phrase, 2 the phrase, and 3 the punctuation after.
        while let match = rest.firstMatch(of: /([\s,.;:!?]*)\b((?i:new paragraph|neuer absatz))\b([.,;:!?]*)\s*/) {
            let head = result + rest[..<match.range.lowerBound]
            let precedingWord = head.split(whereSeparator: \.isWhitespace).last?.lowercased()
            if match.1.allSatisfy(\.isWhitespace), let precedingWord, literalPrefixes.contains(precedingWord) {
                result = head + rest[match.range.lowerBound..<match.2.endIndex]
                rest = rest[match.2.endIndex...]
                continue
            }
            // A sentence still open, also before a closing bracket or quote, gets the "?" or "!" said
            // around the command, or a period. Commas and colons go.
            let last = head.last { !")]\"'”’“‘»«".contains($0) }
            let isOpen = last.map { !$0.isWhitespace && !".?!…".contains($0) } ?? false
            let ending = isOpen ? (match.1 + match.3).first { "?!".contains($0) }.map(String.init) ?? "." : ""
            result = head + ending + "\n\n"
            let next = rest[match.range.upperBound...]
            rest = Substring(next.prefix(1).uppercased() + next.dropFirst())
        }
        return result + rest
    }

    /// Words after which "new paragraph" is part of the sentence.
    private static let literalPrefixes: Set = [
        "a", "an", "the", "this", "that", "another", "one", "each", "every", "no", "any", "my", "your", "his",
        "her", "its", "our", "their", "ein", "kein", "mein", "dein", "sein", "ihr", "unser", "euer",
    ]

    private static func wordCount(_ text: Substring) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Positive for a sentence that opens a new topic, negative for one that continues the last.
    private static func openingStrength(_ sentence: Substring) -> Double {
        // Without commas, so "Okay, so" opens like "Okay so".
        let opening = sentence.lowercased().replacingOccurrences(of: ",", with: "")
        let opens = { (phrases: [String]) in
            phrases.contains { phrase in
                opening.hasPrefix(phrase) && !(opening.dropFirst(phrase.count).first?.isLetter ?? false)
            }
        }
        if opens(topicOpenings) { return 0.25 }
        if opens(continuingOpenings) { return -0.3 }
        return 0
    }

    private static let topicOpenings = [
        "also", "anyway", "another thing", "besides", "by the way", "finally", "first", "firstly", "second",
        "secondly", "third", "thirdly", "lastly", "in addition", "in summary", "to summarize", "overall",
        "moving on", "next", "on another note", "speaking of", "okay so", "ok so", "all right", "alright",
        "außerdem", "zudem", "darüber hinaus", "übrigens", "abschließend", "zum schluss", "zusammenfassend",
        "insgesamt", "erstens", "zweitens", "drittens", "als nächstes", "ansonsten", "noch etwas", "okay also",
    ]

    private static let continuingOpenings = [
        "and", "or", "but", "because", "which", "so that", "for example", "for instance", "that means",
        "und", "oder", "aber", "weil", "denn", "sondern", "zum beispiel", "das heißt", "deshalb", "deswegen",
    ]
}
