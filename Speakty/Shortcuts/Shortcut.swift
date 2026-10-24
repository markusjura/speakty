import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The dictation shortcut, held while speaking: a modifier key on its own, such as Right ⌘, or a key
/// with modifiers, such as ⌃⌥D. Key codes are layout-independent; display strings use the current
/// ASCII-capable layout, as macOS menus do.
enum Shortcut: Codable, Hashable, Sendable {
    case modifierKey(ModifierKey)
    case key(UInt16, Modifiers)

    static let `default` = Shortcut.modifierKey(.rightCommand)

    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt8
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        /// Keeps ⌃⌥⇧⌘ from AppKit modifier flags and drops the rest, such as Caps Lock.
        init(flags: NSEvent.ModifierFlags) {
            self = []
            if flags.contains(.control) { insert(.control) }
            if flags.contains(.option) { insert(.option) }
            if flags.contains(.shift) { insert(.shift) }
            if flags.contains(.command) { insert(.command) }
        }

        init(rawValue: UInt8) { self.rawValue = rawValue }

        var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }

        var carbonFlags: UInt32 {
            var result = 0
            if contains(.control) { result |= controlKey }
            if contains(.option) { result |= optionKey }
            if contains(.shift) { result |= shiftKey }
            if contains(.command) { result |= cmdKey }
            return UInt32(result)
        }
    }

    /// A key shortcut from a key-down event, or nil when it would get in the way of typing: a key
    /// needs a modifier, except the function keys F1 to F20.
    init?(keyEvent event: NSEvent) {
        let modifiers = Modifiers(flags: event.modifierFlags)
        guard event.type == .keyDown, !KeyNames.modifierKeyCodes.contains(Int(event.keyCode)),
              !modifiers.isEmpty || KeyNames.functionKeyCodes.contains(Int(event.keyCode)) else { return nil }
        self = .key(event.keyCode, modifiers)
    }

    /// A modifier key watched alone needs an event tap, and so Accessibility.
    var needsAccessibility: Bool {
        if case .modifierKey = self { true } else { false }
    }

    @MainActor var displayString: String {
        switch self {
        case .modifierKey(let key): key.title
        case .key(let code, let modifiers): modifiers.symbols + KeyNames.name(for: code)
        }
    }
}

/// A modifier key that works as the shortcut on its own. Left and right count as different keys,
/// so Right ⌘ can dictate while Left ⌘ keeps typing shortcuts.
enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case rightCommand, leftCommand, rightOption, leftOption, rightControl, leftControl, rightShift, leftShift, function

    init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    var keyCode: UInt16 {
        let code = switch self {
        case .rightCommand: kVK_RightCommand
        case .leftCommand: kVK_Command
        case .rightOption: kVK_RightOption
        case .leftOption: kVK_Option
        case .rightControl: kVK_RightControl
        case .leftControl: kVK_Control
        case .rightShift: kVK_RightShift
        case .leftShift: kVK_Shift
        case .function: kVK_Function
        }
        return UInt16(code)
    }

    /// The bit Core Graphics sets in event flags while this key is down. The device-dependent bits
    /// from IOKit's NX_DEVICE masks tell the left key from the right one.
    var flag: UInt64 {
        switch self {
        case .leftControl: 0x01
        case .leftShift: 0x02
        case .rightShift: 0x04
        case .leftCommand: 0x08
        case .rightCommand: 0x10
        case .leftOption: 0x20
        case .rightOption: 0x40
        case .rightControl: 0x2000
        case .function: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    var title: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .leftCommand: "Left ⌘"
        case .rightOption: "Right ⌥"
        case .leftOption: "Left ⌥"
        case .rightControl: "Right ⌃"
        case .leftControl: "Left ⌃"
        case .rightShift: "Right ⇧"
        case .leftShift: "Left ⇧"
        case .function: "Fn"
        }
    }
}

/// Key names for display, and the key that types a character, for posting ⌘V on any layout.
@MainActor
enum KeyNames {
    nonisolated static let functionKeyCodes: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    nonisolated static let modifierKeyCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    static func name(for keyCode: UInt16) -> String {
        let code = Int(keyCode)
        if let special = special[code] { return special }
        if let index = functionKeyCodes.firstIndex(of: code) { return "F\(index + 1)" }
        return character(for: keyCode).map { String($0).uppercased() } ?? "Key \(keyCode)"
    }

    /// The key that types `character` with ⌘ held on the current layout, such as V for ⌘V on Dvorak.
    /// Layouts such as "Dvorak - QWERTY ⌘" switch to QWERTY while ⌘ is down, so ⌘ must be part of the lookup.
    static func keyCode(typingWithCommand character: Character) -> UInt16? {
        (0...UInt16(kVK_ANSI_KeypadClear)).first { self.character(for: $0, command: true) == character }
    }

    /// The character on the current ASCII-capable layout, like menu key equivalents: unmodified,
    /// or with ⌘ held.
    static func character(for keyCode: UInt16, command: Bool = false) -> Character? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            // UCKeyTranslate takes the Carbon modifier bits shifted down by 8.
            return UCKeyTranslate(base, keyCode, UInt16(kUCKeyActionDisplay), command ? UInt32(cmdKey >> 8) : 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count,
                                  &length, &characters)
        }
        guard status == noErr, length > 0,
              let text = String(utf16CodeUnits: characters, count: length).first,
              !text.isWhitespace else { return nil }
        return text
    }
}
