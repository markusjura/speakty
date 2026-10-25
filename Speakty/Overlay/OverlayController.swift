import AppKit
import Observation
import SwiftUI

/// Shows the recording display while a dictation runs, on the screen with the pointer, at the
/// bottom or top of its visible area. The panel never takes focus or clicks, so typing goes on in
/// the app underneath.
@MainActor
final class OverlayController {
    private let dictation: DictationController
    private let preferences: AppPreferences
    private let model: OverlayModel
    private lazy var panel = OverlayPanel(model: model)

    init(dictation: DictationController, preferences: AppPreferences) {
        self.dictation = dictation
        self.preferences = preferences
        model = OverlayModel(meter: LevelMeter { [recorder = dictation.recorder] in recorder.level })
    }

    func start() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.start() }
        }
    }

    private func update() {
        model.style = preferences.recording.style
        model.position = preferences.recording.position
        switch dictation.phase {
        case .idle:
            model.meter.stop()
            model.isShown = false
            hide()
        case .recording:
            model.isTranscribing = false
            model.isShown = true
            model.meter.start()
            show()
        case .transcribing:
            model.isTranscribing = true
            model.meter.stop()
        }
    }

    /// Setting the alpha also cancels a fade-out still running from the previous dictation.
    private func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(Self.panelFrame(in: area, recording: preferences.recording), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// The panel's frame, centered horizontally in a screen's visible area and the edge distance
    /// away from its bottom or top.
    static func panelFrame(in area: NSRect, recording: RecordingPreferences) -> NSRect {
        let size = OverlayPanel.size
        let y = switch recording.position {
        case .bottom: area.minY + recording.edgeDistance
        case .top: area.maxY - size.height - recording.edgeDistance
        }
        return NSRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }

    private func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Chrome.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }
}

/// What the display shows, kept apart from the panel so SwiftUI redraws only what changed.
@MainActor @Observable
final class OverlayModel {
    var style = OverlayStyle.minimal
    var position = OverlayPosition.bottom
    var isTranscribing = false
    /// Off while hidden, so the display's animation clock stops.
    var isShown = false
    let meter: LevelMeter

    init(meter: LevelMeter) { self.meter = meter }
}

/// A transparent, click-through panel on every Space, including over full-screen apps.
private final class OverlayPanel: NSPanel {
    /// Room for the widest style and its shadow; the style sits at the edge facing the screen edge.
    static let size = CGSize(width: 240, height: 72)

    init(model: OverlayModel) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = Chrome.overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: OverlayRoot(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct OverlayRoot: View {
    let model: OverlayModel

    var body: some View {
        OverlayView(style: model.style, isTranscribing: model.isTranscribing, meter: model.meter, isAnimating: model.isShown)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.position == .bottom ? .bottom : .top)
    }
}
