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

    /// Both icons may be hidden; reopening Speakty from Finder or Spotlight shows Settings.
    var isValid: Bool { true }
}
