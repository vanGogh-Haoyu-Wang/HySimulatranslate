import Foundation

protocol ModelCenterCloudClient: Sendable {
    func fetchModels(providerID: LLMProviderID, apiKey: String) async throws -> [LLMProviderModel]
}

struct DefaultModelCenterCloudClient: ModelCenterCloudClient {
    func fetchModels(providerID: LLMProviderID, apiKey: String) async throws -> [LLMProviderModel] {
        try await LLMModelDiscoveryService().fetchTextModels(for: providerID, apiKey: apiKey)
    }
}

enum ModelListScope: String, Codable, CaseIterable, Sendable {
    case recommended
    case all

    init(storageValue: String?) {
        self = storageValue.flatMap(Self.init(rawValue:)) ?? .recommended
    }
}

struct CloudModelProviderState: Identifiable, Equatable, Sendable {
    let id: LLMProviderID; var configured: Bool; var models: [LLMProviderModel]; var connectivity: LLMProviderCheckStatus
}
struct ModelDeletionRequest: Equatable, Sendable { let resourceID: String; let displayName: String; let size: Int64; let affectedCapability: String }

@MainActor final class ModelCenterViewModel: ObservableObject {
    typealias Installer = @MainActor (String, @escaping @Sendable (Double, String) -> Void) async throws -> URL?
    @Published private(set) var localResources: [ModelResourceSnapshot] = []
    @Published private(set) var cloudProviders: [CloudModelProviderState] = []
    @Published private(set) var progressByResource: [String: Double] = [:]
    @Published private(set) var statusByResource: [String: String] = [:]
    @Published private(set) var selectedModelIDs: [LLMProviderID: String] = [:]
    @Published private(set) var providerCheckResults: [LLMProviderCheckResult] = []
    @Published private(set) var apiReady = false
    @Published private(set) var lastError: String?
    @Published var pendingDeletion: ModelDeletionRequest?
    private(set) var providerAPIKeys: [LLMProviderID: String] = [:]
    private let resourceService: ModelResourceService
    private let providerKeys: () -> [LLMProviderID: String]
    private let cloudClient: any ModelCenterCloudClient
    private let installer: Installer
    private var onModelSelectionChanged: @MainActor (LLMProviderID, String) -> Void
    private var connectivityRecords: [String: LLMProviderModelConnectivityRecord]

    init(resourceService: ModelResourceService = .shared, providerKeys: @escaping () -> [LLMProviderID: String] = { KeychainManager.shared.loadProviderKeys() }, selectedModels: @escaping () -> [LLMProviderID: String] = { [:] }, onModelSelectionChanged: @escaping @MainActor (LLMProviderID, String) -> Void = { _, _ in }, cloudClient: any ModelCenterCloudClient = DefaultModelCenterCloudClient(), installer: @escaping Installer = ModelCenterViewModel.defaultInstaller) {
        self.resourceService = resourceService; self.providerKeys = providerKeys; self.cloudClient = cloudClient; self.installer = installer
        self.selectedModelIDs = selectedModels()
        self.onModelSelectionChanged = onModelSelectionChanged
        self.connectivityRecords = Self.loadConnectivityRecords()
        do {
            try resourceService.migrateLegacyManagedModelsIfNeeded()
        } catch {
            lastError = error.localizedDescription
        }
        rescan()
        cloudProviders = LLMProviderCatalog.modelCenterProviderIDs.map { .init(id: $0, configured: false, models: [], connectivity: .notConfigured) }
    }
    func configureModelSelection(selectedModels: [LLMProviderID: String], onChange: @escaping @MainActor (LLMProviderID, String) -> Void) {
        selectedModelIDs = selectedModels
        onModelSelectionChanged = onChange
    }
    func selectedModelID(for providerID: LLMProviderID) -> String {
        selectedModelIDs[providerID]
            ?? cloudProviders.first(where: { $0.id == providerID })?.models.first?.id
            ?? ""
    }
    func selectModel(_ modelID: String, for providerID: LLMProviderID) {
        guard !modelID.isEmpty else { return }
        selectedModelIDs[providerID] = modelID
        if let key = Self.modelStorageKey(for: providerID) {
            UserDefaults.standard.set(modelID, forKey: key)
        }
        onModelSelectionChanged(providerID, modelID)
    }
    var selectedProviderModelNames: [LLMProviderID: String] {
        [
            .groq: selectedModelIDs[.groq] ?? LLMProviderCatalog.defaultGroqModelName,
            .agnes: selectedModelIDs[.agnes] ?? LLMProviderCatalog.defaultAgnesOrganizerModelName
        ]
    }
    @discardableResult
    func updateProviderAPIKeys(_ keys: [LLMProviderID: String]) -> Bool {
        let changed = providerAPIKeys != keys
        providerAPIKeys = keys
        providerCheckResults = LLMProviderCatalog.mergedCheckResults(
            from: keys,
            testedResults: changed ? [] : providerCheckResults,
            selectedModelNames: selectedProviderModelNames
        )
        if changed { apiReady = false }
        return changed
    }
    func setAPIReady(_ ready: Bool) { apiReady = ready }
    func setProviderCheckResults(_ results: [LLMProviderCheckResult]) {
        providerCheckResults = results
        apiReady = results.first(where: { $0.provider.id == .groq })?.passed == true
    }
    func invalidateConnectivity() {
        providerCheckResults = LLMProviderCatalog.mergedCheckResults(
            from: providerAPIKeys,
            testedResults: [],
            selectedModelNames: selectedProviderModelNames
        )
        apiReady = false
    }
    func testConnectivity(
        llm: LLMService,
        summary: OmniRouteSummaryService,
        agnes: AgnesHistoryOrganizerService,
        omniRouteBaseURL: String
    ) async -> [LLMProviderCheckResult] {
        let results = [
            await llm.testConnectivity(credential: LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys, selectedModelNames: selectedProviderModelNames)),
            await summary.testConnectivity(credential: LLMProviderCatalog.omniRouteSummaryCredential(from: providerAPIKeys, baseURL: omniRouteBaseURL)),
            await agnes.testConnectivity(credential: LLMProviderCatalog.agnesOrganizerCredential(from: providerAPIKeys, selectedModelNames: selectedProviderModelNames))
        ]
        setProviderCheckResults(results)
        recordConnectivity(results)
        return results
    }
    func visibleModels(for providerID: LLMProviderID, scope: ModelListScope) -> [LLMProviderModel] {
        guard let provider = cloudProviders.first(where: { $0.id == providerID }) else { return [] }
        guard scope == .recommended else { return provider.models }
        let selected = selectedModelIDs[providerID]
        return provider.models.filter {
            LLMProviderCatalog.isRecommended(providerID: providerID, modelID: $0.id) || $0.id == selected
        }
    }
    func rescan() { localResources = resourceService.scan() }
    func refreshCloud() async {
        let keys = providerAPIKeys.isEmpty ? providerKeys() : providerAPIKeys; var result: [CloudModelProviderState] = []
        for id in LLMProviderCatalog.modelCenterProviderIDs {
            guard let key = keys[id], !key.isEmpty else { result.append(.init(id: id, configured: false, models: [], connectivity: .notConfigured)); continue }
            do {
                var models = try await cloudClient.fetchModels(providerID: id, apiKey: key)
                let serverModelIDs = Set(models.map(\.id))
                let selected = selectedModelIDs[id]
                if let selected = selectedModelIDs[id],
                   !models.contains(where: { $0.id == selected }),
                   let preserved = LLMProviderCatalog.model(for: id, modelID: selected, preserveUnknown: true) {
                    models.append(preserved)
                }
                let connectivity: LLMProviderCheckStatus
                if let selected, !serverModelIDs.contains(selected) {
                    connectivity = .failed("当前模型不可用")
                } else {
                    connectivity = models.isEmpty ? .failed("无可用模型") : .passed
                }
                result.append(.init(id: id, configured: true, models: LLMProviderCatalog.sortedModels(models), connectivity: connectivity))
            } catch {
                let previousModels = cloudProviders.first(where: { $0.id == id })?.models ?? []
                result.append(.init(id: id, configured: true, models: previousModels, connectivity: .failed(error.localizedDescription)))
            }
        }
        cloudProviders = result
    }
    func download(resourceID: String) async {
        lastError = nil; progressByResource[resourceID] = 0
        do {
            try resourceService.migrateLegacyManagedModelsIfNeeded()
            let installedLocation = try await installer(resourceID) { [weak self] progress, status in Task { @MainActor in self?.progressByResource[resourceID] = progress; self?.statusByResource[resourceID] = status } }
            rescan()
            guard let report = resourceService.validationReport(resourceID: resourceID), report.state == .ready else {
                let report = resourceService.validationReport(resourceID: resourceID)
                let fallbackPath = installedLocation?.path ?? "未知路径"
                let message = report?.failureDescription ?? "模型完整性校验失败。实际下载路径：\(fallbackPath)"
                throw NSError(domain: "ModelCenter.Integrity", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
            progressByResource[resourceID] = 1
        } catch { lastError = error.localizedDescription; statusByResource[resourceID] = "失败，可重试"; rescan() }
    }
    func retry(resourceID: String) async { await download(resourceID: resourceID) }
    func requestDelete(resourceID: String) {
        guard let item = localResources.first(where: { $0.definition.id == resourceID }) else { return }
        pendingDeletion = .init(resourceID: resourceID, displayName: item.definition.displayName, size: item.size, affectedCapability: item.definition.affectedCapability)
    }
    func confirmDelete() {
        guard let request = pendingDeletion else { return }
        do { try resourceService.delete(resourceID: request.resourceID); pendingDeletion = nil; lastError = nil; rescan() }
        catch { lastError = error.localizedDescription }
    }
    nonisolated private static func defaultInstaller(resourceID: String, progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL? {
        switch resourceID {
        case "sherpa": return try await ResourceDownloadService.ensureSherpaModel(onProgress: progress)
        case "vad": return try await ResourceDownloadService.ensureVADModel(onProgress: progress)
        case "whisperkit":
            return try await WhisperKitService().prepareModel(allowDownload: true, onProgress: progress)
        case "speakerkit":
            progress(0.05, "检查 SpeakerKit 模型...")
            let location = try await SpeakerDiarizationService().prepareModel(allowDownload: true)
            progress(1, "SpeakerKit 模型已就绪")
            return location
        default: throw ModelResourceError.resourceMissing
        }
    }

    private func recordConnectivity(_ results: [LLMProviderCheckResult]) {
        for result in results {
            let status: LLMProviderModelConnectivityStatus
            let detail: String
            switch result.status {
            case .passed: status = .passed; detail = ""
            case .failed(let reason): status = .failed; detail = reason
            case .notConfigured: continue
            }
            let key = LLMProviderCatalog.connectivityKey(providerID: result.provider.id, modelID: result.provider.modelName)
            connectivityRecords[key] = .init(
                providerID: result.provider.id,
                modelID: result.provider.modelName,
                status: status,
                detail: detail,
                testedAt: Date()
            )
        }
        guard let data = try? JSONEncoder().encode(Array(connectivityRecords.values)) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "providerModelConnectivityRecordsJSON")
    }

    private static func loadConnectivityRecords() -> [String: LLMProviderModelConnectivityRecord] {
        guard let json = UserDefaults.standard.string(forKey: "providerModelConnectivityRecordsJSON"),
              let data = json.data(using: .utf8),
              let records = try? JSONDecoder().decode([LLMProviderModelConnectivityRecord].self, from: data)
        else { return [:] }
        return LLMProviderCatalog.connectivityRecordsByKey(records)
    }

    private static func modelStorageKey(for providerID: LLMProviderID) -> String? {
        switch providerID {
        case .groq: "groqCoreModelName"
        case .agnes: "agnesOrganizerModelName"
        case .omniRoute: nil
        }
    }
}
