import Foundation
import SwiftUI
import AppKit

// MARK: - 🎙️ 主力同传引擎 ViewModel（对应 Python WhisperTranscriptionApp）
// Sherpa-onnx 实时流式 + WhisperKit 本地精校 + Groq LLM 格式化 + 多引擎翻译 + NVIDIA 中文总结

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var engineStatus: EngineStatus = .idle
    @Published var statusMessage: String = "初始化..."
    @Published var draftText: String = ""
    @Published var historyItems: [TranscriptionItem] = []
    @Published var dynamicItems: [TranscriptionItem] = []
    @Published var isRecording = false
    @Published var translationEnabled = true
    @Published var canRestart = false
    @Published var whisperQueueSize: Int = 0
    @Published var llmQueueSize: Int = 0
    @Published var micDeviceName: String = ""
    @Published var micVolume: Float = 0.0
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStatus: String = ""
    @Published var sherpaReady = false
    @Published var whisperReady = false
    @Published var apiReady = false
    @Published var providerCheckResults: [LLMProviderCheckResult] = []
    @Published var liveSummaryText: String = ""
    @Published var liveSummaryStatus: String = "未配置"
    @Published var liveSummaryReady = false
    @Published var isLiveSummaryUpdating = false
    @Published var isFinalizingSession = false

    var providerAPIKeys: [LLMProviderID: String] = [:]
    var currentCourse: CourseSubject?
    var pauseVal: Double = 0.6
    var hardCutVal: Double = 20.0

    var canStartTranscription: Bool {
        guard !isFinalizingSession else { return false }
        guard case .ready = engineStatus else { return false }
        return sherpaReady && whisperReady
    }

    var startTranscriptionButtonTitle: String {
        translationEnabled ? "开始同声传译" : "本地同声传译"
    }

    // Services
    private let speechEngine = SpeechEngine()
    private let sherpaService = SherpaService()
    private let whisperKitService = WhisperKitService()
    private let llmService = LLMService()
    private let translationService = TranslationService()
    private let nvidiaSummaryService = NvidiaSummaryService()

    // 队列
    private var whisperQueue: [WhisperQueueItem] = []
    private var llmFormatQueue: [LLMQueueItem] = []
    private var organizerQueue: [OrganizerQueueItem] = []
    private var transQueue: [(UUID, String)] = []

    private var lastRenderTime: TimeInterval = 0
    private let dynamicIdleFlushSeconds: TimeInterval = 2.0
    private let organizerBufferSeconds: TimeInterval = 1.2
    private let organizerMaxBatchSize = 4
    private let maxMergedAccentAnalysisPCMBytes = 32000 * 6
    private var lastDynamicInputTime: TimeInterval = 0
    private var liveSummaryCursor = LiveSummaryCursor()
    private var filePath: URL?
    private var isRunning = false

    // Worker handles
    private var whisperWorkerTask: Task<Void, Never>?
    private var llmWorkerTask: Task<Void, Never>?
    private var organizerWorkerTask: Task<Void, Never>?
    private var translationWorkerTask1: Task<Void, Never>?
    private var translationWorkerTask2: Task<Void, Never>?
    private var volumePollTask: Task<Void, Never>?
    private var dynamicIdleFlushTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var finalSummaryTask: Task<Void, Never>?

    private let forbiddenEnds: Set<String> = [
        "of", "the", "and", "or", "a", "an", "is", "are", "in", "on", "at",
        "to", "with", "that", "as", "for", "by", "from", "about", "but", "because"
    ]

    // MARK: - 系统自检

    private var isChecking = false

    func runSystemCheck() {
        guard !isChecking else { return }
        guard let course = currentCourse else {
            setStatus(.error("请先选择强化专项"))
            return
        }
        isChecking = true
        downloadProgress = 0.0
        downloadStatus = ""
        sherpaReady = false
        whisperReady = false
        apiReady = false
        liveSummaryReady = false
        liveSummaryStatus = "未配置"
        providerCheckResults = LLMProviderCatalog.mergedCheckResults(from: providerAPIKeys, testedResults: [])
        translationEnabled = false
        historyItems.removeAll { $0.isSystemMessage }

        Task { [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }

            // 1️⃣ Sherpa-onnx 模型检查
            print("[TranscriptionViewModel] Self-check started for \(course.name)")
            setStatus(.checking("检查 Sherpa-onnx 模型..."))
            let sherpaModelDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SherpaOnnxModel")
                .appendingPathComponent("sherpa-onnx-streaming-zipformer-en-2023-06-26")
                .path

            guard FileManager.default.fileExists(atPath: sherpaModelDir),
                  await sherpaService.configure(modelDir: sherpaModelDir) else {
                sherpaReady = false
                whisperReady = false
                apiReady = false
                publishSelfCheckSummary(sherpa: false, whisper: false, providerResults: providerCheckResults)
                setStatus(.error("Sherpa 模型缺失：请确保 \(sherpaModelDir) 存在"))
                return
            }
            sherpaReady = true

            // 2️⃣ WhisperKit 模型加载
            setStatus(.checking("加载 WhisperKit 本地引擎..."))
            whisperReady = await whisperKitService.configure(allowDownload: false, onProgress: { [weak self] fraction, status in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                    self?.downloadStatus = status
                }
            })
            if !whisperReady {
                downloadProgress = 0.0
                downloadStatus = "WhisperKit large-v3 未检测到"
            }
            print("[TranscriptionViewModel] WhisperKit ready: \(whisperReady)")

            // 3️⃣ Groq 核心 + NVIDIA 总结测试
            setStatus(.checking("测试 Groq 与 NVIDIA 总结..."))
            let groqResult = await llmService.testConnectivity(
                credential: LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys)
            )
            let summaryResult = await nvidiaSummaryService.testConnectivity(
                credential: LLMProviderCatalog.nvidiaSummaryCredential(from: providerAPIKeys)
            )
            let mergedResults = [groqResult, summaryResult]
            providerCheckResults = mergedResults
            apiReady = groqResult.passed
            translationEnabled = apiReady
            liveSummaryReady = summaryResult.passed
            liveSummaryStatus = liveSummaryReady ? "等待历史内容" : summaryResult.status.displayText
            print("[TranscriptionViewModel] Groq core: \(groqResult.status.displayText), NVIDIA summary: \(summaryResult.status.displayText)")

            publishSelfCheckSummary(sherpa: sherpaReady, whisper: whisperReady, providerResults: mergedResults)

            guard sherpaReady && whisperReady else {
                setStatus(.error("自检未通过：Sherpa 和 Whisper large-v3 都必须本地可用"))
                print("[TranscriptionViewModel] Self-check failed: sherpa=\(sherpaReady), whisper=\(whisperReady), api=\(apiReady)")
                return
            }

            let mode = apiReady ? "在线同传" : "本地同传"
            let summarySuffix = liveSummaryReady ? "，NVIDIA 总结可用" : ""
            setStatus(apiReady
                ? .ready("✅ 自检通过：\(course.name) \(mode)\(summarySuffix)")
                : .ready("🟡 API 未连通：\(course.name) \(mode)"))
            print("[TranscriptionViewModel] Self-check ready: \(mode), translation=\(apiReady)")
        }
    }

    // MARK: - 启动/停止

    func startTranscription() {
        guard !isFinalizingSession else { return }
        guard !isRunning else { return }
        guard canStartTranscription else { return }
        finalSummaryTask?.cancel()
        finalSummaryTask = nil
        isFinalizingSession = false
        isRunning = true
        isRecording = true
        canRestart = false
        draftText = ""
        historyItems = []
        dynamicItems = []
        whisperQueue = []
        llmFormatQueue = []
        organizerQueue = []
        transQueue = []
        liveSummaryText = ""
        liveSummaryStatus = liveSummaryReady ? "等待历史内容" : "未配置"
        isLiveSummaryUpdating = false
        liveSummaryCursor.reset()
        llmQueueSize = 0
        whisperQueueSize = 0
        lastRenderTime = Date().timeIntervalSince1970
        lastDynamicInputTime = lastRenderTime
        setupFilePath()

        sherpaService.pauseVal = pauseVal
        sherpaService.limitVal = hardCutVal

        Task { [weak self] in
            guard let self else { return }

            guard await SpeechEngine.requestMicrophoneAccess() else {
                await MainActor.run {
                    self.handleStartFailure("麦克风权限未授权。请在系统设置中允许 HySimulatranslate 使用麦克风。")
                }
                return
            }
            guard self.isRunning else { return }

            // 配置 LLM / Translation 回调
            await llmService.configure { [weak self] uid, text in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.postProcessResult(uid: uid, finalText: text)
                }
            }
            await translationService.configure(onResult: { [weak self] uid, zhText in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.applyTranslation(uid: uid, zhText: zhText)
                }
            })
            guard self.isRunning else { return }

            // 配置 Sherpa segment 回调
            await sherpaService.startStreaming(
                onSegment: { [weak self] uid, pcm, sherpaText in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.enqueueWhisperItem(uid: uid, pcm: pcm, sherpaText: sherpaText)
                    }
                },
                onDraft: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.noteDynamicInput()
                        self.draftText = text
                    }
                }
            )
            guard self.isRunning else { return }

            // 配置音频采集 → 喂 Sherpa
            speechEngine.configure { [weak self] samples, sampleRate in
                Task { [weak self] in
                    await self?.sherpaService.acceptWaveform(samples: samples, sampleRate: sampleRate)
                }
            }

            // 启动各级 Worker
            startWhisperWorker()
            startLLMWorker()
            startOrganizerWorker()
            startTranslationWorkers()
            startVolumePolling()
            startDynamicIdleFlushWorker()

            do {
                try speechEngine.start()
                micDeviceName = speechEngine.micDeviceName
            } catch {
                await MainActor.run {
                    self.handleStartFailure("无法启动音频引擎: \(error.localizedDescription)")
                }
                return
            }
            setStatus(.running("✅ 引擎运转中"))
            renderUI(force: true)
        }
    }

    func stopTranscription() {
        guard !(isFinalizingSession && !isRecording) else { return }
        let wasRecording = isRecording
        isRunning = false
        isRecording = false
        if wasRecording {
            beginSessionFinalization()
        } else {
            canRestart = false
        }

        cancelWorkerTasks()

        speechEngine.stop()
        Task {
            await sherpaService.stopStreaming()
            await llmService.stop()
        }

        if wasRecording {
            for i in 0..<dynamicItems.count { dynamicItems[i].zone = .history }
            historyItems.append(contentsOf: dynamicItems)
        }
        dynamicItems = []
        draftText = ""
        setStatus(.idle)
        statusMessage = wasRecording ? "正在整理详细总结..." : "麦克风已断开"
        if wasRecording {
            startFinalSessionSummaryAndWriteNotes()
        }
        renderUI(force: true)
    }

    private func beginSessionFinalization() {
        finalSummaryTask?.cancel()
        finalSummaryTask = nil
        isFinalizingSession = true
        canRestart = false
        isLiveSummaryUpdating = false
        liveSummaryStatus = liveSummaryReady ? "整理最终总结中" : "写入笔记中"
    }

    private func startFinalSessionSummaryAndWriteNotes() {
        let credential = LLMProviderCatalog.nvidiaSummaryCredential(from: providerAPIKeys)
        let previousSummary = liveSummaryText
        let fullContent = liveSummarySourceUnits(includeUntranslated: true)
            .map(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldRequestDetailedSummary = liveSummaryReady && credential != nil && !fullContent.isEmpty
        let summaryService = nvidiaSummaryService

        finalSummaryTask = Task { [weak self] in
            var finalSummary: String?
            if shouldRequestDetailedSummary, let credential {
                finalSummary = await summaryService.summarizeFinalDetailed(
                    previousSummary: previousSummary,
                    fullContent: fullContent,
                    credential: credential
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }

                if let finalSummary {
                    self.liveSummaryText = finalSummary
                    self.liveSummaryStatus = "已写入笔记"
                } else if shouldRequestDetailedSummary {
                    self.liveSummaryStatus = self.liveSummaryText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                        ? "总结失败，已写入笔记"
                        : "总结失败，保留已有总结"
                } else {
                    self.liveSummaryStatus = "已写入笔记"
                }

                self.writeFileNow()
                self.finalSummaryTask = nil
                self.isFinalizingSession = false
                self.canRestart = true
                self.statusMessage = "笔记已完成"
                self.renderUI(force: true)
            }
        }
    }

    private func handleStartFailure(_ message: String) {
        isRunning = false
        isRecording = false
        canRestart = false
        cancelWorkerTasks()
        speechEngine.stop()
        Task {
            await sherpaService.stopStreaming()
            await llmService.stop()
        }
        setStatus(.error(message))
        renderUI(force: true)
    }

    private func cancelWorkerTasks() {
        whisperWorkerTask?.cancel()
        llmWorkerTask?.cancel()
        organizerWorkerTask?.cancel()
        translationWorkerTask1?.cancel()
        translationWorkerTask2?.cancel()
        volumePollTask?.cancel()
        dynamicIdleFlushTask?.cancel()
        summaryTask?.cancel()

        whisperWorkerTask = nil
        llmWorkerTask = nil
        organizerWorkerTask = nil
        translationWorkerTask1 = nil
        translationWorkerTask2 = nil
        volumePollTask = nil
        dynamicIdleFlushTask = nil
        summaryTask = nil
        isLiveSummaryUpdating = false
    }

    func prepareRestart() {
        guard !isFinalizingSession else { return }
        canRestart = false
        historyItems = []
        dynamicItems = []
        organizerQueue = []
        draftText = ""
        liveSummaryText = ""
        liveSummaryStatus = liveSummaryReady ? "等待历史内容" : "未配置"
        liveSummaryCursor.reset()
        setStatus(translationEnabled
            ? .ready("🟢 引擎已重置，随时可启动")
            : .ready("🟢 引擎已重置（本地模式）"))
        renderUI(force: true)
    }

    func updatePauseValue(_ value: Double) {
        pauseVal = value
        sherpaService.pauseVal = value
    }

    func clearDisplayHistory() {
        guard !isFinalizingSession else { return }
        historyItems = []
        dynamicItems = []
        organizerQueue = []
        draftText = ""
        liveSummaryText = ""
        liveSummaryStatus = liveSummaryReady ? "等待历史内容" : "未配置"
        liveSummaryCursor.reset()
        canRestart = false
        renderUI(force: true)
    }

    func publishSelfCheckSummary(
        sherpa: Bool,
        whisper: Bool,
        providerResults: [LLMProviderCheckResult]
    ) {
        historyItems.removeAll { $0.isSystemMessage }
        var messages = [
            "[自检] Sherpa: \(sherpa ? "通过" : "未通过")",
            "[自检] WhisperKit large-v3: \(whisper ? "通过" : "未通过")"
        ]
        messages.append(contentsOf: providerResults.map {
            "[自检] \($0.provider.displayName) / \($0.provider.modelName): \($0.status.displayText)"
        })
        historyItems.append(contentsOf: messages.map {
            TranscriptionItem(
                english: $0,
                status: .done,
                zone: .history,
                doneTime: Date().timeIntervalSince1970,
                isSystemMessage: true
            )
        })
        renderUI(force: true)
    }

    // MARK: - 队列操作

    private func enqueueWhisperItem(uid: UUID, pcm: Data, sherpaText: String) {
        if moveReadyDynamicItemsToHistory(forceLeadingCompleted: true) {
            syncFileOnQueue()
        }
        if mergeIntoQueuedAccentAnalysisIfPossible(pcm: pcm, sherpaText: sherpaText) {
            draftText = ""
            renderUI(force: true)
            return
        }
        noteDynamicInput()
        draftText = ""
        let item = WhisperQueueItem(uid: uid, pcmData: pcm, sherpaTextBackup: sherpaText)
        whisperQueue.append(item)
        whisperQueueSize = whisperQueue.count
        let newItem = TranscriptionItem(id: uid, english: sherpaText, status: .whispering, zone: .dynamic)
        dynamicItems.append(newItem)
        renderUI(force: true)
    }

    func enqueueWhisperItemForTesting(uid: UUID, pcm: Data, sherpaText: String) {
        enqueueWhisperItem(uid: uid, pcm: pcm, sherpaText: sherpaText)
    }

    private func mergeIntoQueuedAccentAnalysisIfPossible(pcm: Data, sherpaText: String) -> Bool {
        guard WhisperKitService.isAccentAnalysisPlaceholder(sherpaText),
              let lastIndex = whisperQueue.indices.last,
              WhisperKitService.isAccentAnalysisPlaceholder(whisperQueue[lastIndex].sherpaTextBackup),
              whisperQueue[lastIndex].pcmData.count + pcm.count <= maxMergedAccentAnalysisPCMBytes
        else { return false }

        whisperQueue[lastIndex].pcmData.append(pcm)
        whisperQueueSize = whisperQueue.count
        return true
    }

    private func enqueueLLMItem(uid: UUID, text: String, taskType: LLMTaskType) {
        let item = LLMQueueItem(
            priority: taskType == .format ? 1 : 2,
            timestamp: Date().timeIntervalSince1970,
            taskType: taskType, uid: uid, rawText: text
        )
        if let idx = dynamicItems.firstIndex(where: { $0.id == uid }) {
            dynamicItems[idx].english = text
            dynamicItems[idx].status = taskType == .format ? .llmFormatting : .llmAggregating
        }
        llmFormatQueue.append(item)
        llmQueueSize = llmFormatQueue.count
        renderUI(force: true)
    }

    private func enqueueTranslation(uid: UUID, text: String) {
        transQueue.append((uid, text))
    }

    // MARK: - Workers

    /// Whisper Worker：Groq Whisper API → WhisperKit 本地兜底（对应 Python whisper_cloud_local_worker）
    private func startWhisperWorker() {
        whisperWorkerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let item: WhisperQueueItem? = await MainActor.run {
                    guard !self.whisperQueue.isEmpty else { return nil }
                    let i = self.whisperQueue.removeFirst()
                    self.whisperQueueSize = self.whisperQueue.count
                    return i
                }
                guard let item else { try? await Task.sleep(nanoseconds: 100_000_000); continue }

                let uid = item.uid
                let pcm = item.pcmData
                let sherpaBackup = item.sherpaTextBackup
                var finalText = sherpaBackup

                if pcm.count >= 16000 {
                    var whisperText: String? = nil

                    // 1️⃣ Groq Whisper API
                    let groqKey = await MainActor.run { self.groqAPIKey() }
                    if groqKey.hasPrefix("gsk_") {
                        whisperText = await groqWhisperAPI(pcmData: pcm, apiKey: groqKey)
                    }

                    // 2️⃣ WhisperKit 本地兜底
                    if whisperText == nil {
                        whisperText = await self.whisperKitService.transcribe(pcmData: pcm)
                    }

                    // 3️⃣ 兜底失败 → 用 Sherpa 文本
                    if whisperText == nil {
                        whisperText = sherpaBackup
                    }

                    // 4️⃣ 质量检查
                    let wr = whisperText ?? ""
                    let isHalluc = self.whisperKitService.isHallucination(wr)
                    let lenRatio = Double(wr.count) / Double(max(1, sherpaBackup.count))
                    let isTooShort = lenRatio < 0.4
                    let isTooLong  = lenRatio > 2.5
                    let hasRepeats  = self.whisperKitService.hasRepeatedPhrase(wr)

                    if wr.isEmpty || isHalluc || isTooShort || isTooLong || hasRepeats {
                        if !sherpaBackup.contains("捕获到口音") {
                            finalText = sherpaBackup
                        } else {
                            finalText = wr
                        }
                    } else {
                        finalText = wr
                    }
                }

                let isSessionEnding = await MainActor.run {
                    self.looksLikeSessionEnding()
                }
                if self.whisperKitService.shouldDropASRSegment(finalText, isSessionEnding: isSessionEnding) {
                    await MainActor.run { self.markAsDropped(uid: uid) }
                } else {
                    await MainActor.run {
                        self.enqueueLLMItem(uid: uid, text: finalText, taskType: .format)
                    }
                }
            }
        }
    }

    private func startLLMWorker() {
        llmWorkerTask = Task { [weak self] in
            guard let self else { return }
            await self.llmService.start()
            while !Task.isCancelled {
                let item: LLMQueueItem? = await MainActor.run {
                    guard !self.llmFormatQueue.isEmpty else { return nil }
                    self.llmFormatQueue.sort {
                        $0.priority != $1.priority ? $0.priority < $1.priority : $0.timestamp < $1.timestamp
                    }
                    let i = self.llmFormatQueue.removeFirst()
                    self.llmQueueSize = self.llmFormatQueue.count
                    return i
                }
                guard let item, let course = self.currentCourse else {
                    try? await Task.sleep(nanoseconds: 100_000_000); continue
                }
                let ctx = self.getRecentContext()
                let credential = await MainActor.run { self.groqCoreCredential() }
                await self.llmService.processItem(
                    item,
                    groqCredential: credential,
                    course: course,
                    recentContext: ctx
                )
            }
        }
    }

    private func startOrganizerWorker() {
        organizerWorkerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let ready = await MainActor.run {
                    self.isOrganizerBatchReady(now: Date().timeIntervalSince1970, force: false)
                }
                if ready {
                    await self.processNextOrganizerBatch(force: false)
                } else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    func flushOrganizerQueueForTesting() async {
        while !organizerQueue.isEmpty {
            _ = await processNextOrganizerBatch(force: true)
        }
    }

    @discardableResult
    private func processNextOrganizerBatch(force: Bool) async -> Bool {
        guard isOrganizerBatchReady(now: Date().timeIntervalSince1970, force: force) else { return false }

        let batchSize = organizerQueue.count >= 2 ? min(organizerMaxBatchSize, organizerQueue.count) : 1
        let batch = Array(organizerQueue.prefix(batchSize))
        organizerQueue.removeFirst(batch.count)

        let fragments = batch.map { TranscriptOrganizerFragment(id: $0.uid, text: $0.text) }
        let recentHistory = recentOrganizerHistory(excluding: Set(batch.map(\.uid)))
        var result = TranscriptOrganizer.organizeRuleBased(fragments: fragments, recentHistory: recentHistory)

        let originalTexts = fragments.map(\.text)
        if TranscriptOrganizer.shouldUseAIFallback(for: originalTexts),
           let lines = await llmService.organizeFragments(
                originalTexts,
                credential: groqCoreCredential(),
                course: currentCourse
           ) {
            result = TranscriptOrganizer.organizeFromAILines(
                lines,
                fragments: fragments,
                recentHistory: recentHistory
            )
        }

        applyOrganizerResult(result, originalIDs: batch.map(\.uid))
        return true
    }

    private func isOrganizerBatchReady(now: TimeInterval, force: Bool) -> Bool {
        guard let first = organizerQueue.first else { return false }
        if force { return true }
        if organizerQueue.count >= 2 { return true }
        return now - first.timestamp >= organizerBufferSeconds
    }

    private func recentOrganizerHistory(excluding excludedIDs: Set<UUID>) -> [String] {
        (historyItems + dynamicItems)
            .filter {
                $0.isVisible &&
                !excludedIDs.contains($0.id) &&
                ($0.status == .done || $0.status == .translating)
            }
            .suffix(24)
            .flatMap { TranscriptDisplayBlock(item: $0).englishLines }
    }

    private func applyOrganizerResult(_ result: TranscriptOrganizerResult, originalIDs: [UUID]) {
        let consumedIDs = Set(result.outputs.flatMap(\.consumedIDs))
        let unconsumedIDs = Set(originalIDs).subtracting(consumedIDs).subtracting(result.droppedIDs)
        for uid in Set(result.droppedIDs).union(unconsumedIDs) {
            hideOrganizerItem(uid: uid)
        }

        for output in result.outputs {
            if whisperKitService.shouldDropASRSegment(output.text, isSessionEnding: looksLikeSessionEnding()) {
                for uid in output.consumedIDs {
                    hideOrganizerItem(uid: uid)
                }
                continue
            }

            for uid in output.consumedIDs where uid != output.primaryID {
                hideOrganizerItem(uid: uid)
            }
            applyOrganizedText(uid: output.primaryID, text: output.text)
        }

        renderUI(force: true)
    }

    private func hideOrganizerItem(uid: UUID) {
        if let idx = dynamicItems.firstIndex(where: { $0.id == uid }) {
            dynamicItems[idx].isVisible = false
            dynamicItems[idx].status = .dropped
            dynamicItems[idx].zone = .history
        } else if let idx = historyItems.firstIndex(where: { $0.id == uid }) {
            historyItems[idx].isVisible = false
            historyItems[idx].status = .dropped
        }
    }

    private func applyOrganizedText(uid: UUID, text: String) {
        guard let idx = dynamicItems.firstIndex(where: { $0.id == uid }) else { return }
        let now = Date().timeIntervalSince1970
        dynamicItems[idx].english = text
        dynamicItems[idx].doneTime = now
        if translationEnabled {
            dynamicItems[idx].status = .translating
            enqueueTranslation(uid: uid, text: text)
        } else {
            dynamicItems[idx].status = .done
        }
    }

    private func startTranslationWorkers() {
        func worker(_ s: TranscriptionViewModel) async {
            while !Task.isCancelled {
                let pair: (UUID, String)? = await MainActor.run {
                    guard !s.transQueue.isEmpty else { return nil }
                    return s.transQueue.removeFirst()
                }
                guard let (uid, text) = pair else { try? await Task.sleep(nanoseconds: 100_000_000); continue }
                let credential = await MainActor.run { s.groqCoreCredential() }
                await s.translationService.translate(uid: uid, englishText: text, groqCredential: credential)
            }
        }
        translationWorkerTask1 = Task { [weak self] in guard let self else { return }; await worker(self) }
        translationWorkerTask2 = Task { [weak self] in guard let self else { return }; await worker(self) }
    }

    private func startVolumePolling() {
        volumePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let v = self.speechEngine.currentVolume
                await MainActor.run { self.micVolume = v }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func startDynamicIdleFlushWorker() {
        dynamicIdleFlushTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await MainActor.run {
                    self.flushDynamicItemsForIdleInput()
                }
            }
        }
    }

    // MARK: - 结果处理

    func postProcessResult(uid: UUID, finalText: String) {
        var t = finalText
            .replacingOccurrences(of: "\\.{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        t = LLMService.normalizeASRCasingForDisplay(t)
        if t.isEmpty { t = "." }
        guard let idx = dynamicItems.firstIndex(where: { $0.id == uid }) else { return }
        if whisperKitService.shouldDropASRSegment(t, isSessionEnding: looksLikeSessionEnding()) {
            markAsDropped(uid: uid)
            return
        }
        dynamicItems[idx].english = t
        dynamicItems[idx].status = .organizing
        let now = Date().timeIntervalSince1970
        dynamicItems[idx].doneTime = now
        organizerQueue.append(OrganizerQueueItem(uid: uid, text: t, timestamp: now))
        renderUI(force: true)
    }

    func applyTranslation(uid: UUID, zhText: String) {
        let now = Date().timeIntervalSince1970
        if let idx = dynamicItems.firstIndex(where: { $0.id == uid }) {
            dynamicItems[idx].chinese = zhText
            dynamicItems[idx].status = .done
            dynamicItems[idx].doneTime = now
            renderUI(force: true)
            return
        }

        guard let idx = historyItems.firstIndex(where: { $0.id == uid }) else { return }
        historyItems[idx].chinese = zhText
        historyItems[idx].status = .done
        historyItems[idx].doneTime = now
        syncFileOnQueue()
        maybeRequestLiveSummary()
        renderUI(force: true)
    }

    private func markAsDropped(uid: UUID) {
        guard let idx = dynamicItems.firstIndex(where: { $0.id == uid }) else { return }
        dynamicItems[idx].isVisible = false
        dynamicItems[idx].status = .dropped
        dynamicItems[idx].zone = .history
        renderUI(force: true)
    }

    // MARK: - Zone 迁移 + UI 渲染

    private func noteDynamicInput(now: TimeInterval = Date().timeIntervalSince1970) {
        lastDynamicInputTime = now
    }

    func flushDynamicItemsForIdleInput(now: TimeInterval = Date().timeIntervalSince1970) {
        guard now - lastDynamicInputTime >= dynamicIdleFlushSeconds else { return }

        let movedToHistory = moveReadyDynamicItemsToHistory(now: now)

        let clearedDraft = !draftText.isEmpty
        if clearedDraft {
            draftText = ""
        }

        if movedToHistory {
            syncFileOnQueue()
        }
        if movedToHistory || clearedDraft {
            renderUI(force: true)
        }
    }

    func renderUI(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || (now - lastRenderTime > 0.15) else { return }
        lastRenderTime = now

        if moveReadyDynamicItemsToHistory(now: now) {
            syncFileOnQueue()
        }
    }

    @discardableResult
    private func moveReadyDynamicItemsToHistory(
        now: TimeInterval = Date().timeIntervalSince1970,
        forceLeadingCompleted: Bool = false
    ) -> Bool {
        let idleElapsed = now - lastDynamicInputTime
        var moved = false
        var i = 0

        while i < dynamicItems.count {
            let item = dynamicItems[i]
            guard item.isVisible, item.zone == .dynamic else {
                i += 1
                continue
            }
            guard item.status == .done || item.status == .translating else {
                break
            }

            let wordCount = item.english.split(separator: " ").count
            let doneElapsed = now - item.doneTime
            let hasFollowingVisibleDynamic = dynamicItems.suffix(from: i + 1)
                .contains { $0.isVisible && $0.zone == .dynamic }
            let shouldFlushForIdle = idleElapsed >= dynamicIdleFlushSeconds && doneElapsed >= dynamicIdleFlushSeconds
            let shouldMove = forceLeadingCompleted || hasFollowingVisibleDynamic || wordCount >= 15 || shouldFlushForIdle
            guard shouldMove else { break }

            moveDynamicItemToHistory(at: i)
            moved = true
        }

        return moved
    }

    private func moveDynamicItemToHistory(at index: Int) {
        var item = dynamicItems[index]
        item.zone = .history
        if item.status == .translating {
            item.status = .done
            if item.doneTime == 0 {
                item.doneTime = Date().timeIntervalSince1970
            }
        }
        historyItems.append(item)
        dynamicItems.remove(at: index)
        maybeRequestLiveSummary()
    }

    private func getRecentContext() -> String {
        (historyItems + dynamicItems)
            .filter { $0.isVisible && ($0.status == .translating || $0.status == .done) }
            .suffix(2).map(\.english).joined(separator: " ")
    }

    // MARK: - Session 结束检测

    func looksLikeSessionEnding() -> Bool {
        let recent = (historyItems + dynamicItems)
            .filter { $0.isVisible && ($0.status == .translating || $0.status == .done) }
            .suffix(4).map { $0.english.lowercased() }.joined(separator: " ")
        let cues: Set = ["that's all","that is all","see you","next time","next week",
                         "have a good","have a nice","end of","we'll stop","we will stop",
                         "finish here","wrap up","any questions","thanks everyone",
                         "thank you everyone","bye","goodbye"]
        return cues.contains(where: recent.contains)
    }

    // MARK: - 文件

    private func setupFilePath() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        let dateStr = df.string(from: Date())
        guard let course = currentCourse else { return }
        filePath = desktop.appendingPathComponent("\(course.abbrev)_Session_\(dateStr).txt")
    }

    private func syncFile() {
        guard let course = currentCourse else { return }
        let items = historyItems + dynamicItems
        let path = filePath
        let on = translationEnabled
        let summary = liveSummaryText
        DispatchQueue.global(qos: .utility).async {
            Self.writeFile(to: path, course: course, translationEnabled: on, items: items, finalSummary: summary)
        }
    }

    private func syncFileOnQueue() {
        guard let course = self.currentCourse else { return }
        let path = self.filePath
        let on = self.translationEnabled
        let items = self.historyItems + self.dynamicItems
        let summary = self.liveSummaryText
        DispatchQueue.global(qos: .utility).async {
            Self.writeFile(to: path, course: course, translationEnabled: on, items: items, finalSummary: summary)
        }
    }

    private func writeFileNow() {
        guard let course = currentCourse else { return }
        Self.writeFile(
            to: filePath,
            course: course,
            translationEnabled: translationEnabled,
            items: historyItems + dynamicItems,
            finalSummary: liveSummaryText
        )
    }

    nonisolated private static func writeFile(to path: URL?, course: CourseSubject,
                                               translationEnabled: Bool, items: [TranscriptionItem],
                                               finalSummary: String) {
        guard let path else { return }
        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: translationEnabled,
            items: items,
            finalSummary: finalSummary
        )
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }

    private func maybeRequestLiveSummary() {
        guard liveSummaryReady,
              !isFinalizingSession,
              !isLiveSummaryUpdating,
              let credential = LLMProviderCatalog.nvidiaSummaryCredential(from: providerAPIKeys)
        else { return }

        let units = liveSummarySourceUnits()
        guard let range = liveSummaryCursor.pendingRange(totalCount: units.count) else { return }

        let newContent = units[range]
            .map(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newContent.isEmpty else { return }

        let previousSummary = liveSummaryText
        let countAtRequest = units.count
        let summaryService = nvidiaSummaryService
        isLiveSummaryUpdating = true
        liveSummaryStatus = "总结中"

        summaryTask = Task { [weak self] in
            let summary = await summaryService.summarize(
                previousSummary: previousSummary,
                newContent: newContent,
                credential: credential
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLiveSummaryUpdating = false
                self.summaryTask = nil
                if let summary {
                    self.liveSummaryText = summary
                    self.liveSummaryStatus = "已更新"
                    self.liveSummaryCursor.markSummarized(upTo: countAtRequest)
                    self.syncFileOnQueue()
                    self.renderUI(force: true)
                    self.maybeRequestLiveSummary()
                } else {
                    self.liveSummaryStatus = "总结失败"
                    self.liveSummaryCursor.markFailed(at: countAtRequest)
                    self.renderUI(force: true)
                }
            }
        }
    }

    private struct LiveSummarySourceUnit {
        let text: String
    }

    private struct OrganizerQueueItem {
        let uid: UUID
        let text: String
        let timestamp: TimeInterval
    }

    private func liveSummarySourceUnits(includeUntranslated: Bool = false) -> [LiveSummarySourceUnit] {
        (includeUntranslated ? historyItems + dynamicItems : historyItems)
            .filter {
                guard $0.isVisible,
                      !$0.isSystemMessage,
                      $0.status != .dropped,
                      !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return false }
                if includeUntranslated { return true }
                return $0.zone == .history && $0.status == .done
            }
            .flatMap { liveSummarySourceUnits(for: $0, includeUntranslated: includeUntranslated) }
    }

    private func liveSummarySourceUnits(
        for item: TranscriptionItem,
        includeUntranslated: Bool = false
    ) -> [LiveSummarySourceUnit] {
        let block = TranscriptDisplayBlock(item: item)
        if translationEnabled, block.chineseLines.isEmpty, !includeUntranslated {
            return []
        }

        if block.canInterleaveLineByLine {
            return block.englishLines.indices.map { idx in
                LiveSummarySourceUnit(text: """
                英文原文：\(block.englishLines[idx])
                中文译文：\(block.chineseLines[idx])
                """)
            }
        }

        let english = block.englishLines.joined(separator: " ")
        let chinese = block.chineseLines.joined(separator: " ")
        if translationEnabled {
            guard !chinese.isEmpty else {
                return includeUntranslated ? [LiveSummarySourceUnit(text: "英文原文：\(english)")] : []
            }
            return [LiveSummarySourceUnit(text: """
            英文原文：\(english)
            中文译文：\(chinese)
            """)]
        }
        return [LiveSummarySourceUnit(text: "英文原文：\(english)")]
    }

    private func groqCoreCredential() -> LLMProviderCredential? {
        guard apiReady else { return nil }
        return LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys)
    }

    private func groqAPIKey() -> String {
        providerAPIKeys[.groq, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setStatus(_ s: EngineStatus) {
        engineStatus = s
        switch s {
        case .idle:                statusMessage = "空闲"
        case .checking(let m):     statusMessage = m
        case .ready(let m):        statusMessage = m
        case .running(let m):      statusMessage = m
        case .error(let m):        statusMessage = m
        }
    }
}

// MARK: - Groq Whisper API Helper

private func groqWhisperAPI(pcmData: Data, apiKey: String) async -> String? {
    // int16 PCM → WAV
    var wav = Data()
    var sampleRate: UInt32 = 16_000
    var channels: UInt16 = 1
    var bitsPerSample: UInt16 = 16
    var byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    var blockAlign: UInt16 = channels * (bitsPerSample / 8)
    var dataSize: UInt32 = UInt32(pcmData.count)

    wav.append("RIFF".data(using: .ascii)!)
    var fileSize: UInt32 = 36 + dataSize
    wav.append(Data(bytes: &fileSize, count: 4))
    wav.append("WAVEfmt ".data(using: .ascii)!)
    var fmtSize: UInt32 = 16
    wav.append(Data(bytes: &fmtSize, count: 4))
    var format: UInt16 = 1
    wav.append(Data(bytes: &format, count: 2))
    wav.append(Data(bytes: &channels, count: 2))
    wav.append(Data(bytes: &sampleRate, count: 4))
    wav.append(Data(bytes: &byteRate, count: 4))
    wav.append(Data(bytes: &blockAlign, count: 2))
    wav.append(Data(bytes: &bitsPerSample, count: 2))
    wav.append("data".data(using: .ascii)!)
    wav.append(Data(bytes: &dataSize, count: 4))
    wav.append(pcmData)

    var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 4.0
    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let boundary = UUID().uuidString
    request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
    body.append("whisper-large-v3\r\n".data(using: .utf8)!)
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
    body.append("en\r\n".data(using: .utf8)!)
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
    body.append("json\r\n".data(using: .utf8)!)
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(wav)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespaces)
        }
    } catch { return nil }
    return nil
}
