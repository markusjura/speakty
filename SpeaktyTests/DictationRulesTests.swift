import XCTest
@testable import Speakty

@MainActor
final class DictationRulesTests: XCTestCase {
    private let start = ContinuousClock.now

    private func action(_ event: HotkeyMonitor.Event, _ phase: DictationController.Phase, after ms: Int = 0) -> DictationController.Action {
        DictationController.action(for: event, in: phase, at: start + .milliseconds(ms))
    }

    func testAHoldRecordsUntilItsRelease() {
        XCTAssertEqual(action(.pressed, .idle), .start(.held(since: start)))
        XCTAssertEqual(action(.released, .recording(.held(since: start)), after: 900), .stop)
        XCTAssertEqual(action(.interrupted, .recording(.held(since: start))), .cancel)
    }

    func testATapRecordsUntilTheNextTapEnds() {
        XCTAssertEqual(action(.released, .recording(.held(since: start)), after: 120), .become(.latched))
        XCTAssertEqual(action(.pressed, .recording(.latched)), .become(.ending))
        XCTAssertEqual(action(.released, .recording(.ending)), .stop)
    }

    /// Right ⌘C pressed while a tap's recording runs discards it instead of pasting.
    func testAShortcutTypedWithTheEndingTapCancels() {
        XCTAssertEqual(action(.interrupted, .recording(.ending)), .cancel)
    }

    func testEscapeCancelsUntilThePaste() {
        XCTAssertEqual(action(.escape, .recording(.latched)), .cancel)
        XCTAssertEqual(action(.escape, .transcribing), .cancel)
        XCTAssertEqual(action(.escape, .idle), .ignore)
        XCTAssertEqual(action(.pressed, .transcribing), .ignore)
    }
}
