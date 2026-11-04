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

    /// Downloads the model if needed, loads it onto the Neural Engine, and returns its recognizer.
    func load(progress: ProgressHandler? = nil) async throws -> Recognizer {
        let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: progress)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return { samples in
            var decoder = TdtDecoderState.make()
            return try await manager.transcribe(samples, decoderState: &decoder)
        }
    }
}

/// A loaded model: 16 kHz mono speech in, text with the per-token timings vocabulary boosting needs
/// out. `Scripts/benchmark.sh` runs candidate models through one too.
typealias Recognizer = @Sendable ([Float]) async throws -> ASRResult

/// Downloads, loads, and runs the dictation model on the Neural Engine through FluidAudio. With a
/// vocabulary, `VocabularyBoosting` checks each transcript against it, so names and terms win when
/// the audio supports them.
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

    @ObservationIgnored private var recognizer: Recognizer?
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var vocabulary: [String] = []
    /// The keyword model, loaded once and shared by every vocabulary's session.
    @ObservationIgnored private var ctcModels: Task<CtcModels, Error>?
    @ObservationIgnored private var boosting: VocabularyBoosting?
    /// Builds `boosting`, and is nil once that finished or failed.
    @ObservationIgnored private var boostingTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "local.markus.Speakty", category: "Transcriber")

    init() {
        state = AsrModels.modelsExist(at: model.directory, version: model.version) ? .loading : .absent
    }

    /// Downloads the model if needed and loads it, so the first dictation is as fast as the rest.
    func prepare() {
        guard !isPreparing, recognizer == nil else { return }
        let model = model
        isPreparing = true
        state = AsrModels.modelsExist(at: model.directory, version: model.version) ? .loading : .downloading(0)
        Task {
            do {
                let recognizer = try await model.load { progress in
                    Task { @MainActor in if self.isPreparing { self.report(progress) } }
                }
                // A short transcription compiles the decoder paths, so the first dictation doesn't pay for it.
                _ = try? await recognizer([Float](repeating: 0, count: Transcript.sampleRate))
                isPreparing = false
                self.recognizer = recognizer
                state = .ready
                logger.info("\(model.title, privacy: .public) is ready")
            } catch {
                isPreparing = false
                state = .failed(error.localizedDescription)
                logger.error("Preparing \(model.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the downloaded model. Dictation stays off until it's downloaded again.
    func remove() {
        guard state == .ready else { return }
        recognizer = nil
        try? FileManager.default.removeItem(at: model.directory)
        state = .absent
    }

    /// Keeps the rescoring session in step with the vocabulary. The first word downloads the 98 MB
    /// keyword model; until the session is ready, transcripts go out unboosted.
    func useVocabulary(_ terms: [String]) {
        guard terms != vocabulary else { return }
        vocabulary = terms
        loadBoosting()
    }

    /// Builds the session for the current vocabulary, replacing one in progress.
    private func loadBoosting() {
        boosting = nil
        boostingTask?.cancel()
        boostingTask = nil
        let terms = vocabulary
        guard !terms.isEmpty else { return }
        let models = ctcModels ?? Task { try await CtcModels.downloadAndLoad(variant: .ctc110m) }
        ctcModels = models
        boostingTask = Task {
            defer { if !Task.isCancelled { boostingTask = nil } }
            do {
                let session = try await VocabularyBoosting(terms: terms, models: models.value)
                guard !Task.isCancelled else { return }
                boosting = session
            } catch {
                // Usually no network for the first download. The next dictation tries again.
                if ctcModels == models, (try? await models.value) == nil { ctcModels = nil }
                logger.error("Vocabulary boosting is off: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The transcript of 16 kHz mono speech, with the vocabulary terms the audio supports put in.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let recognizer else { throw TranscriberError.notReady }
        if boosting == nil, boostingTask == nil { loadBoosting() }
        let result = try await recognizer(samples)
        logger.info("Transcribed \(result.duration, format: .fixed(precision: 1)) s in \(result.processingTime, format: .fixed(precision: 2)) s")
        guard let boosting else { return result.text }
        return await boosting.transcript(of: result, audio: samples)
    }

    private func report(_ progress: DownloadProgress) {
        switch progress.phase {
        case .listing, .downloading: state = .downloading(progress.fractionCompleted)
        case .compiling: state = .loading
        }
    }
}

enum TranscriberError: Error { case notReady }
