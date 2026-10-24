import AppKit
import ApplicationServices

// Drives Speakty with posted input and reports its windows, menu, and the clipboard as text.
// Posting events needs Accessibility access for the app running this tool, such as the terminal.
// Coordinates are global points with the origin at the top left of the main display.
//
// Usage:
//   speakty-ui windows                      on-screen windows of Speakty: id, layer, bounds, alpha, name
//   speakty-ui menu [item]                  lists the menu bar menu's items, or chooses one
//   speakty-ui hold <key> <seconds> [mods]  holds a key at the HID level, where the dictation shortcut sees it:
//                                           rcmd, lcmd, ropt, lopt, rctrl, rshift, fn, or a key code with mods
//   speakty-ui press <keycode> [mods]       one key press, such as `press 53` for Escape
//   speakty-ui clipboard                    the clipboard's text

/// Speakty Dev when it runs, else the installed Speakty. Only one of them runs at a time.
let bundleID = ["local.markus.Speakty.dev", "local.markus.Speakty"]
    .first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? "local.markus.Speakty.dev"
let args = Array(CommandLine.arguments.dropFirst())
let source = CGEventSource(stateID: .hidSystemState)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) ?? [] }
func title(_ element: AXUIElement) -> String { attribute(element, kAXTitleAttribute) ?? "" }

func app() -> NSRunningApplication {
    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { fail("\(bundleID) is not running") }
    return running
}

/// Parses a modifier list such as `command,shift`.
func modifiers(_ list: String) -> CGEventFlags {
    var flags: CGEventFlags = []
    for name in list.split(separator: ",") {
        switch name {
        case "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option": flags.insert(.maskAlternate)
        case "control": flags.insert(.maskControl)
        default: fail("unknown modifier \(name)")
        }
    }
    return flags
}

/// Modifier keys by name: key code and flags, including the device bit that tells left from right.
let modifierKeys: [String: (code: CGKeyCode, flags: UInt64)] = [
    "lcmd": (55, CGEventFlags.maskCommand.rawValue | 0x08), "rcmd": (54, CGEventFlags.maskCommand.rawValue | 0x10),
    "lopt": (58, CGEventFlags.maskAlternate.rawValue | 0x20), "ropt": (61, CGEventFlags.maskAlternate.rawValue | 0x40),
    "lctrl": (59, CGEventFlags.maskControl.rawValue | 0x01), "rctrl": (62, CGEventFlags.maskControl.rawValue | 0x2000),
    "lshift": (56, CGEventFlags.maskShift.rawValue | 0x02), "rshift": (60, CGEventFlags.maskShift.rawValue | 0x04),
    "fn": (63, CGEventFlags.maskSecondaryFn.rawValue),
]

func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, type: CGEventType? = nil) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
    if let type { event?.type = type }
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(8_000)
}

func windows() {
    let pid = app().processIdentifier
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where window[kCGWindowOwnerPID as String] as? pid_t == pid {
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print("id \(window[kCGWindowNumber as String] ?? 0) layer \(window[kCGWindowLayer as String] ?? 0)",
              "bounds \(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0)) \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))",
              "alpha \(window[kCGWindowAlpha as String] ?? 0)", "name \(window[kCGWindowName as String] ?? "")")
    }
}

/// Opens the menu bar item's menu, lists or chooses an item, and closes the menu again.
func menu(choosing item: String?) {
    let element = AXUIElementCreateApplication(app().processIdentifier)
    guard let extras: AXUIElement = attribute(element, kAXExtrasMenuBarAttribute),
          let statusItem = children(extras).first else { fail("Speakty shows no menu bar item") }
    AXUIElementPerformAction(statusItem, kAXPressAction as CFString)
    usleep(300_000)
    guard let menu = children(statusItem).first else { fail("the menu didn't open") }
    let items = children(menu)
    if let item {
        guard let match = items.first(where: { title($0) == item }) else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            fail("no item \(item); items: \(items.map(title).filter { !$0.isEmpty })")
        }
        let enabled: Bool = attribute(match, kAXEnabledAttribute) ?? true
        guard enabled else { AXUIElementPerformAction(menu, kAXCancelAction as CFString); fail("\(item) is disabled") }
        AXUIElementPerformAction(match, kAXPressAction as CFString)
        print("ok")
    } else {
        for entry in items where !title(entry).isEmpty {
            let enabled: Bool = attribute(entry, kAXEnabledAttribute) ?? true
            print(title(entry) + (enabled ? "" : " (disabled)"))
        }
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }
}

switch args.first {
case "windows": windows()
case "menu": menu(choosing: args.count > 1 ? args[1] : nil)
case "hold":
    guard args.count >= 3, let seconds = Double(args[2]) else { fail("usage: hold <key> <seconds> [mods]") }
    if let key = modifierKeys[args[1]] {
        // A modifier press and release are flagsChanged events, as a keyboard sends them.
        post(key.code, down: true, flags: CGEventFlags(rawValue: key.flags), type: .flagsChanged)
        usleep(useconds_t(seconds * 1_000_000))
        post(key.code, down: false, flags: [], type: .flagsChanged)
    } else if let code = CGKeyCode(args[1]) {
        let flags = args.count > 3 ? modifiers(args[3]) : []
        post(code, down: true, flags: flags)
        usleep(useconds_t(seconds * 1_000_000))
        post(code, down: false, flags: flags)
    } else { fail("unknown key \(args[1])") }
case "press":
    guard args.count > 1, let code = CGKeyCode(args[1]) else { fail("usage: press <keycode> [command,shift,option,control]") }
    let flags = args.count > 2 ? modifiers(args[2]) : []
    post(code, down: true, flags: flags)
    post(code, down: false, flags: flags)
case "clipboard": print(NSPasteboard.general.string(forType: .string) ?? "")
default:
    print("Usage: speakty-ui windows | menu [item] | hold <key> <seconds> [mods] | press <keycode> [mods] | clipboard")
    exit(1)
}
