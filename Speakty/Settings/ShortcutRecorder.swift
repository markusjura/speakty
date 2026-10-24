import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records the dictation shortcut, drawn like Raycast's hotkey recorder: plain text at rest, a thin
/// border on hover, and a thick accent border while recording. Click, Space, or Return starts
/// recording; Escape cancels. It takes a modifier key pressed and let go on its own, such as
/// Right ⌘, or a key with modifiers. The dictation shortcut pauses meanwhile, so it can be re-recorded.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    let hotkeys: HotkeyMonitor

    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton() }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onRecordingChange = { [hotkeys] in hotkeys.isPaused = $0 }
        button.onRecord = { shortcut = $0 }
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.stopRecording() }
}

final class ShortcutRecorderButton: NSButton {
    var onRecord: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var shortcut = Shortcut.default { didSet { if shortcut != oldValue { refresh() } } }
    private var isRecording = false
    private var resignObservation: NSObjectProtocol?
    /// Modifier keys down now, and every one pressed since none were: a single key let go alone
    /// becomes the shortcut.
    private var heldKeys: Set<ModifierKey> = []
    private var pressedKeys: Set<ModifierKey> = []
    private var isHovering = false { didSet { needsDisplay = true } }

    // Raycast's hotkey recorder colors, except the recording border.
    private static let valueColor = NSColor.settings(light: 0x000000, dark: 0xFFFFFF)
    private static let placeholderColor = NSColor.settings(light: 0x959595, dark: 0x757575)
    private static let hoverBorder = NSColor.settings(light: 0xC7C7C7, dark: 0x474747)
    private static let font = NSFont.systemFont(ofSize: 13)
    /// The visible box is 142 × 26 pt; the view is 1 pt larger on each side for the recording border.
    private static let boxInset: CGFloat = 1
    private static let textInset: CGFloat = 8

    init() {
        super.init(frame: .zero)
        isBordered = false
        // The recording border marks focus instead.
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        toolTip = "Click, then press a modifier key such as Right ⌘, or a key with modifiers. Escape cancels."
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 144, height: 28) }

    private var box: NSRect { bounds.insetBy(dx: Self.boxInset, dy: Self.boxInset) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        if isRecording {
            // Centered on the box edge, so it reaches 1 pt outside, as in Raycast.
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
        } else if isHovering {
            let inner = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            Self.hoverBorder.setStroke(); inner.lineWidth = 1; inner.stroke()
        }
        let color = isRecording ? Self.placeholderColor : Self.valueColor
        let text = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
        text.draw(at: NSPoint(x: box.minX + Self.textInset, y: box.midY - text.size().height / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard let window, window.makeFirstResponder(self) else { return }
        isRecording = true
        resignObservation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        heldKeys = []
        pressedKeys = []
        onRecordingChange?(true)
        refresh()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let resignObservation { NotificationCenter.default.removeObserver(resignObservation) }
        resignObservation = nil
        onRecordingChange?(false)
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    /// Command-key combinations arrive here before menus handle them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording, let key = ModifierKey(keyCode: event.keyCode) else { return super.flagsChanged(with: event) }
        // AppKit's modifier flags carry the same left and right bits as Core Graphics event flags.
        if UInt64(event.modifierFlags.rawValue) & key.flag != 0 {
            heldKeys.insert(key)
            pressedKeys.insert(key)
        } else {
            heldKeys.remove(key)
        }
        if heldKeys.isEmpty {
            // A single modifier let go on its own becomes the shortcut; several are a slip.
            if pressedKeys.count == 1, let key = pressedKeys.first { return finish(.modifierKey(key)) }
            pressedKeys = []
        }
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == kVK_Escape, Shortcut.Modifiers(flags: event.modifierFlags).isEmpty { return stopRecording() }
        guard let shortcut = Shortcut(keyEvent: event) else { return NSSound.beep() }
        finish(shortcut)
    }

    private func finish(_ shortcut: Shortcut) {
        stopRecording()
        onRecord?(shortcut)
    }

    private func refresh() {
        let held = heldKeys.count == 1 ? heldKeys.first?.title : nil
        title = isRecording ? (held.map { $0 + "…" } ?? "Type Shortcut…") : shortcut.displayString
        needsDisplay = true
        setAccessibilityLabel("Dictation shortcut")
        setAccessibilityValue(isRecording ? "Recording" : title)
    }
}
