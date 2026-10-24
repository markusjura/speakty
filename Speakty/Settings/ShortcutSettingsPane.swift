import SwiftUI

struct ShortcutSettingsPane: View {
    @Bindable var preferences: AppPreferences
    let permissions: Permissions
    let hotkeys: HotkeyMonitor

    var body: some View {
        Form {
            Section("Dictation") {
                HStack {
                    Text("Hold to dictate")
                    Spacer()
                    ShortcutRecorder(shortcut: $preferences.recording.shortcut, hotkeys: hotkeys).fixedSize()
                }
                .settingsRowWarning(warning) {
                    if needsAccess { Button("Allow…") { permissions.requestAccessibility() }.controlSize(.small) }
                }
            }
        }
    }

    private var needsAccess: Bool { preferences.recording.shortcut.needsAccessibility && !permissions.isAccessibilityTrusted }

    /// What keeps the shortcut from working, if anything.
    private var warning: String? {
        let shortcut = preferences.recording.shortcut
        if needsAccess { return "Needs Accessibility access." }
        if hotkeys.isTaken { return "Another app or macOS already uses this shortcut." }
        // macOS treats a press of 🌐 as its own shortcut unless it's set to do nothing.
        if shortcut == .modifierKey(.function), UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") != 0 {
            return "Set “Press 🌐 key to” Do Nothing in System Settings > Keyboard."
        }
        return nil
    }
}
