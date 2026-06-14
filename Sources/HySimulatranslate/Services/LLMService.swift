import Foundation

// MARK: - 🚀 Groq LLM 强化
// 对应 Python llm_formatting_worker + Groq OpenAI-compatible chat completions

actor LLMService {
    private var isRunning = false

    typealias ResultHandler = @Sendable (UUID, String) -> Void
    private var onResult: ResultHandler?

    func configure(onResult: @escaping ResultHandler) {
        self.onResult = onResult
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    /// 处理一个格式化任务。这里保持串行等待，避免长时间录音时同时堆积过多 LLM 请求。
    func processItem(
        _ item: LLMQueueItem,
        groqCredential: LLMProviderCredential?,
        course: CourseSubject,
        recentContext: String
    ) async {
        guard isRunning else { return }
        let formatted: String
        if item.taskType == .format {
            formatted = await formatWithGroq(
                rawText: item.rawText,
                whisperText: item.whisperText,
                sherpaText: item.sherpaText,
                mode: .format,
                credential: groqCredential,
                course: course,
                stableContext: recentContext
            )
        } else {
            formatted = await formatWithGroq(
                rawText: item.rawText,
                whisperText: item.whisperText,
                sherpaText: item.sherpaText,
                mode: .aggregate,
                credential: groqCredential,
                course: course,
                stableContext: recentContext
            )
        }
        guard isRunning else { return }
        onResult?(item.uid, formatted)
    }

    func testConnectivity(credential: LLMProviderCredential?) async -> LLMProviderCheckResult {
        let provider = credential?.provider ?? LLMProviderCatalog.groqCoreProvider!
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

    func organizeFragments(
        _ fragments: [String],
        credential: LLMProviderCredential?,
        course: CourseSubject?
    ) async -> [String]? {
        guard isRunning, let credential else { return nil }
        guard TranscriptOrganizer.shouldUseAIFallback(for: fragments) else { return nil }

        let focus = course.map {
            "The current reinforcement specialty is '\($0.name)'. Preserve domain terms: \($0.keywords)."
        } ?? "Preserve the speaker's original wording."
        let prompt = """
        Task: Clean this tiny sequential ASR transcript window.
        \(focus)

        Rules:
        1. Output only the cleaned English transcript.
        2. Remove repeated overlap between adjacent fragments.
        3. Merge fragments only when they are clearly one sentence.
        4. If fragments are separate sentences, keep them on separate lines.
        5. Do not summarize, translate, answer, add a title, add labels, or invent content.

        Fragments:
        \(fragments.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        """

        let result = await requestChatCompletion(
            credential: credential,
            systemRole: "You are a conservative transcript stitching tool. You only remove ASR repetition.",
            prompt: prompt,
            temperature: 0.0,
            maxTokens: 220,
            timeout: min(credential.provider.timeout, 4.0)
        )
        guard case .success(let content) = result else { return nil }
        return TranscriptOrganizer.validatedAILines(content, originalFragments: fragments)
    }

    // MARK: - 核心格式化方法

    private func formatWithGroq(
        rawText: String,
        whisperText: String = "",
        sherpaText: String = "",
        mode: LLMTaskType,
        credential: LLMProviderCredential?,
        course: CourseSubject,
        stableContext: String
    ) async -> String {
        guard let credential else {
            return mode == .aggregate ? rawText : simpleFallbackFormat(rawText)
        }

        // 构建 system role
        let systemRole: String
        if course.abbrev == "IndP" {
            systemRole = """
            You are an elite note taker for a focused reinforcement specialty session. \
            \(course.meetingFocus) \
            Pay extreme attention to correcting phonetic errors related to: \(course.keywords).
            """
        } else {
            systemRole = """
            You are an elite note taker for HySimulatranslate. \
            You are currently taking notes for the reinforcement specialty '\(course.name)'. \
            Fix punctuation and minor phonetic errors. Do NOT rephrase, change words, or invent content. \
            \(course.meetingFocus) \
            Pay attention to domain terms: \(course.keywords).
            """
        }

        let sourceText = Self.sourceTextForPrompt(rawText: rawText, whisperText: whisperText, sherpaText: sherpaText)

        // 构建 prompt
        let prompt: String
        if mode == .format {
            if course.abbrev == "IndP" {
                prompt = """
                Task: Refine this ASR transcript from a focused reinforcement specialty session. Fix punctuation and correct technical phonetic errors based on the 'Context'.
                CRITICAL RULES:
                1. Preserve the speaker's meaning. Do NOT invent extra technical details.
                2. Make supervisor requirements clear: tasks, decisions, deadlines, validation criteria, literature references, code changes, and next steps.
                3. Correct project-specific terms such as acoustic emission, AE, source localization, hit detection, waveform, arrival time, steel structures, MATLAB, Julia, Python, porting, migration, validation, benchmark, API, unit tests, and documentation.
                4. If the sentence contains an instruction or action item, keep the action verb clear: implement, compare, validate, benchmark, document, refactor, read, email, upload, or discuss.
                5. STRICT FORMATTING: Output EACH complete sentence on a NEW LINE. Do NOT combine multiple sentences into a paragraph.
                6. Do NOT answer, advise, summarize, or add conversational filler.
                7. DELETE repetitive hallucinations and meaningless duplicated segments.
                8. Use the WhisperKit transcript as primary. Use the Sherpa draft only to recover obvious omissions, hallucinations, or technical term errors. Do NOT invent content.
                Output ONLY the corrected meeting transcript.

                Context: \(stableContext)
                \(sourceText)
                """
            } else {
                prompt = """
                Task: Refine this highly accurate ASR transcript. Fix punctuation and correct obvious ASR or phonetic errors based on the 'Context'.
                CRITICAL RULES:
                1. STRICT FORMATTING: You MUST output EACH complete sentence on a NEW LINE. Do NOT combine multiple sentences into a single paragraph!
                2. Do NOT use ellipses (...) at all. Force a period (.) or comma (,).
                3. Do NOT answer or add conversational filler.
                4. DELETE REPETITIVE HALLUCINATIONS: Delete meaningless duplicated segments!
                5. IMPORTANT: Do NOT change words or rephrase. Only fix punctuation and obvious phonetic errors.
                6. Use the WhisperKit transcript as primary. Use the Sherpa draft only to recover obvious omissions, hallucinations, or technical term errors. Do NOT invent content.
                Output ONLY the perfectly formatted text.

                Context: \(stableContext)
                \(sourceText)
                """
            }
        } else {
            if course.abbrev == "IndP" {
                prompt = """
                Task: Merge and refine these sequential fragments from a focused reinforcement specialty session.
                CRITICAL RULES:
                1. Preserve the meeting meaning and the supervisor's instructions.
                2. Merge fragments into clear sentences while keeping action items, decisions, deadlines, concerns, validation criteria, and technical requirements explicit.
                3. Correct project-specific terms related to acoustic emission analysis, steel structures, MATLAB-to-Julia/Python migration, open-source frameworks, signal processing, source localization, feature extraction, validation, tests, and documentation.
                4. Do NOT turn the session into generic notes.
                5. STRICT FORMATTING: Output EACH complete sentence on a NEW LINE. Do NOT combine multiple sentences into a paragraph.
                6. DELETE repetitive hallucinations and meaningless duplicated segments.
                Output ONLY the refined meeting transcript.

                Fragments: \(rawText)
                """
            } else {
                prompt = """
                Task: Merge and gracefully refine these sequential sentence fragments into perfectly punctuated text for a focused reinforcement specialty session.
                CRITICAL RULES:
                1. STRICT FORMATTING: You MUST output EACH complete sentence on a NEW LINE. Do NOT combine multiple sentences into a single paragraph!
                2. Fix any minor phonetic mishearings.
                3. Do NOT use ellipses (...). Force a period.
                4. STITCH DANGLING WORDS: Seamlessly connect prepositions.
                5. DELETE REPETITIVE HALLUCINATIONS: Remove any duplicated meaningless phrases.
                6. IMPORTANT: Do NOT rephrase or invent content. Merge the fragments as-is with minimal editing.
                Output ONLY the refined text.

                Fragments: \(rawText)
                """
            }
        }

        let result = await requestChatCompletion(
            credential: credential,
            systemRole: systemRole,
            prompt: prompt,
            temperature: 0.05,
            maxTokens: mode == .format ? 200 : 350,
            timeout: credential.provider.timeout
        )
        switch result {
        case .success(let content):
            let llmText = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !llmText.isEmpty && llmText.count <= rawText.count * 3 {
                return llmText
            }
        case .failure:
            break
        }

        return fallbackText(for: rawText, mode: mode)
    }

    nonisolated static func sourceTextForPrompt(
        rawText: String,
        whisperText: String,
        sherpaText: String
    ) -> String {
        let whisper = whisperText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sherpa = sherpaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sherpa.isEmpty, sherpa != whisper else {
            return "Raw ASR: \(rawText)"
        }
        return """
        WhisperKit primary transcript:
        \(whisper.isEmpty ? rawText : whisper)

        Sherpa draft reference:
        \(sherpa)
        """
    }

    private enum ChatCompletionResult {
        case success(String)
        case failure(String)
    }

    private func requestChatCompletion(
        credential: LLMProviderCredential,
        systemRole: String,
        prompt: String,
        temperature: Double,
        maxTokens: Int,
        timeout: TimeInterval
    ) async -> ChatCompletionResult {
        await ChatRateLimiter.shared.waitTurn(for: credential)
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
            await ChatRateLimiter.shared.noteHTTPStatus(httpResp.statusCode, for: credential)
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

    private func fallbackText(for rawText: String, mode: LLMTaskType) -> String {
        mode == .aggregate ? Self.normalizeASRCasingForDisplay(rawText) : simpleFallbackFormat(rawText)
    }

    /// 简单兜底格式化（与 Python _simple_fallback_format 一致）
    private func simpleFallbackFormat(_ text: String) -> String {
        let trimmed = Self.normalizeASRCasingForDisplay(text.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty else { return "..." }
        let words = trimmed.split(separator: " ")
        if words.count < 5 {
            return trimmed
        }
        return Self.hasSentenceTerminator(trimmed) ? trimmed : trimmed + "."
    }

    nonisolated static func normalizeASRCasingForDisplay(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard shouldNormalizeAllCapsASR(trimmed) else { return text }

        var normalized = trimmed.lowercased()
        normalized = restoreFirstPersonPronouns(in: normalized)
        normalized = restoreKnownAcronyms(in: normalized)
        return capitalizeSentenceStarts(in: normalized)
    }

    nonisolated private static func shouldNormalizeAllCapsASR(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count >= 5 else { return false }

        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 20 else { return false }

        let uppercaseCount = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let lowercaseCount = letters.filter { CharacterSet.lowercaseLetters.contains($0) }.count
        return uppercaseCount * 100 >= letters.count * 85
            && lowercaseCount <= max(2, letters.count / 20)
    }

    nonisolated private static func restoreFirstPersonPronouns(in text: String) -> String {
        var result = text
        let replacements = [
            ("\\bi\\b", "I"),
            ("\\bi'm\\b", "I'm"),
            ("\\bi've\\b", "I've"),
            ("\\bi'll\\b", "I'll"),
            ("\\bi'd\\b", "I'd")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    nonisolated private static func restoreKnownAcronyms(in text: String) -> String {
        var result = text
        let acronyms = [
            "AE", "AI", "API", "ASR", "CPU", "GPU", "HTTP", "HTTPS", "IPO", "LLM",
            "ML", "MSc", "NVIDIA", "RTX", "TCP", "UDP", "UI", "URL"
        ]
        for acronym in acronyms {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: acronym.lowercased()))\\b",
                with: acronym,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    nonisolated private static func capitalizeSentenceStarts(in text: String) -> String {
        var result = ""
        var shouldCapitalize = true
        for character in text {
            if shouldCapitalize, character.isLetter {
                result += character.uppercased()
                shouldCapitalize = false
            } else {
                result.append(character)
            }

            if character == "." || character == "!" || character == "?" || character == "\n" {
                shouldCapitalize = true
            } else if !character.isWhitespace && character != "\"" && character != "'" {
                shouldCapitalize = false
            }
        }
        return result
    }

    nonisolated private static func hasSentenceTerminator(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "!" || last == "?"
    }
}
