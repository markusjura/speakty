import AppKit
import SwiftUI

/// Design tokens for Speakty's floating chrome, the recording display. It sits over whatever the
/// user is typing in, so the dark styles keep fixed dark island colors in both appearances.
/// Settings draws its own colors, in SettingsTheme.
@MainActor
enum Chrome {
    /// The recording display sits just below the cursor: above app windows, full-screen apps,
    /// the menu bar, and other apps' floating panels.
    static let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 2)

    /// The dark island capsule behind the recording display.
    static let islandFill = Color(white: 0.12, opacity: 0.9)
    static let islandRim = Color(white: 1, opacity: 0.16)
    static let islandLabel = Color(white: 0.96)

    /// The orb's ring, after the system accent hues.
    static let orbGradient = AngularGradient(colors: [
        Color(red: 0.04, green: 0.52, blue: 1), Color(red: 0.37, green: 0.36, blue: 0.9), Color(red: 0.75, green: 0.35, blue: 0.95),
        Color(red: 1, green: 0.22, blue: 0.37), Color(red: 1, green: 0.62, blue: 0.04), Color(red: 0.04, green: 0.52, blue: 1),
    ], center: .center)

    static let fadeDuration: TimeInterval = 0.15
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
