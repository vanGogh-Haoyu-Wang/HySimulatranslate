import Foundation

struct AudioCaptureSource: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case microphone
        case systemAudio
        case applicationAudio
    }

    var kind: Kind
    var appBundleIdentifier: String?
    var appName: String?

    var id: String {
        storageValue
    }

    var storageValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return Self.microphoneStorageValue }
        return string
    }

    var menuTitle: String {
        switch kind {
        case .microphone:
            return "麦克风"
        case .systemAudio:
            return "全系统音频"
        case .applicationAudio:
            return appName?.isEmpty == false ? appName! : "应用音频"
        }
    }

    var statusTitle: String {
        switch kind {
        case .microphone:
            return "麦克风"
        case .systemAudio:
            return "全系统音频 + 麦克风"
        case .applicationAudio:
            let name = appName?.isEmpty == false ? appName! : "应用"
            return "\(name) + 麦克风"
        }
    }

    var systemImage: String {
        switch kind {
        case .microphone:
            return "mic"
        case .systemAudio:
            return "speaker.wave.2"
        case .applicationAudio:
            return "app.connected.to.app.below.fill"
        }
    }

    static let microphone = AudioCaptureSource(kind: .microphone, appBundleIdentifier: nil, appName: nil)
    static let systemAudio = AudioCaptureSource(kind: .systemAudio, appBundleIdentifier: nil, appName: nil)

    static let microphoneStorageValue = #"{"kind":"microphone"}"#

    static func application(bundleIdentifier: String, name: String) -> AudioCaptureSource {
        AudioCaptureSource(kind: .applicationAudio, appBundleIdentifier: bundleIdentifier, appName: name)
    }

    static func fromStorageValue(_ value: String) -> AudioCaptureSource {
        guard let data = value.data(using: .utf8),
              let source = try? JSONDecoder().decode(AudioCaptureSource.self, from: data)
        else { return .microphone }
        switch source.kind {
        case .applicationAudio:
            return .systemAudio
        case .microphone, .systemAudio:
            return source
        }
    }

    static func containsDeprecatedApplicationAudio(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8),
              let source = try? JSONDecoder().decode(AudioCaptureSource.self, from: data)
        else { return false }
        return source.kind == .applicationAudio
    }
}
