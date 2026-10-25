import SwiftUI

struct ShortcutSettingsPane: View {
    @Bindable var preferences: AppPreferences
    let permissions: Permissions
    let hotkeys: HotkeyMonitor
    /// The command that already uses a shortcut just recorded for another, which keeps its own.
    @State private var conflicts: [DictationCommand: DictationCommand] = [:]

    var body: some View {
        Form {
            Section("Dictation") {
                row(.dictate) {
                    Picker("Mode", selection: $preferences.recording.shortcutMode) {
                        Text("Hold or tap").tag(ShortcutMode.holdOrTap)
                        Text("Hold").tag(ShortcutMode.hold)
                        Text("Tap").tag(ShortcutMode.tap)
                    }
                    .labelsHidden()
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
                .settingsRowWarning(conflict(.dictate) ?? dictateWarning) {
                    if conflicts[.dictate] == nil, needsAccess {
                        Button("Allow…") { permissions.requestAccessibility() }.controlSize(.small)
                    }
                }
                row(.cancel).settingsRowWarning(conflict(.cancel))
                row(.send).settingsRowWarning(conflict(.send))
                Button("Restore Defaults") {
                    // All at once, since restoring one shortcut at a time could clash with one not restored yet.
                    let defaults = RecordingPreferences()
                    var recording = preferences.recording
                    recording.shortcutMode = defaults.shortcutMode
                    for command in DictationCommand.allCases { recording[command] = defaults[command] }
                    preferences.recording = recording
                    conflicts = [:]
                }
            }
        }
    }

    /// The command's title and recorder on one line, with optional controls before the recorder.
    private func row(_ command: DictationCommand, @ViewBuilder controls: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Text(command.title)
            Spacer()
            controls()
            ShortcutRecorder(command: command, shortcut: preferences.recording[command], hotkeys: hotkeys) { assign($0, to: command) }
                .fixedSize()
        }
    }

    private func assign(_ shortcut: Shortcut?, to command: DictationCommand) {
        conflicts[command] = shortcut.flatMap { preferences.recording.command(using: $0, besides: command) }
        if conflicts[command] == nil { preferences.recording[command] = shortcut }
    }

    private func conflict(_ command: DictationCommand) -> String? {
        conflicts[command].map { "Already used by \($0.title)." }
    }

    private var needsAccess: Bool { preferences.recording.shortcut.needsAccessibility && !permissions.isAccessibilityTrusted }

    /// What keeps the dictation shortcut from working, if anything.
    private var dictateWarning: String? {
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
