import SwiftUI

/// The recording display in one of its styles. Listening follows the voice level; transcribing
/// keeps moving without it, so the two read apart at a glance.
struct OverlayView: View {
    let style: OverlayStyle
    let isTranscribing: Bool
    let meter: LevelMeter
    /// False while hidden, where an animation clock would keep redrawing for nothing.
    var isAnimating = true

    var body: some View {
        // One clock for every style's motion; it also pauses with Reduce Motion.
        TimelineView(.animation(paused: !isAnimating || Chrome.reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            switch style {
            case .minimal: MinimalOverlay(isTranscribing: isTranscribing, level: meter.level, time: time)
            case .glass: GlassOverlay(isTranscribing: isTranscribing, history: meter.history, time: time)
            case .orb: OrbOverlay(isTranscribing: isTranscribing, level: meter.level, time: time)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isTranscribing ? "Transcribing" : "Listening")
    }
}

/// Level bars in Shotty's dark island capsule.
private struct MinimalOverlay: View {
    let isTranscribing: Bool
    let level: Float
    let time: TimeInterval
    private static let count = 9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.count, id: \.self) { index in
                Capsule().frame(width: 3, height: height(index))
            }
        }
        .foregroundStyle(Chrome.islandLabel)
        .frame(height: 28)
        .padding(.horizontal, 11)
        .background(Chrome.islandFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Chrome.islandRim, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    /// Listening: taller in the middle and jittering with the voice. Transcribing: a low wave
    /// running left to right.
    private func height(_ index: Int) -> CGFloat {
        let i = Double(index)
        if isTranscribing { return 3 + 4 * max(0, sin(time * 5 - i * 0.7)) }
        let center = 1 - abs(i - Double(Self.count - 1) / 2) / 6
        return 3 + 13 * Double(level) * center * (0.5 + 0.5 * abs(sin(time * 4.6 + i * 1.7)))
    }
}

/// A waveform scrolling through a Liquid Glass capsule. Transcribing freezes it and runs a light
/// across the bars.
private struct GlassOverlay: View {
    let isTranscribing: Bool
    let history: [Float]
    let time: TimeInterval

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(history.indices, id: \.self) { index in
                Capsule().frame(width: 2.5, height: 3 + 20 * CGFloat(history[index]))
            }
        }
        .foregroundStyle(isTranscribing ? AnyShapeStyle(sweep) : AnyShapeStyle(.primary.opacity(0.9)))
        .frame(width: 144, height: 40)
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: Capsule())
    }

    /// Dimmed bars with a bright band moving left to right about once a second.
    private var sweep: LinearGradient {
        let center = (time.truncatingRemainder(dividingBy: 1.1) / 1.1) * 1.6 - 0.3
        return LinearGradient(stops: [
            .init(color: .primary.opacity(0.3), location: center - 0.25),
            .init(color: .primary, location: center),
            .init(color: .primary.opacity(0.3), location: center + 0.25),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

/// A glowing ring that breathes with the voice, and turns quickly while transcribing.
private struct OrbOverlay: View {
    let isTranscribing: Bool
    let level: Float
    let time: TimeInterval

    var body: some View {
        let glow = isTranscribing ? 0.45 : 0.2 + 0.7 * Double(level)
        let angle = Angle.degrees(time * (isTranscribing ? 180 : 24))
        ZStack {
            Circle().fill(Chrome.orbGradient).rotationEffect(angle).blur(radius: 9).opacity(glow)
            Circle().fill(Chrome.orbGradient).rotationEffect(angle)
            Circle().inset(by: 3.5).fill(Color(white: 0.09, opacity: 0.88))
        }
        .frame(width: 36, height: 36)
        .scaleEffect(isTranscribing ? 1 : 1 + 0.18 * CGFloat(level))
        // Room for the glow, which spills past the ring.
        .padding(10)
    }
}
