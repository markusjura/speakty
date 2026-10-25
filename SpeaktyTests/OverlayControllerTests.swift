import XCTest
@testable import Speakty

@MainActor
final class OverlayControllerTests: XCTestCase {
    private let area = NSRect(x: 0, y: 0, width: 2560, height: 1410)

    func testTheEdgeDistanceSeparatesThePanelFromTheBottomEdge() {
        var recording = RecordingPreferences()
        recording.edgeDistance = 40
        XCTAssertEqual(OverlayController.panelFrame(in: area, recording: recording).minY, 40)
    }

    func testTheEdgeDistanceSeparatesThePanelFromTheTopEdge() {
        var recording = RecordingPreferences()
        recording.position = .top
        recording.edgeDistance = 40
        XCTAssertEqual(OverlayController.panelFrame(in: area, recording: recording).maxY, 1410 - 40)
    }
}
