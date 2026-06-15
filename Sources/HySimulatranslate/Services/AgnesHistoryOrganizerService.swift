import Foundation

struct AgnesHistoryOrganizerItem: Codable, Equatable, Sendable {
    let id: String
    let english: String
    let chinese: String?
}

struct AgnesHistoryOrganizerUpdate: Codable, Equatable, Sendable {
    let id: String
    let english: String?
    let chinese: String?
    let drop: Bool?
}

actor AgnesHistoryOrganizerService {
    private struct ResponseEnvelope: Codable {
        let updates: [AgnesHistoryOrganizerUpdate]
    }

    private enum ChatCompletionResult {
        case success(String)
        case failure(String)
    }

    private let minimumRequestInterval: TimeInterval = 3.5
    private var lastRequestAt: Date?

    func testConnectivity(credential: LLMProviderCredential?) async -> LLMProviderCheckResult {
        let provider = credential?.provider ?? LLMProviderCatalog.agnesOrganizerProvider!
        guard let credential else {
            return LLMProviderCheckResult(provider: provider, status: .notConfigured)
        }

        let result = await requestChatCompletion(
            credential: credential,
            systemRole: "You are a concise connectivity tester.",
            prompt: "Reply with exactly: ok",
            temperature: 0.0,
            maxTokens: 8,
            timeout: min(credential.provider.timeout, 8.0)
        )
        switch result {
        case .success(let content):
            let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return LLMProviderCheckResult(
                provider: credential.provider,
                status: normalized.contains("ok") ? .passed : .failed("空响应")
            )
        case .failure(let reason):
            return LLMProviderCheckResult(provider: credential.provider, status: .failed(reason))
        }
    }

    func organizeHistory(
        items: [AgnesHistoryOrganizerItem],
        credential: LLMProviderCredential,
        course: CourseSubject?,
        polishTranslations: Bool
    ) async -> [AgnesHistoryOrganizerUpdate]? {
        guard !items.isEmpty else { return nil }

        let courseText = course.map {
            "Current reinforcement specialty: \($0.name). Domain terms: \($0.keywords)."
        } ?? "No specialty context is available."
        let translationRule = polishTranslations
            ? "You may lightly smooth existing Chinese translations so they read naturally, but only when they directly match the English source."
            : "Do not create new Chinese translations. If a Chinese field is empty, return it empty."
        let itemJSON = Self.encodeItemsForPrompt(items)
        let prompt = """
        Task: Conservatively organize confirmed transcript history items for HySimulatranslate.
        \(courseText)

        Rules:
        1. Return JSON only, with this shape: {"updates":[{"id":"...","english":"...","chinese":"...","drop":false}]}.
        2. Keep the same IDs and the same order. Return exactly one update for every input item.
        3. Remove only obvious repeated paragraphs or obvious adjacent boundary overlap.
        4. If the end of one item repeats the beginning of the next item, delete the repeated tail from the earlier item.
        5. Do not summarize, answer, add explanations, add labels, or invent content.
        6. Keep English meaning unchanged. Only fix transcript seams and obvious duplication.
        7. \(translationRule)
        8. Set drop=true only for a wholly duplicated item that should not appear in notes.

        Items:
        \(itemJSON)
        """

        let result = await requestChatCompletion(
            credential: credential,
            systemRole: "You are a conservative transcript history editor. You only remove duplication and smooth seams.",
            prompt: prompt,
            temperature: 0.0,
            maxTokens: max(900, min(2200, items.count * 220)),
            timeout: credential.provider.timeout
        )
        guard case .success(let content) = result else { return nil }
        return Self.validatedUpdates(from: content, originalItems: items)
    }

    static func validatedUpdates(
        from responseText: String,
        originalItems: [AgnesHistoryOrganizerItem]
    ) -> [AgnesHistoryOrganizerUpdate]? {
        guard let json = jsonObjectSlice(from: responseText),
              let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data)
        else { return nil }

        let originalsByID = Dictionary(uniqueKeysWithValues: originalItems.map { ($0.id, $0) })
        let expectedIDs = Set(originalsByID.keys)
        let returnedIDs = Set(envelope.updates.map(\.id))
        guard returnedIDs == expectedIDs else { return nil }

        var seen: Set<String> = []
        for update in envelope.updates {
            guard seen.insert(update.id).inserted,
                  let original = originalsByID[update.id]
            else { return nil }

            if update.drop == true { continue }

            guard let english = update.english?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !english.isEmpty
            else { return nil }

            let originalEnglish = original.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard english.count <= max(originalEnglish.count * 2, originalEnglish.count + 160) else {
                return nil
            }

            if let chinese = update.chinese?.trimmingCharacters(in: .whitespacesAndNewlines),
               let originalChinese = original.chinese?.trimmingCharacters(in: .whitespacesAndNewlines),
               !originalChinese.isEmpty,
               chinese.count > max(originalChinese.count * 3, originalChinese.count + 180) {
                return nil
            }
        }

        return envelope.updates
    }

    private func requestChatCompletion(
        credential: LLMProviderCredential,
        systemRole: String,
        prompt: String,
        temperature: Double,
        maxTokens: Int,
        timeout: TimeInterval
    ) async -> ChatCompletionResult {
        await waitForTurn()

        var request = URLRequest(url: credential.provider.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": credential.provider.modelName,
            "messages": [
                ["role": "system", "content": systemRole],
                ["role": "user", "content": prompt]
            ],
            "temperature": temperature,
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

    private func waitForTurn() async {
        if let lastRequestAt {
            let wait = minimumRequestInterval - Date().timeIntervalSince(lastRequestAt)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }

    private static func encodeItemsForPrompt(_ items: [AgnesHistoryOrganizerItem]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    private static func jsonObjectSlice(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else { return nil }
        return String(trimmed[start...end])
    }
}
