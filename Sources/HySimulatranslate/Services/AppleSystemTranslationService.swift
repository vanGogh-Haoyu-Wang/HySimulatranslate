import Foundation
#if canImport(Translation)
import Translation
#endif

protocol AppleSystemTranslating: Sendable {
    func prepare() async -> Bool
    func translate(_ text: String) async -> String?
}

enum TranslationExecutionMode: Equatable, Sendable {
    case online
    case appleOffline
    case unavailable

    static func resolve(apiReady: Bool, appleReady: Bool) -> TranslationExecutionMode {
        if apiReady { return .online }
        if appleReady { return .appleOffline }
        return .unavailable
    }

    var isTranslationEnabled: Bool {
        self != .unavailable
    }

    var statusTitle: String {
        switch self {
        case .online:
            return "在线同传"
        case .appleOffline:
            return "Apple 离线同传"
        case .unavailable:
            return "本地转录"
        }
    }
}

enum AppleTranslationTextNormalizer {
    static func simplifiedChinese(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }
}

actor AppleTranslationRequestGate {
    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isAvailable {
            isAvailable = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAvailable = true
            return
        }
        waiters.removeFirst().resume()
    }
}

actor AppleSystemTranslationService: AppleSystemTranslating {
    private var translationHandler: (@Sendable (String) async -> String?)?

    func prepare() async -> Bool {
        if translationHandler != nil { return true }

        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let backend = AppleTranslationSessionBackend()
            guard await backend.prepare() else { return false }
            translationHandler = { text in
                await backend.translate(text)
            }
            return true
        }
        #endif

        return false
    }

    func translate(_ text: String) async -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, let translationHandler else { return nil }
        guard let translated = await translationHandler(source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !translated.isEmpty
        else { return nil }
        return AppleTranslationTextNormalizer.simplifiedChinese(translated)
    }
}

#if canImport(Translation)
@available(macOS 26.0, *)
private actor AppleTranslationSessionBackend {
    private var session: TranslationSession?
    private let requestGate = AppleTranslationRequestGate()

    func prepare() async -> Bool {
        if session != nil { return true }

        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        let newSession: TranslationSession
        if #available(macOS 26.4, *) {
            newSession = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        } else {
            newSession = TranslationSession(installedSource: source, target: target)
        }

        guard await newSession.isReady else { return false }
        session = newSession
        return true
    }

    func translate(_ text: String) async -> String? {
        await requestGate.acquire()
        guard !Task.isCancelled, let session else {
            await requestGate.release()
            return nil
        }

        let translated: String?
        do {
            translated = try await session.translate(text).targetText
        } catch {
            translated = nil
        }
        await requestGate.release()
        return translated
    }
}
#endif
