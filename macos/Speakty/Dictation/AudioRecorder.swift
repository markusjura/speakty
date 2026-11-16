@preconcurrency import AVFoundation
import AudioToolbox
import Synchronization
import os

/// Records the microphone as 16 kHz mono samples, the format Parakeet takes, and meters the voice
/// level for the recording display.
///
/// Speech before the microphone starts is lost, so starting fast matters. The engine is built once
/// per input and kept, since building one adds 100–200 ms to a start. It runs only while recording,
/// which keeps the microphone and its indicator off between dictations, unless it's kept on: an
/// interface such as the Vocaster takes over half a second to start from idle.
///
/// The engine lives on a serial queue of its own, as capture sessions do, so a slow start never
/// holds up the key events that tell a tap from a hold. Calls queue up in the order they're made,
/// so a stop or cancel always follows the start it belongs to. Its mutable state is only touched
/// on that queue, which is why the class can be unchecked Sendable.
final class AudioRecorder: @unchecked Sendable {
    enum Failure: Error { case noInput }

    private let queue = DispatchQueue(label: "local.markus.Speakty.audio", qos: .userInitiated)
    /// Written on the audio thread, read on the main thread.
    private let capture = Capture()
    private var microphone: Microphone?
    /// The Core Audio UID of the chosen input, or nil for the system default.
    private var inputUID: String?
    private var keepsOn = false
    private var isRecording = false
    private let logger = Logger(subsystem: "local.markus.Speakty", category: "Audio")
    #if DEBUG
    private var testAudio: DispatchSourceTimer?
    private var testChunks: ArraySlice<[Float]> = []
    #endif

    /// The voice level in 0...1, for drawing.
    var level: Float { capture.level }

    /// False while Speakty Dev replays a test file instead of the microphone.
    var usesMicrophone: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: Self.testAudioKey) == nil
        #else
        true
        #endif
    }

    /// Records from the input with Core Audio UID `inputUID`, or the system default input when it's
    /// nil or no longer connected. With `keepsOn`, the microphone runs between recordings too.
    func configure(inputUID: String?, keepsOn: Bool) {
        queue.async { [self] in
            guard inputUID != self.inputUID || keepsOn != self.keepsOn else { return }
            self.inputUID = inputUID
            self.keepsOn = keepsOn
            updateOrLog()
        }
    }

    /// Follows a change of devices, such as a microphone connected after it was chosen.
    func refresh() {
        queue.async { [self] in updateOrLog() }
    }

    /// Returns at once; `started` runs on the main actor once the microphone is live, or with the
    /// error that kept it from starting.
    func start(started: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void) {
        let requested = ContinuousClock.now
        queue.async { [self] in
            capture.begin()
            isRecording = true
            let result = Result {
                try update()
                #if DEBUG
                // Speakty Dev can replay a file instead of the microphone, so checks run without speaking:
                // `defaults write local.markus.Speakty.dev testAudioFile /path/to/speech.wav`.
                if let path = UserDefaults.standard.string(forKey: Self.testAudioKey) { try replay(URL(fileURLWithPath: path)) }
                #endif
            }
            if case .success = result {
                logger.info("Recording after \(requested.duration(to: .now).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            }
            Task { @MainActor in started(result) }
        }
    }

    /// Stops and returns everything recorded since `start`. Main actor, like the calls to `start` and
    /// `cancel`, so the stop is queued right away, ahead of any start that follows it.
    @MainActor func stop() async -> [Float] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: finish()) }
        }
    }

    func cancel() {
        queue.async { [self] in _ = finish() }
    }

    private func finish() -> [Float] {
        isRecording = false
        #if DEBUG
        testAudio?.cancel()
        testAudio = nil
        testChunks = []
        #endif
        let samples = capture.end()
        updateOrLog()
        return samples
    }

    /// Runs the microphone while it records or is kept on, and stops it otherwise. Builds a new
    /// engine when the input or its format changed.
    private func update() throws {
        guard usesMicrophone, isRecording || keepsOn else {
            microphone?.stop()
            return
        }
        guard let device = inputUID.flatMap(AudioDevices.deviceID(forUID:)) ?? AudioDevices.defaultInput else { throw Failure.noInput }
        if let microphone, microphone.device != device || !microphone.isCurrent { self.microphone = nil }
        let microphone = try self.microphone ?? Microphone(device: device, capture: capture) { [weak self] in
            // The engine stops itself when a device changes, as when headphones connect.
            self?.refresh()
        }
        self.microphone = microphone
        try microphone.start()
    }

    /// For updates without a start to report a failure to.
    private func updateOrLog() {
        do { try update() } catch { logger.error("Microphone didn't start: \(error.localizedDescription, privacy: .public)") }
    }

    #if DEBUG
    private static let testAudioKey = "testAudioFile"

    /// Feeds the file in real time, as the microphone would, so the level moves and a short hold
    /// records only the start.
    private func replay(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = MonoConverter(from: file.processingFormat, deviceChannels: file.processingFormat.channelCount) else { throw Failure.noInput }
        try file.read(into: buffer)
        let samples = converter.convert(buffer)
        let chunk = Transcript.sampleRate / 20
        testChunks = ArraySlice(stride(from: 0, to: samples.count, by: chunk).map { Array(samples[$0..<min($0 + chunk, samples.count)]) })
        // On the recorder's queue, so a stop or cancel ends it before the next recording starts.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [self] in
            if let next = testChunks.popFirst() { capture.append(next) } else { testAudio?.cancel() }
        }
        timer.resume()
        testAudio = timer
    }
    #endif
}

/// An engine with a tap that feeds one input device into `capture`. Used only on the recorder's queue.
private final class Microphone {
    let device: AudioDeviceID
    private let engine = AVAudioEngine()
    private let deviceFormat: AVAudioFormat
    private var observer: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "local.markus.Speakty", category: "Audio")

    /// `changed` runs on any thread when the engine stops itself for a change of devices.
    init(device: AudioDeviceID, capture: Capture, changed: @escaping @Sendable () -> Void) throws {
        self.device = device
        let input = engine.inputNode
        if let unit = input.audioUnit {
            var selected = device
            // The input unit takes a new device only while uninitialized; set on the running unit, the
            // engine delivers no audio at all. It keeps the default device's channel count, with the
            // chosen device's channels first.
            AudioUnitUninitialize(unit)
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
            AudioUnitInitialize(unit)
            if status != noErr { logger.error("Couldn't select input \(device): \(status)") }
        }
        // The tap's format can be wider than the device, as above, so the device's own format says
        // how many of its channels carry sound.
        let format = input.outputFormat(forBus: 0)
        deviceFormat = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = MonoConverter(from: format, deviceChannels: deviceFormat.channelCount) else { throw AudioRecorder.Failure.noInput }
        // AVFAudio calls the tap on its own realtime queue.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable [capture] buffer, _ in
            capture.append(converter.convert(buffer))
        }
        engine.prepare()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { _ in changed() }
        logger.info("Microphone ready: \(self.deviceFormat.sampleRate) Hz, \(self.deviceFormat.channelCount) channels")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// False once the device's format changed, as when its sample rate is switched, since the tap's
    /// converter was made for the old one.
    var isCurrent: Bool { engine.inputNode.inputFormat(forBus: 0) == deviceFormat }

    func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    func stop() { engine.stop() }
}

/// The samples and level of the recording in progress, shared between the audio and main threads.
/// Chunks that arrive while it isn't recording, from a microphone kept on, are dropped.
private final class Capture: Sendable {
    private struct State {
        var samples: [Float] = []
        var level: Float = 0
        var isRecording = false
    }

    private let state = Mutex(State())

    var level: Float { state.withLock(\.level) }

    func begin() { state.withLock { $0 = State(isRecording: true) } }

    func end() -> [Float] {
        state.withLock { state in
            defer { state = State() }
            return state.samples
        }
    }

    /// Appends a chunk and moves the level toward its loudness: quickly up, slowly down, as meters do.
    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        // -50 dB is silence and -10 dB a loud voice.
        let loudness = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
        state.withLock { state in
            guard state.isRecording else { return }
            state.samples += chunk
            state.level = loudness > state.level ? loudness : state.level * 0.7 + loudness * 0.3
        }
    }
}

/// Mixes the device's voice channels to mono and resamples them to 16 kHz Float32. Used only on the
/// audio thread after creation, which is why it can be unchecked Sendable.
final class MonoConverter: @unchecked Sendable {
    private let channels: Int
    private let mono: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter

    /// `input` is the standard (deinterleaved Float32) format of the buffers, and `deviceChannels` the
    /// number of them the device fills. Mono and stereo devices mix every channel. Interfaces with
    /// more, such as the Vocaster's ten, carry the voice mix on channel 1 and separate sources and
    /// loopbacks on the rest, so they record channel 1 alone.
    init?(from input: AVAudioFormat, deviceChannels: AVAudioChannelCount) {
        let channels = Int(min(deviceChannels > 2 ? 1 : deviceChannels, input.channelCount))
        guard input.commonFormat == .pcmFormatFloat32, !input.isInterleaved, channels > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 1),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Transcript.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: output) else { return nil }
        self.channels = channels
        self.mono = mono
        self.output = output
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let source = buffer.floatChannelData,
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let destination = mixed.floatChannelData?[0] else { return [] }
        let scale = 1 / Float(channels)
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels { sum += source[channel][frame] }
            destination[frame] = sum * scale
        }
        mixed.frameLength = buffer.frameLength

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / mono.sampleRate) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mixed
        }
        guard error == nil, let channel = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}
