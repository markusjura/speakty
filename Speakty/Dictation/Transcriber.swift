import FluidAudio
import Foundation
import Observation
import os

/// The local dictation models. Parakeet Ultra is the only one for now; another case becomes another
/// row in Settings > Models.
enum DictationModel: String, CaseIterable, Identifiable, Sendable {
    case parakeetUltra

    var id: Self { self }
    var title: String { "Parakeet Ultra" }
    var summary: String { "Fast and accurate in 25 European languages." }
    var size: String { "632 MB" }
    fileprivate var version: AsrModelVersion { .ultra }
    fileprivate var directory: URL { AsrModels.defaultCacheDirectory(for: version) }
}

/// Downloads, loads, and runs the dictation model on the Neural Engine through FluidAudio. With a
/// vocabulary, a second small model rescores each transcript against it, so names and terms win
/// when the audio supports them.
@MainActor @Observable
final class Transcriber {
    enum State: Equatable {
        case absent
        /// Fraction downloaded, 0 to 1.
        case downloading(Double)
        /// Compiling and loading onto the Neural Engine.
        case loading
        case ready
        case failed(String)
    }

    let model = DictationModel.parakeetUltra
    private(set) var state: State

    @ObservationIgnored private var manager: AsrManager?
    /// Identifies the preparation in progress. FluidAudio downloads don't stop for cancellation, so a
    /// preparation that `remove()` abandoned finishes on its own and must not touch the state.
    @ObservationIgnored private var preparation: UUID?
    @ObservationIgnored private var vocabulary: [String] = []
    @ObservationIgnored private var boosting: VocabularyBoostingSession?
    @ObservationIgnored private var boostingTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "local.markus.Speakty", category: "Transcriber")

    init() {
        state = AsrModels.modelsExist(at: model.directory, version: model.version) ? .loading : .absent
    }

    /// Downloads the model if needed and loads it, so the first dictation is as fast as the rest.
    func prepare() {
        guard preparation == nil, manager == nil else { return }
        let model = model, id = UUID()
        preparation = id
        state = AsrModels.modelsExist(at: model.directory, version: model.version) ? .loading : .downloading(0)
        Task {
            do {
                let models = try await AsrModels.downloadAndLoad(version: model.version) { progress in
                    Task { @MainActor in if self.preparation == id { self.report(progress) } }
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                // A short transcription compiles the decoder paths, so the first dictation doesn't pay for it.
                var decoder = TdtDecoderState.make()
                _ = try? await manager.transcribe([Float](repeating: 0, count: Transcript.sampleRate), decoderState: &decoder)
                guard preparation == id else { return }
                preparation = nil
                self.manager = manager
                state = .ready
                logger.info("\(model.title, privacy: .public) is ready")
            } catch {
                guard preparation == id else { return }
                preparation = nil
                state = .failed(error.localizedDescription)
                logger.error("Preparing \(model.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the downloaded model. Dictation stays off until it's downloaded again.
    func remove() {
        preparation = nil
        manager = nil
        try? FileManager.default.removeItem(at: model.directory)
        state = .absent
    }

    /// Keeps the rescoring session in step with the vocabulary. The first word downloads the 98 MB
    /// keyword model; until the session is ready, transcripts go out unboosted.
    func useVocabulary(_ terms: [String]) {
        guard terms != vocabulary else { return }
        vocabulary = terms
        boosting = nil
        boostingTask?.cancel()
        guard !terms.isEmpty else { return }
        boostingTask = Task {
            do {
                let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                // Dictation vocabularies are short names that sound like ordinary words. MacParakeet found
                // a similarity floor of 0.65 keeps ordinary words from turning into terms, and FluidAudio
                // recommends turning off its acoustic rescue for them, which otherwise replaced
                // "pastes the text" with "Spotty" here.
                let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }, minSimilarity: 0.65)
                let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels,
                                                                  config: .init(spotterRescueEnabled: false))
                guard !Task.isCancelled else { return }
                boosting = session
            } catch {
                logger.error("Vocabulary boosting is off: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The transcript of 16 kHz mono speech, rescored against the vocabulary when there is one.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notReady }
        var decoder = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &decoder)
        logger.info("Transcribed \(result.duration, format: .fixed(precision: 1)) s in \(result.processingTime, format: .fixed(precision: 2)) s")
        guard let boosting, let timings = result.tokenTimings,
              let rescored = await boosting.rescore(text: result.text, tokenTimings: timings, audioSamples: samples) else {
            return result.text
        }
        return rescored.text
    }

    private func report(_ progress: DownloadProgress) {
        switch progress.phase {
        case .listing, .downloading: state = .downloading(progress.fractionCompleted)
        case .compiling: state = .loading
        }
    }
}

enum TranscriberError: Error { case notReady }
