import XCTest
@testable import HySimulatranslate

final class ModelCenterTests: XCTestCase {
    func testWhisperKitValidationAcceptsRealHubRepositoryLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let variant = repository.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try makeWhisperKitFixture(at: variant)

        let service = ModelResourceService(resources: [
            .init(id: "whisperkit", displayName: "WhisperKit", location: repository, requiredFiles: [], affectedCapability: "精校", validationKind: .whisperKit)
        ])

        let report = try XCTUnwrap(service.validationReport(resourceID: "whisperkit"))
        XCTAssertEqual(report.state, .ready)
        XCTAssertTrue(report.missingComponents.isEmpty)
        XCTAssertEqual(report.location.standardizedFileURL, repository.standardizedFileURL)
    }

    func testSpeakerKitValidationAcceptsNestedRealHubRepositoryLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
        try makeSpeakerKitFixture(at: repository)

        let service = ModelResourceService(resources: [
            .init(id: "speakerkit", displayName: "SpeakerKit", location: repository, requiredFiles: [], affectedCapability: "说话人分离", validationKind: .speakerKit)
        ])

        XCTAssertEqual(service.validationReport(resourceID: "speakerkit")?.state, .ready)
    }

    func testSpecializedValidationReportsMissingAndEmptyComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("whisperkit-coreml", isDirectory: true)
        let variant = repository.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try FileManager.default.createDirectory(at: variant.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true)
        try Data().write(to: variant.appendingPathComponent("config.json"))

        let service = ModelResourceService(resources: [
            .init(id: "whisperkit", displayName: "WhisperKit", location: repository, requiredFiles: [], affectedCapability: "精校", validationKind: .whisperKit)
        ])
        let report = try XCTUnwrap(service.validationReport(resourceID: "whisperkit"))

        XCTAssertEqual(report.state, .corrupt)
        XCTAssertTrue(report.missingComponents.contains("config.json"))
        XCTAssertTrue(report.missingComponents.contains("MelSpectrogram.mlmodelc"))
        XCTAssertTrue(report.missingComponents.contains("AudioEncoder.mlmodelc"))
        XCTAssertTrue(report.missingComponents.contains("TextDecoder.mlmodelc"))
    }

    func testLegacyHubRepositoriesMigrateWithoutTouchingUnrelatedModels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support/HySimulatranslate", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let legacyWhisper = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let legacySpeaker = documents.appendingPathComponent("huggingface/models/argmaxinc/speakerkit-coreml", isDirectory: true)
        let unrelated = documents.appendingPathComponent("huggingface/models/example/keep-me", isDirectory: true)
        try makeWhisperKitFixture(at: legacyWhisper.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true))
        try makeSpeakerKitFixture(at: legacySpeaker)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([1]).write(to: unrelated.appendingPathComponent("model.bin"))
        let store = ManagedModelStore(supportDirectory: support, documentsDirectory: documents)

        try store.migrateLegacyRepositoriesIfNeeded()
        try store.migrateLegacyRepositoriesIfNeeded()

        XCTAssertEqual(store.validationReport(for: .whisperKit).state, .ready)
        XCTAssertEqual(store.validationReport(for: .speakerKit).state, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyWhisper.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySpeaker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testLegacyMigrationCopyFallbackValidatesBeforeRemovingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedModelStore(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            documentsDirectory: root.appendingPathComponent("documents", isDirectory: true),
            migrationMovePolicy: .copyOnly
        )
        let source = store.legacyRepositoryDirectory(for: .speakerKit)
        try makeSpeakerKitFixture(at: source)

        try store.migrateLegacyRepositoriesIfNeeded()

        XCTAssertEqual(store.validationReport(for: .speakerKit).state, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testStandardResourcesUseManagedHubRepositoryLocations() throws {
        let support = URL(fileURLWithPath: "/tmp/hysimulatranslate-model-test", isDirectory: true)
        let store = ManagedModelStore(
            supportDirectory: support,
            documentsDirectory: URL(fileURLWithPath: "/tmp/documents", isDirectory: true)
        )
        let resources = ModelResourceService.standardResources(support: support)

        XCTAssertEqual(
            resources.first(where: { $0.id == "whisperkit" })?.location,
            store.repositoryDirectory(for: .whisperKit)
        )
        XCTAssertEqual(
            resources.first(where: { $0.id == "speakerkit" })?.location,
            store.repositoryDirectory(for: .speakerKit)
        )
        XCTAssertEqual(store.downloadBase(for: .whisperKit).lastPathComponent, "WhisperKit")
        XCTAssertEqual(store.downloadBase(for: .speakerKit).lastPathComponent, "SpeakerKit")
    }

    @MainActor func testModelCenterMigratesValidLegacyModelBeforeOfferingDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let documents = root.appendingPathComponent("documents", isDirectory: true)
        let store = ManagedModelStore(supportDirectory: support, documentsDirectory: documents)
        let legacy = store.legacyRepositoryDirectory(for: .whisperKit)
        try makeWhisperKitFixture(at: legacy.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true))
        let resource = ModelResourceDefinition(id: "whisperkit", displayName: "WhisperKit", location: store.repositoryDirectory(for: .whisperKit), requiredFiles: [], affectedCapability: "精校", validationKind: .whisperKit)
        let service = ModelResourceService(resources: [resource], managedModelStore: store)

        let vm = ModelCenterViewModel(resourceService: service, providerKeys: { [:] })

        XCTAssertEqual(vm.localResources.first?.state, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    @MainActor func testDownloadIntegrityFailureNamesMissingComponentsAndPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("whisperkit-coreml", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let service = ModelResourceService(resources: [
            .init(id: "whisperkit", displayName: "WhisperKit", location: repository, requiredFiles: [], affectedCapability: "精校", validationKind: .whisperKit)
        ])
        let vm = ModelCenterViewModel(resourceService: service, providerKeys: { [:] }, installer: { _, _ in
            repository
        })

        await vm.download(resourceID: "whisperkit")

        XCTAssertTrue(vm.lastError?.contains("MelSpectrogram.mlmodelc") == true)
        XCTAssertTrue(vm.lastError?.contains(repository.path) == true)
    }

    func testModelListScopeStorageDefaultsToRecommendedAndRoundTripsAll() {
        XCTAssertEqual(ModelListScope(storageValue: nil), .recommended)
        XCTAssertEqual(ModelListScope(storageValue: "invalid"), .recommended)
        XCTAssertEqual(ModelListScope(storageValue: ModelListScope.all.rawValue), .all)
    }

    func testResourceSpecificLeaseBlocksOnlyLeasedModelAndReleasesAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sherpa = root.appendingPathComponent("sherpa"), whisper = root.appendingPathComponent("whisper")
        try FileManager.default.createDirectory(at: sherpa, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: whisper, withIntermediateDirectories: true)
        let service = ModelResourceService(resources: [
            .init(id: "sherpa", displayName: "Sherpa", location: sherpa, requiredFiles: [], affectedCapability: "实时转写"),
            .init(id: "whisperkit", displayName: "WhisperKit", location: whisper, requiredFiles: [], affectedCapability: "精校")
        ])
        let usage = ModelUsageCoordinator(resources: service)
        do { try await usage.withLease(owner: "import", resourceIDs: ["whisperkit"]) { throw TestError.expected } } catch {}
        try service.delete(resourceID: "whisperkit")
        let lease = try service.tryAcquireLease(resourceIDs: ["sherpa"], owner: "recording")
        XCTAssertThrowsError(try service.delete(resourceID: "sherpa"))
        try service.delete(resourceID: "whisperkit")
        lease.release()
    }

    @MainActor func testModelCenterStartupScanCloudRefreshProgressRetryAndDeleteConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model")
        let service = ModelResourceService(resources: [.init(id: "sherpa", displayName: "Sherpa", location: model, requiredFiles: ["tokens.txt"], affectedCapability: "实时转写")])
        let cloud = CloudClientStub()
        var attempts = 0
        let vm = ModelCenterViewModel(resourceService: service, providerKeys: { [.groq: "gsk_test"] }, cloudClient: cloud) { _, progress in
            attempts += 1; progress(0.5, "下载中")
            if attempts == 1 { throw TestError.expected }
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data([1]).write(to: model.appendingPathComponent("tokens.txt"))
            return model
        }
        XCTAssertEqual(vm.localResources.first?.state, .missing)
        await vm.refreshCloud()
        XCTAssertEqual(vm.cloudProviders.first { $0.id == .groq }?.models.map(\.id), ["model-a"])
        await vm.download(resourceID: "sherpa")
        XCTAssertNotNil(vm.lastError)
        await vm.retry(resourceID: "sherpa")
        XCTAssertEqual(vm.localResources.first?.state, .ready)
        XCTAssertEqual(vm.progressByResource["sherpa"], 1)
        vm.requestDelete(resourceID: "sherpa")
        XCTAssertEqual(vm.pendingDeletion?.affectedCapability, "实时转写")
        XCTAssertGreaterThan(vm.pendingDeletion?.size ?? 0, 0)
    }

    func testPersistenceRecordsContainNoAPIKeyField() {
        let names = Mirror(reflecting: MeetingRecord(title: "x", source: .live)).children.compactMap(\.label)
        XCTAssertFalse(names.contains { $0.lowercased().contains("key") || $0.lowercased().contains("secret") })
    }

    @MainActor func testCloudModelSelectionCoversAllProvidersAndNotifiesOwner() async throws {
        var persisted: [LLMProviderID: String] = [
            .groq: "groq-old",
            .agnes: "agnes-old"
        ]
        var changes: [(LLMProviderID, String)] = []
        let vm = ModelCenterViewModel(
            resourceService: ModelResourceService(resources: []),
            providerKeys: { [.groq: "gsk_test", .agnes: "sk-test"] },
            selectedModels: { persisted },
            onModelSelectionChanged: { providerID, modelID in
                persisted[providerID] = modelID
                changes.append((providerID, modelID))
            },
            cloudClient: CloudClientStub()
        )

        await vm.refreshCloud()
        for providerID in [LLMProviderID.groq, .agnes] {
            vm.selectModel("model-a", for: providerID)
            XCTAssertEqual(vm.selectedModelID(for: providerID), "model-a")
        }
        XCTAssertEqual(changes.map(\.0), [.groq, .agnes])
        XCTAssertEqual(persisted.values.filter { $0 == "model-a" }.count, 2)
    }

    @MainActor func testCloudRefreshUsesOneRequestAndFiltersRecommendedWithoutDroppingSelection() async throws {
        let cloud = CountingCloudClient(models: [
            .init(providerID: .groq, id: LLMProviderCatalog.defaultGroqModelName, freeStatus: .free, recommendationScore: 100),
            .init(providerID: .groq, id: "acme/new-text-model", freeStatus: .unknown, recommendationScore: 50)
        ])
        let vm = ModelCenterViewModel(
            resourceService: ModelResourceService(resources: []),
            providerKeys: { [.groq: "gsk_test"] },
            selectedModels: { [.groq: "acme/previous-selection"] },
            cloudClient: cloud
        )

        await vm.refreshCloud()

        let groqRequestCount = await cloud.requestCount(for: .groq)
        let totalRequestCount = await cloud.totalRequestCount()
        XCTAssertEqual(groqRequestCount, 1)
        XCTAssertEqual(totalRequestCount, 1)
        XCTAssertEqual(vm.cloudProviders.first(where: { $0.id == .groq })?.connectivity, .failed("当前模型不可用"))
        XCTAssertEqual(
            Set(vm.visibleModels(for: .groq, scope: .all).map(\.id)),
            Set([LLMProviderCatalog.defaultGroqModelName, "acme/new-text-model", "acme/previous-selection"])
        )
        XCTAssertEqual(
            Set(vm.visibleModels(for: .groq, scope: .recommended).map(\.id)),
            Set([LLMProviderCatalog.defaultGroqModelName, "acme/previous-selection"])
        )
        XCTAssertEqual(vm.selectedModelID(for: .groq), "acme/previous-selection")
    }

    @MainActor func testCloudRefreshFailurePreservesLastSuccessfulModels() async throws {
        let cloud = CountingCloudClient(models: [
            .init(providerID: .agnes, id: LLMProviderCatalog.defaultAgnesOrganizerModelName, freeStatus: .free, recommendationScore: 100),
            .init(providerID: .agnes, id: "agnes-1.5-flash", freeStatus: .unknown, recommendationScore: 50)
        ])
        let vm = ModelCenterViewModel(
            resourceService: ModelResourceService(resources: []),
            providerKeys: { [.agnes: "sk-test"] },
            selectedModels: { [.agnes: LLMProviderCatalog.defaultAgnesOrganizerModelName] },
            cloudClient: cloud
        )
        await vm.refreshCloud()
        let successfulModels = vm.cloudProviders.first(where: { $0.id == .agnes })?.models

        await cloud.setShouldFail(true)
        await vm.refreshCloud()

        XCTAssertEqual(vm.cloudProviders.first(where: { $0.id == .agnes })?.models, successfulModels)
        XCTAssertEqual(vm.cloudProviders.first(where: { $0.id == .agnes })?.connectivity, .failed("模拟刷新失败"))
        let agnesRequestCount = await cloud.requestCount(for: .agnes)
        XCTAssertEqual(agnesRequestCount, 2)
    }

    func testMissingResourceNeverPresentsAsInUse() {
        let missing = ModelResourceSnapshot(
            definition: .init(
                id: "missing",
                displayName: "Missing",
                location: URL(fileURLWithPath: "/missing"),
                requiredFiles: [],
                affectedCapability: "test"
            ),
            state: .missing,
            size: 0,
            activeOwners: ["model loading"]
        )
        XCTAssertFalse(missing.shouldDisplayInUse)
    }

    func testDeleteAtomicallyRejectsLeaseWhileFilesystemRemovalIsInFlight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let enteredDelete = DispatchSemaphore(value: 0), allowDelete = DispatchSemaphore(value: 0)
        let service = ModelResourceService(resources: [
            .init(id: "model", displayName: "Model", location: root, requiredFiles: [], affectedCapability: "test")
        ], removeItem: { url in enteredDelete.signal(); allowDelete.wait(); try FileManager.default.removeItem(at: url) })
        let finished = expectation(description: "delete")
        DispatchQueue.global().async { defer { finished.fulfill() }; try? service.delete(resourceID: "model") }
        XCTAssertEqual(enteredDelete.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try service.tryAcquireLease(resourceIDs: ["model"], owner: "late"))
        allowDelete.signal(); wait(for: [finished], timeout: 2)
    }

    func testFileAndDirectoryValidationRejectsEmptyWrongShapeAndMissingSpeakerComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vad = root.appendingPathComponent("silero.onnx")
        let speaker = root.appendingPathComponent("speaker", isDirectory: true)
        try Data().write(to: vad); try FileManager.default.createDirectory(at: speaker, withIntermediateDirectories: true)
        let service = ModelResourceService(resources: [
            .init(id: "vad", displayName: "VAD", location: vad, requiredFiles: [], affectedCapability: "VAD", locationKind: .file, minimumBytes: 1),
            .init(id: "speaker", displayName: "Speaker", location: speaker, requiredFiles: ["segmentation*", "embedding*"], affectedCapability: "diarization", locationKind: .directory)
        ])
        XCTAssertEqual(service.scan().map(\.state), [.corrupt, .corrupt])
        try Data([1]).write(to: vad)
        try Data([1]).write(to: speaker.appendingPathComponent("segmentation-model.mlmodelc"))
        try Data([1]).write(to: speaker.appendingPathComponent("embedding-model.mlmodelc"))
        XCTAssertEqual(service.scan().map(\.state), [.ready, .ready])
    }

    private enum TestError: Error { case expected }

    private func makeWhisperKitFixture(at variant: URL) throws {
        try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
        try Data([1]).write(to: variant.appendingPathComponent("config.json"))
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let bundle = variant.appendingPathComponent("\(component).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([1]).write(to: bundle.appendingPathComponent("weights.bin"))
        }
    }

    private func makeSpeakerKitFixture(at repository: URL) throws {
        let components = [
            "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc",
            "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc"
        ]
        for relativePath in components {
            let bundle = relativePath.split(separator: "/").reduce(repository) { $0.appendingPathComponent(String($1), isDirectory: true) }
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([1]).write(to: bundle.appendingPathComponent("weights.bin"))
        }
    }
}

private actor CloudClientStub: ModelCenterCloudClient {
    func fetchModels(providerID: LLMProviderID, apiKey: String) async throws -> [LLMProviderModel] {
        [.init(providerID: providerID, id: "model-a", freeStatus: .free, recommendationScore: 1)]
    }
}

private actor CountingCloudClient: ModelCenterCloudClient {
    private let models: [LLMProviderModel]
    private var counts: [LLMProviderID: Int] = [:]
    private var shouldFail = false

    init(models: [LLMProviderModel]) { self.models = models }

    func fetchModels(providerID: LLMProviderID, apiKey: String) async throws -> [LLMProviderModel] {
        counts[providerID, default: 0] += 1
        if shouldFail { throw CountingCloudError.failed }
        return models.filter { $0.providerID == providerID }
    }

    func setShouldFail(_ value: Bool) { shouldFail = value }
    func requestCount(for providerID: LLMProviderID) -> Int { counts[providerID, default: 0] }
    func totalRequestCount() -> Int { counts.values.reduce(0, +) }
}

private enum CountingCloudError: LocalizedError {
    case failed
    var errorDescription: String? { "模拟刷新失败" }
}
