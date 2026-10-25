import SwiftUI

/// The recording display in one of its styles. Listening follows the voice level; transcribing
/// shows a spinner in the capsules and turns the orb fast, so the two read apart at a glance.
struct OverlayView: View {
    /// The size of every style at 100%. The capsules fill it; the orb is as tall and as wide as tall.
    static let size = CGSize(width: 73, height: 28)
    /// How long the capsules take to swap the level bars for the spinner.
    static let stateChange = Animation.smooth(duration: 0.2)

    let style: OverlayStyle
    let isTranscribing: Bool
    let meter: LevelMeter
    /// False while hidden, where an animation clock would keep redrawing for nothing.
    var isAnimating = true

    var body: some View {
        // One clock for every style's motion. Reduce Motion stops the decorative motion, which time
        // drives, and keeps the voice level, which still needs the clock to redraw. The spinner
        // shows progress, so it keeps turning, as the system's spinners do.
        TimelineView(.animation(paused: !isAnimating)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let time = Chrome.reduceMotion ? 0 : now
            switch style {
            // Glass blends its label into the background, which takes more off the spinner's thin
            // stroke, so it needs more opacity to look as dim as Dark's.
            case .dark:
                CapsuleContent(isTranscribing: isTranscribing, level: meter.level, time: time, spinnerTime: now, spinnerOpacity: 0.5)
                    .modifier(DarkCapsule())
            case .glass:
                CapsuleContent(isTranscribing: isTranscribing, level: meter.level, time: time, spinnerTime: now, spinnerOpacity: 0.7)
                    .modifier(GlassCapsule())
            case .orb: OrbOverlay(isTranscribing: isTranscribing, level: meter.level, time: time)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isTranscribing ? "Transcribing" : "Listening")
    }

    /// How far a part of a style moves for the voice level, from 0 to 1: up to the level, pulsing
    /// at its own phase so a steady voice still looks alive. Every style moves by it, so they all
    /// respond to the same voice alike and only a loud one reaches the top.
    static func swing(level: Float, time: TimeInterval, phase: Double) -> Double {
        Double(level) * (0.5 + 0.5 * abs(sin(time * 4.6 + phase)))
    }
}

extension OverlayPosition {
    /// Where the display sits in the space it's given.
    var alignment: Alignment { self == .bottom ? .bottom : .top }
    /// The point the display grows from, so a larger size keeps its distance from the screen edge.
    var anchor: UnitPoint { self == .bottom ? .bottom : .top }
}

/// The dark island capsule.
private struct DarkCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Chrome.islandLabel)
            .background(Chrome.islandFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Chrome.islandRim, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

/// A Liquid Glass capsule of the same size.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary.opacity(0.9))
            .glassEffect(.regular, in: Capsule())
    }
}

/// What the capsule styles show, filling the display's size: the level bars while listening, and
/// a spinner while transcribing. Neither looks like the other, so the moment speech stops counting
/// is clear.
private struct CapsuleContent: View {
    let isTranscribing: Bool
    let level: Float
    let time: TimeInterval
    let spinnerTime: TimeInterval
    /// How much of the label color the spinner keeps. Muted, like a control that's off, since the
    /// voice no longer counts.
    let spinnerOpacity: Double

    var body: some View {
        ZStack {
            if isTranscribing {
                Spinner(time: spinnerTime).opacity(spinnerOpacity).transition(.opacity.combined(with: .scale(scale: 0.5)))
            } else {
                LevelBars(level: level, time: time).transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .frame(width: OverlayView.size.width, height: OverlayView.size.height)
    }
}

/// Bars taller in the middle, swinging with the voice.
private struct LevelBars: View {
    let level: Float
    let time: TimeInterval
    private static let count = 9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.count, id: \.self) { index in
                Capsule().frame(width: 3, height: height(index))
            }
        }
    }

    private func height(_ index: Int) -> CGFloat {
        let i = Double(index)
        let center = 1 - abs(i - Double(Self.count - 1) / 2) / 6
        return 3 + 13 * center * OverlayView.swing(level: level, time: time, phase: i * 1.7)
    }
}

/// A plain open arc turning a little faster than once a second.
private struct Spinner: View {
    let time: TimeInterval

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            .frame(width: 10.5, height: 10.5)
            .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
    }
}

/// A glowing ring that breathes with the voice, and turns quickly while transcribing.
private struct OrbOverlay: View {
    let isTranscribing: Bool
    let level: Float
    let time: TimeInterval

    var body: some View {
        let swing = isTranscribing ? 0 : OverlayView.swing(level: level, time: time, phase: 0)
        let glow = isTranscribing ? 0.45 : 0.2 + 0.7 * swing
        let angle = Angle.degrees(time * (isTranscribing ? 180 : 24))
        ZStack {
            Circle().fill(Chrome.orbGradient).rotationEffect(angle).blur(radius: 7).opacity(glow)
            Circle().fill(Chrome.orbGradient).rotationEffect(angle)
            Circle().inset(by: 2.75).fill(Color(white: 0.09, opacity: 0.88))
        }
        // The glow spills past the frame, into the panel's margin.
        .frame(width: OverlayView.size.height, height: OverlayView.size.height)
        .scaleEffect(1 + 0.18 * swing)
    }
}
