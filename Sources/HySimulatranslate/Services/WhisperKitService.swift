import Foundation
import WhisperKit

// MARK: - 🚀 WhisperKit 本地灾备引擎 — 先准备模型，故障时按需加载

struct WhisperKitRuntimeState: Equatable, Sendable {
    let isAvailable: Bool
    let isLoaded: Bool
}

actor WhisperKitService {
    nonisolated static let defaultModel = "large-v3-v20240930_626MB"

    private var whisperKit: WhisperKit?
    private var isConfigured = false
    private var modelFolder: URL?
    private let model: String
    private let modelSearchRoots: [URL]?

    init(
        model: String = WhisperKitService.defaultModel,
        modelSearchRoots: [URL]? = nil
    ) {
        self.model = model
        self.modelSearchRoots = modelSearchRoots
    }

    typealias ProgressHandler = @Sendable (Double, String) -> Void

    // MARK: - 配置（只准备模型，不加载 CoreML）

    func configure(
        allowDownload: Bool = false,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async -> Bool {
        if isConfigured { return true }
        do {
            // 第一步：下载模型（如果已缓存则跳过）
            onProgress?(0.0, "检查模型缓存...")

            let modelFolder: URL
            let cached = findCachedModel()
            if let cached {
                modelFolder = cached
                onProgress?(1.0, "本地灾备模型缓存可用")
            } else {
                guard allowDownload else {
                    onProgress?(0.0, "WhisperKit 模型未缓存，使用 Sherpa 快速模式")
                    print("[WhisperKitService] No cached model for '\(model)'; skipping download during self-check")
                    return false
                }
                onProgress?(0.05, "正在下载模型 (~626MB，仅首次)...")
                modelFolder = try await WhisperKit.download(
                    variant: model,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        let status = fraction > 0.01
                            ? String(format: "下载中 %.0f%%...", fraction * 100)
                            : "连接 HuggingFace..."
                        onProgress?(max(0.05, fraction * 0.90), status)
                    }
                )
                onProgress?(0.92, "下载完成，准备按需加载...")
            }

            self.modelFolder = modelFolder
            self.isConfigured = true
            onProgress?(1.0, "本地灾备模型已就绪（按需加载）")
            print("[WhisperKitService] Model '\(model)' available for lazy fallback")
            return true
        } catch {
            onProgress?(0.0, "加载失败: \(error.localizedDescription)")
            print("[WhisperKitService] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 转录

    func transcribe(pcmData: Data) async -> String? {
        await transcribe(pcmData: pcmData, language: nil)
    }

    func transcribe(pcmData: Data, language: String?) async -> String? {
        guard isConfigured else { return nil }
        if whisperKit == nil {
            guard await loadModelIfNeeded() else { return nil }
        }
        guard let wk = whisperKit else { return nil }

        let samples = pcmData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float] in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            let count = min(int16Ptr.count, pcmData.count / 2)
            return (0..<count).map { Float(int16Ptr[$0]) / 32768.0 }
        }

        guard !samples.isEmpty else { return nil }

        do {
            let normalizedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
            let options = normalizedLanguage.map { DecodingOptions(language: $0, detectLanguage: false) }
            let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
            return results.first?.text.trimmingCharacters(in: .whitespaces)
        } catch {
            print("[WhisperKitService] Transcription error: \(error)")
            return nil
        }
    }

    // MARK: - 缓存检查

    private func findCachedModel() -> URL? {
        Self.findCachedModel(
            in: modelSearchRoots ?? Self.defaultCacheSearchRoots(),
            model: model
        )
    }

    func runtimeState() -> WhisperKitRuntimeState {
        WhisperKitRuntimeState(
            isAvailable: isConfigured && modelFolder != nil,
            isLoaded: whisperKit != nil
        )
    }

    func unloadModel() {
        whisperKit = nil
    }

    private func loadModelIfNeeded() async -> Bool {
        if whisperKit != nil { return true }
        guard let modelFolder else { return false }
        do {
            whisperKit = try await WhisperKit(
                modelFolder: modelFolder.path,
                computeOptions: .init(
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU
                ),
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
            print("[WhisperKitService] Model '\(model)' loaded for local fallback")
            return true
        } catch {
            print("[WhisperKitService] Lazy load failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func findCachedModel(in roots: [URL], model: String) -> URL? {
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            if let modelFolder = findCachedModelFolder(under: root, model: model) {
                return modelFolder
            }
        }
        return nil
    }

    nonisolated private static func defaultCacheSearchRoots() -> [URL] {
        AppResourceLocator.whisperModelSearchRoots()
    }

    nonisolated private static func findCachedModelFolder(under root: URL, model: String) -> URL? {
        if isUsableModelFolder(root, model: model) { return root }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let candidate as URL in enumerator {
            guard candidateHasModelName(candidate, model: model),
                  isUsableModelFolder(candidate, model: model) else {
                continue
            }
            return candidate
        }
        return nil
    }

    nonisolated private static func candidateHasModelName(_ url: URL, model: String) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let modelName = model.lowercased()
        return name.contains(modelName) && !name.contains("turbo")
    }

    nonisolated private static func isUsableModelFolder(_ url: URL, model: String) -> Bool {
        guard candidateHasModelName(url, model: model) || hasRequiredModelComponents(in: url) else {
            return false
        }
        return hasRequiredModelComponents(in: url)
    }

    nonisolated private static func hasRequiredModelComponents(in folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            hasModelComponent(named: $0, in: folder)
        }
    }

    nonisolated private static func hasModelComponent(named name: String, in folder: URL) -> Bool {
        let compiled = folder.appendingPathComponent("\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return true }

        let package = folder.appendingPathComponent("\(name).mlpackage")
        if FileManager.default.fileExists(atPath: package.path) { return true }

        let packageModel = package
            .appendingPathComponent("Data")
            .appendingPathComponent("com.apple.CoreML")
            .appendingPathComponent("model.mlmodel")
        return FileManager.default.fileExists(atPath: packageModel.path)
    }

    // MARK: - 质量检查（与 Python 完全一致）

    nonisolated static func isAccentAnalysisPlaceholder(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("捕获到口音") || normalized.contains("分析中")
    }

    @Sendable nonisolated func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased()
        let badPatterns = ["___", "thank you", "subtitles by", "amara.org",
                           "translated by", "subscribe", "捕获到口音"]
        return badPatterns.contains(where: { t.contains($0) })
    }

    @Sendable nonisolated func hasRepeatedPhrase(_ text: String) -> Bool {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard words.count >= 6 else { return false }
        for n in [3, 4] {
            guard words.count >= n * 3 else { continue }
            for i in 0...(words.count - n) {
                let gram = words[i..<(i + n)].joined(separator: " ")
                var count = 0
                var pos = 0
                while pos <= words.count - n {
                    let chunk = words[pos..<(pos + n)].joined(separator: " ")
                    if chunk == gram { count += 1; pos += n }
                    else { pos += 1 }
                }
                if count >= 3 { return true }
            }
        }
        return false
    }

    @Sendable nonisolated func shouldDropASRSegment(
        _ text: String,
        isSessionEnding: Bool = false
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if Self.isAccentAnalysisPlaceholder(trimmed) { return true }

        let normalized = trimmed.lowercased()

        let subtitleJunk = ["subtitles by", "amara org", "translated by", "thanks for watching",
                            "please subscribe", "like and subscribe"]
        if subtitleJunk.contains(where: { normalized.contains($0) }) { return true }

        let stripped = stripPunctuation(normalized)
        let isolatedThanks: Set<String> = [
            "thank you", "thank you thank you", "thanks", "thank you very much",
            "thank you so much", "okay thank you", "right thank you"
        ]
        if isolatedThanks.contains(stripped), !isSessionEnding { return true }

        let isolatedClosings: Set<String> = ["good night", "goodnight"]
        if isolatedClosings.contains(stripped), !isSessionEnding { return true }

        let apologyFragments: Set<String> = ["im sorry", "i am sorry"]
        if apologyFragments.contains(stripped) { return true }
        let words = stripped.split(separator: " ")
        if words.count <= 4, apologyFragments.contains(where: { stripped.hasSuffix($0) }) {
            return true
        }
        if stripped.components(separatedBy: "im sorry").count - 1 >= 2 {
            return true
        }

        if !SmartWhisperRouting.containsLexicalContent(trimmed) {
            return true
        }

        if stripped.split(separator: " ").count <= 2 {
            let trivial: Set<String> = [
                "hello", "hi", "hey", "ok", "okay", "yes", "no", "yeah", "uh", "um",
                "hmm", "oh", "ah", "well", "so", "right", "good", "fine", "sure",
                "sorry", "please", "bye", "goodbye", "morning", "afternoon", "evening",
                "testing", "test", "one two", "check", "mic test"
            ]
            if trivial.contains(stripped) { return true }
        }
        return false
    }

    @Sendable nonisolated func stripPunctuation(_ text: String) -> String {
        text.replacingOccurrences(of: "[^a-z\\s]", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
