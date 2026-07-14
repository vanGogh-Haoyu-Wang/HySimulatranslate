import Foundation

enum ModelResourceState: Equatable, Sendable { case missing, corrupt, ready }
enum ModelResourceLocationKind: Equatable, Sendable { case file, directory }
struct ModelResourceDefinition: Equatable, Sendable {
    let id: String; let displayName: String; let location: URL; let requiredFiles: [String]; let affectedCapability: String; let version: String?; let locationKind: ModelResourceLocationKind; let minimumBytes: Int64; let validationKind: ModelResourceValidationKind
    init(id: String, displayName: String, location: URL, requiredFiles: [String], affectedCapability: String, version: String? = nil, locationKind: ModelResourceLocationKind = .directory, minimumBytes: Int64 = 1, validationKind: ModelResourceValidationKind = .generic) {
        self.id = id; self.displayName = displayName; self.location = location; self.requiredFiles = requiredFiles; self.affectedCapability = affectedCapability; self.version = version; self.locationKind = locationKind; self.minimumBytes = minimumBytes; self.validationKind = validationKind
    }
}
struct ModelResourceSnapshot: Equatable, Sendable {
    let definition: ModelResourceDefinition; let state: ModelResourceState; let size: Int64; let activeOwners: [String]
    var isLoadedOrInUse: Bool { !activeOwners.isEmpty }
    var shouldDisplayInUse: Bool { state == .ready && isLoadedOrInUse }
}
enum ModelResourceError: LocalizedError {
    case resourceMissing, resourceInUse([String]), resourceDeleting
    var errorDescription: String? { switch self { case .resourceMissing: "模型不存在"; case .resourceInUse(let owners): "模型正在被使用：\(owners.joined(separator: "、"))"; case .resourceDeleting: "模型正在删除" } }
}

final class ModelResourceLease: @unchecked Sendable {
    private let releaseAction: () -> Void
    private let lock = NSLock(); private var released = false
    init(release: @escaping () -> Void) { releaseAction = release }
    func release() { lock.lock(); guard !released else { lock.unlock(); return }; released = true; lock.unlock(); releaseAction() }
    deinit { release() }
}

final class ModelResourceService: @unchecked Sendable {
    static let shared = ModelResourceService(resources: standardResources(), managedModelStore: .standard)
    let resources: [ModelResourceDefinition]
    private struct LeaseEntry { let owner: String; let resourceIDs: Set<String> }
    private var leases: [UUID: LeaseEntry] = [:]
    private var deletingResourceIDs: Set<String> = []
    private let lock = NSLock()
    private let removeItem: @Sendable (URL) throws -> Void
    private let managedModelStore: ManagedModelStore?
    init(resources: [ModelResourceDefinition], managedModelStore: ManagedModelStore? = nil, removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) { self.resources = resources; self.managedModelStore = managedModelStore; self.removeItem = removeItem }

    func scan() -> [ModelResourceSnapshot] { resources.map(snapshot) }
    func validationReport(resourceID: String) -> ModelResourceValidationReport? {
        guard let resource = resources.first(where: { $0.id == resourceID }) else { return nil }
        return Self.validationReport(for: resource)
    }
    func migrateLegacyManagedModelsIfNeeded() throws { try managedModelStore?.migrateLegacyRepositoriesIfNeeded() }
    func acquireLease(owner: String) -> ModelResourceLease { acquireLease(resourceIDs: Set(resources.map(\.id)), owner: owner) }
    func acquireLease(resourceIDs: Set<String>, owner: String) -> ModelResourceLease {
        (try? tryAcquireLease(resourceIDs: resourceIDs, owner: owner)) ?? ModelResourceLease(release: {})
    }
    func tryAcquireLease(resourceIDs: Set<String>, owner: String) throws -> ModelResourceLease {
        lock.lock()
        guard deletingResourceIDs.isDisjoint(with: resourceIDs) else { lock.unlock(); throw ModelResourceError.resourceDeleting }
        let id = UUID(); leases[id] = .init(owner: owner, resourceIDs: resourceIDs); lock.unlock()
        return ModelResourceLease { [weak self] in self?.lock.lock(); self?.leases.removeValue(forKey: id); self?.lock.unlock() }
    }
    func activeOwners(resourceID: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(leases.values.filter { $0.resourceIDs.contains(resourceID) }.map(\.owner))).sorted()
    }
    func delete(resourceID: String) throws {
        guard let resource = resources.first(where: { $0.id == resourceID }) else { throw ModelResourceError.resourceMissing }
        lock.lock()
        let owners = Array(Set(leases.values.filter { $0.resourceIDs.contains(resourceID) }.map(\.owner))).sorted()
        guard owners.isEmpty else { lock.unlock(); throw ModelResourceError.resourceInUse(owners) }
        guard !deletingResourceIDs.contains(resourceID) else { lock.unlock(); throw ModelResourceError.resourceDeleting }
        deletingResourceIDs.insert(resourceID); lock.unlock()
        defer { lock.lock(); deletingResourceIDs.remove(resourceID); lock.unlock() }
        if FileManager.default.fileExists(atPath: resource.location.path) { try removeItem(resource.location) }
    }
    private func snapshot(_ resource: ModelResourceDefinition) -> ModelResourceSnapshot {
        let report = Self.validationReport(for: resource)
        return .init(definition: resource, state: report.state, size: report.size, activeOwners: activeOwners(resourceID: resource.id))
    }

    private static func validationReport(for resource: ModelResourceDefinition) -> ModelResourceValidationReport {
        ManagedModelStore.validationReport(
            at: resource.location,
            kind: resource.validationKind,
            requiredFiles: resource.requiredFiles,
            locationKind: resource.locationKind,
            minimumBytes: resource.minimumBytes
        )
    }

    static func standardResources(support: URL = AppResourceLocator.defaultSupportDirectory()) -> [ModelResourceDefinition] {
        func resource(_ path: String) -> URL { path.split(separator: "/").reduce(support) { $0.appendingPathComponent(String($1)) } }
        let managedStore = ManagedModelStore(
            supportDirectory: support,
            documentsDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        )
        return [
            .init(id: "sherpa", displayName: "Sherpa", location: resource(AppResourceLocator.sherpaModelRelativePath), requiredFiles: ["encoder*", "decoder*", "joiner*", "tokens.txt"], affectedCapability: "实时转写", version: "2023-06-26"),
            .init(id: "vad", displayName: "Silero VAD", location: resource(AppResourceLocator.vadModelRelativePath), requiredFiles: [], affectedCapability: "语音分段", version: "Silero", locationKind: .file),
            .init(id: "whisperkit", displayName: "WhisperKit", location: managedStore.repositoryDirectory(for: .whisperKit), requiredFiles: [], affectedCapability: "本地精校与音频导入", version: WhisperKitService.defaultModel, validationKind: .whisperKit),
            .init(id: "speakerkit", displayName: "SpeakerKit", location: managedStore.repositoryDirectory(for: .speakerKit), requiredFiles: [], affectedCapability: "说话人分离", validationKind: .speakerKit)
        ]
    }
}

final class ModelUsageCoordinator: @unchecked Sendable {
    private let resources: ModelResourceService
    init(resources: ModelResourceService = .shared) { self.resources = resources }
    func begin(owner: String, resourceIDs: Set<String>) throws -> ModelResourceLease { try resources.tryAcquireLease(resourceIDs: resourceIDs, owner: owner) }
    func withLease<T>(owner: String, resourceIDs: Set<String>, operation: () async throws -> T) async throws -> T {
        let lease = try begin(owner: owner, resourceIDs: resourceIDs); defer { lease.release() }
        return try await operation()
    }
}
