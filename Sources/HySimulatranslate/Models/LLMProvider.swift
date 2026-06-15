import Foundation

enum LLMProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case groq
    case nvidia
    case agnes

    var id: String { rawValue }
}

struct LLMProvider: Identifiable, Equatable, Sendable {
    let id: LLMProviderID
    let displayName: String
    let modelName: String
    let chatCompletionsURL: URL
    let modelsURL: URL
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

    func withModelName(_ modelName: String) -> LLMProvider {
        LLMProvider(
            id: id,
            displayName: displayName,
            modelName: modelName,
            chatCompletionsURL: chatCompletionsURL,
            modelsURL: modelsURL,
            getAPIKeyURL: getAPIKeyURL,
            keychainAccount: keychainAccount,
            keyPlaceholder: keyPlaceholder,
            requiredKeyPrefix: requiredKeyPrefix,
            timeout: timeout
        )
    }
}

enum LLMProviderModelFreeStatus: String, Codable, Sendable {
    case free
    case unknown

    var displayText: String {
        switch self {
        case .free: return "Free"
        case .unknown: return "Unknown"
        }
    }

    var sortRank: Int {
        switch self {
        case .free: return 0
        case .unknown: return 1
        }
    }
}

struct LLMProviderModel: Identifiable, Codable, Equatable, Sendable {
    let providerID: LLMProviderID
    let id: String
    let freeStatus: LLMProviderModelFreeStatus
    let recommendationScore: Int

    var displayText: String {
        "\(id) · \(freeStatus.displayText)"
    }
}

enum LLMProviderModelConnectivityStatus: String, Codable, Sendable {
    case passed
    case failed
}

struct LLMProviderModelConnectivityRecord: Codable, Equatable, Sendable {
    let providerID: LLMProviderID
    let modelID: String
    let status: LLMProviderModelConnectivityStatus
    let detail: String
    let testedAt: Date
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
    static let defaultGroqModelName = "llama-3.3-70b-versatile"
    static let defaultNvidiaSummaryModelName = "nvidia/llama-3.3-nemotron-super-49b-v1"
    static let defaultAgnesOrganizerModelName = "agnes-2.0-flash"

    static let allProviders: [LLMProvider] = [
        LLMProvider(
            id: .groq,
            displayName: "Groq",
            modelName: defaultGroqModelName,
            chatCompletionsURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            modelsURL: URL(string: "https://api.groq.com/openai/v1/models")!,
            getAPIKeyURL: URL(string: "https://console.groq.com/keys")!,
            keychainAccount: "groq_api_key",
            keyPlaceholder: "gsk_...",
            requiredKeyPrefix: "gsk_",
            timeout: 4.0
        ),
        LLMProvider(
            id: .nvidia,
            displayName: "NVIDIA 总结",
            modelName: defaultNvidiaSummaryModelName,
            chatCompletionsURL: URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!,
            modelsURL: URL(string: "https://integrate.api.nvidia.com/v1/models")!,
            getAPIKeyURL: URL(string: "https://build.nvidia.com")!,
            keychainAccount: "nvidia_api_key",
            keyPlaceholder: "nvapi-...",
            requiredKeyPrefix: "nvapi-",
            timeout: 25.0
        ),
        LLMProvider(
            id: .agnes,
            displayName: "Agnes 整理",
            modelName: defaultAgnesOrganizerModelName,
            chatCompletionsURL: URL(string: "https://apihub.agnes-ai.com/v1/chat/completions")!,
            modelsURL: URL(string: "https://apihub.agnes-ai.com/v1/models")!,
            getAPIKeyURL: URL(string: "https://agnes-ai.com")!,
            keychainAccount: "agnes_api_key",
            keyPlaceholder: "sk-...",
            requiredKeyPrefix: "sk-",
            timeout: 15.0
        )
    ]

    static let groqCoreModels: [LLMProviderModel] = sortedModels(groqKnownFreeTextModels.map {
        LLMProviderModel(providerID: .groq, id: $0.key, freeStatus: .free, recommendationScore: $0.value)
    })

    static let nvidiaSummaryModels: [LLMProviderModel] = sortedModels(nvidiaKnownFreeSummaryModels.map {
        LLMProviderModel(providerID: .nvidia, id: $0.key, freeStatus: .free, recommendationScore: $0.value)
    })

    static let agnesOrganizerModels: [LLMProviderModel] = [
        LLMProviderModel(
            providerID: .agnes,
            id: defaultAgnesOrganizerModelName,
            freeStatus: .free,
            recommendationScore: 100
        )
    ]

    static func models(for id: LLMProviderID) -> [LLMProviderModel] {
        switch id {
        case .groq:
            return groqCoreModels
        case .nvidia:
            return nvidiaSummaryModels
        case .agnes:
            return agnesOrganizerModels
        }
    }

    static func freeModels(for providerID: LLMProviderID, modelIDs: [String]) -> [LLMProviderModel] {
        let uniqueIDs = Array(Set(modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
        let models = uniqueIDs.compactMap { model(for: providerID, modelID: $0, preserveUnknown: false) }
        return sortedModels(models)
    }

    static func model(
        for providerID: LLMProviderID,
        modelID: String,
        preserveUnknown: Bool
    ) -> LLMProviderModel? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        switch providerID {
        case .groq:
            if isKnownGroqFreeTextModel(id) {
                return LLMProviderModel(
                    providerID: providerID,
                    id: id,
                    freeStatus: .free,
                    recommendationScore: recommendationScore(for: providerID, modelID: id)
                )
            }
        case .nvidia:
            if isLikelyNvidiaFreeSummaryModel(id) {
                return LLMProviderModel(
                    providerID: providerID,
                    id: id,
                    freeStatus: .free,
                    recommendationScore: recommendationScore(for: providerID, modelID: id)
                )
            }
        case .agnes:
            if id == defaultAgnesOrganizerModelName {
                return LLMProviderModel(
                    providerID: providerID,
                    id: id,
                    freeStatus: .free,
                    recommendationScore: recommendationScore(for: providerID, modelID: id)
                )
            }
        }

        guard preserveUnknown else { return nil }
        return LLMProviderModel(
            providerID: providerID,
            id: id,
            freeStatus: .unknown,
            recommendationScore: recommendationScore(for: providerID, modelID: id)
        )
    }

    static func provider(for id: LLMProviderID, modelName: String? = nil) -> LLMProvider? {
        guard let provider = allProviders.first(where: { $0.id == id }) else { return nil }
        guard let modelName = normalizedModelName(modelName), !modelName.isEmpty else {
            return provider
        }
        return provider.withModelName(modelName)
    }

    static var groqCoreProvider: LLMProvider? {
        provider(for: .groq)
    }

    static var nvidiaSummaryProvider: LLMProvider? {
        provider(for: .nvidia)
    }

    static var agnesOrganizerProvider: LLMProvider? {
        provider(for: .agnes)
    }

    static func groqCoreCredential(from keys: [LLMProviderID: String]) -> LLMProviderCredential? {
        credential(for: .groq, from: keys)
    }

    static func groqCoreCredential(
        from keys: [LLMProviderID: String],
        selectedModelNames: [LLMProviderID: String]
    ) -> LLMProviderCredential? {
        credential(for: .groq, from: keys, selectedModelNames: selectedModelNames)
    }

    static func nvidiaSummaryCredential(from keys: [LLMProviderID: String]) -> LLMProviderCredential? {
        credential(for: .nvidia, from: keys)
    }

    static func nvidiaSummaryCredential(
        from keys: [LLMProviderID: String],
        selectedModelNames: [LLMProviderID: String]
    ) -> LLMProviderCredential? {
        credential(for: .nvidia, from: keys, selectedModelNames: selectedModelNames)
    }

    static func agnesOrganizerCredential(from keys: [LLMProviderID: String]) -> LLMProviderCredential? {
        credential(for: .agnes, from: keys)
    }

    static func credential(
        for id: LLMProviderID,
        from keys: [LLMProviderID: String],
        selectedModelNames: [LLMProviderID: String] = [:]
    ) -> LLMProviderCredential? {
        guard let provider = provider(for: id, modelName: selectedModelNames[id]) else { return nil }
        let key = keys[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.acceptsKey(key) else { return nil }
        return LLMProviderCredential(provider: provider, apiKey: key)
    }

    static func mergedCheckResults(
        from keys: [LLMProviderID: String],
        testedResults: [LLMProviderCheckResult],
        selectedModelNames: [LLMProviderID: String] = [:]
    ) -> [LLMProviderCheckResult] {
        allProviders.map { baseProvider in
            if let tested = testedResults.first(where: { $0.provider.id == baseProvider.id }) {
                return tested
            }
            let provider = provider(for: baseProvider.id, modelName: selectedModelNames[baseProvider.id]) ?? baseProvider
            let key = keys[provider.id, default: ""]
            let status: LLMProviderCheckStatus = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .notConfigured
                : .failed("Key 格式不匹配")
            return LLMProviderCheckResult(provider: provider, status: status)
        }
    }

    static func sortedModels(
        _ models: [LLMProviderModel],
        connectivityRecords: [String: LLMProviderModelConnectivityRecord] = [:]
    ) -> [LLMProviderModel] {
        var bestByID: [String: LLMProviderModel] = [:]
        for model in models {
            if let existing = bestByID[model.id],
               existing.recommendationScore >= model.recommendationScore,
               existing.freeStatus.sortRank <= model.freeStatus.sortRank {
                continue
            }
            bestByID[model.id] = model
        }
        return bestByID.values.sorted {
            let leftFailed = connectivityRecords[connectivityKey(providerID: $0.providerID, modelID: $0.id)]?.status == .failed
            let rightFailed = connectivityRecords[connectivityKey(providerID: $1.providerID, modelID: $1.id)]?.status == .failed
            if leftFailed != rightFailed {
                return !leftFailed
            }
            if $0.freeStatus.sortRank != $1.freeStatus.sortRank {
                return $0.freeStatus.sortRank < $1.freeStatus.sortRank
            }
            if $0.recommendationScore != $1.recommendationScore {
                return $0.recommendationScore > $1.recommendationScore
            }
            return $0.id < $1.id
        }
    }

    static func connectivityKey(providerID: LLMProviderID, modelID: String) -> String {
        "\(providerID.rawValue)|\(modelID)"
    }

    static func connectivityRecordsByKey(
        _ records: [LLMProviderModelConnectivityRecord]
    ) -> [String: LLMProviderModelConnectivityRecord] {
        Dictionary(uniqueKeysWithValues: records.map {
            (connectivityKey(providerID: $0.providerID, modelID: $0.modelID), $0)
        })
    }

    private static func normalizedModelName(_ modelName: String?) -> String? {
        modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let groqKnownFreeTextModels: [String: Int] = [
        defaultGroqModelName: 100,
        "openai/gpt-oss-120b": 98,
        "openai/gpt-oss-20b": 94,
        "llama-3.1-8b-instant": 88,
        "moonshotai/kimi-k2-instruct": 86,
        "qwen/qwen3-32b": 84,
        "meta-llama/llama-4-scout-17b-16e-instruct": 82,
        "meta-llama/llama-4-maverick-17b-128e-instruct": 80,
        "deepseek-r1-distill-llama-70b": 78,
        "gemma2-9b-it": 74,
        "compound-beta": 65,
        "compound-beta-mini": 60
    ]

    private static let nvidiaKnownFreeSummaryModels: [String: Int] = [
        defaultNvidiaSummaryModelName: 100,
        "nvidia/nemotron-3-nano-30b-a3b": 92,
        "nvidia/llama-3.1-nemotron-70b-instruct": 86,
        "meta/llama-3.1-70b-instruct": 72
    ]

    private static func isKnownGroqFreeTextModel(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        return groqKnownFreeTextModels[id] != nil ||
            id.hasPrefix("openai/gpt-oss-") ||
            id.hasPrefix("qwen/") ||
            id.hasPrefix("moonshotai/kimi-k2") ||
            id.hasPrefix("meta-llama/llama-4-") ||
            id == "llama-3.1-8b-instant" ||
            id == "llama-3.3-70b-versatile" ||
            id == "deepseek-r1-distill-llama-70b" ||
            id == "gemma2-9b-it" ||
            id.hasPrefix("compound-beta")
    }

    private static func isLikelyNvidiaFreeSummaryModel(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        if nvidiaKnownNonFreeOrProblemModels.contains(id) { return false }
        if nvidiaKnownFreeSummaryModels[id] != nil { return true }
        guard id.contains("llama") || id.contains("nemotron") else { return false }
        let excludedFragments = [
            "safety", "guard", "vl", "vision", "embed", "rerank", "retriever",
            "parakeet", "asr", "tts", "ocr", "translate", "cosmos", "be v",
            "yolo", "parse", "content-safety", "jailbreak"
        ]
        return !excludedFragments.contains { id.contains($0) }
    }

    private static func recommendationScore(for providerID: LLMProviderID, modelID: String) -> Int {
        let id = modelID.lowercased()
        switch providerID {
        case .groq:
            if let score = groqKnownFreeTextModels[id] { return score }
        case .nvidia:
            if let score = nvidiaKnownFreeSummaryModels[id] { return score }
        case .agnes:
            if id == defaultAgnesOrganizerModelName { return 100 }
        }
        if id.contains("gpt-oss-120b") { return 98 }
        if id.contains("super-49b-v1") && !id.contains("v1.5") { return 100 }
        if id.contains("gpt-oss-20b") { return 94 }
        if id.contains("70b") { return 86 }
        if id.contains("49b") { return 84 }
        if id.contains("32b") { return 82 }
        if id.contains("30b") { return 80 }
        if id.contains("17b") { return 78 }
        if id.contains("12b") { return 70 }
        if id.contains("9b") || id.contains("8b") { return 64 }
        if id.contains("mini") || id.contains("nano") { return 58 }
        return 50
    }

    private static let nvidiaKnownNonFreeOrProblemModels: Set<String> = [
        "nvidia/llama-3.3-nemotron-super-49b-v1.5"
    ]
}
