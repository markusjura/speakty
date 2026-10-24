import AVFoundation
import AppKit
import ApplicationServices
import Observation

/// Microphone and Accessibility access. Re-read whenever Speakty becomes active, as after a visit to
/// System Settings, and when macOS reports an Accessibility change, so Settings and the shortcut
/// monitor follow a grant without a relaunch.
@MainActor @Observable
final class Permissions {
    private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    /// Needed to paste with ⌘V and to watch a modifier key such as Right ⌘.
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The notification arrives before the new trust value is readable.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                self?.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone != self.microphone { self.microphone = microphone }
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
    }

    /// Shows macOS's microphone prompt, which it does only once, and returns whether access is granted.
    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    /// Shows macOS's Accessibility prompt, which links to System Settings.
    func requestAccessibility() {
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
