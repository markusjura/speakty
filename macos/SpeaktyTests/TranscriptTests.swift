import XCTest
@testable import Speakty

final class TranscriptTests: XCTestCase {
    func testInvalidPatternsAreRejected() {
        let broken = Replacement(find: "(unclosed", replacement: "x", isPattern: true)
        XCTAssertFalse(broken.isValid)
        XCTAssertFalse(TranscriptPreferences(replacements: [broken]).isValid)
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
}
