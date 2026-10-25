import SwiftUI

/// Status follows `Permissions`, which re-reads access whenever Speakty becomes active.
struct PermissionSettingsPane: View {
    let permissions: Permissions

    var body: some View {
        Form {
            Section("Microphone") {
                let microphone = permissions.microphone
                status(microphone == .authorized, missing: microphone == .notDetermined ? "Not requested" : "Not allowed")
                if microphone == .notDetermined {
                    Button("Request Access") { Task { _ = await permissions.requestMicrophone() } }
                } else if microphone != .authorized {
                    Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.microphone) }
                }
            }
            Section("Accessibility") {
                status(permissions.isAccessibilityTrusted, missing: "Not allowed")
                    .settingsRowNote("Needed to paste and for shortcuts such as Right ⌘.")
                if !permissions.isAccessibilityTrusted {
                    HStack {
                        Button("Request Access") { permissions.requestAccessibility() }
                        Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.accessibility) }
                    }
                }
            }
        }
    }

    /// A status row with an outlined green checkmark when granted, or a gray cross.
    /// Both glyphs are outlined circles of one size, so the row keeps its alignment when the status changes.
    private func status(_ ok: Bool, missing: String) -> some View {
        LabeledContent("Status") {
            Label {
                Text(ok ? "Allowed" : missing)
            } icon: {
                Image(systemName: ok ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(ok ? SettingsColor.success : SettingsColor.secondaryText)
            }
            .foregroundStyle(ok ? SettingsColor.primaryText : SettingsColor.secondaryText)
        }
    }
}
