import Foundation

enum AppResourceLocator {
    static let appSupportDirectoryName = "HySimulatranslate"
    static let payloadDirectoryName = "HySimulatranslatePayload"
    static let supportDirectoryEnvironmentKey = "HYSIMULATRANSLATE_SUPPORT_DIR"
    static let sherpaModelFolderName = "sherpa-onnx-streaming-zipformer-en-2023-06-26"
    static let whisperModelFolderName = "openai_whisper-large-v3"
    static let vadModelFileName = "silero_vad.onnx"
    static let sherpaModelRelativePath = "Models/Sherpa/\(sherpaModelFolderName)"
    static let whisperModelRelativePath = "Models/WhisperKit/\(whisperModelFolderName)"
    static let vadModelRelativePath = "Models/VAD/\(vadModelFileName)"

    static func defaultSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[supportDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    static func bundledPayloadDirectory(bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let payload = resourceURL.appendingPathComponent(payloadDirectoryName, isDirectory: true)
        return FileManager.default.fileExists(atPath: payload.path) ? payload : nil
    }

    static func installBundledResourcesIfNeeded(
        supportDirectory: URL = defaultSupportDirectory(),
        bundledPayloadDirectory: URL? = bundledPayloadDirectory()
    ) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard let bundledPayloadDirectory,
              FileManager.default.fileExists(atPath: bundledPayloadDirectory.path) else {
            return
        }

        try copyMissingContents(from: bundledPayloadDirectory, to: supportDirectory)
    }

    static func sherpaModelDirectory(
        supportDirectory: URL = defaultSupportDirectory(),
        bundledPayloadDirectory: URL? = bundledPayloadDirectory()
    ) -> URL? {
        let candidates = [
            supportDirectory.appendingRelativePath(sherpaModelRelativePath),
            bundledPayloadDirectory?.appendingRelativePath(sherpaModelRelativePath),
            legacySherpaModelDirectory()
        ].compactMap { $0 }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func vadModelFile(
        supportDirectory: URL = defaultSupportDirectory(),
        bundledPayloadDirectory: URL? = bundledPayloadDirectory()
    ) -> URL? {
        modelFile(
            relativePath: vadModelRelativePath,
            supportDirectory: supportDirectory,
            bundledPayloadDirectory: bundledPayloadDirectory
        )
    }

    static func isUsableSherpaModelDirectory(_ directory: URL) -> Bool {
        let requiredGlobs = ["encoder*.onnx", "decoder*.onnx", "joiner*.onnx"]
        let hasModelFiles = requiredGlobs.allSatisfy { pattern in
            findFile(in: directory, matching: pattern) != nil
        }
        let hasTokens = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("tokens.txt").path
        )
        return hasModelFiles && hasTokens
    }

    static func whisperModelSearchRoots(
        supportDirectory: URL = defaultSupportDirectory(),
        bundledPayloadDirectory: URL? = bundledPayloadDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots: [URL] = [
            supportDirectory.appendingRelativePath(whisperModelRelativePath)
        ]

        if let bundledPayloadDirectory {
            roots.append(bundledPayloadDirectory.appendingRelativePath(whisperModelRelativePath))
        }

        roots.append(contentsOf: legacyWhisperCacheSearchRoots(environment: environment))
        return roots.removingDuplicatesByStandardizedPath()
    }

    private static func legacySherpaModelDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SherpaOnnxModel", isDirectory: true)
            .appendingPathComponent(sherpaModelFolderName, isDirectory: true)
    }

    private static func modelFile(
        relativePath: String,
        supportDirectory: URL,
        bundledPayloadDirectory: URL?
    ) -> URL? {
        let candidates = [
            supportDirectory.appendingRelativePath(relativePath),
            bundledPayloadDirectory?.appendingRelativePath(relativePath)
        ].compactMap { $0 }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func findFile(in directory: URL, matching pattern: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            return files.first { $0.lastPathComponent == pattern }
        }
        let prefix = parts[0]
        let suffix = parts[1]
        return files.first {
            $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix)
        }
    }

    private static func legacyWhisperCacheSearchRoots(environment: [String: String]) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []

        if let explicitHubCache = environment["HUGGINGFACE_HUB_CACHE"], !explicitHubCache.isEmpty {
            roots.append(URL(fileURLWithPath: explicitHubCache, isDirectory: true))
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            roots.append(URL(fileURLWithPath: hfHome, isDirectory: true).appendingPathComponent("hub", isDirectory: true))
        }

        roots.append(
            home
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
                .appendingPathComponent("models--argmaxinc--whisperkit-coreml", isDirectory: true)
        )
        roots.append(
            home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
                .appendingPathComponent("models--argmaxinc--whisperkit-coreml", isDirectory: true)
        )
        roots.append(
            home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("whisperkit", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        )
        return roots
    }

    private static func copyMissingContents(from source: URL, to destination: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try copyMissingItem(from: item, to: target)
        }
    }

    private static func copyMissingItem(from source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        let destinationExists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)

        if destinationExists {
            var sourceIsDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
            if sourceIsDirectory.boolValue && isDirectory.boolValue {
                try copyMissingContents(from: source, to: destination)
            }
            return
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private extension URL {
    func appendingRelativePath(_ relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { url, component in
                url.appendingPathComponent(String(component), isDirectory: true)
            }
    }
}

private extension Array where Element == URL {
    func removingDuplicatesByStandardizedPath() -> [URL] {
        var seen = Set<String>()
        return filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}
