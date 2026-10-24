import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Puts a transcript where the user is typing: on the clipboard, then ⌘V into the focused app, then
/// the previous clipboard back. Without Accessibility, macOS drops posted keys, so the transcript
/// stays on the clipboard to paste by hand.
@MainActor
enum TextInserter {
    private static let logger = Logger(subsystem: "local.markus.Speakty", category: "Paste")
    /// Marks the transcript as transient, so clipboard managers that honor nspasteboard.org skip it.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return logger.info("Copied the transcript; pasting needs Accessibility")
        }
        let saved: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        let ours = pasteboard.changeCount
        postPaste()
        // The target app reads the clipboard after it handles ⌘V, which can take a moment.
        try? await Task.sleep(for: .milliseconds(400))
        guard pasteboard.changeCount == ours else { return }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
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

    /// ⌘ plus whichever key types "v" in the current layout, so Dvorak and Colemak paste too.
    private static func postPaste() {
        let key = CGKeyCode(KeyNames.keyCode(typingWithCommand: "v") ?? UInt16(kVK_ANSI_V))
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
