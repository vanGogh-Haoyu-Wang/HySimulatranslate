import Foundation

enum LLMProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case groq
    case nvidia

    var id: String { rawValue }
}

struct LLMProvider: Identifiable, Equatable, Sendable {
    let id: LLMProviderID
    let displayName: String
    let modelName: String
    let chatCompletionsURL: URL
    let getAPIKeyURL: URL
    let keychainAccount: String
    let keyPlaceholder: String
    let requiredKeyPrefix: String?
    let timeout: TimeInterval

    func acceptsKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let requiredKeyPrefix else { return true }
        return trimmed.hasPrefix(requiredKeyPrefix)
    }
}

struct LLMProviderCredential: Equatable, Sendable {
    let provider: LLMProvider
    let apiKey: String
}

enum LLMProviderCheckStatus: Equatable, Sendable {
    case notConfigured
    case passed
    case failed(String)

    var displayText: String {
        switch self {
        case .notConfigured:
            return "未配置"
        case .passed:
            return "通过"
        case .failed(let reason):
            return reason.isEmpty ? "未通过" : "未通过（\(reason)）"
        }
    }
}

struct LLMProviderCheckResult: Equatable, Sendable {
    let provider: LLMProvider
    let status: LLMProviderCheckStatus

    var passed: Bool {
        status == .passed
    }
}

enum LLMProviderCatalog {
    static let allProviders: [LLMProvider] = [
        LLMProvider(
            id: .groq,
            displayName: "Groq",
            modelName: "llama-3.3-70b-versatile",
            chatCompletionsURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            getAPIKeyURL: URL(string: "https://console.groq.com/keys")!,
            keychainAccount: "groq_api_key",
            keyPlaceholder: "gsk_...",
            requiredKeyPrefix: "gsk_",
            timeout: 4.0
        ),
        LLMProvider(
            id: .nvidia,
            displayName: "NVIDIA 总结",
            modelName: "nvidia/llama-3.3-nemotron-super-49b-v1",
            chatCompletionsURL: URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!,
            getAPIKeyURL: URL(string: "https://build.nvidia.com")!,
            keychainAccount: "nvidia_api_key",
            keyPlaceholder: "nvapi-...",
            requiredKeyPrefix: "nvapi-",
            timeout: 25.0
        )
    ]

    static func provider(for id: LLMProviderID) -> LLMProvider? {
        allProviders.first { $0.id == id }
    }

    static var groqCoreProvider: LLMProvider? {
        provider(for: .groq)
    }

    static var nvidiaSummaryProvider: LLMProvider? {
        provider(for: .nvidia)
    }

    static func groqCoreCredential(from keys: [LLMProviderID: String]) -> LLMProviderCredential? {
        credential(for: .groq, from: keys)
    }

    static func nvidiaSummaryCredential(from keys: [LLMProviderID: String]) -> LLMProviderCredential? {
        credential(for: .nvidia, from: keys)
    }

    static func credential(for id: LLMProviderID, from keys: [LLMProviderID: String]) -> LLMProviderCredential? {
        guard let provider = provider(for: id) else { return nil }
        let key = keys[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.acceptsKey(key) else { return nil }
        return LLMProviderCredential(provider: provider, apiKey: key)
    }

    static func mergedCheckResults(
        from keys: [LLMProviderID: String],
        testedResults: [LLMProviderCheckResult]
    ) -> [LLMProviderCheckResult] {
        allProviders.map { provider in
            if let tested = testedResults.first(where: { $0.provider.id == provider.id }) {
                return tested
            }
            let key = keys[provider.id, default: ""]
            let status: LLMProviderCheckStatus = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .notConfigured
                : .failed("Key 格式不匹配")
            return LLMProviderCheckResult(provider: provider, status: status)
        }
    }
}
