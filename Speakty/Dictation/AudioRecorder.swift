@preconcurrency import AVFoundation
import AudioToolbox
import Synchronization
import os

/// Records the microphone as 16 kHz mono samples, the format Parakeet takes, and meters the voice
/// level for the recording display. A fresh engine per recording keeps the microphone off, and its
/// indicator hidden, between dictations, and picks up the chosen input every time.
@MainActor
final class AudioRecorder {
    enum Failure: Error { case noInput }

    /// Written on the audio thread, read on the main thread.
    private nonisolated let capture = Capture()
    private var engine: AVAudioEngine?
    private let logger = Logger(subsystem: "local.markus.Speakty", category: "Audio")
    #if DEBUG
    private var testAudio: Task<Void, Never>?
    #endif

    /// The voice level in 0...1, for drawing.
    nonisolated var level: Float { capture.level }

    /// False while Speakty Dev replays a test file instead of the microphone.
    var usesMicrophone: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: Self.testAudioKey) == nil
        #else
        true
        #endif
    }

    /// Records from the input with Core Audio UID `inputUID`, or the system default input when it's
    /// nil or no longer connected.
    func start(inputUID: String?) throws {
        capture.reset()
        #if DEBUG
        // Speakty Dev can replay a file instead of the microphone, so checks run without speaking:
        // `defaults write local.markus.Speakty.dev testAudioFile /path/to/speech.wav`.
        if let path = UserDefaults.standard.string(forKey: Self.testAudioKey) { return try replay(URL(fileURLWithPath: path)) }
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let inputUID, var device = AudioDevices.deviceID(forUID: inputUID), let unit = input.audioUnit {
            // The input unit takes a new device only while uninitialized; set on the running unit, the
            // engine delivers no audio at all. It keeps the default device's channel count, with the
            // chosen device's channels first.
            AudioUnitUninitialize(unit)
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            AudioUnitInitialize(unit)
            if status != noErr { logger.error("Couldn't select input \(inputUID, privacy: .public): \(status)") }
        }
        // The tap's format can be wider than the device, as above, so the device's own format says
        // how many of its channels carry sound.
        let format = input.outputFormat(forBus: 0)
        let device = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = MonoConverter(from: format, deviceChannels: device.channelCount) else { throw Failure.noInput }
        // @Sendable, so the closure isn't main-actor isolated like this method: AVFAudio calls it on
        // its own realtime queue, where a main-actor closure traps.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable [capture] buffer, _ in
            capture.append(converter.convert(buffer))
        }
        try engine.start()
        self.engine = engine
        logger.info("Recording from \(device.sampleRate) Hz, \(device.channelCount) channels")
    }

    /// Stops and returns everything recorded since `start`.
    func stop() -> [Float] {
        tearDown()
        return capture.take()
    }

    func cancel() {
        tearDown()
        _ = capture.take()
    }

    private func tearDown() {
        #if DEBUG
        testAudio?.cancel()
        testAudio = nil
        #endif
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
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
        testAudio = Task { [capture] in
            let chunk = Transcript.sampleRate / 20
            for start in stride(from: 0, to: samples.count, by: chunk) {
                capture.append(Array(samples[start..<min(start + chunk, samples.count)]))
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
        }
    }
    #endif
}

/// The samples and level of the recording in progress, shared between the audio and main threads.
private final class Capture: Sendable {
    private struct State {
        var samples: [Float] = []
        var level: Float = 0
    }

    private let state = Mutex(State())

    var level: Float { state.withLock(\.level) }

    func reset() { state.withLock { $0 = State() } }

    func take() -> [Float] {
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
