import Foundation

enum OmniRouteSummaryError: LocalizedError, Equatable {
    case http(Int, String)
    case invalidResponse
    case invalidContent
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let detail): return "OmniRoute HTTP \(status)：\(detail)"
        case .invalidResponse: return "OmniRoute 响应格式无效"
        case .invalidContent: return "OmniRoute 未返回有效摘要"
        case .network(let detail): return "OmniRoute 网络异常：\(detail)"
        }
    }
}

actor OmniRouteSummaryService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func summarize(prompt: String, credential: LLMProviderCredential, isFinal: Bool) async throws -> String {
        try normalizedSummary(from: await requestChatCompletion(
            credential: credential,
            prompt: prompt,
            maxTokens: isFinal ? 1800 : 900,
            timeout: isFinal ? 60 : credential.provider.timeout
        ))
    }
    static func makePrompt(
        template: SummaryTemplateRecord,
        previousSummary: String,
        content: String,
        isFinal: Bool
    ) throws -> String {
        try SummaryPromptRenderer.make(
            template: template,
            previousSummary: previousSummary,
            content: content,
            isFinal: isFinal
        )
    }

    func testConnectivity(credential: LLMProviderCredential?) async -> LLMProviderCheckResult {
        let provider = credential?.provider ?? LLMProviderCatalog.omniRouteSummaryProvider()!
        guard let credential else {
            return LLMProviderCheckResult(provider: provider, status: .notConfigured)
        }
        let result = await requestChatCompletion(
            credential: credential,
            prompt: "只回复两个汉字：正常",
            maxTokens: 8,
            timeout: credential.provider.timeout
        )
        switch result {
        case .success(let content):
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMProviderCheckResult(
                provider: credential.provider,
                status: trimmed.contains("正常") ? .passed : .failed("空响应")
            )
        case .failure(let reason):
            return LLMProviderCheckResult(provider: credential.provider, status: .failed(reason.localizedDescription))
        }
    }

    func summarize(
        previousSummary: String,
        newContent: String,
        credential: LLMProviderCredential
    ) async throws -> String {
        let prompt = LiveSummaryPrompt.make(previousSummary: previousSummary, newContent: newContent)
        let result = await requestChatCompletion(
            credential: credential,
            prompt: prompt,
            maxTokens: 900,
            timeout: credential.provider.timeout
        )
        return try normalizedSummary(from: result)
    }

    func summarize(
        previousSummary: String,
        newContent: String,
        template: SummaryTemplateRecord,
        credential: LLMProviderCredential
    ) async throws -> String {
        let prompt = try Self.makePrompt(template: template, previousSummary: previousSummary, content: newContent, isFinal: false)
        return try normalizedSummary(from: await requestChatCompletion(
            credential: credential, prompt: prompt, maxTokens: 900,
            timeout: credential.provider.timeout
        ))
    }

    func summarizeFinalDetailed(
        previousSummary: String,
        fullContent: String,
        credential: LLMProviderCredential
    ) async throws -> String {
        let prompt = LiveSummaryPrompt.makeFinalDetailed(
            previousSummary: previousSummary,
            fullContent: fullContent
        )
        let result = await requestChatCompletion(
            credential: credential,
            prompt: prompt,
            maxTokens: 1800,
            timeout: 60.0
        )
        return try normalizedSummary(from: result)
    }

    func summarizeFinalDetailed(
        previousSummary: String,
        fullContent: String,
        template: SummaryTemplateRecord,
        credential: LLMProviderCredential
    ) async throws -> String {
        let prompt = try Self.makePrompt(template: template, previousSummary: previousSummary, content: fullContent, isFinal: true)
        return try normalizedSummary(from: await requestChatCompletion(
            credential: credential, prompt: prompt, maxTokens: 1800, timeout: 60
        ))
    }

    private func normalizedSummary(from result: ChatCompletionResult) throws -> String {
        switch result {
        case .success(let content):
            guard let normalized = Self.normalizedSummaryContent(content) else { throw OmniRouteSummaryError.invalidContent }
            return normalized
        case .failure(let error):
            throw error
        }
    }

    static func normalizedSummaryContent(_ content: String) -> String? {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        guard !trimmed.isEmpty else { return nil }

        let compact = trimmed
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        let failureMarkers = [
            "总结失败",
            "无法总结",
            "无法生成总结",
            "无法根据提供内容",
            "没有足够信息"
        ]
        guard !failureMarkers.contains(where: compact.contains) else { return nil }
        return trimmed
    }

    private enum ChatCompletionResult {
        case success(String)
        case failure(OmniRouteSummaryError)
    }

    private func requestChatCompletion(
        credential: LLMProviderCredential,
        prompt: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async -> ChatCompletionResult {
        let request = Self.makeRequest(credential: credential, prompt: prompt, maxTokens: maxTokens, timeout: timeout)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard httpResp.statusCode == 200 else {
                let detail = Self.errorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResp.statusCode)
                return .failure(.http(httpResp.statusCode, detail))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                return .failure(.invalidResponse)
            }
            return .success(content)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    nonisolated static func makeRequest(
        credential: LLMProviderCredential,
        prompt: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: credential.provider.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": credential.provider.modelName,
            "messages": [
                ["role": "system", "content": "你是严谨的中文会议总结助手，只根据给定内容总结。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": maxTokens,
            "stream": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
