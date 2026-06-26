import Foundation

struct AudioInputSelection: Codable, Equatable, Sendable {
    var microphoneEnabled: Bool
    var systemAudioEnabled: Bool

    static let defaultSelection = AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: false)
    static let defaultSelectionStorageValue = #"{"microphoneEnabled":true,"systemAudioEnabled":false}"#

    var hasEnabledInput: Bool {
        microphoneEnabled || systemAudioEnabled
    }

    var storageValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return Self.defaultSelectionStorageValue
        }
        return string
    }

    var displayTitle: String {
        switch (microphoneEnabled, systemAudioEnabled) {
        case (true, true):
            return "麦克风 + 电脑音频"
        case (true, false):
            return "麦克风"
        case (false, true):
            return "电脑音频"
        case (false, false):
            return "未选择音频"
        }
    }

    static func fromStorageValue(
        _ value: String?,
        legacyAudioCaptureSourceStorage legacyValue: String?
    ) -> AudioInputSelection {
        if let value,
           !value.isEmpty,
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AudioInputSelection.self, from: data) {
            return decoded
        }

        guard let legacyValue,
              !legacyValue.isEmpty,
              let data = legacyValue.data(using: .utf8),
              let source = try? JSONDecoder().decode(AudioCaptureSource.self, from: data) else {
            return .defaultSelection
        }

        switch source.kind {
        case .microphone:
            return AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: false)
        case .systemAudio, .applicationAudio:
            return AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: true)
        }
    }
}
