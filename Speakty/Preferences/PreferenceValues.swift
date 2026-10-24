import Foundation

// Typed, persisted preference sections. Each section is one Codable value stored by
// AppPreferences; `isValid` rejects writes that would leave the app unusable.

enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

struct GeneralPreferences: Codable, Equatable, Sendable {
    var appearance = AppearancePreference.system
    /// Off gives the Settings sidebar an opaque fill instead of the desktop showing through.
    var usesTranslucentSidebar = true
    var showsMenuBarIcon = true
    var showsDockIcon = false
    /// A soft tick when dictation starts and when the text lands.
    var playsSounds = true

    /// Both icons may be hidden; reopening Speakty from Finder or Spotlight shows Settings.
    var isValid: Bool { true }
}

/// How the recording display looks. Each style shows the voice level while listening and moves
/// differently while transcribing.
enum OverlayStyle: String, Codable, CaseIterable, Sendable {
    /// Level bars in a small dark capsule.
    case minimal
    /// A scrolling waveform in a Liquid Glass capsule.
    case glass
    /// A glowing ring that breathes with the voice.
    case orb
}

enum OverlayPosition: String, Codable, CaseIterable, Sendable { case bottom, top }

struct RecordingPreferences: Codable, Equatable, Sendable {
    var shortcut = Shortcut.default
    var style = OverlayStyle.minimal
    var position = OverlayPosition.bottom
    /// The Core Audio UID of the chosen microphone; nil follows the system default input.
    var microphoneUID: String?
    var mutesAudio = true

    var isValid: Bool { true }
}

struct TranscriptPreferences: Codable, Equatable, Sendable {
    /// Names and terms recognition should lean toward, newest first.
    var vocabulary: [String] = []
    /// Applied top to bottom after recognition.
    var replacements: [Replacement] = []
    /// Adds a leading space and lowercases the first word to match the text before the caret.
    var matchesSurroundingText = true

    var isValid: Bool { replacements.allSatisfy(\.isValid) }
}
