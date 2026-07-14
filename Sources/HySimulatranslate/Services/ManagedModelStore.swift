import Foundation

enum ManagedModelKind: String, CaseIterable, Sendable {
    case whisperKit
    case speakerKit
}

enum ModelResourceValidationKind: Equatable, Sendable {
    case generic
    case whisperKit
    case speakerKit
}

enum ManagedModelMigrationMovePolicy: Equatable, Sendable {
    case automatic
    case copyOnly
}

struct ModelResourceValidationReport: Equatable, Sendable {
    let state: ModelResourceState
    let location: URL
    let size: Int64
    let missingComponents: [String]

    var failureDescription: String? {
        guard state != .ready else { return nil }
        let reason = missingComponents.isEmpty ? "目录不存在或不是有效模型目录" : "缺少或为空：\(missingComponents.joined(separator: "、"))"
        return "模型完整性校验失败（\(reason)）。检查路径：\(location.path)"
    }
}

struct ManagedModelStore {
    static var standard: ManagedModelStore {
        ManagedModelStore(
            supportDirectory: AppResourceLocator.defaultSupportDirectory(),
            documentsDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        )
    }

    let supportDirectory: URL
    let documentsDirectory: URL
    let migrationMovePolicy: ManagedModelMigrationMovePolicy

    init(
        supportDirectory: URL,
        documentsDirectory: URL,
        migrationMovePolicy: ManagedModelMigrationMovePolicy = .automatic
    ) {
        self.supportDirectory = supportDirectory
        self.documentsDirectory = documentsDirectory
        self.migrationMovePolicy = migrationMovePolicy
    }

    func downloadBase(for kind: ManagedModelKind) -> URL {
        supportDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(kind == .whisperKit ? "WhisperKit" : "SpeakerKit", isDirectory: true)
    }

    func repositoryDirectory(for kind: ManagedModelKind) -> URL {
        downloadBase(for: kind)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent(kind == .whisperKit ? "whisperkit-coreml" : "speakerkit-coreml", isDirectory: true)
    }

    func legacyRepositoryDirectory(for kind: ManagedModelKind) -> URL {
        documentsDirectory
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent(kind == .whisperKit ? "whisperkit-coreml" : "speakerkit-coreml", isDirectory: true)
    }

    func validationReport(for kind: ManagedModelKind) -> ModelResourceValidationReport {
        Self.validationReport(
            at: repositoryDirectory(for: kind),
            kind: kind == .whisperKit ? .whisperKit : .speakerKit
        )
    }

    func migrateLegacyRepositoriesIfNeeded() throws {
        for kind in ManagedModelKind.allCases {
            try migrateLegacyRepositoryIfNeeded(kind)
        }
    }

    private func migrateLegacyRepositoryIfNeeded(_ kind: ManagedModelKind) throws {
        let destination = repositoryDirectory(for: kind)
        if Self.validationReport(at: destination, kind: kind == .whisperKit ? .whisperKit : .speakerKit).state == .ready {
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        let source = legacyRepositoryDirectory(for: kind)
        let sourceReport = Self.validationReport(at: source, kind: kind == .whisperKit ? .whisperKit : .speakerKit)
        guard sourceReport.state == .ready else { return }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if migrationMovePolicy == .copyOnly {
            try copyValidatedRepository(from: source, to: destination, kind: kind)
            return
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            let movedReport = Self.validationReport(at: destination, kind: kind == .whisperKit ? .whisperKit : .speakerKit)
            guard movedReport.state == .ready else {
                try? FileManager.default.moveItem(at: destination, to: source)
                throw ManagedModelStoreError.migrationValidationFailed(movedReport)
            }
        } catch let error as ManagedModelStoreError {
            throw error
        } catch {
            try copyValidatedRepository(from: source, to: destination, kind: kind)
        }
    }

    private func copyValidatedRepository(from source: URL, to destination: URL, kind: ManagedModelKind) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        let copiedReport = Self.validationReport(at: temporary, kind: kind == .whisperKit ? .whisperKit : .speakerKit)
        guard copiedReport.state == .ready else {
            throw ManagedModelStoreError.migrationValidationFailed(copiedReport)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.removeItem(at: source)
    }

    static func validationReport(
        at location: URL,
        kind: ModelResourceValidationKind,
        requiredFiles: [String] = [],
        locationKind: ModelResourceLocationKind = .directory,
        minimumBytes: Int64 = 1
    ) -> ModelResourceValidationReport {
        guard FileManager.default.fileExists(atPath: location.path) else {
            return .init(state: .missing, location: location, size: 0, missingComponents: [])
        }

        let values = try? location.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        let shapeValid = locationKind == .file ? values?.isRegularFile == true : values?.isDirectory == true
        let urls = descendants(of: location)
        let size = values?.isRegularFile == true ? fileSize(location) : urls.reduce(0) { $0 + fileSize($1) }
        var missing: [String]

        switch kind {
        case .generic:
            missing = requiredFiles.filter { required in
                if required.contains("*") {
                    let prefix = required.split(separator: "*", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    return !urls.contains { $0.lastPathComponent.hasPrefix(prefix) && fileOrTreeHasContent($0) }
                }
                return !fileOrTreeHasContent(location.appendingPathComponent(required))
            }
        case .whisperKit:
            let directories = [location] + urls.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            if directories.contains(where: isWhisperVariantDirectory) {
                missing = []
            } else {
                missing = ["config.json"].filter { name in
                    !urls.contains { $0.lastPathComponent == name && fileSize($0) > 0 }
                }
                missing.append(contentsOf: ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].filter { name in
                    !urls.contains { $0.lastPathComponent == name && fileOrTreeHasContent($0) }
                })
                if missing.isEmpty { missing = ["完整 WhisperKit 模型版本目录"] }
            }
        case .speakerKit:
            missing = ["SpeakerSegmenter.mlmodelc", "SpeakerEmbedderPreprocessor.mlmodelc", "SpeakerEmbedder.mlmodelc", "PldaProjector.mlmodelc"].filter { name in
                !urls.contains { $0.lastPathComponent == name && fileOrTreeHasContent($0) }
            }
        }

        let valid = shapeValid && size >= minimumBytes && missing.isEmpty
        return .init(state: valid ? .ready : .corrupt, location: location, size: size, missingComponents: missing)
    }

    private static func descendants(of location: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: location,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return [] }
        return enumerator.allObjects.compactMap { $0 as? URL }
    }

    static func isWhisperVariantDirectory(_ folder: URL) -> Bool {
        guard fileSize(folder.appendingPathComponent("config.json")) > 0 else { return false }
        return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
            fileOrTreeHasContent(folder.appendingPathComponent($0, isDirectory: true))
        }
    }

    private static func fileOrTreeHasContent(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values?.isRegularFile == true { return fileSize(url) > 0 }
        return descendants(of: url).contains { candidate in
            (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && fileSize(candidate) > 0
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64(((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0)
    }
}

enum ManagedModelStoreError: LocalizedError {
    case migrationValidationFailed(ModelResourceValidationReport)
    case modelIntegrityFailed(ModelResourceValidationReport)

    var errorDescription: String? {
        switch self {
        case .migrationValidationFailed(let report):
            report.failureDescription ?? "迁移后的模型未通过完整性校验"
        case .modelIntegrityFailed(let report):
            report.failureDescription ?? "下载结果未通过模型完整性校验"
        }
    }
}
