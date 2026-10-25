import XCTest
@testable import Speakty

@MainActor
final class DictationRulesTests: XCTestCase {
    private let start: TimeInterval = 1000

    private func action(_ event: HotkeyMonitor.Event, _ phase: DictationController.Phase) -> DictationController.Action {
        DictationController.action(for: event, in: phase)
    }

    func testAHoldRecordsUntilItsRelease() {
        XCTAssertEqual(action(.pressed(at: start), .idle), .start(.held(since: start)))
        XCTAssertEqual(action(.released(at: start + 0.9), .recording(.held(since: start))), .stop)
        XCTAssertEqual(action(.interrupted, .recording(.held(since: start))), .cancel)
    }

    func testATapRecordsUntilTheNextTapEnds() {
        XCTAssertEqual(action(.released(at: start + 0.12), .recording(.held(since: start))), .become(.latched))
        XCTAssertEqual(action(.pressed(at: start + 2), .recording(.latched)), .become(.ending))
        XCTAssertEqual(action(.released(at: start + 2.1), .recording(.ending)), .stop)
    }

    /// Right ⌘C pressed while a tap's recording runs discards it instead of pasting.
    func testAShortcutTypedWithTheEndingTapCancels() {
        XCTAssertEqual(action(.interrupted, .recording(.ending)), .cancel)
    }

    func testEscapeCancelsUntilThePaste() {
        XCTAssertEqual(action(.escape, .recording(.latched)), .cancel)
        XCTAssertEqual(action(.escape, .transcribing), .cancel)
        XCTAssertEqual(action(.escape, .idle), .ignore)
        XCTAssertEqual(action(.pressed(at: start), .transcribing), .ignore)
    }
}
