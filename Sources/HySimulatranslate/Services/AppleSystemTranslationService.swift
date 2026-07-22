import Foundation
#if canImport(Translation)
import Translation
#endif

protocol AppleSystemTranslating: Sendable {
    func prepare(sourceLanguage: String, targetLanguage: String) async -> Bool
    func translate(_ text: String, sourceLanguage: String, targetLanguage: String) async -> String?
}

extension AppleSystemTranslating {
    func prepare() async -> Bool {
        await prepare(sourceLanguage: "en", targetLanguage: "zh")
    }

    func translate(_ text: String) async -> String? {
        await translate(text, sourceLanguage: "en", targetLanguage: "zh")
    }
}

struct TranslationLanguagePair: Hashable, Sendable {
    let source: String
    let target: String

    init(source: String, target: String) {
        self.source = source.lowercased().hasPrefix("zh") ? "zh-Hans" : source
        self.target = target.lowercased().hasPrefix("zh") ? "zh-Hans" : target
    }
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
    private var translationHandlers: [TranslationLanguagePair: @Sendable (String) async -> String?] = [:]

    func prepare(sourceLanguage: String = "en", targetLanguage: String = "zh") async -> Bool {
        let pair = TranslationLanguagePair(source: sourceLanguage, target: targetLanguage)
        guard pair.source != pair.target else { return false }
        if translationHandlers[pair] != nil { return true }

        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let backend = AppleTranslationSessionBackend(pair: pair)
            guard await backend.prepare() else { return false }
            translationHandlers[pair] = { text in
                await backend.translate(text)
            }
            return true
        }
        #endif

        return false
    }

    func translate(_ text: String, sourceLanguage: String = "en", targetLanguage: String = "zh") async -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pair = TranslationLanguagePair(source: sourceLanguage, target: targetLanguage)
        if translationHandlers[pair] == nil {
            guard await prepare(sourceLanguage: pair.source, targetLanguage: pair.target) else { return nil }
        }
        guard !source.isEmpty, let translationHandler = translationHandlers[pair] else { return nil }
        guard let translated = await translationHandler(source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !translated.isEmpty
        else { return nil }
        return pair.target.lowercased().hasPrefix("zh")
            ? AppleTranslationTextNormalizer.simplifiedChinese(translated)
            : translated
    }
}

#if canImport(Translation)
@available(macOS 26.0, *)
private actor AppleTranslationSessionBackend {
    private let pair: TranslationLanguagePair
    private var session: TranslationSession?
    private let requestGate = AppleTranslationRequestGate()

    init(pair: TranslationLanguagePair) {
        self.pair = pair
    }

    func prepare() async -> Bool {
        if session != nil { return true }

        let source = Locale.Language(identifier: pair.source)
        let target = Locale.Language(identifier: pair.target)
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
