import AppKit
import Carbon.HIToolbox
import Observation
import os

/// Watches the dictation shortcut, and Cancel and Send while a dictation runs. A modifier key such as
/// Right ⌘ comes from a session event tap, which needs Accessibility; a key with modifiers comes
/// from `RegisterEventHotKey`, which needs no permission. Both follow the shortcut in preferences,
/// the Accessibility grant, and `isPaused`, which the shortcut recorder sets while it records.
/// Keep one instance for the app's lifetime.
@MainActor @Observable
final class HotkeyMonitor {
    enum Event: Equatable {
        case pressed
        case released
        /// Another key went down while a modifier shortcut was held, as in ⌘C with Right ⌘.
        case interrupted
        /// The Cancel or Send shortcut, while `isDictating`.
        case cancel, send
    }

    /// Set while Settings records a new shortcut, so the current one doesn't fire.
    var isPaused = false
    /// True when the key shortcut couldn't be registered, usually because another app has it.
    private(set) var isTaken = false
    /// Cancel and Send are hot keys only while a dictation runs, so their keys stay free for other apps.
    var isDictating = false

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let handler: @MainActor (Event) -> Void
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var watchedKey: ModifierKey?
    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "local.markus.Speakty", category: "Shortcut")

    private nonisolated static let signature: OSType = 0x5350_4B54 // "SPKT"
    private nonisolated static let shortcutID: UInt32 = 1
    /// Cancel or Send's hot keys. Each key gets a second hot key with the dictation shortcut's
    /// modifiers added, which are still down while the shortcut is held.
    private struct DictationKey {
        let id: UInt32
        let heldID: UInt32
        let command: DictationCommand
        let event: Event
    }

    private static let dictationKeys = [
        DictationKey(id: 2, heldID: 3, command: .cancel, event: .cancel),
        DictationKey(id: 4, heldID: 5, command: .send, event: .send),
    ]

    init(preferences: AppPreferences, permissions: Permissions, handler: @escaping @MainActor (Event) -> Void) {
        self.preferences = preferences
        self.permissions = permissions
        self.handler = handler
    }

    func start() {
        installHotKeyHandler()
        synchronize()
        synchronizeDictationKeys()
    }

    /// Re-registers whenever the shortcut, the grant, or `isPaused` changes.
    private func synchronize() {
        let (shortcut, trusted, paused) = withObservationTracking {
            (preferences.recording.shortcut, permissions.isAccessibilityTrusted, isPaused)
        } onChange: { [weak self] in
            Task { @MainActor in self?.synchronize() }
        }
        if isHeld { isHeld = false; handler(.released) }
        removeTap()
        unregister(Self.shortcutID)
        isTaken = false
        guard !paused else { return }
        switch shortcut {
        case .modifierKey(let key):
            guard trusted else { return logger.info("Waiting for Accessibility to watch \(key.title, privacy: .public)") }
            watchedKey = key
            installTap()
        case .key(let code, let modifiers):
            // Exclusive, so a combination another app already owns fails here instead of never firing.
            isTaken = !register(Self.shortcutID, keyCode: UInt32(code), modifiers: modifiers.carbonFlags, exclusive: true)
        }
    }

    // MARK: Event tap

    /// An active tap, which Accessibility allows; a listen-only tap would need Input Monitoring.
    /// It passes every event through unchanged.
    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            // The tap's run loop source is on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // Trust can lag behind the grant, and no trust change follows to retry, so retry shortly.
            logger.error("Couldn't create the event tap")
            let key = watchedKey
            Task {
                try? await Task.sleep(for: .seconds(1))
                if tap == nil, key != nil, watchedKey == key { installTap() }
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        watchedKey = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // A release may have passed unseen, so end a held shortcut and listen again.
            if isHeld { isHeld = false; handler(.released) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            guard let watchedKey, event.getIntegerValueField(.keyboardEventKeycode) == Int64(watchedKey.keyCode) else { return }
            let isDown = event.flags.rawValue & watchedKey.flag != 0
            guard isDown != isHeld else { return }
            isHeld = isDown
            handler(isDown ? .pressed : .released)
        case .keyDown:
            guard isHeld, !isDictationKey(event) else { return }
            isHeld = false
            handler(.interrupted)
        default:
            break
        }
    }

    /// Cancel and Send act on the dictation, so unlike other keys they don't interrupt a held shortcut.
    /// Their hot keys handle them.
    private func isDictationKey(_ event: CGEvent) -> Bool {
        guard isDictating else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let pressed = Shortcut.Modifiers(flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        let recording = preferences.recording
        return Self.dictationKeys.contains { key in
            guard case .key(let keyCode, let modifiers) = recording[key.command] else { return false }
            return keyCode == code && (pressed == modifiers || pressed == modifiers.union(recording.shortcut.modifiers))
        }
    }

    // MARK: Carbon hot keys

    private func installHotKeyHandler() {
        let types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userInfo in
            guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyMonitor.signature else { return OSStatus(eventNotHandledErr) }
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            // The application event target dispatches on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().hotKey(id, isPress: isPress)
            }
            return noErr
        }, types.count, types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr { logger.error("Couldn't install the hot key handler: \(status)") }
    }

    private func hotKey(_ id: UInt32, isPress: Bool) {
        switch id {
        case Self.shortcutID:
            guard isPress != isHeld else { return }
            isHeld = isPress
            handler(isPress ? .pressed : .released)
        default:
            guard isPress, let key = Self.dictationKeys.first(where: { $0.id == id || $0.heldID == id }) else { return }
            handler(key.event)
        }
    }

    /// Re-registers Cancel and Send whenever a dictation starts or ends, their shortcuts change, or
    /// `isPaused` changes. Separate from `synchronize()`, which would end a held shortcut.
    private func synchronizeDictationKeys() {
        let (recording, isOn) = withObservationTracking {
            (preferences.recording, isDictating && !isPaused)
        } onChange: { [weak self] in
            Task { @MainActor in self?.synchronizeDictationKeys() }
        }
        for key in Self.dictationKeys { unregister(key.id); unregister(key.heldID) }
        guard isOn else { return }
        let bindings = Self.dictationKeys.compactMap { key in recording[key.command].map { (key: key, shortcut: $0) } }
        for (key, shortcut) in bindings {
            guard case .key(let code, let modifiers) = shortcut else { continue }
            register(key.id, keyCode: UInt32(code), modifiers: modifiers.carbonFlags)
        }
        // An app can register a combination only once, so a held variant that's already taken, as ⌘Esc
        // for Cancel when Send is ⌘Esc, leaves it to the command that has it. Cancel's variant goes first.
        var taken = Set(bindings.map(\.shortcut))
        for (key, shortcut) in bindings {
            guard case .key(let code, let modifiers) = shortcut else { continue }
            let heldModifiers = modifiers.union(recording.shortcut.modifiers)
            guard taken.insert(.key(code, heldModifiers)).inserted else { continue }
            register(key.heldID, keyCode: UInt32(code), modifiers: heldModifiers.carbonFlags)
        }
    }

    @discardableResult
    private func register(_ id: UInt32, keyCode: UInt32, modifiers: UInt32, exclusive: Bool = false) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), exclusive ? OptionBits(kEventHotKeyExclusive) : 0, &reference)
        guard status == noErr, let reference else {
            logger.error("Couldn't register hot key \(id): \(status)")
            return false
        }
        hotKeys[id] = reference
        return true
    }

    private func unregister(_ id: UInt32) {
        if let reference = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }
}
