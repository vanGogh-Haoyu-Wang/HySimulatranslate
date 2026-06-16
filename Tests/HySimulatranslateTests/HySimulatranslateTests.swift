import XCTest
@testable import HySimulatranslate

final class HySimulatranslateTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: "audioCaptureSource")
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        UserDefaults.standard.removeObject(forKey: "audioCaptureSource")
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HySimulatranslateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    func testAppResourceInstallerCopiesBundledPayloadWithoutOverwritingUserFiles() throws {
        let root = try makeTemporaryDirectory()
        let payload = root
            .appendingPathComponent("Bundle")
            .appendingPathComponent(AppResourceLocator.payloadDirectoryName)
        let support = root.appendingPathComponent("Support")
        let sherpaRelativePath = AppResourceLocator.sherpaModelRelativePath
        let bundledSherpaModel = payload.appendingPathComponent(sherpaRelativePath)
        let installedSherpaModel = support.appendingPathComponent(sherpaRelativePath)
        let bundledScripts = payload.appendingPathComponent("Scripts")

        try FileManager.default.createDirectory(at: bundledSherpaModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedSherpaModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledScripts, withIntermediateDirectories: true)
        try Data("bundled tokens".utf8).write(to: bundledSherpaModel.appendingPathComponent("tokens.txt"))
        try Data("user tokens".utf8).write(to: installedSherpaModel.appendingPathComponent("tokens.txt"))
        try Data("#!/usr/bin/env bash\n".utf8).write(to: bundledScripts.appendingPathComponent("package_dmg.sh"))

        try AppResourceLocator.installBundledResourcesIfNeeded(
            supportDirectory: support,
            bundledPayloadDirectory: payload
        )

        let preservedTokens = try String(contentsOf: installedSherpaModel.appendingPathComponent("tokens.txt"))
        XCTAssertEqual(preservedTokens, "user tokens")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: support
                    .appendingPathComponent("Scripts")
                    .appendingPathComponent("package_dmg.sh")
                    .path
            )
        )
    }

    func testAppResourceLocatorPrefersInstalledModelsThenBundledPayload() throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("Support")
        let payload = root
            .appendingPathComponent("Bundle")
            .appendingPathComponent(AppResourceLocator.payloadDirectoryName)
        let supportSherpa = support.appendingPathComponent(AppResourceLocator.sherpaModelRelativePath)
        let payloadSherpa = payload.appendingPathComponent(AppResourceLocator.sherpaModelRelativePath)
        let supportWhisper = support.appendingPathComponent(AppResourceLocator.whisperModelRelativePath)
        let payloadWhisper = payload.appendingPathComponent(AppResourceLocator.whisperModelRelativePath)

        try FileManager.default.createDirectory(at: supportSherpa, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadSherpa, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportWhisper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadWhisper, withIntermediateDirectories: true)

        XCTAssertEqual(
            AppResourceLocator.sherpaModelDirectory(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            )?.standardizedFileURL.path,
            supportSherpa.standardizedFileURL.path
        )
        XCTAssertEqual(
            AppResourceLocator.whisperModelSearchRoots(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            ).prefix(2).map { $0.standardizedFileURL.path },
            [
                supportWhisper.standardizedFileURL.path,
                payloadWhisper.standardizedFileURL.path
            ]
        )

        try FileManager.default.removeItem(at: supportSherpa)

        XCTAssertEqual(
            AppResourceLocator.sherpaModelDirectory(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            )?.standardizedFileURL.path,
            payloadSherpa.standardizedFileURL.path
        )
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
        let agnes = try XCTUnwrap(LLMProviderCatalog.agnesOrganizerProvider)

        XCTAssertEqual(groq.displayName, "Groq")
        XCTAssertEqual(groq.modelName, "llama-3.3-70b-versatile")
        XCTAssertEqual(groq.getAPIKeyURL.absoluteString, "https://console.groq.com/keys")

        XCTAssertEqual(nvidia.displayName, "NVIDIA 总结")
        XCTAssertEqual(nvidia.modelName, "nvidia/llama-3.3-nemotron-super-49b-v1")
        XCTAssertEqual(nvidia.getAPIKeyURL.absoluteString, "https://build.nvidia.com")
        XCTAssertGreaterThanOrEqual(nvidia.timeout, 20)

        XCTAssertEqual(agnes.displayName, "Agnes 整理")
        XCTAssertEqual(agnes.modelName, "agnes-2.0-flash")
        XCTAssertEqual(agnes.chatCompletionsURL.absoluteString, "https://apihub.agnes-ai.com/v1/chat/completions")
        XCTAssertTrue(agnes.acceptsKey("sk-test-key"))
    }

    func testLLMProviderCredentialsKeepGroqCoreSeparateFromNvidiaSummary() {
        let keys: [LLMProviderID: String] = [
            .groq: "gsk_test_key",
            .nvidia: "nvapi-test-key",
            .agnes: "sk-test-key"
        ]

        let coreCredential = LLMProviderCatalog.groqCoreCredential(from: keys)
        let summaryCredential = LLMProviderCatalog.nvidiaSummaryCredential(from: keys)
        let organizerCredential = LLMProviderCatalog.agnesOrganizerCredential(from: keys)

        XCTAssertEqual(coreCredential?.provider.id, .groq)
        XCTAssertEqual(summaryCredential?.provider.id, .nvidia)
        XCTAssertEqual(organizerCredential?.provider.id, .agnes)
    }

    func testKeychainProviderKeysPayloadKeepsOnlyNonEmptyKnownProviders() {
        let payload = KeychainManager.providerKeysPayload([
            .groq: "  gsk_test  ",
            .nvidia: "",
            .agnes: "sk_test"
        ])

        XCTAssertEqual(payload, [
            "groq": "gsk_test",
            "agnes": "sk_test"
        ])
    }

    func testKeychainProviderKeysAggregateJSONRoundTrips() {
        let encoded = KeychainManager.encodeProviderKeys([
            .groq: "gsk_test",
            .nvidia: " nvapi_test ",
            .agnes: "sk_test"
        ])

        XCTAssertEqual(KeychainManager.decodeProviderKeys(encoded), [
            .groq: "gsk_test",
            .nvidia: "nvapi_test",
            .agnes: "sk_test"
        ])
        XCTAssertNil(KeychainManager.decodeProviderKeys("not json"))
    }

    func testKeychainProviderKeysResolveUsesAggregateWhenPresent() {
        let aggregate = KeychainManager.encodeProviderKeys([
            .groq: "gsk_aggregate"
        ])
        let resolved = KeychainManager.resolveProviderKeys(aggregate: aggregate)

        XCTAssertEqual(resolved, [.groq: "gsk_aggregate"])
    }

    func testKeychainProviderKeysResolveReturnsEmptyWhenAggregateMissingOrInvalid() {
        XCTAssertEqual(KeychainManager.resolveProviderKeys(aggregate: nil), [:])
        XCTAssertEqual(KeychainManager.resolveProviderKeys(aggregate: "not json"), [:])
    }

    func testKeychainProviderKeysCanMigrateLegacyAccountsWhenExplicitlyRequested() {
        let legacyValues = [
            "groq_api_key": "gsk_legacy",
            "nvidia_api_key": " nvapi_legacy ",
            "agnes_api_key": "sk_legacy"
        ]
        let migrated = KeychainManager.migrateLegacyProviderKeys { account in
            legacyValues[account]
        }

        XCTAssertEqual(migrated, [
            .groq: "gsk_legacy",
            .nvidia: "nvapi_legacy",
            .agnes: "sk_legacy"
        ])
    }

    func testLLMProviderModelListsContainOnlyFreeDefaults() {
        let groqModels = LLMProviderCatalog.models(for: .groq)
        let nvidiaModels = LLMProviderCatalog.models(for: .nvidia)
        let agnesModels = LLMProviderCatalog.models(for: .agnes)

        XCTAssertEqual(groqModels.first?.id, LLMProviderCatalog.defaultGroqModelName)
        XCTAssertEqual(groqModels.first?.freeStatus, .free)
        XCTAssertEqual(nvidiaModels.first?.id, LLMProviderCatalog.defaultNvidiaSummaryModelName)
        XCTAssertEqual(nvidiaModels.first?.freeStatus, .free)
        XCTAssertEqual(agnesModels, [
            LLMProviderModel(
                providerID: .agnes,
                id: LLMProviderCatalog.defaultAgnesOrganizerModelName,
                freeStatus: .free,
                recommendationScore: 100
            )
        ])
        XCTAssertFalse(nvidiaModels.contains { $0.id == "nvidia/llama-3.3-nemotron-super-49b-v1.5" })
        XCTAssertTrue(groqModels.allSatisfy { $0.freeStatus == .free })
        XCTAssertTrue(nvidiaModels.allSatisfy { $0.freeStatus == .free })
    }

    func testModelDiscoveryParsesOpenAICompatibleModelIDs() throws {
        let fixture = """
        {"object":"list","data":[{"id":"llama-3.3-70b-versatile"},{"id":"whisper-large-v3"}]}
        """.data(using: .utf8)!

        XCTAssertEqual(
            try LLMModelDiscoveryService.modelIDs(from: fixture),
            ["llama-3.3-70b-versatile", "whisper-large-v3"]
        )
    }

    func testFreeModelFilteringKeepsOnlySupportedChatModels() {
        let groq = LLMProviderCatalog.freeModels(
            for: .groq,
            modelIDs: ["llama-3.3-70b-versatile", "whisper-large-v3", "openai/gpt-oss-120b"]
        )
        let nvidia = LLMProviderCatalog.freeModels(
            for: .nvidia,
            modelIDs: [
                "nvidia/llama-3.3-nemotron-super-49b-v1",
                "nvidia/llama-3.3-nemotron-super-49b-v1.5",
                "nvidia/parakeet-tdt-0.6b-v2"
            ]
        )

        XCTAssertEqual(groq.map(\.id), ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"])
        XCTAssertEqual(nvidia.map(\.id), ["nvidia/llama-3.3-nemotron-super-49b-v1"])
    }

    func testAgnesHistoryOrganizerValidationRejectsMissingIDsAndExpansions() {
        let items = [
            AgnesHistoryOrganizerItem(id: "a", english: "The AI factory started with Nvidia.", chinese: "AI 工厂始于 Nvidia。"),
            AgnesHistoryOrganizerItem(id: "b", english: "Nvidia provided the first platform.", chinese: "Nvidia 提供了第一个平台。")
        ]
        let valid = """
        {"updates":[
          {"id":"a","english":"The AI factory started with Nvidia.","chinese":"AI 工厂始于 Nvidia。","drop":false},
          {"id":"b","english":"Nvidia provided the first platform.","chinese":"Nvidia 提供了第一个平台。","drop":false}
        ]}
        """
        let missing = """
        {"updates":[
          {"id":"a","english":"The AI factory started with Nvidia.","chinese":"AI 工厂始于 Nvidia。","drop":false}
        ]}
        """
        let expanded = """
        {"updates":[
          {"id":"a","english":"The AI factory started with Nvidia and then this model invents an entire extra explanation about markets, architecture, products, strategy, roadmap, pricing, customers, revenue, competitors, and many facts that were never in the transcript.","chinese":"AI 工厂始于 Nvidia。","drop":false},
          {"id":"b","english":"Nvidia provided the first platform.","chinese":"Nvidia 提供了第一个平台。","drop":false}
        ]}
        """

        XCTAssertEqual(AgnesHistoryOrganizerService.validatedUpdates(from: valid, originalItems: items)?.count, 2)
        XCTAssertNil(AgnesHistoryOrganizerService.validatedUpdates(from: missing, originalItems: items))
        XCTAssertNil(AgnesHistoryOrganizerService.validatedUpdates(from: expanded, originalItems: items))
    }

    func testHistoryWallCleanerDropsDuplicatesAndTrimsAdjacentBoundaryOverlap() {
        let first = TranscriptionItem(
            english: "The product roadmap is clear customer support workflow automation",
            status: .done,
            zone: .history
        )
        let second = TranscriptionItem(
            english: "support workflow automation will launch next quarter.",
            status: .done,
            zone: .history
        )
        let duplicate = TranscriptionItem(
            english: "support workflow automation will launch next quarter.",
            status: .done,
            zone: .history
        )

        let cleaned = HistoryWallCleaner.clean([first, second, duplicate])

        XCTAssertEqual(cleaned[0].english, "The product roadmap is clear customer")
        XCTAssertTrue(cleaned[1].isVisible)
        XCTAssertFalse(cleaned[2].isVisible)
        XCTAssertEqual(cleaned[2].status, .dropped)
    }

    func testFailedConnectivityRecordsSinkModelsButKeepRecommendationOrder() {
        let failed = LLMProviderModelConnectivityRecord(
            providerID: .groq,
            modelID: "openai/gpt-oss-120b",
            status: .failed,
            detail: "HTTP 404",
            testedAt: Date(timeIntervalSince1970: 0)
        )
        let records = LLMProviderCatalog.connectivityRecordsByKey([failed])
        let sorted = LLMProviderCatalog.sortedModels(
            [
                LLMProviderModel(providerID: .groq, id: "openai/gpt-oss-120b", freeStatus: .free, recommendationScore: 98),
                LLMProviderModel(providerID: .groq, id: "gemma2-9b-it", freeStatus: .free, recommendationScore: 74),
                LLMProviderModel(providerID: .groq, id: "llama-3.1-8b-instant", freeStatus: .free, recommendationScore: 88)
            ],
            connectivityRecords: records
        )

        XCTAssertEqual(sorted.map(\.id), ["llama-3.1-8b-instant", "gemma2-9b-it", "openai/gpt-oss-120b"])
    }

    func testSelectedProviderModelsOverrideCredentialModelNames() {
        let keys: [LLMProviderID: String] = [
            .groq: "gsk_test_key",
            .nvidia: "nvapi-test-key"
        ]
        let selected: [LLMProviderID: String] = [
            .groq: "llama-3.1-8b-instant",
            .nvidia: "nvidia/llama-3.1-nemotron-70b-instruct"
        ]

        XCTAssertEqual(
            LLMProviderCatalog.groqCoreCredential(
                from: keys,
                selectedModelNames: selected
            )?.provider.modelName,
            "llama-3.1-8b-instant"
        )
        XCTAssertEqual(
            LLMProviderCatalog.nvidiaSummaryCredential(
                from: keys,
                selectedModelNames: selected
            )?.provider.modelName,
            "nvidia/llama-3.1-nemotron-70b-instruct"
        )
    }

    @MainActor
    func testChangingProviderModelInvalidatesPreviousConnectivityState() {
        let vm = TranscriptionViewModel()
        vm.providerAPIKeys = [.groq: "gsk_test_key", .nvidia: "nvapi-test-key"]
        vm.engineStatus = .ready("ready")
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.apiReady = true
        vm.translationEnabled = true
        vm.liveSummaryReady = true
        vm.groqCoreModelName = "llama-3.1-8b-instant"

        vm.noteProviderModelSelectionChanged()

        XCTAssertFalse(vm.apiReady)
        XCTAssertFalse(vm.translationEnabled)
        XCTAssertFalse(vm.liveSummaryReady)
        XCTAssertTrue(vm.providerCheckResults.contains {
            $0.provider.id == .groq && $0.provider.modelName == "llama-3.1-8b-instant"
        })
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

    func testSessionNoteRendererMarkdownUsesHeadingsAndRules() {
        let course = CourseSubject(name: "默认", abbrev: "Default", keywords: "", meetingFocus: "")
        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: true,
            items: [
                TranscriptionItem(
                    english: "Markdown works with Obsidian.",
                    chinese: "Markdown 可以和 Obsidian 配合。",
                    status: .done,
                    zone: .history
                )
            ],
            finalSummary: "本次讨论确认支持 Markdown。",
            format: .markdown,
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.contains("# HySimulatranslate Notes"))
        XCTAssertTrue(content.contains("## 逐句同传记录"))
        XCTAssertTrue(content.contains("---"))
        XCTAssertTrue(content.contains("## 最终中文总结"))
        XCTAssertTrue(content.contains("Markdown works with Obsidian.\nMarkdown 可以和 Obsidian 配合。"))
    }

    @MainActor
    func testStartGateRequiresMicrophoneSherpaAndWhisperButAllowsOfflineAPI() {
        let vm = TranscriptionViewModel()
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.sherpaReady = true
        vm.whisperReady = false
        vm.apiReady = true

        XCTAssertFalse(vm.canStartTranscription)

        vm.whisperReady = true
        vm.apiReady = false
        vm.translationEnabled = false

        vm.microphoneReady = false
        XCTAssertFalse(vm.canStartTranscription)

        vm.microphoneReady = true

        XCTAssertTrue(vm.canStartTranscription)
        XCTAssertEqual(vm.startTranscriptionButtonTitle, "本地同声传译")

        vm.apiReady = true
        vm.translationEnabled = true

        XCTAssertTrue(vm.canStartTranscription)
        XCTAssertEqual(vm.startTranscriptionButtonTitle, "开始同声传译")
    }

    @MainActor
    func testStartGateRequiresSystemAudioWhenComputerAudioSourceIsSelected() {
        let vm = TranscriptionViewModel()
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.micDeviceName = "MacBook Pro 麦克风"
        vm.selectAudioCaptureSource(.systemAudio)
        vm.systemAudioReady = false
        vm.sherpaReady = true
        vm.whisperReady = true

        XCTAssertTrue(vm.microphoneReady)
        XCTAssertFalse(vm.systemAudioReady)
        XCTAssertEqual(vm.audioCaptureSourceStatus, "麦克风已通过；电脑音频待自检")
        XCTAssertFalse(vm.canStartTranscription)

        vm.systemAudioReady = true

        XCTAssertTrue(vm.canStartTranscription)
        vm.selectAudioCaptureSource(.microphone)
        XCTAssertTrue(vm.microphoneReady)
        XCTAssertFalse(vm.systemAudioReady)
        XCTAssertTrue(vm.canStartTranscription)
    }

    func testApplicationAudioStorageDowngradesToSystemAudio() {
        let source = AudioCaptureSource.application(
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let decoded = AudioCaptureSource.fromStorageValue(source.storageValue)

        XCTAssertEqual(decoded, .systemAudio)
        XCTAssertEqual(AudioCaptureSource.fromStorageValue("not-json"), .microphone)
        XCTAssertEqual(AudioCaptureSource.systemAudio.statusTitle, "全系统音频 + 麦克风")
    }

    @MainActor
    func testAudioSourceListDoesNotExposeApplicationAudioSources() {
        let vm = TranscriptionViewModel()

        XCTAssertEqual(vm.availableAudioCaptureSources, [.microphone, .systemAudio])

        vm.refreshAudioCaptureSources()

        XCTAssertEqual(vm.availableAudioCaptureSources, [.microphone, .systemAudio])

        vm.selectAudioCaptureSource(.application(
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        ))

        XCTAssertEqual(vm.selectedAudioCaptureSource, .systemAudio)
        XCTAssertEqual(vm.availableAudioCaptureSources, [.microphone, .systemAudio])
    }

    @MainActor
    func testSavedApplicationAudioSourceDowngradesToSystemAudio() {
        let legacySource = AudioCaptureSource.application(
            bundleIdentifier: "com.apple.WindowManager",
            name: "Window Manager"
        )
        UserDefaults.standard.set(legacySource.storageValue, forKey: "audioCaptureSource")

        let vm = TranscriptionViewModel()

        XCTAssertEqual(vm.selectedAudioCaptureSource, .systemAudio)
        XCTAssertEqual(vm.availableAudioCaptureSources, [.microphone, .systemAudio])
        XCTAssertEqual(vm.audioCaptureSourceStatus, "已切换为全系统音频，避免应用捕获授权冲突")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "audioCaptureSource"),
            AudioCaptureSource.systemAudio.storageValue
        )
    }

    func testSystemAudioEngineDoesNotExposeApplicationAudioSources() async {
        let sources = await SystemAudioCaptureEngine.availableApplicationSources()

        XCTAssertTrue(sources.isEmpty)
    }

    func testSystemAudioPermissionMessageDoesNotMentionMicrophonePermission() {
        let error = NSError(
            domain: "SystemAudioCaptureEngine",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "TCC denied"]
        )

        let message = SystemAudioCaptureEngine.permissionMessage(for: .systemAudio, error: error)

        XCTAssertTrue(message.contains("屏幕与系统音频录制"))
        XCTAssertTrue(message.contains("仅系统录音"))
        XCTAssertTrue(message.contains("电脑音频未授权"))
        XCTAssertFalse(message.contains("麦克风权限未授权"))
    }

    func testGeneratedInfoPlistsDeclareMicrophoneAndSystemAudioUsage() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptPaths = [
            packageRoot.appendingPathComponent("script/build_and_run.sh"),
            packageRoot.appendingPathComponent("script/package_dmg.sh")
        ]

        for scriptPath in scriptPaths {
            let script = try String(contentsOf: scriptPath, encoding: .utf8)
            XCTAssertTrue(script.contains("NSMicrophoneUsageDescription"))
            XCTAssertTrue(script.contains("NSScreenCaptureUsageDescription"))
            XCTAssertTrue(script.contains("NSAudioCaptureUsageDescription"))
            XCTAssertTrue(script.contains("record your local speech"))
            XCTAssertTrue(script.contains("screen and system audio recording access"))
        }
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
            microphone: true,
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

        XCTAssertEqual(vm.historyItems.count, 6)
        XCTAssertTrue(vm.historyItems.allSatisfy(\.isSystemMessage))
        XCTAssertEqual(vm.historyItems.map(\.english), [
            "[自检] 麦克风: 通过",
            "[自检] 音频源: 麦克风: 通过",
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

    func testNoteRecordScannerReturnsSupportedNoteFilesInModificationOrder() throws {
        let directory = try makeTemporaryDirectory()
        let older = directory.appendingPathComponent("older.txt")
        let newer = directory.appendingPathComponent("newer.TXT")
        let newest = directory.appendingPathComponent("newest.md")
        let markdown = directory.appendingPathComponent("reference.markdown")
        let ignored = directory.appendingPathComponent("ignored.json")
        let nested = directory.appendingPathComponent("Nested", isDirectory: true)

        try Data("Older note body".utf8).write(to: older)
        try Data("Newer note body".utf8).write(to: newer)
        try Data("# Newest note\n---\nMarkdown body".utf8).write(to: newest)
        try Data("# Reference note".utf8).write(to: markdown)
        try Data("Not a note".utf8).write(to: ignored)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("Nested note".utf8).write(to: nested.appendingPathComponent("nested.txt"))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)],
            ofItemAtPath: newest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 150)],
            ofItemAtPath: markdown.path
        )

        let records = TranscriptionViewModel.scanNoteRecords(in: directory)

        XCTAssertEqual(records.map(\.fileName), ["newest.md", "newer.TXT", "reference.markdown", "older.txt"])
        XCTAssertEqual(records.map(\.format), [.markdown, .text, .markdown, .text])
        XCTAssertEqual(records.first?.previewSummary, "Newest note Markdown body")
    }

    @MainActor
    func testRefreshNoteRecordsUsesConfiguredNoteDirectory() throws {
        let directory = try makeTemporaryDirectory()
        try Data("Session note".utf8).write(to: directory.appendingPathComponent("session.txt"))
        try Data("# Markdown note".utf8).write(to: directory.appendingPathComponent("session.md"))
        try Data("Ignore".utf8).write(to: directory.appendingPathComponent("session.json"))

        let vm = TranscriptionViewModel()
        vm.noteDirectoryPath = directory.path
        vm.refreshNoteRecords()

        XCTAssertEqual(Set(vm.noteRecords.map(\.fileName)), Set(["session.txt", "session.md"]))
    }

    @MainActor
    func testNoteFileFormatDefaultsToMarkdownAndBuildsExpectedExtensions() {
        UserDefaults.standard.removeObject(forKey: "noteFileFormat")
        let vm = TranscriptionViewModel()
        let course = CourseSubject(name: "默认", abbrev: "Default", keywords: "", meetingFocus: "")

        XCTAssertEqual(vm.noteFileFormat, .markdown)
        XCTAssertEqual(
            TranscriptionViewModel.noteFileName(course: course, dateString: "2026-06-15_02-45", format: .markdown),
            "Default_Session_2026-06-15_02-45.md"
        )
        XCTAssertEqual(
            TranscriptionViewModel.noteFileName(course: course, dateString: "2026-06-15_02-45", format: .text),
            "Default_Session_2026-06-15_02-45.txt"
        )
    }

    @MainActor
    func testStartNewRecordClearsDisplayButKeepsReadinessAndProviderResults() {
        let vm = TranscriptionViewModel()
        let result = LLMProviderCheckResult(
            provider: LLMProviderCatalog.groqCoreProvider!,
            status: .passed
        )
        vm.selectAudioCaptureSource(.microphone)
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.apiReady = true
        vm.translationEnabled = true
        vm.liveSummaryReady = true
        vm.providerCheckResults = [result]
        vm.historyItems = [TranscriptionItem(english: "History item.", status: .done, zone: .history)]
        vm.dynamicItems = [TranscriptionItem(english: "Dynamic item.", status: .done, zone: .dynamic)]
        vm.draftText = "Current draft"
        vm.liveSummaryText = "Summary"
        vm.canRestart = true

        vm.startNewRecordWithoutSelfCheck()

        XCTAssertTrue(vm.historyItems.isEmpty)
        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.draftText, "")
        XCTAssertEqual(vm.liveSummaryText, "")
        XCTAssertTrue(vm.microphoneReady)
        XCTAssertTrue(vm.sherpaReady)
        XCTAssertTrue(vm.whisperReady)
        XCTAssertTrue(vm.apiReady)
        XCTAssertTrue(vm.liveSummaryReady)
        XCTAssertEqual(vm.providerCheckResults, [result])
        XCTAssertTrue(vm.canStartTranscription)
    }

    @MainActor
    func testSelectCourseUpdatesCurrentCourseButDoesNotChangeWhileRecording() {
        let vm = TranscriptionViewModel()
        let first = CourseSubject(name: "First", abbrev: "F", keywords: "", meetingFocus: "")
        let second = CourseSubject(name: "Second", abbrev: "S", keywords: "", meetingFocus: "")

        vm.selectCourse(first)
        XCTAssertEqual(vm.currentCourse, first)

        vm.isRecording = true
        vm.selectCourse(second)
        XCTAssertEqual(vm.currentCourse, first)
    }

    @MainActor
    func testProviderCheckStripHidesAfterTranscriptionStartsOrHistoryArrives() {
        let results = [
            LLMProviderCheckResult(provider: LLMProviderCatalog.groqCoreProvider!, status: .passed),
            LLMProviderCheckResult(provider: LLMProviderCatalog.nvidiaSummaryProvider!, status: .passed)
        ]
        let systemHistory = [
            TranscriptionItem(english: "[自检] Sherpa: 通过", status: .done, zone: .history, isSystemMessage: true)
        ]
        let formalHistory = [
            TranscriptionItem(english: "Hello.", status: .done, zone: .history, isSystemMessage: false)
        ]

        XCTAssertTrue(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: false,
            canRestart: false,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: true,
            isFinalizingSession: false,
            canRestart: false,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: true,
            canRestart: false,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: false,
            canRestart: true,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: false,
            canRestart: false,
            historyItems: formalHistory,
            providerCheckResults: results
        ))
    }

    @MainActor
    func testUpdateProviderAPIKeysUpdatesViewModelProviderKeys() {
        let vm = TranscriptionViewModel()
        vm.updateProviderAPIKeys([
            .groq: "gsk_test_key",
            .nvidia: "nvapi-test-key",
            .agnes: "sk-test-key"
        ])

        XCTAssertEqual(vm.providerAPIKeys[.groq], "gsk_test_key")
        XCTAssertEqual(vm.providerAPIKeys[.nvidia], "nvapi-test-key")
        XCTAssertEqual(vm.providerAPIKeys[.agnes], "sk-test-key")
        XCTAssertEqual(vm.providerCheckResults.count, 3)
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

    func testVADAndDenoiserResourcesPreferApplicationSupportFiles() throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("Support")
        let payload = root
            .appendingPathComponent("Bundle")
            .appendingPathComponent(AppResourceLocator.payloadDirectoryName)
        let supportVAD = support.appendingPathComponent(AppResourceLocator.vadModelRelativePath)
        let payloadDenoiser = payload.appendingPathComponent(AppResourceLocator.speechDenoiserModelRelativePath)

        try FileManager.default.createDirectory(at: supportVAD.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadDenoiser.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("vad".utf8).write(to: supportVAD)
        try Data("denoiser".utf8).write(to: payloadDenoiser)

        XCTAssertEqual(
            AppResourceLocator.vadModelFile(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            )?.standardizedFileURL.path,
            supportVAD.standardizedFileURL.path
        )
        XCTAssertEqual(
            AppResourceLocator.speechDenoiserModelFile(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            )?.standardizedFileURL.path,
            payloadDenoiser.standardizedFileURL.path
        )
    }

    func testLLMPromptUsesWhisperAsPrimaryAndSherpaAsReference() {
        let promptSource = LLMService.sourceTextForPrompt(
            rawText: "Whisper transcript.",
            whisperText: "WhisperKit recovered the technical phrase.",
            sherpaText: "Sherpa draft recovered the technical phrase."
        )

        XCTAssertTrue(promptSource.contains("WhisperKit primary transcript"))
        XCTAssertTrue(promptSource.contains("Sherpa draft reference"))
        XCTAssertTrue(promptSource.contains("WhisperKit recovered the technical phrase."))
        XCTAssertTrue(promptSource.contains("Sherpa draft recovered the technical phrase."))
    }

    @MainActor
    func testLLMFormatCandidatesBatchBeforeQueuedReview() {
        let vm = TranscriptionViewModel()
        vm.apiReady = true
        let first = UUID()
        let second = UUID()
        let third = UUID()

        vm.enqueueLLMFormatCandidateForTesting(
            uid: first,
            text: "Whisper first.",
            sherpaText: "Sherpa first."
        )
        vm.enqueueLLMFormatCandidateForTesting(
            uid: second,
            text: "Whisper second.",
            sherpaText: "Sherpa second."
        )

        XCTAssertEqual(vm.queuedLLMItemsForTesting.count, 0)
        XCTAssertEqual(vm.llmQueueSize, 2)

        vm.enqueueLLMFormatCandidateForTesting(
            uid: third,
            text: "Whisper third.",
            sherpaText: "Sherpa third."
        )

        let queued = vm.queuedLLMItemsForTesting
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.sourceIDs, [first, second, third])
        XCTAssertTrue(queued.first?.whisperText.contains("1. Whisper first.") == true)
        XCTAssertTrue(queued.first?.sherpaText.contains("3. Sherpa third.") == true)
        XCTAssertEqual(vm.llmQueueSize, 1)
    }

    func testChatRateLimiterPolicyUsesConservativeBatchingNearLimit() {
        XCTAssertFalse(
            ChatRateLimiter.shouldUseConservativeBatching(
                currentRPM: 10,
                queueDepth: 1,
                recentlyRateLimited: false
            )
        )
        XCTAssertTrue(
            ChatRateLimiter.shouldUseConservativeBatching(
                currentRPM: ChatRateLimiter.targetRPM,
                queueDepth: 1,
                recentlyRateLimited: false
            )
        )
        XCTAssertEqual(ChatRateLimiter.targetBatchSize(conservative: false), 3)
        XCTAssertEqual(ChatRateLimiter.targetBatchSize(conservative: true), 5)
    }

    func testNoteDirectoryDefaultsToDesktopAndExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL

        XCTAssertEqual(
            TranscriptionViewModel.noteDirectory(from: "").standardizedFileURL.path,
            desktop.path
        )
        XCTAssertEqual(
            TranscriptionViewModel.noteDirectory(from: "~/HySimulatranslateNotes").standardizedFileURL.path,
            home.appendingPathComponent("HySimulatranslateNotes", isDirectory: true).standardizedFileURL.path
        )
    }
}
