import XCTest
@testable import Speakty

@MainActor
final class AppPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "AppPreferencesTests")
        defaults.removePersistentDomain(forName: "AppPreferencesTests")
    }

    func testAKeyShortcutReplacesTheDefaultModifierKeyAfterRelaunch() {
        let shortcut = Shortcut.key(49, [.control, .option])
        AppPreferences(defaults: defaults).recording.shortcut = shortcut
        XCTAssertEqual(AppPreferences(defaults: defaults).recording.shortcut, shortcut,
                       "A stored enum case replaces the default case instead of merging with it")
    }

    func testTheDarkStyleLoadsFromItsFormerNameMinimal() throws {
        defaults.set(try JSONSerialization.data(withJSONObject: ["style": "minimal", "position": "top"]),
                     forKey: "preferences.v1.recording")
        let recording = AppPreferences(defaults: defaults).recording
        XCTAssertEqual(recording.style, .dark)
        XCTAssertEqual(recording.position, .top, "The rest of the stored section survives")
    }

    func testAnInvalidReplacementIsRejected() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.transcript.replacements = [Replacement(find: "(", replacement: "", isPattern: true)]
        XCTAssertTrue(preferences.transcript.replacements.isEmpty)
    }
}
