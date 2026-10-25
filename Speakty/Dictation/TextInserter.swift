import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Puts a transcript where the user is typing: on the clipboard, then ⌘V into the focused app, and
/// Return when sending, then the previous clipboard back. Without Accessibility, macOS drops posted keys, so the transcript
/// stays on the clipboard to paste by hand.
@MainActor
enum TextInserter {
    private static let logger = Logger(subsystem: "local.markus.Speakty", category: "Paste")
    /// Marks the transcript as transient, so clipboard managers that honor nspasteboard.org skip it.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The clipboard from before the last transcript while it waits to be restored. A transcript
    /// pasted meanwhile keeps it, so a quick second dictation doesn't restore the first transcript.
    private static var pendingRestore: (items: [NSPasteboardItem], changeCount: Int, task: Task<Void, Never>)?

    static func insert(_ text: String, pressingReturn: Bool = false) {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return logger.info("Copied the transcript; pasting needs Accessibility")
        }
        let saved = if let pendingRestore, pendingRestore.changeCount == pasteboard.changeCount {
            pendingRestore.items
        } else {
            copies(of: pasteboard)
        }
        pendingRestore?.task.cancel()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        let ours = pasteboard.changeCount
        post(KeyNames.keyCode(typingWithCommand: "v") ?? UInt16(kVK_ANSI_V), flags: .maskCommand)
        if pressingReturn { post(UInt16(kVK_Return)) }
        pendingRestore = (saved, ours, Task {
            // The target app reads the clipboard after it handles ⌘V, which can take a moment.
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            pendingRestore = nil
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        })
    }

    private static func copies(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
    }

    /// The text before the caret on its line and a few lines back, or nil when the focused app
    /// doesn't expose its text through Accessibility, as many terminals and web views don't.
    static func textBeforeCaret() -> String? {
        let system = AXUIElementCreateSystemWide()
        // An unresponsive app would otherwise stall the paste for seconds.
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard let focused: AXUIElement = attribute(system, kAXFocusedUIElementAttribute),
              let selection: AXValue = attribute(focused, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection, .cfRange, &range) else { return nil }
        let length = min(range.location, 200)
        var before = CFRange(location: range.location - length, length: length)
        guard let value = AXValueCreate(.cfRange, &before) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &text) == .success else { return nil }
        return text as? String
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Presses and releases the key. ⌘V uses whichever key types "v" in the current layout, so
    /// Dvorak and Colemak paste too.
    private static func post(_ key: UInt16, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
