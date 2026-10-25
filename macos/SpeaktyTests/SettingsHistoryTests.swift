import XCTest
@testable import Speakty

final class SettingsHistoryTests: XCTestCase {
    func testBackAndForwardRetraceVisitsAndANewVisitClearsForward() {
        var history = SettingsHistory()
        XCTAssertNil(history.back(from: .general))

        history.visit(.permissions, from: .general)
        history.visit(.permissions, from: .permissions)
        XCTAssertEqual(history.back(from: .permissions), .general)
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.forward(from: .general), .permissions)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.back(from: .permissions), .general)
        history.visit(.permissions, from: .general)
        XCTAssertFalse(history.canGoForward, "A new visit clears the forward history")
    }
}
