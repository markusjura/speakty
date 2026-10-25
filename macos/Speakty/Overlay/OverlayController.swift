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
        model.scale = preferences.recording.scale
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
            // Only this swap animates, so the next dictation opens on its bars without a spinner fading out.
            withAnimation(OverlayView.stateChange) { model.isTranscribing = true }
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

    /// Room around the display for its shadow and the orb's glow, at every size.
    static let margin: CGFloat = 24

    /// The panel's frame, centered horizontally in a screen's visible area, with the display the
    /// edge distance away from its bottom or top. The margin may reach past that edge.
    static func panelFrame(in area: NSRect, recording: RecordingPreferences) -> NSRect {
        let size = OverlayPanel.size
        let y = switch recording.position {
        case .bottom: area.minY + recording.edgeDistance - margin
        case .top: area.maxY - size.height - recording.edgeDistance + margin
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
    var style = OverlayStyle.dark
    var scale = 1.0
    var position = OverlayPosition.bottom
    var isTranscribing = false
    /// Off while hidden, so the display's animation clock stops.
    var isShown = false
    let meter: LevelMeter

    init(meter: LevelMeter) { self.meter = meter }
}

/// A transparent, click-through panel on every Space, including over full-screen apps.
private final class OverlayPanel: NSPanel {
    /// Room for the display at its largest, and the margin around it.
    static let size = CGSize(width: OverlayView.size.width * RecordingPreferences.scaleRange.upperBound + 2 * OverlayController.margin,
                             height: OverlayView.size.height * RecordingPreferences.scaleRange.upperBound + 2 * OverlayController.margin)

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
            .scaleEffect(model.scale, anchor: model.position.anchor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.position.alignment)
            .padding(OverlayController.margin)
    }
}
