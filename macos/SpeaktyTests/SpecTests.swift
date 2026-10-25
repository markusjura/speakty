import XCTest
@testable import Speakty

/// Runs the cases in spec/transcript-cases.json, which the Linux app's tests run too.
final class SpecTests: XCTestCase {
    private struct Case: Decodable {
        var name: String?
        var input: String
        var output: String
    }

    private struct Rule: Decodable {
        var find: String
        var replacement: String
        var isPattern: Bool?
    }

    private struct ReplacementCase: Decodable {
        var name: String?
        var rules: [Rule]
        var input: String
        var output: String
    }

    private struct FittingCase: Decodable {
        var name: String?
        var text: String
        var before: String?
        var output: String
    }

    private struct Spec: Decodable {
        var replacements: [ReplacementCase]
        var fitting: [FittingCase]
        var fittingNames: [String]
        var closing: [Case]
        var paragraphCommands: [Case]
        var paragraphs: [Case]
    }

    private static let spec: Spec = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../spec/transcript-cases.json").standardizedFileURL
        return try! JSONDecoder().decode(Spec.self, from: Data(contentsOf: url))
    }()

    func testReplacements() {
        for test in Self.spec.replacements {
            let rules = test.rules.map { Replacement(find: $0.find, replacement: $0.replacement, isPattern: $0.isPattern ?? false) }
            XCTAssertEqual(Transcript.applying(rules, to: test.input), test.output, test.name ?? test.input)
        }
    }

    func testFitting() {
        for test in Self.spec.fitting {
            XCTAssertEqual(Transcript.fitting(test.text, after: test.before, keepingCaseOf: Self.spec.fittingNames), test.output,
                           test.name ?? test.text)
        }
    }

    func testClosing() {
        for test in Self.spec.closing { XCTAssertEqual(Transcript.closing(test.input), test.output, test.name ?? test.input) }
    }

    func testParagraphCommands() {
        for test in Self.spec.paragraphCommands {
            XCTAssertEqual(Transcript.applyingParagraphCommands(to: test.input), test.output, test.name ?? test.input)
        }
    }

    func testParagraphs() {
        for test in Self.spec.paragraphs { XCTAssertEqual(Transcript.paragraphs(test.input), test.output, test.name ?? test.input) }
    }
}
