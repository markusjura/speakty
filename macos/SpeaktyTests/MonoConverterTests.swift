import AVFoundation
import XCTest
@testable import Speakty

final class MonoConverterTests: XCTestCase {
    /// A chosen stereo device can arrive in the default device's ten-channel layout, with its own
    /// channels first. Its second channel counts; an interface's second channel doesn't.
    func testMixesTheDeviceChannelsThatCarrySound() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 10))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let secondChannelOnly = try tone(in: format, onChannel: 1)
        let firstChannelOnly = try tone(in: format, onChannel: 0)

        let stereo = try XCTUnwrap(MonoConverter(from: format, deviceChannels: 2))
        let interface = try XCTUnwrap(MonoConverter(from: format, deviceChannels: 10))

        XCTAssertGreaterThan(rms(stereo.convert(secondChannelOnly)), 0.1)
        XCTAssertEqual(rms(interface.convert(secondChannelOnly)), 0)
        XCTAssertGreaterThan(rms(interface.convert(firstChannelOnly)), 0.1)
    }

    private func tone(in format: AVAudioFormat, onChannel channel: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for c in 0..<Int(format.channelCount) {
            for frame in 0..<4800 { samples[c][frame] = c == channel ? 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000) : 0 }
        }
        return buffer
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}
