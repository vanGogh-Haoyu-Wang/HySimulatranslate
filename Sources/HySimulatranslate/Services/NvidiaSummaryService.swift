import Foundation

actor NvidiaSummaryService {
    func summarize(prompt: String, credential: LLMProviderCredential, isFinal: Bool) async -> String? {
        normalizedSummary(from: await requestChatCompletion(
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
        let provider = credential?.provider ?? LLMProviderCatalog.nvidiaSummaryProvider!
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
            return LLMProviderCheckResult(provider: credential.provider, status: .failed(reason))
        }
    }

    func summarize(
        previousSummary: String,
        newContent: String,
        credential: LLMProviderCredential
    ) async -> String? {
        let prompt = LiveSummaryPrompt.make(previousSummary: previousSummary, newContent: newContent)
        let result = await requestChatCompletion(
            credential: credential,
            prompt: prompt,
            maxTokens: 900,
            timeout: credential.provider.timeout
        )
        return normalizedSummary(from: result)
    }

    func summarize(
        previousSummary: String,
        newContent: String,
        template: SummaryTemplateRecord,
        credential: LLMProviderCredential
    ) async -> String? {
        guard let prompt = try? Self.makePrompt(template: template, previousSummary: previousSummary, content: newContent, isFinal: false) else { return nil }
        return normalizedSummary(from: await requestChatCompletion(
            credential: credential, prompt: prompt, maxTokens: 900,
            timeout: credential.provider.timeout
        ))
    }

    func summarizeFinalDetailed(
        previousSummary: String,
        fullContent: String,
        credential: LLMProviderCredential
    ) async -> String? {
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
        return normalizedSummary(from: result)
    }

    func summarizeFinalDetailed(
        previousSummary: String,
        fullContent: String,
        template: SummaryTemplateRecord,
        credential: LLMProviderCredential
    ) async -> String? {
        guard let prompt = try? Self.makePrompt(template: template, previousSummary: previousSummary, content: fullContent, isFinal: true) else { return nil }
        return normalizedSummary(from: await requestChatCompletion(
            credential: credential, prompt: prompt, maxTokens: 1800, timeout: 60
        ))
    }

    private func normalizedSummary(from result: ChatCompletionResult) -> String? {
        switch result {
        case .success(let content):
            return Self.normalizedSummaryContent(content)
        case .failure:
            return nil
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
        case failure(String)
    }

    private func requestChatCompletion(
        credential: LLMProviderCredential,
        prompt: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async -> ChatCompletionResult {
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
            "max_tokens": maxTokens
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                return .failure("无 HTTP 响应")
            }
            guard httpResp.statusCode == 200 else {
                return .failure("HTTP \(httpResp.statusCode)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                return .failure("响应解析失败")
            }
            return .success(content)
        } catch {
            return .failure("网络异常")
        }
    }
}
