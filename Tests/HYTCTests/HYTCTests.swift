import XCTest
@testable import HYTC

final class HYTCTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HYTCTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    func testCourseSubjectCodableRoundTrips() throws {
        let subject = CourseSubject(
            name: "Advanced Thermodynamics",
            abbrev: "Thermo",
            keywords: "entropy, enthalpy",
            meetingFocus: "Preserve technical definitions."
        )

        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(CourseSubject.self, from: data)

        XCTAssertEqual(decoded.name, subject.name)
        XCTAssertEqual(decoded.abbrev, subject.abbrev)
        XCTAssertEqual(decoded.keywords, subject.keywords)
        XCTAssertEqual(decoded.meetingFocus, subject.meetingFocus)
    }

    func testCourseDatabaseShipsOnlyProtectedDefaultSubject() throws {
        UserDefaults.standard.removeObject(forKey: "CustomSubjects")
        UserDefaults.standard.removeObject(forKey: "HiddenDefaultSubjects")
        let database = CourseDatabase()

        XCTAssertEqual(database.defaultSubjects.map(\.name), ["默认"])
        XCTAssertEqual(database.allSubjects.map(\.name), ["默认"])
        XCTAssertFalse(database.hasHiddenDefaultSubjects)

        let defaultSubject = try XCTUnwrap(database.defaultSubjects.first)
        XCTAssertFalse(database.canRemoveSubject(defaultSubject))
        XCTAssertTrue(defaultSubject.meetingFocus.lowercased().contains("do not invent"))

        database.removeSubject(defaultSubject)

        XCTAssertEqual(database.allSubjects.map(\.name), ["默认"])
        XCTAssertFalse(database.hasHiddenDefaultSubjects)
    }

    func testASRSegmentFilterDropsCommonJunk() {
        let service = WhisperKitService()

        XCTAssertTrue(service.shouldDropASRSegment("Thank you."))
        XCTAssertTrue(service.shouldDropASRSegment("Subtitles by Amara.org"))
        XCTAssertTrue(service.shouldDropASRSegment("mic test"))
        XCTAssertTrue(service.shouldDropASRSegment("I'm sorry."))
        XCTAssertTrue(service.shouldDropASRSegment("NINE I'm sorry."))
        XCTAssertTrue(service.shouldDropASRSegment("I'm sorry. I'm sorry."))
        XCTAssertTrue(service.shouldDropASRSegment("Good night."))
        XCTAssertFalse(service.shouldDropASRSegment("The polymer glass transition temperature is important."))
    }

    func testASRSegmentFilterDropsAccentAnalysisPlaceholder() {
        let service = WhisperKitService()

        XCTAssertTrue(WhisperKitService.isAccentAnalysisPlaceholder("[🎤 捕获到口音音频，分析中...]"))
        XCTAssertTrue(service.shouldDropASRSegment("[🎤 捕获到口音音频，分析中...]"))
        XCTAssertTrue(service.shouldDropASRSegment("捕获到口音音频，分析中"))
    }

    func testSherpaNoTextCutKeepsShortAccentAnalysisWindow() {
        XCTAssertFalse(SherpaService.shouldCutNoTextSegment(text: "", audioSec: 1.9))
        XCTAssertTrue(SherpaService.shouldCutNoTextSegment(text: "", audioSec: 2.0))
        XCTAssertFalse(SherpaService.shouldCutNoTextSegment(text: "actual speech", audioSec: 8.0))
    }

    @MainActor
    func testAccentAnalysisPlaceholderStillQueuesWhenOnlyInFlightPlaceholderExists() {
        let vm = TranscriptionViewModel()
        vm.dynamicItems = [
            TranscriptionItem(
                english: "[🎤 捕获到口音音频，分析中...]",
                status: .whispering,
                zone: .dynamic
            )
        ]

        vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 0, count: 64_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )

        XCTAssertEqual(vm.whisperQueueSize, 1)
        XCTAssertEqual(vm.dynamicItems.count, 2)
    }

    @MainActor
    func testQueuedAccentAnalysisPlaceholdersMergeWithoutDroppingAudio() {
        let vm = TranscriptionViewModel()

        vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 0, count: 64_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )
        vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 1, count: 64_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )

        XCTAssertEqual(vm.whisperQueueSize, 1)
        XCTAssertEqual(vm.dynamicItems.count, 1)
    }

    @MainActor
    func testQueuedAccentAnalysisPlaceholdersSplitWhenMergedAudioWouldExceedSixSeconds() {
        let vm = TranscriptionViewModel()

        vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 0, count: 100_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )
        vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 1, count: 100_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )

        XCTAssertEqual(vm.whisperQueueSize, 2)
        XCTAssertEqual(vm.dynamicItems.count, 2)
    }

    func testASRSegmentFilterKeepsThanksWhenSessionIsEnding() {
        let service = WhisperKitService()

        XCTAssertFalse(service.shouldDropASRSegment("Thank you.", isSessionEnding: true))
        XCTAssertFalse(service.shouldDropASRSegment("Thanks.", isSessionEnding: true))
        XCTAssertFalse(service.shouldDropASRSegment("Good night.", isSessionEnding: true))
        XCTAssertTrue(service.shouldDropASRSegment("Subtitles by Amara.org", isSessionEnding: true))
    }

    func testASRDisplayCasingNormalizesLongAllCapsFallbacks() {
        let raw = "AGAINST MY QUESTION AFTER THAT IS WHAT HAD TO COME TOGETHER STRATEGICALLY TO DELIVER NVIDIA API GROWTH"

        let normalized = LLMService.normalizeASRCasingForDisplay(raw)

        XCTAssertEqual(
            normalized,
            "Against my question after that is what had to come together strategically to deliver NVIDIA API growth"
        )
        XCTAssertEqual(
            LLMService.normalizeASRCasingForDisplay("A $46 billion net income quarter. So we've moved from years to quarters."),
            "A $46 billion net income quarter. So we've moved from years to quarters."
        )
    }

    func testWhisperKitCacheSearchFindsHuggingFaceSnapshotVariantFolder() throws {
        let root = try makeTemporaryDirectory()
        let variant = root
            .appendingPathComponent("models--argmaxinc--whisperkit-coreml")
            .appendingPathComponent("snapshots")
            .appendingPathComponent("abc123")
            .appendingPathComponent("openai_whisper-large-v3")
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: variant.appendingPathComponent("\(component).mlmodelc"),
                withIntermediateDirectories: true
            )
        }

        let found = WhisperKitService.findCachedModel(in: [root], model: "large-v3")

        XCTAssertEqual(found?.standardizedFileURL.path, variant.standardizedFileURL.path)
    }

    func testWhisperKitCacheSearchIgnoresIncompleteHuggingFaceCache() throws {
        let root = try makeTemporaryDirectory()
        let incomplete = root
            .appendingPathComponent("models--argmaxinc--whisperkit-coreml")
            .appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("abc123".utf8).write(to: incomplete.appendingPathComponent("main"))

        let found = WhisperKitService.findCachedModel(in: [root], model: "large-v3")

        XCTAssertNil(found)
    }

    func testTranslationChunkingKeepsQueriesUnderLimit() {
        let text = """
        If you don't take the time to create the life you want, you will be forced to spend more time coping with the life you don't want. On the way to success, no one will wake you up and no one will pay for you. You need self-management and self-breakthrough. No flower is a flower from the beginning. If we choose comfort, we don't have envy other than for their splendour and beauty. And enrichment. If we choose stormy waves, we need to be firm and indomitable. People's potential is unlimited. Satisfied with the status quo, you will be gradually eliminated.
        """

        let chunks = TranslationService.chunkTextForTranslation(text)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TranslationService.maxTranslationQueryCharacters })
        XCTAssertTrue(chunks.joined(separator: " ").contains("People's potential is unlimited"))
    }

    func testTranslationURLsPercentEncodeQuerySeparators() throws {
        let text = "NVIDIA & OpenAI + Azure #1?"

        let googleURL = try XCTUnwrap(TranslationService.googleTranslateURL(for: text))
        let myMemoryURL = try XCTUnwrap(TranslationService.myMemoryTranslateURL(for: text))

        XCTAssertEqual(
            URLComponents(url: googleURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
            text
        )
        XCTAssertEqual(
            URLComponents(url: myMemoryURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
            text
        )
        XCTAssertTrue(googleURL.absoluteString.contains("%26"))
        XCTAssertTrue(googleURL.absoluteString.contains("%2B"))
        XCTAssertTrue(googleURL.absoluteString.contains("%231"))
    }

    func testLLMProviderCatalogSeparatesGroqCoreAndNvidiaSummaryModelsWithGetLinks() throws {
        let groq = try XCTUnwrap(LLMProviderCatalog.groqCoreProvider)
        let nvidia = try XCTUnwrap(LLMProviderCatalog.nvidiaSummaryProvider)

        XCTAssertEqual(groq.displayName, "Groq")
        XCTAssertEqual(groq.modelName, "llama-3.3-70b-versatile")
        XCTAssertEqual(groq.getAPIKeyURL.absoluteString, "https://console.groq.com/keys")

        XCTAssertEqual(nvidia.displayName, "NVIDIA 总结")
        XCTAssertEqual(nvidia.modelName, "nvidia/llama-3.3-nemotron-super-49b-v1")
        XCTAssertEqual(nvidia.getAPIKeyURL.absoluteString, "https://build.nvidia.com")
        XCTAssertGreaterThanOrEqual(nvidia.timeout, 20)
    }

    func testLLMProviderCredentialsKeepGroqCoreSeparateFromNvidiaSummary() {
        let keys: [LLMProviderID: String] = [
            .groq: "gsk_test_key",
            .nvidia: "nvapi-test-key"
        ]

        let coreCredential = LLMProviderCatalog.groqCoreCredential(from: keys)
        let summaryCredential = LLMProviderCatalog.nvidiaSummaryCredential(from: keys)

        XCTAssertEqual(coreCredential?.provider.id, .groq)
        XCTAssertEqual(summaryCredential?.provider.id, .nvidia)
    }

    func testLiveSummaryCursorRequestsOnlyAfterEightTranslatedUnits() {
        var cursor = LiveSummaryCursor()

        XCTAssertNil(cursor.pendingRange(totalCount: 7))
        XCTAssertEqual(cursor.pendingRange(totalCount: 8), 0..<8)

        cursor.markSummarized(upTo: 8)

        XCTAssertNil(cursor.pendingRange(totalCount: 15))
        XCTAssertEqual(cursor.pendingRange(totalCount: 16), 8..<16)

        cursor.markSummarized(upTo: 16)
        XCTAssertNil(cursor.pendingRange(totalCount: 3))
        XCTAssertEqual(cursor.pendingRange(totalCount: 8), 0..<8)
    }

    func testLiveSummaryCursorDoesNotImmediatelyRetryFailedBatch() {
        var cursor = LiveSummaryCursor()

        XCTAssertEqual(cursor.pendingRange(totalCount: 8), 0..<8)
        cursor.markFailed(at: 8)

        XCTAssertNil(cursor.pendingRange(totalCount: 8))
        XCTAssertNil(cursor.pendingRange(totalCount: 15))
        XCTAssertEqual(cursor.pendingRange(totalCount: 16), 0..<16)
    }

    func testTranslationUnitsPreserveLLMLineBreaks() {
        let text = "First sentence.\nSecond sentence.\n\nThird sentence."

        XCTAssertEqual(
            TranslationService.translationUnits(for: text),
            ["First sentence.", "Second sentence.", "Third sentence."]
        )
    }

    func testTranscriptOrganizerMergesAdjacentTokenOverlap() {
        let first = UUID()
        let second = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(id: first, text: "NVIDIA is in a quiet period right now, but"),
                TranscriptOrganizerFragment(id: second, text: "right now, but what we want to hear from him is the bigger picture.")
            ],
            recentHistory: []
        )

        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(
            result.outputs.first?.text,
            "NVIDIA is in a quiet period right now, but what we want to hear from him is the bigger picture."
        )
        XCTAssertEqual(result.outputs.first?.consumedIDs, [first, second])
        XCTAssertTrue(result.droppedIDs.isEmpty)
    }

    func testTranscriptOrganizerDropsRecentDuplicate() {
        let duplicate = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(
                    id: duplicate,
                    text: "AI actually reinvented the computer industry."
                )
            ],
            recentHistory: [
                "The computer industry is changing.",
                "AI actually reinvented the computer industry."
            ]
        )

        XCTAssertTrue(result.outputs.isEmpty)
        XCTAssertEqual(result.droppedIDs, [duplicate])
    }

    func testTranscriptOrganizerDropsContainedNearDuplicate() {
        let duplicate = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(
                    id: duplicate,
                    text: "We invested in the infrastructure layer."
                )
            ],
            recentHistory: [
                "That's right, and we invested in the infrastructure layer, we invested in companies like CoreWeave and Nebulon."
            ]
        )

        XCTAssertTrue(result.outputs.isEmpty)
        XCTAssertEqual(result.droppedIDs, [duplicate])
    }

    func testTranscriptOrganizerFiltersContextLeaksAndSpeakerLabelsButKeepsAcronyms() {
        let context = UUID()
        let speaker = UUID()
        let acronym = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(
                    id: context,
                    text: "Context: capabilities one in order to think you have to generate tokens."
                ),
                TranscriptOrganizerFragment(id: speaker, text: "JAMES UNLESS"),
                TranscriptOrganizerFragment(id: acronym, text: "NVIDIA GPU demand is rising.")
            ],
            recentHistory: []
        )

        XCTAssertEqual(result.outputs.map(\.text), ["NVIDIA GPU demand is rising."])
        XCTAssertEqual(Set(result.droppedIDs), Set([context, speaker]))
    }

    func testTranscriptOrganizerRejectsUnsafeAIFallbackOutput() {
        let fragments = [
            "It creates wonderful things for you, generates a bunch of images.",
            "generates a bunch of images and then comes back with a brochure."
        ]

        XCTAssertNil(
            TranscriptOrganizer.validatedAILines(
                "Here is the cleaned transcript:\nIt creates a full marketing plan and a brochure.",
                originalFragments: fragments
            )
        )
    }

    func testTranscriptDisplayBlockKeepsMismatchedTranslationAsOneBlock() {
        let item = TranscriptionItem(
            english: "First sentence.\nSecond sentence.",
            chinese: "第一句。第二句。",
            status: .done,
            zone: .history
        )

        let block = TranscriptDisplayBlock(item: item)

        XCTAssertEqual(block.englishLines, ["First sentence.", "Second sentence."])
        XCTAssertEqual(block.chineseLines, ["第一句。第二句。"])
        XCTAssertFalse(block.canInterleaveLineByLine)
    }

    func testTranscriptDisplayBlockInterleavesMatchingTranslations() {
        let item = TranscriptionItem(
            english: "First sentence.\nSecond sentence.",
            chinese: "第一句。\n第二句。",
            status: .done,
            zone: .history
        )

        let block = TranscriptDisplayBlock(item: item)

        XCTAssertTrue(block.canInterleaveLineByLine)
    }

    func testLiveSummaryPromptRequiresChineseOnlyAndNoInventedContent() {
        let prompt = LiveSummaryPrompt.make(
            previousSummary: "前面讨论了实验目标。",
            newContent: "The speaker said the benchmark should be repeated."
        )

        XCTAssertTrue(prompt.contains("只输出中文"))
        XCTAssertTrue(prompt.contains("不要预测"))
        XCTAssertTrue(prompt.contains("不得补充"))
        XCTAssertTrue(prompt.contains("不要写“以下是”"))
        XCTAssertTrue(prompt.contains("前面讨论了实验目标。"))
        XCTAssertTrue(prompt.contains("The speaker said the benchmark should be repeated."))
    }

    func testLiveSummaryPromptRequestsSpeakerAwareMeetingSummary() {
        let prompt = LiveSummaryPrompt.make(
            previousSummary: "",
            newContent: "Alice asked whether the budget can move. Bob said the deadline matters more."
        )

        XCTAssertTrue(prompt.contains("谁提出"))
        XCTAssertTrue(prompt.contains("谁回答"))
        XCTAssertTrue(prompt.contains("不同观点"))
        XCTAssertTrue(prompt.contains("要求"))
        XCTAssertTrue(prompt.contains("不要臆造身份"))
    }

    func testFinalDetailedSummaryPromptUsesFullTranscriptAndExistingSummary() {
        let prompt = LiveSummaryPrompt.makeFinalDetailed(
            previousSummary: "已有总结：A 认为预算可调整。",
            fullContent: "英文原文：Alice asked whether the budget can move.\n中文译文：Alice 询问预算能否调整。"
        )

        XCTAssertTrue(prompt.contains("最终详细中文总结"))
        XCTAssertTrue(prompt.contains("人物/角色与观点"))
        XCTAssertTrue(prompt.contains("问题与回答"))
        XCTAssertTrue(prompt.contains("分歧或补充观点"))
        XCTAssertTrue(prompt.contains("已有总结：A 认为预算可调整。"))
        XCTAssertTrue(prompt.contains("Alice asked whether the budget can move."))
    }

    func testNvidiaSummaryServiceRejectsFailureSummaryText() {
        XCTAssertNil(NvidiaSummaryService.normalizedSummaryContent("总结失败"))
        XCTAssertNil(NvidiaSummaryService.normalizedSummaryContent("无法根据提供内容生成总结。"))
        XCTAssertEqual(
            NvidiaSummaryService.normalizedSummaryContent("A 提出预算问题，B 回答期限优先。"),
            "A 提出预算问题，B 回答期限优先。"
        )
    }

    func testSessionNoteRendererAppendsFinalSummaryAndSkipsSystemMessages() {
        let course = CourseSubject(
            name: "默认",
            abbrev: "Default",
            keywords: "",
            meetingFocus: ""
        )
        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: true,
            items: [
                TranscriptionItem(
                    english: "[自检] Sherpa: 通过",
                    status: .done,
                    zone: .history,
                    isSystemMessage: true
                ),
                TranscriptionItem(
                    english: "AI reinvented the computer industry.",
                    chinese: "人工智能重塑了计算机行业。",
                    status: .done,
                    zone: .history
                )
            ],
            finalSummary: "人工智能带来了新的计算方式。",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.contains("逐句同传记录"))
        XCTAssertTrue(content.contains("AI reinvented the computer industry.\n人工智能重塑了计算机行业。"))
        XCTAssertTrue(content.contains("最终中文总结"))
        XCTAssertTrue(content.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("人工智能带来了新的计算方式。"))
        XCTAssertFalse(content.contains("[自检] Sherpa"))
    }

    func testSessionNoteRendererRemovesRepeatedTranscriptParagraphs() {
        let course = CourseSubject(name: "默认", abbrev: "Default", keywords: "", meetingFocus: "")
        let items = [
            TranscriptionItem(
                english: "We invested in the infrastructure layer.",
                chinese: "我们投资了基础设施层。",
                status: .done,
                zone: .history
            ),
            TranscriptionItem(
                english: "Infrastructure layer, we invested in companies like CoreWeave and Nebulon.",
                chinese: "基础设施层，我们投资了 CoreWeave 和 Nebulon 等公司。",
                status: .done,
                zone: .history
            ),
            TranscriptionItem(
                english: "We invested in the infrastructure layer.",
                chinese: "我们投资了基础设施层。",
                status: .done,
                zone: .history
            )
        ]

        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: true,
            items: items,
            finalSummary: "",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.components(separatedBy: "We invested in the infrastructure layer.").count - 1, 1)
        XCTAssertEqual(content.components(separatedBy: "我们投资了基础设施层。").count - 1, 1)
        XCTAssertTrue(content.contains("Infrastructure layer, we invested in companies like CoreWeave and Nebulon."))
    }

    @MainActor
    func testStartGateRequiresSherpaAndWhisperButAllowsOfflineAPI() {
        let vm = TranscriptionViewModel()
        vm.engineStatus = .ready("ready")
        vm.sherpaReady = true
        vm.whisperReady = false
        vm.apiReady = true

        XCTAssertFalse(vm.canStartTranscription)

        vm.whisperReady = true
        vm.apiReady = false
        vm.translationEnabled = false

        XCTAssertTrue(vm.canStartTranscription)
        XCTAssertEqual(vm.startTranscriptionButtonTitle, "本地同声传译")

        vm.apiReady = true
        vm.translationEnabled = true

        XCTAssertTrue(vm.canStartTranscription)
        XCTAssertEqual(vm.startTranscriptionButtonTitle, "开始同声传译")
    }

    @MainActor
    func testFormattedResultEntersOrganizingBeforeTranslation() {
        let vm = TranscriptionViewModel()
        let uid = UUID()
        vm.dynamicItems = [
            TranscriptionItem(
                id: uid,
                english: "Raw text",
                status: .llmFormatting,
                zone: .dynamic
            )
        ]

        vm.postProcessResult(uid: uid, finalText: "AI changed the computer industry.")

        XCTAssertEqual(vm.dynamicItems.first?.english, "AI changed the computer industry.")
        XCTAssertEqual(vm.dynamicItems.first?.status, .organizing)
    }

    @MainActor
    func testOrganizerMergeKeepsVisibleOrderAndConsumesDuplicateFragment() async {
        let vm = TranscriptionViewModel()
        let first = UUID()
        let second = UUID()
        vm.translationEnabled = false
        vm.dynamicItems = [
            TranscriptionItem(id: first, english: "First", status: .llmFormatting, zone: .dynamic),
            TranscriptionItem(id: second, english: "Second", status: .llmFormatting, zone: .dynamic)
        ]

        vm.postProcessResult(uid: first, finalText: "It creates wonderful things for you, generates a bunch of images.")
        vm.postProcessResult(uid: second, finalText: "generates a bunch of images and then comes back with a brochure.")
        await vm.flushOrganizerQueueForTesting()

        let visibleItems = (vm.historyItems + vm.dynamicItems).filter(\.isVisible)
        XCTAssertEqual(visibleItems.map(\.id), [first])
        XCTAssertEqual(
            visibleItems.first?.english,
            "It creates wonderful things for you, generates a bunch of images and then comes back with a brochure."
        )
        XCTAssertEqual(visibleItems.first?.status, .done)
    }

    @MainActor
    func testSelfCheckSummaryIsPrintedToHistoryWall() {
        let vm = TranscriptionViewModel()

        vm.publishSelfCheckSummary(
            sherpa: true,
            whisper: true,
            providerResults: [
                LLMProviderCheckResult(
                    provider: LLMProviderCatalog.groqCoreProvider!,
                    status: .passed
                ),
                LLMProviderCheckResult(
                    provider: LLMProviderCatalog.nvidiaSummaryProvider!,
                    status: .notConfigured
                )
            ]
        )

        XCTAssertEqual(vm.historyItems.count, 4)
        XCTAssertTrue(vm.historyItems.allSatisfy(\.isSystemMessage))
        XCTAssertEqual(vm.historyItems.map(\.english), [
            "[自检] Sherpa: 通过",
            "[自检] WhisperKit large-v3: 通过",
            "[自检] Groq / llama-3.3-70b-versatile: 通过",
            "[自检] NVIDIA 总结 / nvidia/llama-3.3-nemotron-super-49b-v1: 未配置"
        ])
    }

    @MainActor
    func testIdleFlushMovesDoneDynamicItemToHistoryAndClearsDraft() {
        let vm = TranscriptionViewModel()
        let now: TimeInterval = 100
        let item = TranscriptionItem(
            english: "The coating thickness is controlled by deposition time.",
            status: .done,
            zone: .dynamic,
            doneTime: now - 3
        )

        vm.dynamicItems = [item]
        vm.draftText = "The coating thickness"

        vm.flushDynamicItemsForIdleInput(now: now)

        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.historyItems.map(\.english), [item.english])
        XCTAssertEqual(vm.draftText, "")
    }

    @MainActor
    func testIdleFlushMovesTranslatingDynamicItemToHistoryBeforeTranslationReturns() {
        let vm = TranscriptionViewModel()
        let now: TimeInterval = 100
        let item = TranscriptionItem(
            english: "The translation is still pending but the sentence can already appear on the history wall.",
            status: .translating,
            zone: .dynamic,
            doneTime: now - 3
        )

        vm.dynamicItems = [item]

        vm.flushDynamicItemsForIdleInput(now: now)
        vm.renderUI(force: true)

        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.historyItems.map(\.english), [item.english])
        XCTAssertEqual(vm.historyItems.first?.status, .done)
        XCTAssertNil(vm.historyItems.first?.chinese)
    }

    @MainActor
    func testLateTranslationResultUpdatesHistoryItemMovedBeforeTranslationReturns() {
        let vm = TranscriptionViewModel()
        let uid = UUID()
        vm.historyItems = [
            TranscriptionItem(
                id: uid,
                english: "The sentence already moved to the history wall.",
                status: .done,
                zone: .history
            )
        ]

        vm.applyTranslation(uid: uid, zhText: "这句话已经先进入历史墙。")

        XCTAssertEqual(vm.historyItems.first?.chinese, "这句话已经先进入历史墙。")
        XCTAssertEqual(vm.historyItems.first?.status, .done)
    }

    @MainActor
    func testRenderKeepsWallOrderWhenShortSentencePrecedesLongSentence() {
        let vm = TranscriptionViewModel()
        let short = TranscriptionItem(
            english: "I'm just kidding.",
            status: .done,
            zone: .dynamic,
            doneTime: 100
        )
        let long = TranscriptionItem(
            english: "Sometimes we become numb to the scale of the numbers and the transformation we are experiencing in the market today.",
            status: .done,
            zone: .dynamic,
            doneTime: 101
        )

        vm.dynamicItems = [short, long]
        vm.renderUI(force: true)

        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.historyItems.map(\.english), [short.english, long.english])
    }

    @MainActor
    func testRenderDoesNotLetLongSentenceBypassUnfinishedEarlierSentence() {
        let vm = TranscriptionViewModel()
        let pending = TranscriptionItem(
            english: "Earlier sentence is still being formatted.",
            status: .llmFormatting,
            zone: .dynamic
        )
        let long = TranscriptionItem(
            english: "A later long sentence has enough words to trigger hard wall movement but must not bypass the earlier item.",
            status: .done,
            zone: .dynamic,
            doneTime: 100
        )

        vm.dynamicItems = [pending, long]
        vm.renderUI(force: true)

        XCTAssertTrue(vm.historyItems.isEmpty)
        XCTAssertEqual(vm.dynamicItems.map(\.english), [pending.english, long.english])
    }

    @MainActor
    func testClearDisplayHistoryRemovesWallDynamicAndDraft() {
        let vm = TranscriptionViewModel()
        vm.historyItems = [TranscriptionItem(english: "History item.", status: .done, zone: .history)]
        vm.dynamicItems = [TranscriptionItem(english: "Dynamic item.", status: .done, zone: .dynamic)]
        vm.draftText = "Current draft"
        vm.canRestart = true

        vm.clearDisplayHistory()

        XCTAssertTrue(vm.historyItems.isEmpty)
        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.draftText, "")
        XCTAssertFalse(vm.canRestart)
    }

    @MainActor
    func testStopTranscriptionKeepsRestartDisabledUntilFinalNotesFinish() async {
        let vm = TranscriptionViewModel()
        vm.currentCourse = CourseSubject(
            name: "默认",
            abbrev: "Default",
            keywords: "",
            meetingFocus: ""
        )
        vm.isRecording = true
        vm.canRestart = true
        vm.liveSummaryReady = false
        vm.historyItems = [
            TranscriptionItem(
                english: "Alice asked whether the budget can move.",
                chinese: "Alice 询问预算能否调整。",
                status: .done,
                zone: .history
            )
        ]

        vm.stopTranscription()

        XCTAssertTrue(vm.isFinalizingSession)
        XCTAssertFalse(vm.canRestart)

        for _ in 0..<20 where vm.isFinalizingSession {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(vm.isFinalizingSession)
        XCTAssertTrue(vm.canRestart)
        XCTAssertEqual(vm.liveSummaryStatus, "已写入笔记")
    }
}
