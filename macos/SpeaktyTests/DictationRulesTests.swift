import XCTest
@testable import Speakty

@MainActor
final class DictationRulesTests: XCTestCase {
    private let start = ContinuousClock.now
    private var held: DictationController.Phase { .recording(.held(since: start)) }

    private func action(_ event: HotkeyMonitor.Event, _ phase: DictationController.Phase, after ms: Int = 0,
                        _ mode: ShortcutMode = .holdOrTap) -> DictationController.Action {
        DictationController.action(for: event, in: phase, mode: mode, at: start + .milliseconds(ms))
    }

    func testAHoldRecordsUntilItsRelease() {
        XCTAssertEqual(action(.pressed, .idle), .start(.held(since: start)))
        XCTAssertEqual(action(.released, held, after: 900), .stop)
    }

    func testATapRecordsUntilTheNextPress() {
        XCTAssertEqual(action(.released, held, after: 120), .latch)
        XCTAssertEqual(action(.pressed, .recording(.latched)), .stop)
    }

    func testTheModeDecidesWhatAReleaseDoes() {
        XCTAssertEqual(action(.released, held, after: 120, .hold), .stop)
        XCTAssertEqual(action(.released, held, after: 900, .tap), .latch)
    }

    /// Right ⌘C discards the dictation its press started instead of pasting.
    func testAShortcutTypedWithTheHeldKeyCancels() {
        XCTAssertEqual(action(.interrupted, held), .cancel)
        XCTAssertEqual(action(.interrupted, .recording(.latched)), .ignore)
    }

    func testCancelAndSendWorkUntilThePaste() {
        XCTAssertEqual(action(.cancel, held), .cancel)
        XCTAssertEqual(action(.cancel, .transcribing), .cancel)
        XCTAssertEqual(action(.send, .recording(.latched)), .send)
        XCTAssertEqual(action(.send, .transcribing), .send)
        XCTAssertEqual(action(.send, .idle), .ignore)
        XCTAssertEqual(action(.pressed, .transcribing), .ignore)
    }
}
