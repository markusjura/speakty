import Foundation
import Observation

/// Samples a voice level 30 times a second for the recording display. Only views that read it
/// redraw, and only while it runs.
@MainActor @Observable
final class LevelMeter {
    private(set) var level: Float = 0

    @ObservationIgnored private let source: @MainActor () -> Float
    @ObservationIgnored private var timer: Timer?

    init(source: @escaping @MainActor () -> Float) {
        self.source = source
    }

    /// A meter that moves like a voice, for previews of the display in Settings.
    static func demo() -> LevelMeter {
        let start = Date.now
        return LevelMeter {
            let t = Date.now.timeIntervalSince(start)
            let syllables = abs(sin(t * 7.3)) * (0.55 + 0.45 * sin(t * 1.9))
            return Float(max(0.08, syllables))
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // Common modes keep it running while the menu bar menu is open, as when choosing Stop Dictation.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Freezes the level where it is.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        level = source()
    }
}
