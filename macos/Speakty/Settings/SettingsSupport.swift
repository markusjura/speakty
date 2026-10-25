import AppKit
import SwiftUI

extension AppearancePreference {
    /// Nil follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension GeneralPreferences {
    var activationPolicy: NSApplication.ActivationPolicy { showsDockIcon ? .regular : .accessory }
}

/// System Settings destinations used by the Settings panes.
enum SystemSettingsLink {
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    /// Falls back to Privacy & Security if a deep link stops resolving.
    static func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.open(privacy) }
    }
}

extension View {
    /// Ends text editing the way native forms do when clicking anywhere outside the field. Left
    /// alone, AppKit keeps the field focused. Return keeps it focused, so words and rules can be
    /// added one after another.
    func endsTextEditingOnClickAway() -> some View {
        background(TextEditingEnder())
    }
}

/// Watches clicks in its window and ends text editing after one outside the field being edited.
private struct TextEditingEnder: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ nsView: MonitorView, context: Context) {}

    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let window = self?.window, event.window === window,
                      let editor = window.firstResponder as? NSText,
                      // The field editor's delegate is the text field being edited.
                      let field = editor.delegate as? NSView,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) else { return event }
                window.makeFirstResponder(nil)
                return event
            }
        }
    }
}
