import Foundation

struct LivePipelineQueueSnapshot: Equatable, Sendable {
    let whisperCount: Int
    let llmCount: Int
    let pendingAudioSeconds: TimeInterval
    let pendingPCMBytes: Int
    let loadState: RefinementLoadState
}

struct LiveTranscriptionPipelineConfiguration: Sendable {
    let course: CourseSubject
    let groqCredential: LLMProviderCredential?
    let translationMode: TranslationExecutionMode
    let pauseSeconds: Double
    let hardCutSeconds: Double
    let processAudio: @MainActor @Sendable (AudioChunk) throws -> [Float]
    let admitSegment: @MainActor @Sendable (SherpaSegment, LivePipelineQueueSnapshot) -> RefinementAdmission
    let recentContext: @MainActor @Sendable () -> String
    let isSessionEnding: @MainActor @Sendable () -> Bool
    let speakerDiarizationActive: @MainActor @Sendable () -> Bool
}

enum LivePipelineEvent: Sendable {
    case draft(String)
    case segmentAccepted(SherpaSegment, RefinementAdmission)
    case segmentMerged
    case refined(id: UUID, text: String, sherpaText: String)
    case formatted(id: UUID, text: String, sourceIDs: [UUID])
    case translated(id: UUID, text: String)
    case dropped(UUID)
    case status(LivePipelineQueueSnapshot)
    case diagnostics(PipelineDiagnosticsSnapshot)
    case error(String)
}

actor LiveTranscriptionPipeline {
    typealias EventHandler = @Sendable (LivePipelineEvent) async -> Void

    private let sherpa: SherpaService
    private let whisper: WhisperKitService
    private let llm: LLMService
    private let translation: TranslationService

    private var configuration: LiveTranscriptionPipelineConfiguration?
    private var onEvent: EventHandler?
    private var running = false
    private var whisperQueue: [WhisperQueueItem] = []
    private var inFlightWhisper: [UUID: WhisperQueueItem] = [:]
    private var llmQueue: [LLMQueueItem] = []
    private var pendingLLMBatch: [LLMQueueItem] = []
    private var sourceIDsByPrimaryID: [UUID: [UUID]] = [:]
    private var translationQueue: [(UUID, String)] = []
    private var whisperWorkers: [Task<Void, Never>] = []
    private var llmWorker: Task<Void, Never>?
    private var translationWorkers: [Task<Void, Never>] = []
    private var diagnosticsWorker: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    init(
        sherpa: SherpaService,
        whisper: WhisperKitService,
        llm: LLMService,
        translation: TranslationService
    ) {
        self.sherpa = sherpa
        self.whisper = whisper
        self.llm = llm
        self.translation = translation
    }

    func start(
        configuration: LiveTranscriptionPipelineConfiguration,
        onEvent: @escaping EventHandler
    ) async {
        await cancel()
        self.configuration = configuration
        self.onEvent = onEvent
        running = true
        sherpa.pauseVal = configuration.pauseSeconds
        sherpa.limitVal = configuration.hardCutSeconds

        await llm.configure { [weak self] id, text in
            Task { await self?.receiveFormatted(id: id, text: text) }
        }
        await translation.configure { [weak self] id, text in
            Task { await self?.emit(.translated(id: id, text: text)) }
        }
        await sherpa.startStreaming(
            onTimedSegment: { [weak self] segment in
                Task { await self?.receive(segment) }
            },
            onDraft: { [weak self] text in
                Task { await self?.emit(.draft(text)) }
            }
        )
        await llm.start()
        whisperWorkers = (0..<2).map { _ in
            Task { [weak self] in await self?.runWhisperWorker() }
        }
        llmWorker = Task { [weak self] in await self?.runLLMWorker() }
        translationWorkers = (0..<2).map { _ in
            Task { [weak self] in await self?.runTranslationWorker() }
        }
        diagnosticsWorker = Task { [weak self] in await self?.runDiagnosticsWorker() }
        publishStatus()
    }

    func accept(_ chunk: AudioChunk) async {
        guard running, let configuration else { return }
        do {
            let mixed = try await configuration.processAudio(chunk)
            if !mixed.isEmpty {
                await sherpa.acceptWaveform(samples: mixed, sampleRate: 16_000)
            }
        } catch {
            emit(.error(error.localizedDescription))
        }
    }

    @discardableResult
    func finish() async -> [WhisperQueueItem] {
        running = false
        cancelTasks()
        let pending = whisperQueue + Array(inFlightWhisper.values)
        clearQueues()
        await sherpa.stopStreaming()
        await llm.stop()
        configuration = nil
        publishStatus()
        await eventTask?.value
        onEvent = nil
        eventTask = nil
        return pending
    }

    func cancel() async {
        _ = await finish()
    }

    func enqueueLLM(
        id: UUID,
        text: String,
        sherpaText: String = "",
        taskType: LLMTaskType = .format,
        forceBatch: Bool? = nil
    ) {
        let item = LLMQueueItem(
            priority: taskType == .format ? 1 : 2,
            timestamp: Date().timeIntervalSince1970,
            taskType: taskType,
            uid: id,
            sourceIDs: [id],
            rawText: text,
            whisperText: text,
            sherpaText: sherpaText
        )
        if taskType == .format {
            pendingLLMBatch.append(item)
            flushPendingLLMBatch(force: forceBatch ?? (configuration?.groqCredential == nil))
        } else {
            llmQueue.append(item)
        }
        publishStatus()
    }

    func enqueueTranslation(id: UUID, text: String) {
        guard running else { return }
        translationQueue.append((id, text))
    }

    func flushPendingLLM(force: Bool = true) {
        flushPendingLLMBatch(force: force)
        publishStatus()
    }

    func queuedLLMItems() -> [LLMQueueItem] {
        llmQueue
    }

    func state() -> LivePipelineQueueSnapshot {
        queueSnapshot()
    }

    func enqueueRefinementForTesting(_ item: WhisperQueueItem) -> Bool {
        if WhisperKitService.isAccentAnalysisPlaceholder(item.sherpaTextBackup),
           let last = whisperQueue.indices.last,
           WhisperKitService.isAccentAnalysisPlaceholder(whisperQueue[last].sherpaTextBackup),
           whisperQueue[last].pcmData.count + item.pcmData.count <= 32_000 * 6 {
            whisperQueue[last].pcmData.append(item.pcmData)
            publishStatus()
            return true
        }
        whisperQueue.append(item)
        publishStatus()
        return false
    }

    func shedRefinementWork() -> [WhisperQueueItem] {
        whisperWorkers.forEach { $0.cancel() }
        whisperWorkers.removeAll()
        let pending = whisperQueue + Array(inFlightWhisper.values)
        whisperQueue.removeAll()
        inFlightWhisper.removeAll()
        llmQueue.removeAll()
        pendingLLMBatch.removeAll()
        sourceIDsByPrimaryID.removeAll()
        translationQueue.removeAll()
        if running {
            whisperWorkers = (0..<2).map { _ in
                Task { [weak self] in await self?.runWhisperWorker() }
            }
        }
        publishStatus(override: .protecting)
        return pending
    }

    private func receive(_ segment: SherpaSegment) async {
        guard running, let configuration else { return }
        let text = segment.text
        let placeholder = WhisperKitService.isAccentAnalysisPlaceholder(text)
        guard placeholder || SmartWhisperRouting.containsLexicalContent(text) else { return }

        if placeholder,
           let last = whisperQueue.indices.last,
           WhisperKitService.isAccentAnalysisPlaceholder(whisperQueue[last].sherpaTextBackup),
           whisperQueue[last].pcmData.count + segment.pcmData.count <= 32_000 * 6 {
            whisperQueue[last].pcmData.append(segment.pcmData)
            emit(.segmentMerged)
            publishStatus()
            return
        }

        let admission = await configuration.admitSegment(segment, queueSnapshot())
        guard running, admission != .drop else { return }
        emit(.segmentAccepted(segment, admission))
        switch admission {
        case .drop:
            break
        case .useSherpa:
            enqueueLLM(id: segment.id, text: text, sherpaText: text)
        case .refine:
            whisperQueue.append(WhisperQueueItem(uid: segment.id, pcmData: segment.pcmData, sherpaTextBackup: text))
            publishStatus()
        }
    }

    private func runWhisperWorker() async {
        while running, !Task.isCancelled {
            guard let item = popWhisperItem() else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            var finalText = item.sherpaTextBackup
            if item.pcmData.count >= 16_000 {
                let key = configuration?.groqCredential?.apiKey ?? ""
                let cloudText = key.hasPrefix("gsk_")
                    ? await groqWhisperAPI(pcmData: item.pcmData, apiKey: key)
                    : nil
                if SmartWhisperRouting.shouldUseLocalFallback(
                    cloudText: cloudText,
                    cloudRequestFailed: !key.hasPrefix("gsk_") || cloudText == nil
                ) {
                    publishStatus(override: .localFallback)
                    let localText = await whisper.transcribe(pcmData: item.pcmData)
                    finalText = usable(localText, backup: item.sherpaTextBackup)
                        ? (localText ?? item.sherpaTextBackup)
                        : item.sherpaTextBackup
                } else if let cloudText {
                    finalText = cloudText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard running, !Task.isCancelled else { return }
            inFlightWhisper.removeValue(forKey: item.uid)
            let ending = await configuration?.isSessionEnding() ?? false
            if whisper.shouldDropASRSegment(finalText, isSessionEnding: ending) {
                emit(.dropped(item.uid))
            } else {
                emit(.refined(id: item.uid, text: finalText, sherpaText: item.sherpaTextBackup))
                enqueueLLM(id: item.uid, text: finalText, sherpaText: item.sherpaTextBackup)
            }
            publishStatus()
        }
    }

    private func runLLMWorker() async {
        while running, !Task.isCancelled {
            flushPendingLLMBatch(force: false)
            guard let item = popLLMItem(), let configuration else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            await llm.processItem(
                item,
                groqCredential: configuration.groqCredential,
                course: configuration.course,
                recentContext: await configuration.recentContext()
            )
        }
    }

    private func runTranslationWorker() async {
        while running, !Task.isCancelled {
            guard !translationQueue.isEmpty, let configuration else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let (id, text) = translationQueue.removeFirst()
            await translation.translate(
                uid: id,
                englishText: text,
                groqCredential: configuration.groqCredential,
                mode: configuration.translationMode
            )
        }
    }

    private func runDiagnosticsWorker() async {
        while running, !Task.isCancelled {
            guard let configuration else { return }
            let state = queueSnapshot()
            emit(.diagnostics(PipelineDiagnosticsSnapshot(
                timestamp: Date().timeIntervalSince1970,
                whisperQueue: state.whisperCount,
                llmQueue: state.llmCount,
                pendingPCMBytes: state.pendingPCMBytes,
                loadState: state.loadState,
                speakerDiarizationActive: await configuration.speakerDiarizationActive(),
                residentMemoryBytes: PipelineDiagnosticsLogger.residentMemoryBytes()
            )))
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func receiveFormatted(id: UUID, text: String) {
        guard running else { return }
        emit(.formatted(id: id, text: text, sourceIDs: sourceIDsByPrimaryID.removeValue(forKey: id) ?? [id]))
    }

    private func popWhisperItem() -> WhisperQueueItem? {
        guard !whisperQueue.isEmpty else { return nil }
        let item = whisperQueue.removeFirst()
        inFlightWhisper[item.uid] = item
        publishStatus()
        return item
    }

    private func popLLMItem() -> LLMQueueItem? {
        guard !llmQueue.isEmpty else { return nil }
        llmQueue.sort {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.timestamp < $1.timestamp
        }
        let item = llmQueue.removeFirst()
        publishStatus()
        return item
    }

    private func flushPendingLLMBatch(force: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        guard !pendingLLMBatch.isEmpty else { return }
        let age = now - (pendingLLMBatch.first?.timestamp ?? now)
        let characters = pendingLLMBatch.reduce(0) { $0 + $1.rawText.count }
        guard force || pendingLLMBatch.count >= 3 || age >= 4.5 || characters >= 700 else { return }

        let batch = pendingLLMBatch
        pendingLLMBatch.removeAll()
        let primary = batch[0]
        let sourceIDs = batch.flatMap(\.sourceIDs)
        sourceIDsByPrimaryID[primary.uid] = sourceIDs
        llmQueue.append(LLMQueueItem(
            priority: primary.priority,
            timestamp: primary.timestamp,
            taskType: .format,
            uid: primary.uid,
            sourceIDs: sourceIDs,
            rawText: batch.map(\.rawText).joined(separator: "\n"),
            whisperText: batch.enumerated().map { "\($0.offset + 1). \($0.element.whisperText)" }.joined(separator: "\n"),
            sherpaText: batch.enumerated().map {
                "\($0.offset + 1). \($0.element.sherpaText.isEmpty ? $0.element.rawText : $0.element.sherpaText)"
            }.joined(separator: "\n")
        ))
    }

    private func usable(_ text: String?, backup: String) -> Bool {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !whisper.isHallucination(value),
              !whisper.hasRepeatedPhrase(value)
        else { return false }
        let ratio = Double(value.count) / Double(max(1, backup.count))
        return ratio >= 0.4 && ratio <= 2.5
    }

    private func queueSnapshot(override: RefinementLoadState? = nil) -> LivePipelineQueueSnapshot {
        let bytes = whisperQueue.reduce(0) { $0 + $1.pcmData.count }
            + inFlightWhisper.values.reduce(0) { $0 + $1.pcmData.count }
        let seconds = Double(bytes) / 32_000.0
        return LivePipelineQueueSnapshot(
            whisperCount: whisperQueue.count,
            llmCount: llmQueue.count + pendingLLMBatch.count,
            pendingAudioSeconds: seconds,
            pendingPCMBytes: bytes,
            loadState: override ?? RefinementBackpressurePolicy.loadState(
                pendingCount: whisperQueue.count,
                pendingAudioSeconds: seconds
            )
        )
    }

    private func publishStatus(override: RefinementLoadState? = nil) {
        emit(.status(queueSnapshot(override: override)))
    }

    private func emit(_ event: LivePipelineEvent) {
        guard let handler = onEvent else { return }
        let previous = eventTask
        eventTask = Task {
            await previous?.value
            await handler(event)
        }
    }

    private func cancelTasks() {
        whisperWorkers.forEach { $0.cancel() }
        translationWorkers.forEach { $0.cancel() }
        llmWorker?.cancel()
        diagnosticsWorker?.cancel()
        whisperWorkers.removeAll()
        translationWorkers.removeAll()
        llmWorker = nil
        diagnosticsWorker = nil
    }

    private func clearQueues() {
        whisperQueue.removeAll()
        inFlightWhisper.removeAll()
        llmQueue.removeAll()
        pendingLLMBatch.removeAll()
        sourceIDsByPrimaryID.removeAll()
        translationQueue.removeAll()
    }
}
