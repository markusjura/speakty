import Foundation
import os

/// Pauses the media that's playing, such as music or a video, while a dictation records, and plays it
/// again afterwards. Media that was already paused stays paused.
///
/// This goes through the private MediaRemote framework. Since macOS 15.4 it doesn't tell apps outside
/// Apple whether anything is playing, but `osascript`, an Apple tool, can still ask, in about 80 ms.
/// Sending play and pause works from Speakty itself.
@MainActor
final class MediaPauser {
    private var pausing: Task<Void, Never>?
    private var didPause = false
    private let logger = Logger(subsystem: "local.markus.Speakty", category: "Media")

    func pause() {
        pausing = Task {
            guard await Self.isPlaying(), !Task.isCancelled else { return }
            didPause = Self.send(.pause)
            logger.info("Paused media")
        }
    }

    /// Also stops a pause that's still asking whether anything plays.
    func resume() {
        pausing?.cancel()
        pausing = nil
        guard didPause else { return }
        didPause = false
        _ = Self.send(.play)
    }

    private nonisolated static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework"

    private nonisolated static func isPlaying() async -> Bool {
        let script = "$.NSBundle.bundleWithPath('\(frameworkPath)').load; $.NSClassFromString('MRNowPlayingRequest').localIsPlaying"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: answer.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    /// MediaRemote's `MRCommand` values.
    private enum Command: UInt32 {
        case play = 0, pause = 1
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard let framework = dlopen("\(frameworkPath)/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(framework, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }
}
