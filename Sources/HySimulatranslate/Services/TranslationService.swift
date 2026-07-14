import Foundation

// MARK: - 🌐 翻译引擎（多引擎回退）
// 对应 Python robust_translate + translation_worker

actor TranslationService {
    typealias ResultHandler = @Sendable (UUID, String) -> Void
    nonisolated static let maxTranslationQueryCharacters = 450
    nonisolated private static let freeTranslateTimeout: TimeInterval = 6
    nonisolated private static let llmTranslateTimeout: TimeInterval = 8
    private let appleTranslator: any AppleSystemTranslating
    private var onResult: ResultHandler?

    init(appleTranslator: any AppleSystemTranslating = AppleSystemTranslationService()) {
        self.appleTranslator = appleTranslator
    }

    func configure(onResult: @escaping ResultHandler) { self.onResult = onResult }

    func translate(
        uid: UUID,
        englishText: String,
        groqCredential: LLMProviderCredential?,
        mode: TranslationExecutionMode = .online
    ) async {
        guard shouldTranslate(englishText) else { onResult?(uid, ""); return }
        let result: String
        switch mode {
        case .online:
            let online = await robustTranslate(englishText, groqCredential: groqCredential)
            if Self.isCompleteTranslationFailure(online),
               let apple = await appleTranslator.translate(englishText) {
                result = AppleTranslationTextNormalizer.simplifiedChinese(apple)
            } else {
                result = online
            }
        case .appleOffline:
            result = await appleTranslator.translate(englishText)
                .map(AppleTranslationTextNormalizer.simplifiedChinese)
                ?? "[翻译超时]"
        case .unavailable:
            result = ""
        }
        onResult?(uid, cleanTranslation(result, original: englishText))
    }

    nonisolated static func isCompleteTranslationFailure(_ text: String) -> Bool {
        let units = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !units.isEmpty && units.allSatisfy { $0 == "[翻译超时]" }
    }

    // MARK: - 跳过无意义文本

    private func shouldTranslate(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "." { return false }
        if t.contains("捕获到口音") || t.contains("分析中") { return false }
        let stripped = t.replacingOccurrences(of: "[^a-zA-Z]", with: "", options: .regularExpression)
        if stripped.isEmpty { return false }
        return true
    }

    // MARK: - 翻译结果清洗

    private func cleanTranslation(_ result: String, original: String) -> String {
        var r = result.trimmingCharacters(in: .whitespaces)
        // 反复解码 percent encoding（某些 API 返回双重编码）
        for _ in 0..<3 {
            if let decoded = r.removingPercentEncoding, decoded != r {
                r = decoded
            } else { break }
        }
        // 手动干掉残留的 %20、% 20 等变形
        r = r.replacingOccurrences(of: "%20", with: " ")
        r = r.replacingOccurrences(of: "% 20", with: " ")
        r = r.replacingOccurrences(of: "%2C", with: ",")
        r = r.replacingOccurrences(of: "%3F", with: "?")
        r = r.replacingOccurrences(of: "%21", with: "!")
        r = r.replacingOccurrences(of: "%2E", with: ".")
        // 合并不必要的空白
        r = r.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 判断翻译是否可用（不包含原文的英文字词残留）

    private func isTranslationUsable(_ translated: String, original: String) -> Bool {
        // 翻译结果如果基本上是英文 + % 乱码 → 不可用
        let cleaned = translated
            .replacingOccurrences(of: "%20", with: "")
            .replacingOccurrences(of: "% 20", with: "")
            .replacingOccurrences(of: "%", with: "")
        let englishWords = original.lowercased().split(separator: " ").filter { $0.count > 2 }
        let matchCount = englishWords.filter { cleaned.lowercased().contains(String($0)) }.count
        // 超过 40% 原文单词出现在翻译结果中 → 翻译失败
        return englishWords.isEmpty || matchCount <= max(1, englishWords.count / 2)
    }

    // MARK: - 多引擎回退

    func robustTranslate(_ text: String, groqCredential: LLMProviderCredential?) async -> String {
        let units = Self.translationUnits(for: text)
        if units.count > 1 {
            var translatedUnits: [String] = []
            for unit in units {
                translatedUnits.append(await translateSingleUnit(unit, groqCredential: groqCredential))
            }
            let usable = translatedUnits.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return usable.isEmpty ? "[翻译超时]" : usable.joined(separator: "\n")
        }

        let chunks = Self.chunkTextForTranslation(text)
        if chunks.count > 1 {
            var translatedChunks: [String] = []
            for chunk in chunks {
                translatedChunks.append(await translateSingleChunk(chunk, groqCredential: groqCredential))
            }
            let usable = translatedChunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return usable.isEmpty ? "[翻译超时]" : usable.joined(separator: "\n")
        }
        return await translateSingleChunk(chunks.first ?? text, groqCredential: groqCredential)
    }

    nonisolated static func translationUnits(for text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func translateSingleUnit(_ text: String, groqCredential: LLMProviderCredential?) async -> String {
        let chunks = Self.chunkTextForTranslation(text)
        if chunks.count > 1 {
            var translatedChunks: [String] = []
            for chunk in chunks {
                translatedChunks.append(await translateSingleChunk(chunk, groqCredential: groqCredential))
            }
            let usable = translatedChunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return usable.isEmpty ? "[翻译超时]" : usable.joined(separator: " ")
        }
        return await translateSingleChunk(chunks.first ?? text, groqCredential: groqCredential)
    }

    private func translateSingleChunk(_ text: String, groqCredential: LLMProviderCredential?) async -> String {
        // 1️⃣ Google no-key endpoint: fastest and currently most reliable free fallback.
        if let r = await retryTranslation(attempts: 2, delayNanoseconds: 500_000_000, operation: {
            await self.googleTranslate(text)
        }),
           r != text, isTranslationUsable(r, original: text) { return r }

        // 2️⃣ Groq: higher-quality fallback when configured and self-check passed.
        if let groqCredential,
           let r = await llmTranslate(text, credential: groqCredential),
           r != text, isTranslationUsable(r, original: text) { return r }

        // 3️⃣ MyMemory: useful as a last resort, but often rate-limited on the free tier.
        if let r = await myMemoryTranslate(text),
           r != text, isTranslationUsable(r, original: text) { return r }
        return "[翻译超时]"
    }

    private func retryTranslation(
        attempts: Int,
        delayNanoseconds: UInt64,
        operation: () async -> String?
    ) async -> String? {
        for attempt in 0..<attempts {
            if let result = await operation() { return result }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return nil
    }

    nonisolated static func chunkTextForTranslation(
        _ text: String,
        maxCharacters: Int = maxTranslationQueryCharacters
    ) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else { return normalized.isEmpty ? [] : [normalized] }

        var chunks: [String] = []
        var current = ""
        let roughSentences = normalized
            .replacingOccurrences(of: "([.!?])\\s+", with: "$1\n", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func appendCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        func appendPiece(_ piece: String) {
            let candidate = current.isEmpty ? piece : "\(current) \(piece)"
            if candidate.count <= maxCharacters {
                current = candidate
                return
            }
            appendCurrent()
            if piece.count <= maxCharacters {
                current = piece
                return
            }

            var wordChunk = ""
            for word in piece.split(separator: " ").map(String.init) {
                let wordCandidate = wordChunk.isEmpty ? word : "\(wordChunk) \(word)"
                if wordCandidate.count <= maxCharacters {
                    wordChunk = wordCandidate
                } else {
                    let trimmed = wordChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { chunks.append(trimmed) }
                    wordChunk = word
                }
            }
            let trimmed = wordChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
        }

        for sentence in roughSentences {
            appendPiece(sentence)
        }
        appendCurrent()
        return chunks
    }

    // MARK: - MyMemory

    private func myMemoryTranslate(_ text: String) async -> String? {
        guard let url = Self.myMemoryTranslateURL(for: text) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: Self.freeTranslateTimeout)
        req.httpMethod = "GET"
        req.addValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rd = json["responseData"] as? [String: Any],
              let translated = rd["translatedText"] as? String
        else { return nil }

        return translated.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func myMemoryTranslateURL(for text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.mymemory.translated.net"
        components.path = "/get"
        components.percentEncodedQuery = encodedQuery([
            ("q", text),
            ("langpair", "en|zh")
        ])
        return components.url
    }

    // MARK: - Google Translate

    private func googleTranslate(_ text: String) async -> String? {
        guard let url = Self.googleTranslateURL(for: text) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: Self.freeTranslateTimeout)
        req.httpMethod = "GET"
        req.addValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }

        // Google 响应: [[["译文","原文",...], null, ...], null, ...]
        guard let outerArray = json.first as? [Any] else { return nil }

        var result = ""
        for element in outerArray {
            guard let segment = element as? [Any],
                  let translated = segment.first as? String
            else { continue }
            result += translated
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func googleTranslateURL(for text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "translate.googleapis.com"
        components.path = "/translate_a/single"
        components.percentEncodedQuery = encodedQuery([
            ("client", "gtx"),
            ("sl", "en"),
            ("tl", "zh"),
            ("dt", "t"),
            ("q", text)
        ])
        return components.url
    }

    nonisolated private static func encodedQuery(_ items: [(String, String)]) -> String {
        items.map { "\($0.0)=\(percentEncodeQueryValue($0.1))" }
            .joined(separator: "&")
    }

    nonisolated private static func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - LLM 翻译

    private func llmTranslate(_ text: String, credential: LLMProviderCredential) async -> String? {
        await ChatRateLimiter.shared.waitTurn(for: credential)
        var req = URLRequest(url: credential.provider.chatCompletionsURL)
        req.httpMethod = "POST"
        req.timeoutInterval = min(credential.provider.timeout, Self.llmTranslateTimeout)
        req.addValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": credential.provider.modelName,
            "messages": [
                ["role": "system", "content":
                    "You are a translator. Translate the English text to Simplified Chinese. Output ONLY the Chinese, nothing else. Do NOT repeat the English."],
                ["role": "user", "content": text]
            ],
            "temperature": 0.0,
            "max_tokens": 256
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        await ChatRateLimiter.shared.noteHTTPStatus(http.statusCode, for: credential)
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String
        else { return nil }

        return content.trimmingCharacters(in: .whitespaces)
    }
}
