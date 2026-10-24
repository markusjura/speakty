import SwiftUI

@main
struct SpeaktyApp: App {
    @NSApplicationDelegateAdaptor(SpeaktyApplicationDelegate.self) private var delegate

    var body: some Scene {
        // A window rather than a Settings scene, which SwiftUI always keeps at a fixed size.
        Window("Settings", id: SettingsView.windowID) {
            SettingsView(preferences: delegate.preferences, permissions: delegate.permissions, transcriber: delegate.transcriber,
                         hotkeys: delegate.hotkeys, updater: delegate.updater)
                .onAppear { delegate.settingsIsOpen = true }
                .onDisappear { delegate.settingsIsOpen = false }
        }
        // System Settings' toolbar height and control size.
        .windowToolbarStyle(.unified)
        .defaultSize(width: 660, height: 608)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            SwiftUI.CommandGroup(replacing: .appSettings) { SettingsButton() }
        }
        MenuBarExtra(isInserted: Binding(
            get: { delegate.preferences.general.showsMenuBarIcon },
            set: { delegate.preferences.general.showsMenuBarIcon = $0 })) {
            SpeaktyMenu(dictation: delegate.dictation, updater: delegate.updater)
        } label: {
            MenuBarLabel(showsUpdateDot: delegate.updater.needsAttention)
        }
    }
}

/// The menu bar item: a waveform that never changes with the dictation state, with a blue dot while
/// an update needs the user. The label must stay static between state changes: a `TimelineView`
/// here re-renders the status item in an endless loop.
private struct MenuBarLabel: View {
    let showsUpdateDot: Bool

    var body: some View {
        Image(nsImage: showsUpdateDot ? Self.iconWithDot : Self.icon)
    }

    /// Larger and heavier than the default status item symbol, so it matches system items such as
    /// Time Machine and Display in size and stroke weight.
    private static let icon: NSImage = {
        let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Speakty")!
        let image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))!
        image.isTemplate = true
        return image
    }()

    /// The icon with a blue dot in its top right corner. A template image can't carry color, so this
    /// one draws the glyph itself in the menu bar's label color, resolved each time it draws.
    private static let iconWithDot: NSImage = {
        let image = NSImage(size: icon.size, flipped: false) { bounds in
            icon.draw(in: bounds)
            NSColor.labelColor.set()
            bounds.fill(using: .sourceAtop)
            let dot = CGRect(x: bounds.maxX - 6, y: bounds.maxY - 6, width: 6, height: 6)
            // A clear ring keeps the dot apart from the bars it overlaps.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = "Speakty, update available"
        return image
    }()
}

/// The menu bar menu. Start Dictation records until Stop Dictation, for when a hand is on the mouse.
private struct SpeaktyMenu: View {
    let dictation: DictationController
    let updater: AppUpdater

    var body: some View {
        Button(dictation.isRecording ? "Stop Dictation" : "Start Dictation") { dictation.toggle() }
            .disabled(!dictation.isRecording && !dictation.canStart)
        Divider()
        UpdateMenuItem(updater: updater)
        SettingsButton()
        Button("Quit Speakty") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class SpeaktyApplicationDelegate: NSObject, NSApplicationDelegate {
    let preferences = AppPreferences()
    let permissions = Permissions()
    let transcriber = Transcriber()
    lazy var dictation = DictationController(preferences: preferences, permissions: permissions, transcriber: transcriber) { [weak self] in
        self?.showSettings(.permissions)
    }
    lazy var updater = AppUpdater(environment: .init(isBusy: { [dictation] in dictation.phase != .idle }))
    private lazy var overlay = OverlayController(dictation: dictation, preferences: preferences)
    lazy var hotkeys = HotkeyMonitor(preferences: preferences, permissions: permissions) { [weak self] in
        self?.dictation.handle($0)
    }
    /// Open Settings makes Speakty a regular app, so the window gets a Dock icon, a Cmd-Tab entry,
    /// and the app menu, and window switchers list it like any other window.
    var settingsIsOpen = false {
        didSet { updateActivationPolicy() }
    }
    private static let launchedBeforeKey = "launchedBefore"
    #if DEBUG
    private var installedLaunchObservation: NSKeyValueObservation?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        #if DEBUG
        keepOneSpeaktyRunning()
        #endif
        observePreferences()
        observeDictation()
        hotkeys.start()
        overlay.start()
        transcriber.prepare()
        // Creating the updater starts Sparkle's schedule; the menu bar may have created it already.
        _ = updater
        // Speakty starts silently, so a first launch would otherwise show nothing. Open Settings
        // once on Permissions, where the user grants the access dictation needs.
        if !UserDefaults.standard.bool(forKey: Self.launchedBeforeKey) {
            UserDefaults.standard.set(true, forKey: Self.launchedBeforeKey)
            showSettings(.permissions)
        }
    }

    #if DEBUG
    /// Speakty Dev and the installed Speakty share the dictation shortcut, so only the one opened
    /// last keeps running. Launching Speakty Dev quits the installed build, and launching the
    /// installed build quits Speakty Dev. Only Debug builds carry this.
    private func keepOneSpeaktyRunning() {
        let installedID = "local.markus.Speakty"
        NSRunningApplication.runningApplications(withBundleIdentifier: installedID).forEach { $0.terminate() }
        installedLaunchObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, change in
            guard change.newValue?.contains(where: { $0.bundleIdentifier == installedID }) == true else { return }
            // Quit from the next run loop pass, outside the KVO callback.
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Opens Settings through its app menu command, the one bridge from AppKit to the SwiftUI window.
    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsView.paneKey) }
        NSApp.activate()
        if let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
        }), let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) {
            menu.performActionForItem(at: index)
        }
    }

    private func observePreferences() {
        withObservationTracking {
            NSApp.appearance = preferences.general.appearance.nsAppearance
            updateActivationPolicy()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePreferences() }
        }
    }

    /// Escape cancels only while a dictation runs, and the vocabulary follows Settings.
    private func observeDictation() {
        withObservationTracking {
            hotkeys.watchesEscape = dictation.phase != .idle
            transcriber.useVocabulary(preferences.transcript.vocabulary)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDictation() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { dictation.cancel() }

    private func updateActivationPolicy() {
        // Read the preference unconditionally so preference observation keeps tracking it.
        let preferred = preferences.general.activationPolicy
        let policy = settingsIsOpen ? .regular : preferred
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Activate after becoming a regular app so Settings comes forward with the app menu. Only
        // Settings activates, so a login launch with the Dock icon on doesn't take focus.
        if settingsIsOpen { NSApp.activate() }
    }
}
