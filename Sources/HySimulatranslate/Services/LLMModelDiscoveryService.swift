import Foundation

enum LLMModelDiscoveryError: LocalizedError {
    case missingProvider
    case missingAPIKey
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return "Provider 未配置"
        case .missingAPIKey:
            return "缺少 API Key"
        case .httpStatus(let status):
            return "HTTP \(status)"
        case .invalidResponse:
            return "模型列表响应无法解析"
        }
    }
}

struct LLMModelDiscoveryService {
    func fetchTextModels(
        for providerID: LLMProviderID,
        apiKey: String
    ) async throws -> [LLMProviderModel] {
        guard let provider = LLMProviderCatalog.provider(for: providerID) else {
            throw LLMModelDiscoveryError.missingProvider
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.acceptsKey(key) else {
            throw LLMModelDiscoveryError.missingAPIKey
        }

        var request = URLRequest(url: provider.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = provider.timeout
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMModelDiscoveryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMModelDiscoveryError.httpStatus(http.statusCode)
        }

        return LLMProviderCatalog.textModels(
            for: providerID,
            modelIDs: try Self.modelIDs(from: data)
        )
    }

    static func modelIDs(from data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else {
            throw LLMModelDiscoveryError.invalidResponse
        }

        if let data = dict["data"] as? [[String: Any]] {
            return data.compactMap { $0["id"] as? String }
        }
        if let models = dict["models"] as? [[String: Any]] {
            return models.compactMap { $0["id"] as? String ?? $0["name"] as? String }
        }
        if let ids = dict["data"] as? [String] {
            return ids
        }
        throw LLMModelDiscoveryError.invalidResponse
    }
}
