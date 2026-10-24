import Foundation
import Observation

/// The single typed preference store. Each section persists immediately on assignment; an
/// invalid section value is ignored, keeping the previous value. Stored sections are merged
/// over current defaults when loaded, so added fields keep their defaults and unknown or
/// invalid stored data falls back to the default for that section only.
@MainActor @Observable
final class AppPreferences {
    private enum Key: String {
        case general, recording, transcript
        var storageKey: String { "preferences.v1.\(rawValue)" }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedGeneral: GeneralPreferences
    private var storedRecording: RecordingPreferences
    private var storedTranscript: TranscriptPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedGeneral = Self.load(.general, from: defaults, default: GeneralPreferences(), isValid: \.isValid)
        storedRecording = Self.load(.recording, from: defaults, default: RecordingPreferences(), isValid: \.isValid)
        storedTranscript = Self.load(.transcript, from: defaults, default: TranscriptPreferences(), isValid: \.isValid)
    }

    var general: GeneralPreferences {
        get { storedGeneral }
        set { guard newValue.isValid, newValue != storedGeneral else { return }; storedGeneral = newValue; save(newValue, .general) }
    }

    var recording: RecordingPreferences {
        get { storedRecording }
        set { guard newValue.isValid, newValue != storedRecording else { return }; storedRecording = newValue; save(newValue, .recording) }
    }

    var transcript: TranscriptPreferences {
        get { storedTranscript }
        set { guard newValue.isValid, newValue != storedTranscript else { return }; storedTranscript = newValue; save(newValue, .transcript) }
    }

    private func save<Value: Encodable>(_ value: Value, _ key: Key) {
        // Encoding plain Codable values cannot fail; a failure would be a programming error.
        guard let data = try? JSONEncoder().encode(value) else { return assertionFailure("Unencodable \(key)") }
        defaults.set(data, forKey: key.storageKey)
    }

    private static func load<Value: Codable>(_ key: Key, from defaults: UserDefaults, default base: Value,
                                             isValid: (Value) -> Bool) -> Value {
        guard let data = defaults.data(forKey: key.storageKey),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseData = try? JSONEncoder().encode(base),
              let baseObject = try? JSONSerialization.jsonObject(with: baseData),
              let mergedData = try? JSONSerialization.data(withJSONObject: merge(stored, over: baseObject)),
              let value = try? JSONDecoder().decode(Value.self, from: mergedData),
              isValid(value) else { return base }
        return value
    }

    /// Stored keys win; nested objects merge recursively so new nested fields keep defaults.
    /// Enum cases with associated values encode as single-key objects; a different stored case
    /// replaces the default case instead of merging with it.
    private static func merge(_ stored: Any, over base: Any) -> Any {
        guard let stored = stored as? [String: Any], let base = base as? [String: Any] else { return stored }
        if stored.count == 1, base.count == 1, stored.keys.first != base.keys.first { return stored }
        return base.merging(stored) { baseValue, storedValue in merge(storedValue, over: baseValue) }
    }
}
