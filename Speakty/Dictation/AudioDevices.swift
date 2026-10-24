import CoreAudio
import Foundation
import os

/// A microphone Settings can pick, identified by its Core Audio UID, which survives reconnects.
struct AudioInput: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Core Audio lookups for the microphone picker, the recorder, and muting while recording.
enum AudioDevices {
    /// Devices with at least one input channel, in Core Audio's order.
    static func inputs() -> [AudioInput] {
        deviceIDs().compactMap { device in
            guard inputChannelCount(device) > 0, let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName) else { return nil }
            return AudioInput(id: uid, name: name)
        }
    }

    /// Yields whenever a device connects or disconnects, until the consuming task ends.
    static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            var address = devicesAddress
            let queue = DispatchQueue(label: "local.markus.Speakty.devices")
            let listener: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in continuation.yield() }
            let system = AudioObjectID(kAudioObjectSystemObject)
            AudioObjectAddPropertyListenerBlock(system, &address, queue, listener)
            continuation.onTermination = { _ in
                var address = devicesAddress
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
            }
        }
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { self.uid(of: $0) == uid }
    }

    static func uid(of device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    static var defaultOutput: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Mutes the default output while recording, so music and calls stay out of it, and restores it
/// afterwards. Leaves a device alone that was already muted or can't be muted. The UID of the device
/// it muted is kept in defaults until it unmutes, so the launch after a crash unmutes it.
@MainActor
final class OutputMuter {
    private static let mutedKey = "mutedOutputDevice"
    private let logger = Logger(subsystem: "local.markus.Speakty", category: "Audio")

    init() { restore() }

    func mute() {
        guard UserDefaults.standard.string(forKey: Self.mutedKey) == nil, let device = AudioDevices.defaultOutput,
              let uid = AudioDevices.uid(of: device), Self.isMuted(device) == false, Self.setMuted(device, true) else { return }
        UserDefaults.standard.set(uid, forKey: Self.mutedKey)
    }

    func restore() {
        guard let uid = UserDefaults.standard.string(forKey: Self.mutedKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.mutedKey)
        // A device unplugged meanwhile has nothing left to unmute.
        if let device = AudioDevices.deviceID(forUID: uid), !Self.setMuted(device, false) {
            logger.error("Couldn't unmute \(uid, privacy: .public)")
        }
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Nil when the device has no mute control.
    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
