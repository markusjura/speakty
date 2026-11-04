import FluidAudio
import XCTest
@testable import Speakty

/// The models `Scripts/benchmark.sh` measures. Speakty's own models load as the app loads them. To
/// measure a candidate, add a case and the few lines that load its recognizer.
enum BenchmarkModel: String, CaseIterable {
    case parakeetUltra = "parakeet-ultra"
    case nemotronUnified = "nemotron-unified"

    var title: String {
        switch self {
        case .parakeetUltra: DictationModel.parakeetUltra.title
        case .nemotronUnified: "Nemotron Unified 0.6B, auto language"
        }
    }

    func load() async throws -> Recognizer {
        switch self {
        case .parakeetUltra:
            return try await DictationModel.parakeetUltra.load()
        case .nemotronUnified:
            let manager = UnifiedAsrManager(config: UnifiedConfig(family: .nemotronMultilingual(.auto)))
            try await manager.loadModels()
            return { try await manager.transcribeDetailed($0) }
        }
    }
}

/// Runs only from `Scripts/benchmark.sh`, which names the models, the eval folder, and where the
/// report goes. Every clip runs as a dictation does: silence trimmed, transcribed, vocabulary boosted,
/// and finished as before pasting, with the model warm.
final class BenchmarkTests: XCTestCase {
    func testBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let names = environment["SPEAKTY_BENCHMARK_MODELS"], let eval = environment["SPEAKTY_BENCHMARK_EVAL"],
              let output = environment["SPEAKTY_BENCHMARK_OUTPUT"] else { throw XCTSkip("Scripts/benchmark.sh runs this") }
        let models = try names.split(separator: " ").map { name in
            try XCTUnwrap(BenchmarkModel(rawValue: String(name)),
                          "Unknown model \(name). Known: \(BenchmarkModel.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let set = try EvalSet(folder: URL(filePath: eval))
        let outputFolder = URL(filePath: output)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let keywordModels = set.vocabulary.isEmpty ? nil : try await CtcModels.downloadAndLoad(variant: .ctc110m)

        var rows: [String] = []
        for model in models {
            let recognizer = try await model.load()
            var boosting: VocabularyBoosting?
            if let keywordModels { boosting = try await VocabularyBoosting(terms: set.vocabulary, models: keywordModels) }
            let dictate = { (audio: [Float]) async throws -> String in
                let speech = Transcript.speech(in: audio)
                // Speakty pastes nothing when it hears no speech.
                guard !speech.isEmpty else { return "" }
                let result = try await recognizer(speech)
                let raw = await boosting?.transcript(of: result, audio: speech) ?? result.text
                return Transcript.finishing(raw, vocabulary: set.vocabulary, replacements: [])
            }
            // The recognizer and the keyword model compile their paths on first use.
            for clip in [set.clips.first, set.clips.first { !set.terms(in: $0.reference).isEmpty }].compactMap(\.self) {
                _ = try await dictate(clip.audio)
            }
            var results: [ClipResult] = []
            for clip in set.clips {
                var text = ""
                let elapsed = try await ContinuousClock().measure { text = try await dictate(clip.audio) }
                results.append(ClipResult(clip: clip, text: text, timeToText: elapsed / .seconds(1)))
            }
            rows.append(Report.row(model.title, results, set: set))
            try Report.transcripts(results).write(to: outputFolder.appending(path: "\(model.rawValue)-transcripts.txt"), atomically: true, encoding: .utf8)
        }
        try Report.table(rows, set: set).write(to: outputFolder.appending(path: "report.md"), atomically: true, encoding: .utf8)
    }

    func testScoringNormalizesBothTexts() {
        XCTAssertEqual(Scoring.words("Der T. Rex (1963) kam; „selbst“ zwölf!", language: "de"),
                       ["der", "t", "rex", "eintausendneunhundertdreiundsechzig", "kam", "selbst", "zwölf"])
        XCTAssertEqual(Scoring.words("Hello, World.", language: "en", keepingCase: true), ["Hello", "World"])
        XCTAssertEqual(Scoring.words("Hello, world.", language: "en", keepingPunctuation: true), ["hello", ",", "world", "."])
        XCTAssertEqual(Scoring.words("dividing by 12", language: "en"), Scoring.words("Dividing by twelve", language: "en"))
    }

    func testWordErrorsCountSubstitutionsInsertionsAndDeletions() {
        XCTAssertEqual(Scoring.errors(["a", "b", "c"], ["a", "b", "c"]), 0)
        XCTAssertEqual(Scoring.errors(["a", "x", "c", "d"], ["a", "b", "c"]), 2)
        XCTAssertEqual(Scoring.errors([], ["a", "b"]), 2)
    }
}

/// The eval folder: `<language>-<name>.wav` with what was said in `<language>-<name>.txt`, and the
/// vocabulary, one term per line, in `vocabulary.txt`.
struct EvalSet {
    struct Clip {
        var name: String
        var language: String
        var audio: [Float]
        var reference: String
    }

    var clips: [Clip]
    var vocabulary: [String]

    init(folder: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        clips = try files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { wav in
            let name = wav.deletingPathExtension().lastPathComponent
            guard let dash = name.firstIndex(of: "-") else {
                throw EvalError("\(name).wav needs its language as a prefix, as in de-\(name).wav")
            }
            let text = wav.deletingPathExtension().appendingPathExtension("txt")
            guard let reference = try? String(contentsOf: text, encoding: .utf8) else { throw EvalError("\(name).wav has no \(name).txt") }
            return Clip(name: name, language: String(name[..<dash]), audio: try AudioConverter().resampleAudioFile(wav),
                        reference: reference.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !clips.isEmpty else { throw EvalError("\(folder.path) has no wav and txt pairs") }
        let terms = (try? String(contentsOf: folder.appending(path: "vocabulary.txt"), encoding: .utf8)) ?? ""
        vocabulary = terms.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var languages: [String] { Array(Set(clips.map(\.language))).sorted() }

    /// How often each vocabulary term occurs in `text`, as whole words and ignoring case.
    func terms(in text: String) -> [String: Int] {
        vocabulary.reduce(into: [:]) { counts, term in
            let pattern = #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: term) + #"(?!\w)"#
            let count = (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
                .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
            if count > 0 { counts[term] = count }
        }
    }
}

struct EvalError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct ClipResult {
    var clip: EvalSet.Clip
    var text: String
    /// Seconds from the end of the audio to the final text.
    var timeToText: Double
}

/// Word error rate as FluidAudio's multilingual benchmarks score it: digits spelled out in the
/// clip's language, then lowercased, with punctuation and symbols removed. Unlike FluidAudio, words in
/// brackets stay, since in a dictation they were said.
enum Scoring {
    /// What's left of `text` to score. `keepingCase` keeps capitalization, and `keepingPunctuation`
    /// keeps . , ? ! : ; as words of their own, to score what normalization hides.
    static func words(_ text: String, language: String, keepingCase: Bool = false, keepingPunctuation: Bool = false) -> [String] {
        var text = spellingOutNumbers(text, locale: Locale(identifier: language))
        if !keepingCase { text = text.lowercased() }
        text = text.precomposedStringWithCompatibilityMapping
        let scalars = text.unicodeScalars.flatMap { scalar -> [Unicode.Scalar] in
            if keepingPunctuation, ".,?!:;".unicodeScalars.contains(scalar) { return [" ", scalar, " "] }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .currencySymbol, .mathSymbol, .modifierSymbol, .otherSymbol,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation: return [" "]
            default: return [scalar]
            }
        }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Digits as words, as in "1976" for "neunzehnhundertsechsundsiebzig", since references and
    /// models write numbers either way. Groups split by a space, as in "30 000", are one number.
    static func spellingOutNumbers(_ text: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        return text.replacing(#/\d+(?:[\u00A0\u2007\u2009\u202F ]\d{3})+|\d+/#) { match in
            let digits = match.output.filter(\.isNumber)
            guard let number = Int(digits), let spelled = formatter.string(from: NSNumber(value: number)) else { return String(match.output) }
            // NumberFormatter separates German and Italian morphemes with soft hyphens.
            return spelled.replacing("\u{00AD}", with: "")
        }
    }

    /// The words to substitute, insert, or delete to turn `hypothesis` into `reference`.
    static func errors(_ hypothesis: [String], _ reference: [String]) -> Int {
        var previous = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var current = [i + 1]
            for (j, candidate) in hypothesis.enumerated() {
                current.append(min(previous[j] + (word == candidate ? 0 : 1), previous[j + 1] + 1, current[j] + 1))
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    /// Errors per reference word over all `results`, so long clips weigh more.
    static func wordErrorRate(_ results: [ClipResult], keepingCase: Bool = false, keepingPunctuation: Bool = false) -> Double {
        let counts = results.map { result in
            let words = { (text: String) in
                Self.words(text, language: result.clip.language, keepingCase: keepingCase, keepingPunctuation: keepingPunctuation)
            }
            let reference = words(result.clip.reference)
            return (errors: errors(words(result.text), reference), words: reference.count)
        }
        return Double(counts.map(\.errors).reduce(0, +)) / Double(max(1, counts.map(\.words).reduce(0, +)))
    }
}

enum Report {
    static func row(_ title: String, _ results: [ClipResult], set: EvalSet) -> String {
        let percent = { (rate: Double) in String(format: "%.1f%%", rate * 100) }
        let byLanguage = set.languages.map { language in percent(Scoring.wordErrorRate(results.filter { $0.clip.language == language })) }
        var said = 0, written = 0, extra = 0
        for result in results {
            let reference = set.terms(in: result.clip.reference), hypothesis = set.terms(in: result.text)
            for term in set.vocabulary {
                said += reference[term, default: 0]
                written += min(reference[term, default: 0], hypothesis[term, default: 0])
                extra += max(0, hypothesis[term, default: 0] - reference[term, default: 0])
            }
        }
        let cells = [title, percent(Scoring.wordErrorRate(results))] + byLanguage + [
            percent(Scoring.wordErrorRate(results, keepingCase: true)),
            percent(Scoring.wordErrorRate(results, keepingPunctuation: true)),
            "\(written)/\(said), \(extra) extra", seconds(median(results.map(\.timeToText))),
        ]
        return "| \(cells.joined(separator: " | ")) |"
    }

    static func table(_ rows: [String], set: EvalSet) -> String {
        let audio = median(set.clips.map { Double($0.audio.count) / Double(Transcript.sampleRate) })
        let counts = set.languages.map { language in "\(set.clips.filter { $0.language == language }.count) \(language)" }
        let columns = ["Model", "WER"] + set.languages.map { "WER \($0)" } + ["Cased", "Punctuated", "Vocabulary", "Time-to-text"]
        return """
            \(set.clips.count) clips (\(counts.joined(separator: ", "))), median \(seconds(audio)) of audio, \(set.vocabulary.count) vocabulary terms.

            | \(columns.joined(separator: " | ")) |
            |\(String(repeating: "---|", count: columns.count))
            \(rows.joined(separator: "\n"))

            WER is scored after normalizing both texts as FluidAudio's multilingual benchmarks do: digits spelled out, lowercased, punctuation and symbols removed. docs/benchmark.md explains the columns.

            """
    }

    static func transcripts(_ results: [ClipResult]) -> String {
        results.map { result in
            let reference = Scoring.words(result.clip.reference, language: result.clip.language)
            let errors = Scoring.errors(Scoring.words(result.text, language: result.clip.language), reference)
            return "\(result.clip.name): \(errors)/\(reference.count) word errors, \(seconds(result.timeToText))\n"
                + "  said:  \(result.clip.reference)\n  wrote: \(result.text)\n"
        }.joined(separator: "\n")
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }
}
