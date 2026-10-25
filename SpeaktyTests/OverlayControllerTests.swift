import XCTest
@testable import Speakty

@MainActor
final class OverlayControllerTests: XCTestCase {
    private let area = NSRect(x: 0, y: 0, width: 2560, height: 1410)

    func testTheEdgeDistanceSeparatesTheDisplayFromTheBottomEdge() {
        var recording = RecordingPreferences()
        recording.edgeDistance = 40
        XCTAssertEqual(displayArea(recording).minY, 40)
    }

    func testTheEdgeDistanceSeparatesTheDisplayFromTheTopEdge() {
        var recording = RecordingPreferences()
        recording.position = .top
        recording.edgeDistance = 40
        XCTAssertEqual(displayArea(recording).maxY, 1410 - 40)
    }

    /// The part of the panel inside its margin, where the display sits.
    private func displayArea(_ recording: RecordingPreferences) -> NSRect {
        let margin = OverlayController.margin
        return OverlayController.panelFrame(in: area, recording: recording).insetBy(dx: margin, dy: margin)
    }
}
