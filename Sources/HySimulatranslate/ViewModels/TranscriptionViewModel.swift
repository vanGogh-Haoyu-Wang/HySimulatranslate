import Foundation
import SwiftUI
import AppKit

enum SelfCheckScope: Equatable {
    case full
    case audioInput
}

// MARK: - 🎙️ 主力同传引擎 ViewModel（对应 Python WhisperTranscriptionApp）
// Sherpa-onnx 实时流式 + WhisperKit 本地精校 + Groq LLM 格式化 + OmniRoute 中文总结

@MainActor
final class TranscriptionViewModel: ObservableObject {
    let modelCenterViewModel: ModelCenterViewModel
    @Published var engineStatus: EngineStatus = .idle
    @Published var statusMessage: String = "初始化..."
    @Published var draftText: String = ""
    @Published var draftAppleTranslation: String = ""
    @Published var appleRealtimeTranslations: [UUID: String] = [:]
    @Published var historyItems: [TranscriptionItem] = []
    @Published var dynamicItems: [TranscriptionItem] = []
    @Published var translationOnlyHistoryBlocks: [TranslationOnlyHistoryBlock] = []
    @Published var isRecording = false
    @Published var translationEnabled = true
    @Published var canRestart = false
    @Published var whisperQueueSize: Int = 0
    @Published var llmQueueSize: Int = 0
    @Published var refinementLoadState: RefinementLoadState = .normal
    @Published var micDeviceName: String = ""
    @Published var micVolume: Float = 0.0
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStatus: String = ""
    @Published var microphoneReady = false
    @Published var systemAudioReady = false
    @Published var sherpaReady = false
    @Published var whisperReady = false
    @Published var speakerKitReady = false
    @Published var appleTranslationReady = false
    @Published var liveSummaryText: String = ""
    @Published var liveSummaryStatus: String = "未配置"
    @Published var liveSummaryReady = false
    @Published var isLiveSummaryUpdating = false
    @Published var isFinalizingSession = false
    @Published var audioInputSelection: AudioInputSelection = .defaultSelection
    @Published var selectedAudioCaptureSource: AudioCaptureSource = .microphone
    @Published var availableAudioCaptureSources: [AudioCaptureSource] = [.microphone, .systemAudio]
    @Published var audioCaptureSourceStatus = ""
    @Published var fullSelfCheckRequired = true
    @Published var audioInputCheckRequired = false
    @Published var noteRecords: [NoteRecord] = []
    @Published var selectedNoteRecord: NoteRecord?
    @Published var notePreviewText: String = ""
    @Published var notePreviewStatus: String = ""
    @Published private(set) var noteWriteError: String?
    @Published var meetingRightPanelMode: MeetingRightPanelMode = .summary
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var selectedMeeting: MeetingRecord?
    @Published private(set) var selectedMeetingSegments: [TranscriptSegmentRecord] = []
    @Published private(set) var selectedMeetingAudioURL: URL?
    @Published private(set) var selectedMeetingRevisions: [TranscriptRevisionRecord] = []
    @Published private(set) var selectedTranslationRevisions: [TranslationRevisionRecord] = []
    @Published var selectedTranslationRevisionID: UUID?
    @Published private(set) var selectedMeetingTranslations: [UUID: String] = [:]
    @Published private(set) var selectedMeetingSpeakerAliases: [String: String] = [:]
    @Published private(set) var pendingImportJobs: [ImportJobRecord] = []
    @Published private(set) var resumedImportProgress: [UUID: Double] = [:]
    @Published var selectedMeetingRevisionID: UUID?
    @Published private(set) var isImportingAudio = false
    @Published private(set) var importProgress: Double = 0
    @Published private(set) var retranslationStatus = ""
    @Published private(set) var retranslationError: String?
    @Published private(set) var meetingLibraryStatus = "正在载入会话库…"
    @Published private(set) var isMeetingLibraryReady = false
    @Published private(set) var summaryWorkspace: SummaryWorkspaceController?
    var unindexedNoteRecords: [NoteRecord] {
        Self.deduplicatedNoteRecords(noteRecords, meetings: meetings)
    }
    var meetingPlayback: MeetingPlaybackController { appServices.playback }
    var selectedMeetingCapabilities: MeetingDetailCapabilities {
        guard let meeting = selectedMeeting else {
            return MeetingDetailCapabilities(
                meeting: MeetingRecord(title: "", source: .live),
                hasPlayableAudio: false,
                revisions: [],
                selectedRevisionID: nil
            )
        }
        return MeetingDetailCapabilities(
            meeting: meeting,
            hasPlayableAudio: selectedMeetingAudioURL != nil,
            revisions: selectedMeetingRevisions,
            selectedRevisionID: selectedMeetingRevisionID
        )
    }
    @AppStorage("noteDirectoryPath") var noteDirectoryPath: String = ""
    @AppStorage("noteFileFormat") var noteFileFormatRaw: String = NoteFileFormat.markdown.rawValue
    @AppStorage("omniRouteBaseURL") var omniRouteBaseURL: String = LLMProviderCatalog.defaultOmniRouteBaseURL
    @AppStorage("historyDisplayMode") var historyDisplayModeRaw: String = HistoryDisplayMode.defaultMode.rawValue
    @AppStorage("audioInputSelection") private var audioInputSelectionStorage: String = AudioInputSelection.defaultSelectionStorageValue
    @AppStorage("audioCaptureSource") private var audioCaptureSourceStorage: String = AudioCaptureSource.microphoneStorageValue
    var providerAPIKeys: [LLMProviderID: String] {
        get { modelCenterViewModel.providerAPIKeys }
        set { _ = modelCenterViewModel.updateProviderAPIKeys(newValue) }
    }
    var providerCheckResults: [LLMProviderCheckResult] {
        get { modelCenterViewModel.providerCheckResults }
        set { modelCenterViewModel.setProviderCheckResults(newValue) }
    }
    var apiReady: Bool {
        get { modelCenterViewModel.apiReady }
        set { modelCenterViewModel.setAPIReady(newValue) }
    }
    var groqCoreModelName: String {
        get { modelCenterViewModel.selectedProviderModelNames[.groq] ?? LLMProviderCatalog.defaultGroqModelName }
        set { modelCenterViewModel.selectModel(newValue, for: .groq) }
    }
    var agnesOrganizerModelName: String {
        get { modelCenterViewModel.selectedProviderModelNames[.agnes] ?? LLMProviderCatalog.defaultAgnesOrganizerModelName }
        set { modelCenterViewModel.selectModel(newValue, for: .agnes) }
    }
    var currentCourse: CourseSubject?
    var pauseVal: Double = 0.6
    var hardCutVal: Double = 20.0
    var noteFileFormat: NoteFileFormat {
        get { NoteFileFormat(rawValue: noteFileFormatRaw) ?? .markdown }
        set { noteFileFormatRaw = newValue.rawValue }
    }
    var historyDisplayMode: HistoryDisplayMode {
        get { HistoryDisplayMode(rawValue: historyDisplayModeRaw) ?? .defaultMode }
        set {
            historyDisplayModeRaw = newValue.rawValue
            refreshTranslationOnlyHistoryBlocks(forceAgnes: true)
        }
    }
    var defaultNoteDirectoryPath: String {
        Self.defaultNoteDirectory().path
    }
    var effectiveNoteDirectoryPath: String {
        Self.noteDirectory(from: noteDirectoryPath).path
    }
    var selectedProviderModelNames: [LLMProviderID: String] {
        modelCenterViewModel.selectedProviderModelNames
    }

    var canStartTranscription: Bool {
        guard !isFinalizingSession else { return false }
        guard isMeetingLibraryReady else { return false }
        guard case .ready = engineStatus else { return false }
        return audioCaptureReady && sherpaReady && whisperReady
    }

    var audioCaptureReady: Bool {
        guard audioInputSelection.hasEnabledInput else { return false }
        if audioInputSelection.microphoneEnabled && !microphoneReady { return false }
        if audioInputSelection.systemAudioEnabled && !systemAudioReady { return false }
        return true
    }

    var nextSelfCheckScope: SelfCheckScope {
        if fullSelfCheckRequired {
            return .full
        }
        if audioInputCheckRequired, sherpaReady, whisperReady {
            return .audioInput
        }
        return .full
    }

    var startTranscriptionButtonTitle: String {
        translationEnabled ? "开始同声传译" : "本地同声传译"
    }

    // Services
    private let speechEngine = SpeechEngine()
    private let systemAudioCaptureEngine = SystemAudioCaptureEngine()
    private let sherpaService = SherpaService()
    private let whisperKitService = WhisperKitService()
    private let llmService = LLMService()
    private let appleTranslationService: any AppleSystemTranslating
    private let translationService: TranslationService
    private let omniRouteSummaryService = OmniRouteSummaryService()
    private let agnesHistoryOrganizerService = AgnesHistoryOrganizerService()
    private let speakerDiarizationService = SpeakerDiarizationService()
    private let sessionAudioStore = SessionAudioStore()
    private let sessionRecoveryJournal = SessionRecoveryJournal()
    private let diagnosticsLogger = PipelineDiagnosticsLogger()
    private let noteExportService = NoteExportService()
    private let noteWriteCoordinator = NoteWriteCoordinator()
    private var noteWriteRevision: UInt64 = 0
    private var meetingLibraryController: MeetingLibraryController?
    private var revisionWorkspaceController: RevisionWorkspaceController?
    private var importWorkspaceController: ImportWorkspaceController?
    private var livePersistenceSession: LivePersistenceSession?
    private var sessionGeneration: UInt64 = 0
    private var sessionCaptureStartedAt: ContinuousClock.Instant?
    private var finalPersistenceSucceeded = true
    private var timedSegments: [UUID: (start: TimeInterval, end: TimeInterval, draft: String)] = [:]
    private let appServices: AppServices
    private var sessionCoordinator: SessionCoordinator?
    private var sessionContext: SessionCoordinator.Context?
    private var loadedModelLease: ModelResourceLease?
    private lazy var livePipeline = LiveTranscriptionPipeline(
        sherpa: sherpaService,
        whisper: whisperKitService,
        llm: llmService,
        translation: translationService
    )

    private var organizerQueue: [OrganizerQueueItem] = []

    private var lastRenderTime: TimeInterval = 0
    private let dynamicIdleFlushSeconds: TimeInterval = 2.0
    private let organizerBufferSeconds: TimeInterval = 1.2
    private let organizerMaxBatchSize = 4
    private var lastDynamicInputTime: TimeInterval = 0
    private var liveSummaryCursor = LiveSummaryCursor()
    private var filePath: URL?
    private var isRunning = false
    private var speakerDiarizationTask: Task<Void, Never>?
    private var translationOnlyOrganizationTask: Task<Void, Never>?
    private var lastTranslationOnlyDisplaySignature = ""
    private var lastTranslationOnlyOrganizationSignature = ""
    private var lectureFocusFilter = LectureFocusFilter()
    private var lectureMetricsByItemID: [UUID: LectureSegmentMetrics] = [:]
    private var recordingStartedAt = Date().timeIntervalSince1970
    private var resourcePressureMonitor: ResourcePressureMonitor?
    private var organizerWorkerTask: Task<Void, Never>?
    private var draftAppleTranslationTask: Task<Void, Never>?
    private var appleRealtimeTranslationTasks: [UUID: Task<Void, Never>] = [:]
    private var volumePollTask: Task<Void, Never>?
    private var dynamicIdleFlushTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var finalSummaryTask: Task<Void, Never>?
    private var agnesOrganizationTask: Task<Void, Never>?
    private var isAgnesOrganizing = false
    private var pendingAgnesOrganization = false
    private var historyItemsAddedSinceAgnesOrganization = 0
    private let agnesOrganizationTriggerCount = 2
    private let agnesRealtimeWindowSize = 12

    private let forbiddenEnds: Set<String> = [
        "of", "the", "and", "or", "a", "an", "is", "are", "in", "on", "at",
        "to", "with", "that", "as", "for", "by", "from", "about", "but", "because"
    ]

    // MARK: - 系统自检

    private var isChecking = false

    init(
        appleTranslationService: any AppleSystemTranslating = AppleSystemTranslationService(),
        modelResourceService: ModelResourceService = .shared,
        appServices: AppServices? = nil
    ) {
        let resolvedServices = appServices ?? AppServices(modelResources: modelResourceService, modelUsage: ModelUsageCoordinator(resources: modelResourceService))
        self.appServices = resolvedServices
        self.modelCenterViewModel = ModelCenterViewModel(resourceService: modelResourceService)
        self.appleTranslationService = appleTranslationService
        self.translationService = TranslationService(
            appleTranslator: appleTranslationService
        )
        let hadDeprecatedApplicationAudio = AudioCaptureSource.containsDeprecatedApplicationAudio(audioCaptureSourceStorage)
        let storedAudioInputSelection = UserDefaults.standard.string(forKey: "audioInputSelection")
        audioInputSelection = AudioInputSelection.fromStorageValue(
            storedAudioInputSelection,
            legacyAudioCaptureSourceStorage: audioCaptureSourceStorage
        )
        selectedAudioCaptureSource = Self.mirroredAudioCaptureSource(for: audioInputSelection)
        audioInputSelectionStorage = audioInputSelection.storageValue
        audioCaptureSourceStorage = selectedAudioCaptureSource.storageValue
        if hadDeprecatedApplicationAudio {
            audioCaptureSourceStatus = "已切换为麦克风 + 电脑音频，避免应用捕获授权冲突"
        }
        availableAudioCaptureSources = Self.supportedAudioCaptureSources(selected: selectedAudioCaptureSource)
        _ = try? SessionRecoveryJournal.recoverPendingSessions(
            rootDirectory: SessionAudioStore.defaultRootDirectory()
        )
        resourcePressureMonitor = ResourcePressureMonitor { [weak self] level in
            Task { @MainActor [weak self] in
                self?.handleResourcePressure(level)
            }
        }
        resourcePressureMonitor?.start()
        let defaults = UserDefaults.standard
        modelCenterViewModel.configureModelSelection(selectedModels: [
            .groq: defaults.string(forKey: "groqCoreModelName") ?? LLMProviderCatalog.defaultGroqModelName,
            .agnes: defaults.string(forKey: "agnesOrganizerModelName") ?? LLMProviderCatalog.defaultAgnesOrganizerModelName
        ]) { [weak self] providerID, modelID in
            self?.selectProviderModel(modelID, for: providerID)
        }
        initializeMeetingLibrary()
    }

    private func selectProviderModel(_ modelID: String, for providerID: LLMProviderID) {
        guard providerID != .omniRoute else { return }
        noteProviderModelSelectionChanged()
    }

    private func initializeMeetingLibrary() {
        let noteDirectory = Self.noteDirectory(from: noteDirectoryPath)
        Task.detached(priority: .utility) { [weak self] in
            do {
                let (database, active, purged) = try WorkspaceCompositionRoot.prepare(noteDirectory: noteDirectory)
                let sessionsRoot = Self.sessionAssetsRootDirectory()
                for id in purged {
                    try? FileManager.default.removeItem(at: sessionsRoot.appendingPathComponent(id.uuidString, isDirectory: true))
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let workspace = WorkspaceCompositionRoot.compose(database: database, app: self.appServices, translationService: self.translationService, appleTranslator: self.appleTranslationService, noteDirectory: Self.noteDirectory(from: self.noteDirectoryPath), sessionsRoot: Self.sessionAssetsRootDirectory(), playback: self.appServices.playback)
                    self.meetingLibraryController = workspace.meetingLibrary
                    let summaryWorkspace = workspace.summaries
                    summaryWorkspace.loadTemplates()
                    self.summaryWorkspace = summaryWorkspace
                    self.importWorkspaceController = workspace.imports
                    self.pendingImportJobs = self.importWorkspaceController?.pendingJobs ?? []
                    self.sessionCoordinator = workspace.sessions
                    self.revisionWorkspaceController = workspace.revisions
                    self.isMeetingLibraryReady = true
                    self.meetings = active
                    self.meetingLibraryStatus = purged.isEmpty ? "" : "已清理 \(purged.count) 个过期会话"
                    for job in self.pendingImportJobs { self.startResumeImport(job) }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isMeetingLibraryReady = false
                    self?.meetingLibraryStatus = "会话库不可用，继续使用笔记文件：\(error.localizedDescription)"
                }
            }
        }
    }

    func refreshMeetingLibrary() {
        guard let meetingLibraryController else { return }
        meetings = (try? meetingLibraryController.refresh()) ?? []
    }

    func selectMeeting(_ meeting: MeetingRecord) {
        guard !isRecording, !isFinalizingSession else { return }
        meetingRightPanelMode = .summary
        clearNotePreview()
        selectMeetingData(meeting)
    }

    func selectMeetingForNavigation(_ meeting: MeetingRecord) async {
        guard !isRecording, !isFinalizingSession else { return }
        guard let note = Self.meetingNoteRecord(for: meeting) else {
            selectMeeting(meeting)
            return
        }
        selectMeetingData(meeting)
        meetingRightPanelMode = meeting.source == .legacyImported ? .note : .summary
        await loadNotePreview(note)
    }

    func selectNoteForNavigation(_ record: NoteRecord) async {
        guard !isRecording, !isFinalizingSession else { return }
        clearSelectedMeeting()
        meetingRightPanelMode = .note
        await loadNotePreview(record)
    }

    func clearNotePreview() {
        selectedNoteRecord = nil
        notePreviewText = ""
        notePreviewStatus = ""
    }

    nonisolated static func meetingNoteRecord(for meeting: MeetingRecord) -> NoteRecord? {
        let path = meeting.source == .legacyImported ? meeting.legacyNotePath : meeting.exportedNotePath
        guard let path,
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let format = NoteFileFormat.fromFileExtension(url.pathExtension) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return NoteRecord(
            url: url,
            fileName: url.lastPathComponent,
            format: format,
            modifiedAt: values?.contentModificationDate ?? meeting.updatedAt,
            fileSize: Int64(values?.fileSize ?? 0),
            previewSummary: meeting.preview
        )
    }

    private func selectMeetingData(_ meeting: MeetingRecord) {
        summaryWorkspace?.load(meeting: meeting)
        do {
            guard let controller = meetingLibraryController else {
                selectedMeeting = meeting
                selectedMeetingSegments = []
                selectedMeetingRevisions = []
                selectedTranslationRevisions = []
                selectedMeetingRevisionID = meeting.currentTranscriptRevisionID
                selectedTranslationRevisionID = meeting.currentTranslationRevisionID
                selectedMeetingAudioURL = nil
                selectedMeetingSpeakerAliases = [:]
                selectedMeetingTranslations = [:]
                return
            }
            let selection = try controller.select(meeting)
            selectedMeeting = selection.meeting; selectedMeetingSegments = selection.segments
            selectedMeetingRevisions = selection.revisions; selectedTranslationRevisions = selection.translationRevisions
            selectedMeetingRevisionID = meeting.currentTranscriptRevisionID; selectedTranslationRevisionID = meeting.currentTranslationRevisionID
            selectedMeetingAudioURL = selection.audioURL; selectedMeetingSpeakerAliases = selection.speakerAliases
            selectedMeetingTranslations = selection.translations
        } catch {
            meetingLibraryStatus = "无法打开会话：\(error.localizedDescription)"
        }
    }

    func setSelectedMeetingSpeakerAlias(speakerID: String, displayName: String) {
        guard let meeting = selectedMeeting, let meetingLibraryController else { return }
        do {
            selectedMeetingSpeakerAliases = try meetingLibraryController.setAlias(meetingID: meeting.id, speakerID: speakerID, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { meetingLibraryStatus = "无法保存说话人名称：\(error.localizedDescription)" }
    }

    func selectedMeetingSpeakerName(_ speakerID: String) -> String {
        selectedMeetingSpeakerAliases[speakerID] ?? SpeakerDisplayName.displayName(for: speakerID)
    }

    func selectMeetingRevision(_ revisionID: UUID?) {
        guard let revisionID, let meeting = selectedMeeting, let revisions = revisionWorkspaceController else { return }
        do {
            guard let refreshed = try revisions.selectTranscript(revisionID, meetingID: meeting.id) else { return }
            selectMeeting(refreshed)
        } catch { meetingLibraryStatus = "无法切换转写版本：\(error.localizedDescription)" }
    }

    func selectTranslationRevision(_ revisionID: UUID?) {
        guard let revisionID, let meeting = selectedMeeting, let revisions = revisionWorkspaceController else { return }
        do { try revisions.selectTranslation(revisionID, meetingID: meeting.id); selectedTranslationRevisionID = revisionID; reloadSelectedTranslations() }
        catch { meetingLibraryStatus = "无法切换翻译版本：\(error.localizedDescription)" }
    }

    // Compatibility forwarding keeps the main view model API stable while summary
    // state and persistence live in SummaryWorkspaceController.
    var selectedSummaryTemplate: SummaryTemplateRecord? { summaryWorkspace?.selectedTemplate }
    func selectSummaryTemplate(_ id: UUID?) { summaryWorkspace?.selectTemplate(id) }
    func selectSummaryRevision(_ id: UUID?) {
        guard let id, let meetingID = selectedMeeting?.id else { return }
        do { try summaryWorkspace?.selectSummaryRevision(id, meetingID: meetingID) }
        catch { meetingLibraryStatus = "无法切换摘要版本：\(error.localizedDescription)" }
    }

    private func reloadSelectedTranslations() {
        guard let revisionID = selectedTranslationRevisionID, let revisions = revisionWorkspaceController else { selectedMeetingTranslations = [:]; return }
        selectedMeetingTranslations = (try? revisions.translations(revisionID)) ?? [:]
    }

    func retranslateSelectedMeeting() async {
        guard let meeting = selectedMeeting, let transcriptID = selectedMeetingRevisionID,
              let workspace = importWorkspaceController else { return }
        retranslationStatus = "正在重新翻译…"
        retranslationError = nil
        let credential = LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys, selectedModelNames: selectedProviderModelNames)
        do {
            let refreshed = try await workspace.retranslate(meeting: meeting, transcriptRevisionID: transcriptID, credential: credential)
            selectMeeting(refreshed)
            retranslationStatus = "重新翻译完成"
            retranslationError = nil
        } catch {
            retranslationStatus = "重新翻译失败"
            retranslationError = error.localizedDescription
        }
    }

    func retryRetranslation() { Task { await retranslateSelectedMeeting() } }

    func retranscribeSelectedMeeting(options: ImportOptions) async {
        guard let meeting = selectedMeeting, let url = selectedMeetingAudioURL,
              let workspace = importWorkspaceController else { return }
        isImportingAudio = true
        let credential = LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys, selectedModelNames: selectedProviderModelNames)
        let refreshed = try? await workspace.retranscribe(meeting: meeting, audioURL: url, options: options, credential: credential)
        importProgress = workspace.progress
        isImportingAudio = false
        if let refreshed { selectMeeting(refreshed) }
    }

    func resumeImport(_ job: ImportJobRecord) async {
        guard let workspace = importWorkspaceController else { return }
        let credential = LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys, selectedModelNames: selectedProviderModelNames)
        await workspace.resume(job, credential: credential)
        pendingImportJobs = workspace.pendingJobs; resumedImportProgress = workspace.resumedProgress
        refreshMeetingLibrary()
    }
    func startResumeImport(_ job: ImportJobRecord) {
        guard let workspace = importWorkspaceController else { return }
        let credential = LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys, selectedModelNames: selectedProviderModelNames)
        workspace.startResume(job, credential: credential)
        resumedImportProgress = workspace.resumedProgress
    }
    func cancelImport(jobID: UUID) { importWorkspaceController?.cancel(jobID: jobID) }

    @discardableResult
    func importAudio(from url: URL, options: ImportOptions) async -> Bool {
        guard !isRecording, !isFinalizingSession, let workspace = importWorkspaceController else { return false }
        isImportingAudio = true; importProgress = 0; meetingLibraryStatus = "正在导入 \(url.lastPathComponent)…"
        let progressTask = Task { @MainActor [weak self, weak workspace] in
            while !Task.isCancelled {
                if let value = workspace?.progress { self?.importProgress = value }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            progressTask.cancel()
            importProgress = workspace.progress
            isImportingAudio = false
        }
        do {
            let credential = LLMProviderCatalog.groqCoreCredential(from: providerAPIKeys, selectedModelNames: selectedProviderModelNames)
            let meeting = try await workspace.importAudio(from: url, options: options, sessionsRoot: Self.sessionAssetsRootDirectory(), credential: credential)
            importProgress = workspace.progress
            meetingLibraryStatus = "导入完成"
            refreshMeetingLibrary()
            selectMeeting(meeting)
            return true
        } catch {
            meetingLibraryStatus = error.localizedDescription.contains("任务已取消")
                ? "导入已取消"
                : "导入失败：\(error.localizedDescription)"
            return false
        }
    }

    func deleteMeeting(_ meeting: MeetingRecord) {
        do {
            try meetingLibraryController?.softDelete(meeting)
            if selectedMeeting?.id == meeting.id {
                clearSelectedMeeting()
            }
            refreshMeetingLibrary()
        } catch { meetingLibraryStatus = "删除失败：\(error.localizedDescription)" }
    }

    var translationExecutionMode: TranslationExecutionMode {
        TranslationExecutionMode.resolve(
            apiReady: apiReady,
            appleReady: appleTranslationReady
        )
    }

    func prepareAppleTranslationForTesting() async {
        appleTranslationReady = await appleTranslationService.prepare()
    }

    func applyTranslationReadinessForTesting(
        apiReady: Bool,
        appleReady: Bool
    ) {
        applyTranslationReadiness(apiReady: apiReady, appleReady: appleReady)
    }

    func applyMeetingLibraryReadinessForTesting(_ ready: Bool, message: String) {
        isMeetingLibraryReady = ready
        meetingLibraryStatus = message
    }

    private func applyTranslationReadiness(
        apiReady: Bool,
        appleReady: Bool
    ) {
        self.apiReady = apiReady
        appleTranslationReady = appleReady
        translationEnabled = translationExecutionMode.isTranslationEnabled
    }

    func setMicrophoneInputEnabled(_ enabled: Bool) {
        guard !isRecording, !isFinalizingSession, !isChecking else { return }
        if !enabled {
            microphoneReady = false
            micDeviceName = ""
        }
        setAudioInputSelection(AudioInputSelection(
            microphoneEnabled: enabled,
            systemAudioEnabled: audioInputSelection.systemAudioEnabled
        ))
    }

    func setSystemAudioInputEnabled(_ enabled: Bool) {
        guard !isRecording, !isFinalizingSession, !isChecking else { return }
        if !enabled {
            systemAudioReady = false
        }
        setAudioInputSelection(AudioInputSelection(
            microphoneEnabled: audioInputSelection.microphoneEnabled,
            systemAudioEnabled: enabled
        ))
    }

    private func setAudioInputSelection(_ selection: AudioInputSelection) {
        guard !isRecording, !isFinalizingSession, !isChecking else { return }
        let previousSelection = audioInputSelection
        guard previousSelection != selection else { return }

        audioInputSelection = selection
        persistAudioInputSelection()
        if previousSelection.microphoneEnabled != selection.microphoneEnabled {
            microphoneReady = false
            micDeviceName = ""
        }
        if previousSelection.systemAudioEnabled != selection.systemAudioEnabled {
            systemAudioReady = false
        }

        audioInputCheckRequired = selection.hasEnabledInput ? !audioCaptureReady : true
        audioCaptureSourceStatus = selection.hasEnabledInput
            ? (audioInputCheckRequired
                ? (fullSelfCheckRequired ? "音频输入已更改，请重新自检" : "音频输入已更改，请检查音频输入")
                : "音频输入已更新，可继续启动")
            : "请至少开启一个音频输入"
        if case .ready = engineStatus {
            setStatus(.ready(audioCaptureSourceStatus))
        }
    }

    func selectAudioCaptureSource(_ source: AudioCaptureSource) {
        guard !isRecording, !isFinalizingSession, !isChecking else { return }
        let normalizedSource = Self.normalizeAudioCaptureSource(source)
        audioInputSelection = normalizedSource.kind == .microphone
            ? AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: false)
            : AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: true)
        persistAudioInputSelection()
        availableAudioCaptureSources = Self.supportedAudioCaptureSources(selected: normalizedSource)
        if normalizedSource.kind == .microphone {
            systemAudioReady = false
            audioCaptureSourceStatus = microphoneReady ? micDeviceName : "音频输入已更改，请重新自检"
        } else {
            systemAudioReady = false
            if source.kind == .applicationAudio {
                audioCaptureSourceStatus = "已切换为麦克风 + 电脑音频，避免应用捕获授权冲突"
            } else {
                audioCaptureSourceStatus = microphoneReady
                    ? "麦克风已通过；电脑音频待自检"
                    : "音频输入已更改，请重新自检"
            }
        }
        audioInputCheckRequired = audioInputSelection.hasEnabledInput ? !audioCaptureReady : true
        if case .ready = engineStatus {
            setStatus(.ready(audioCaptureSourceStatus))
        }
        publishSelfCheckSummary(
            microphone: microphoneReady,
            audioSourceName: normalizedSource.statusTitle,
            audioSourceReady: normalizedSource.kind == .microphone ? microphoneReady : false,
            sherpa: sherpaReady,
            whisper: whisperReady,
            providerResults: providerCheckResults
        )
    }

    func refreshAudioCaptureSources() {
        selectedAudioCaptureSource = Self.mirroredAudioCaptureSource(for: audioInputSelection)
        availableAudioCaptureSources = Self.supportedAudioCaptureSources(selected: selectedAudioCaptureSource)
    }

    func updateProviderAPIKeys(_ keys: [LLMProviderID: String]) {
        if modelCenterViewModel.updateProviderAPIKeys(keys) {
            translationEnabled = false
            liveSummaryReady = false
            liveSummaryStatus = "API 配置已更改，请重新自检"
            fullSelfCheckRequired = true
            audioInputCheckRequired = false
        }
    }

    func selectCourse(_ subject: CourseSubject) {
        guard !isRecording, !isFinalizingSession else { return }
        currentCourse = subject
        if case .idle = engineStatus {
            statusMessage = "已选择 \(subject.name)"
        } else if case .ready = engineStatus {
            setStatus(translationEnabled
                ? .ready("🟢 已选择 \(subject.name)，随时可启动")
                : .ready("🟢 已选择 \(subject.name)（本地模式）"))
        }
    }

    func refreshNoteRecords() {
        noteRecords = Self.scanNoteRecords(in: Self.noteDirectory(from: noteDirectoryPath))
    }

    nonisolated static func deduplicatedNoteRecords(
        _ records: [NoteRecord],
        meetings: [MeetingRecord]
    ) -> [NoteRecord] {
        let indexedPaths = Set(meetings.compactMap(\.legacyNotePath).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } + meetings.compactMap(\.exportedNotePath).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        return records.filter { !indexedPaths.contains($0.url.standardizedFileURL.path) }
    }

    func loadNotePreview(_ record: NoteRecord) async {
        selectedNoteRecord = record
        notePreviewStatus = "读取中"
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try String(contentsOf: record.url, encoding: .utf8)
            }.value
            guard selectedNoteRecord?.id == record.id else { return }
            notePreviewText = text
            notePreviewStatus = "已载入"
        } catch {
            guard selectedNoteRecord?.id == record.id else { return }
            notePreviewText = ""
            notePreviewStatus = "读取失败：\(error.localizedDescription)\n\(record.url.path)"
        }
    }

    func reexportSelectedMeetingNote() async {
        guard let meeting = selectedMeeting,
              let path = meeting.exportedNotePath,
              let format = NoteFileFormat.fromFileExtension(URL(fileURLWithPath: path).pathExtension)
        else { return }
        let items = selectedMeetingSegments.map { segment in
            TranscriptionItem(
                id: segment.id,
                english: segment.refinedText,
                chinese: selectedMeetingTranslations[segment.id],
                status: .done,
                zone: .history,
                doneTime: segment.endTime,
                speakerID: segment.speakerID
            )
        }
        do {
            try noteExportService.export(
                course: CourseSubject(name: meeting.title, abbrev: meeting.title, keywords: "", meetingFocus: ""),
                translationEnabled: !selectedMeetingTranslations.isEmpty,
                items: items,
                finalSummary: summaryWorkspace?.displayedSummary ?? "",
                speakerAliases: selectedMeetingSpeakerAliases,
                format: format,
                to: URL(fileURLWithPath: path)
            )
            if let note = Self.meetingNoteRecord(for: meeting) { await loadNotePreview(note) }
        } catch {
            notePreviewStatus = "重新导出失败：\(error.localizedDescription)\n\(path)"
        }
    }

    func startNewRecordWithoutSelfCheck() {
        guard !isRecording, !isFinalizingSession else { return }
        clearDisplayHistory()
        selectedNoteRecord = nil
        clearSelectedMeeting()
        notePreviewText = ""
        notePreviewStatus = ""
        filePath = nil
        if audioCaptureReady && sherpaReady && whisperReady {
            setStatus(translationEnabled
                ? .ready("🟢 新记录已准备，随时可启动")
                : .ready("🟢 新记录已准备（本地模式）"))
        }
        refreshNoteRecords()
    }

    func runSystemCheck() {
        guard !isChecking else { return }
        guard let course = currentCourse else {
            setStatus(.error("请先选择强化专项"))
            return
        }
        switch nextSelfCheckScope {
        case .audioInput:
            runAudioInputCheckOnly(course: course)
        case .full:
            runFullSystemCheck(course: course)
        }
    }

    private func runFullSystemCheck(course: CourseSubject) {
        loadedModelLease?.release()
        loadedModelLease = nil
        isChecking = true
        fullSelfCheckRequired = true
        audioInputCheckRequired = false
        downloadProgress = 0.0
        downloadStatus = ""
        microphoneReady = false
        systemAudioReady = false
        audioCaptureSourceStatus = ""
        sherpaReady = false
        whisperReady = false
        speakerKitReady = false
        appleTranslationReady = false
        apiReady = false
        liveSummaryReady = false
        liveSummaryStatus = "未配置"
        providerCheckResults = LLMProviderCatalog.mergedCheckResults(
            from: providerAPIKeys,
            testedResults: [],
            selectedModelNames: selectedProviderModelNames
        )
        translationEnabled = false
        historyItems.removeAll { $0.isSystemMessage }

        Task { [weak self] in
            guard let self else { return }
            guard let checkLease = try? self.appServices.selfCheck.beginModelLoading() else {
                self.isChecking = false
                self.setStatus(.error("模型资源正在删除，请稍后重试"))
                return
            }
            var retainsLoadedModels = false
            defer { self.isChecking = false; if !retainsLoadedModels { checkLease.release() } }

            guard audioInputSelection.hasEnabledInput else {
                audioInputCheckRequired = true
                publishSelfCheckSummary(
                    microphone: false,
                    audioSourceReady: false,
                    sherpa: false,
                    whisper: false,
                    providerResults: providerCheckResults
                )
                setStatus(.error("请至少开启一个音频输入"))
                return
            }

            guard await checkSelectedAudioInputs() else {
                publishSelfCheckSummary(
                    microphone: microphoneReady,
                    audioSourceReady: systemAudioReady,
                    sherpa: false,
                    whisper: false,
                    providerResults: providerCheckResults
                )
                setStatus(.error(audioCaptureSourceStatus))
                return
            }

            setStatus(.checking("准备随附模型资源..."))
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AppResourceLocator.installBundledResourcesIfNeeded()
                }.value
            } catch {
                sherpaReady = false
                whisperReady = false
                apiReady = false
                publishSelfCheckSummary(
                    microphone: microphoneReady,
                    sherpa: false,
                    whisper: false,
                    providerResults: providerCheckResults
                )
                setStatus(.error("随附资源安装失败：\(error.localizedDescription)"))
                return
            }

            // 1️⃣ Sherpa-onnx 模型检查 / 下载
            print("[TranscriptionViewModel] Self-check started for \(course.name)")
            setStatus(.checking("检查 Sherpa-onnx 模型..."))
            let sherpaModelDir: URL
            do {
                sherpaModelDir = try await ResourceDownloadService.ensureSherpaModel(onProgress: { [weak self] fraction, status in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = fraction
                        self?.downloadStatus = status
                        self?.setStatus(.checking(status))
                    }
                })
            } catch {
                sherpaReady = false
                whisperReady = false
                apiReady = false
                publishSelfCheckSummary(
                    microphone: microphoneReady,
                    sherpa: false,
                    whisper: false,
                    providerResults: providerCheckResults
                )
                setStatus(.error("Sherpa 模型下载失败：\(error.localizedDescription)"))
                return
            }

            guard FileManager.default.fileExists(atPath: sherpaModelDir.path),
                  await sherpaService.configure(modelDir: sherpaModelDir.path) else {
                sherpaReady = false
                whisperReady = false
                apiReady = false
                publishSelfCheckSummary(
                    microphone: microphoneReady,
                    sherpa: false,
                    whisper: false,
                    providerResults: providerCheckResults
                )
                setStatus(.error("Sherpa 模型缺失：请确保 \(AppResourceLocator.sherpaModelRelativePath) 已随 App 安装"))
                return
            }
            sherpaReady = true

            // 2️⃣ VAD 软依赖：失败时回退旧切段逻辑
            setStatus(.checking("检查 VAD 模型..."))
            let vadURL = try? await ResourceDownloadService.ensureVADModel(onProgress: { [weak self] fraction, status in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                    self?.downloadStatus = status
                }
            })
            let vadReady = await sherpaService.configureVoiceActivity(modelURL: vadURL)
            if !vadReady {
                print("[TranscriptionViewModel] VAD unavailable; using RMS/Sherpa boundary fallback")
            }

            // 3️⃣ WhisperKit 模型加载
            setStatus(.checking("加载 WhisperKit 本地引擎..."))
            whisperReady = await whisperKitService.configure(allowDownload: true, onProgress: { [weak self] fraction, status in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                    self?.downloadStatus = status
                    self?.setStatus(.checking(status))
                }
            })
            if !whisperReady {
                downloadProgress = 0.0
                downloadStatus = "WhisperKit large-v3 下载或加载失败"
            }
            print("[TranscriptionViewModel] WhisperKit ready: \(whisperReady)")

            // 4️⃣ SpeakerKit 说话人分离软依赖
            setStatus(.checking("加载 SpeakerKit 说话人分离..."))
            speakerKitReady = await speakerDiarizationService.configure(allowDownload: true)
            if !speakerKitReady {
                print("[TranscriptionViewModel] SpeakerKit unavailable; speaker labels will fall back to unknown")
            }

            // 5️⃣ Apple 系统翻译：仅使用已安装的英中模型，不在录音中弹下载 UI。
            setStatus(.checking("检查 Apple 系统翻译..."))
            appleTranslationReady = await appleTranslationService.prepare()

            // 6️⃣ Groq 核心 + OmniRoute 总结 + Agnes 整理测试
            setStatus(.checking("测试 Groq、OmniRoute 与 Agnes..."))
            let mergedResults = await modelCenterViewModel.testConnectivity(
                llm: llmService,
                summary: omniRouteSummaryService,
                agnes: agnesHistoryOrganizerService,
                omniRouteBaseURL: omniRouteBaseURL
            )
            let groqResult = mergedResults.first(where: { $0.provider.id == .groq })!
            let summaryResult = mergedResults.first(where: { $0.provider.id == .omniRoute })!
            let agnesResult = mergedResults.first(where: { $0.provider.id == .agnes })!
            applyTranslationReadiness(
                apiReady: groqResult.passed,
                appleReady: appleTranslationReady
            )
            liveSummaryReady = summaryResult.passed
            liveSummaryStatus = liveSummaryReady ? "等待历史内容" : summaryResult.status.displayText
            print("[TranscriptionViewModel] Groq core: \(groqResult.status.displayText), OmniRoute summary: \(summaryResult.status.displayText), Agnes organizer: \(agnesResult.status.displayText)")

            publishSelfCheckSummary(
                microphone: microphoneReady,
                sherpa: sherpaReady,
                whisper: whisperReady,
                speakerKit: speakerKitReady,
                appleTranslation: appleTranslationReady,
                providerResults: mergedResults
            )

            guard audioCaptureReady && sherpaReady && whisperReady else {
                fullSelfCheckRequired = true
                audioInputCheckRequired = !audioCaptureReady
                setStatus(.error("自检未通过：已开启的音频输入、Sherpa 和 Whisper large-v3 都必须可用"))
                print("[TranscriptionViewModel] Self-check failed: microphone=\(microphoneReady), systemAudio=\(systemAudioReady), inputs=\(audioInputSelection.displayTitle), sherpa=\(sherpaReady), whisper=\(whisperReady), api=\(apiReady)")
                return
            }

            fullSelfCheckRequired = false
            audioInputCheckRequired = false
            let mode = translationExecutionMode.statusTitle
            let summarySuffix = liveSummaryReady ? "，OmniRoute 总结可用" : ""
            setStatus(apiReady
                ? .ready("✅ 自检通过：\(course.name) \(mode)\(summarySuffix)")
                : .ready("🟡 API 未连通：\(course.name) \(mode)"))
            loadedModelLease = checkLease
            retainsLoadedModels = true
            modelCenterViewModel.rescan()
            print("[TranscriptionViewModel] Self-check ready: \(mode), translation=\(translationEnabled)")
        }
    }

    private func runAudioInputCheckOnly(course: CourseSubject) {
        isChecking = true
        downloadProgress = 0.0
        downloadStatus = ""
        historyItems.removeAll { $0.isSystemMessage }

        Task { [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }

            guard audioInputSelection.hasEnabledInput else {
                audioInputCheckRequired = true
                publishSelfCheckSummary(
                    microphone: false,
                    audioSourceReady: false,
                    sherpa: sherpaReady,
                    whisper: whisperReady,
                    speakerKit: speakerKitReady,
                    providerResults: providerCheckResults
                )
                setStatus(.error("请至少开启一个音频输入"))
                return
            }

            let passed = await checkSelectedAudioInputs()
            publishSelfCheckSummary(
                microphone: microphoneReady,
                audioSourceReady: systemAudioReady,
                sherpa: sherpaReady,
                whisper: whisperReady,
                speakerKit: speakerKitReady,
                appleTranslation: appleTranslationReady,
                providerResults: providerCheckResults
            )

            guard passed else {
                setStatus(.error(audioCaptureSourceStatus))
                return
            }

            let mode = translationExecutionMode.statusTitle
            let summarySuffix = liveSummaryReady ? "，OmniRoute 总结可用" : ""
            setStatus(apiReady
                ? .ready("✅ 音频输入已通过：\(course.name) \(mode)\(summarySuffix)")
                : .ready("🟡 音频输入已通过：\(course.name) \(mode)"))
        }
    }

    private func checkSelectedAudioInputs() async -> Bool {
        guard audioInputSelection.hasEnabledInput else {
            microphoneReady = false
            micDeviceName = ""
            systemAudioReady = false
            audioInputCheckRequired = true
            audioCaptureSourceStatus = "请至少开启一个音频输入"
            return false
        }

        if audioInputSelection.microphoneEnabled {
            setStatus(.checking("检查麦克风..."))
            let micCheck = await speechEngine.checkMicrophoneConnectivity()
            microphoneReady = micCheck.passed
            micDeviceName = micCheck.deviceName
            guard micCheck.passed else {
                systemAudioReady = audioInputSelection.systemAudioEnabled ? systemAudioReady : false
                audioInputCheckRequired = true
                audioCaptureSourceStatus = micCheck.message
                return false
            }
        } else {
            microphoneReady = false
            micDeviceName = ""
        }

        if audioInputSelection.systemAudioEnabled {
            setStatus(.checking("检查电脑音频..."))
            let systemCheck = await systemAudioCaptureEngine.checkConnectivity(source: .systemAudio)
            systemAudioReady = systemCheck.passed
            guard systemCheck.passed else {
                audioInputCheckRequired = true
                let prefix = audioInputSelection.microphoneEnabled && microphoneReady ? "麦克风已通过；" : ""
                audioCaptureSourceStatus = "\(prefix)\(systemCheck.message)"
                return false
            }
        } else {
            systemAudioReady = false
        }

        audioInputCheckRequired = false
        audioCaptureSourceStatus = audioInputSelection.displayTitle
        return true
    }

    func noteProviderModelSelectionChanged() {
        modelCenterViewModel.invalidateConnectivity()
        translationEnabled = false
        liveSummaryReady = false
        liveSummaryStatus = "模型已更改，请重新自检"
        fullSelfCheckRequired = true
        audioInputCheckRequired = false
        if case .ready = engineStatus {
            setStatus(.ready("模型已更改，请重新自检"))
        }
        publishSelfCheckSummary(
            microphone: microphoneReady,
            sherpa: sherpaReady,
            whisper: whisperReady,
            providerResults: providerCheckResults
        )
    }

    // MARK: - 启动/停止

    func startTranscription() {
        guard !isFinalizingSession else { return }
        guard !isRunning else { return }
        guard canStartTranscription else { return }
        guard let course = currentCourse else { return }
        guard let sessionCoordinator else {
            meetingLibraryStatus = "会话库仍在载入，请稍候再开始"
            return
        }
        clearSelectedMeeting()
        sessionGeneration &+= 1
        let generation = sessionGeneration
        finalSummaryTask?.cancel()
        finalSummaryTask = nil
        isFinalizingSession = false
        isRunning = true
        isRecording = true
        canRestart = false
        draftText = ""
        clearAppleRealtimeTranslations()
        historyItems = []
        dynamicItems = []
        translationOnlyHistoryBlocks = []
        organizerQueue = []
        liveSummaryText = ""
        liveSummaryStatus = liveSummaryReady ? "等待历史内容" : "未配置"
        isLiveSummaryUpdating = false
        liveSummaryCursor.reset()
        resetAgnesOrganizationState()
        lastTranslationOnlyDisplaySignature = ""
        lastTranslationOnlyOrganizationSignature = ""
        translationOnlyOrganizationTask?.cancel()
        translationOnlyOrganizationTask = nil
        speakerDiarizationTask?.cancel()
        speakerDiarizationTask = nil
        sessionAudioStore.cleanupCurrentSession()
        llmQueueSize = 0
        whisperQueueSize = 0
        refinementLoadState = .normal
        lectureFocusFilter = LectureFocusFilter()
        lectureMetricsByItemID = [:]
        recordingStartedAt = Date().timeIntervalSince1970
        sessionCaptureStartedAt = ContinuousClock.now
        timedSegments = [:]
        lastRenderTime = Date().timeIntervalSince1970
        lastDynamicInputTime = lastRenderTime
        setupFilePath()

        sherpaService.pauseVal = pauseVal
        sherpaService.limitVal = hardCutVal

        Task { [weak self, sessionCoordinator] in
            guard let self else { return }

            if audioInputSelection.microphoneEnabled {
                guard await SpeechEngine.requestMicrophoneAccess() else {
                    await MainActor.run {
                        self.handleStartFailure("麦克风权限未授权，请在系统设置 > 隐私与安全性 > 麦克风中允许。")
                    }
                    return
                }
            }
            guard self.isRunning, self.sessionGeneration == generation else { return }

            do {
                let sources: Set<AudioChunkSource> = Set([
                    self.audioInputSelection.microphoneEnabled ? AudioChunkSource.microphone : nil,
                    self.audioInputSelection.systemAudioEnabled ? AudioChunkSource.systemAudio : nil
                ].compactMap { $0 })
                let context = try await sessionCoordinator.begin(title: course.name, subjectID: course.id, enabledSources: sources, noteURL: self.filePath)
                self.sessionContext = context
                let persistenceSession = context.persistence
                self.livePersistenceSession = persistenceSession
                guard self.isRunning, self.sessionGeneration == generation else {
                    try? await sessionCoordinator.abort(context)
                    self.livePersistenceSession = nil
                    self.sessionContext = nil
                    return
                }
                let sessionID = persistenceSession.meetingID
                try self.sessionAudioStore.beginSession(sessionID: sessionID)
                guard let directory = self.sessionAudioStore.currentSessionDirectory(),
                      let notePath = self.filePath else {
                    throw NSError(
                        domain: "TranscriptionViewModel",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "会话路径不可用"]
                    )
                }
                try self.sessionRecoveryJournal.begin(
                    directory: directory,
                    metadata: SessionRecoveryMetadata(
                        notePath: notePath.path,
                        courseName: course.name,
                        courseAbbrev: course.abbrev,
                        translationEnabled: self.translationEnabled,
                        noteFormat: self.noteFileFormat
                    )
                )
                await self.speakerDiarizationService.resetSession()
            } catch {
                await MainActor.run {
                    self.handleStartFailure("无法创建会话恢复文件: \(error.localizedDescription)")
                }
                return
            }
            guard self.isRunning, self.sessionGeneration == generation else {
                await self.cleanupCancelledStart(generation: generation)
                return
            }

            guard let pipelineContext = self.sessionContext else {
                self.handleStartFailure("会话上下文不可用")
                return
            }
            await livePipeline.start(
                configuration: LiveTranscriptionPipelineConfiguration(
                    course: course,
                    groqCredential: self.groqCoreCredential(),
                    translationMode: self.translationExecutionMode,
                    pauseSeconds: self.pauseVal,
                    hardCutSeconds: self.hardCutVal,
                    processAudio: { [weak self] chunk in
                        guard let self, let coordinator = self.sessionCoordinator else {
                            throw LiveSessionPersistenceError.staleSession
                        }
                        return try coordinator.accept(chunk, context: pipelineContext)
                    },
                    admitSegment: { [weak self] segment, queue in
                        self?.admitLiveSegment(segment, queue: queue, generation: generation) ?? .drop
                    },
                    recentContext: { [weak self] in
                        self?.getRecentContext() ?? ""
                    },
                    isSessionEnding: { [weak self] in
                        self?.looksLikeSessionEnding() ?? true
                    },
                    speakerDiarizationActive: { [weak self] in
                        self?.speakerDiarizationTask != nil
                    }
                ),
                onEvent: { [weak self] event in
                    await MainActor.run { [weak self] in
                        self?.handleLivePipelineEvent(event, generation: generation)
                    }
                }
            )
            guard self.isRunning, self.sessionGeneration == generation else {
                await self.cleanupCancelledStart(generation: generation)
                return
            }

            // 配置音频采集 → 串行合流 → 喂 Sherpa
            if audioInputSelection.microphoneEnabled {
                speechEngine.configure { [weak self] samples, sampleRate in
                    Task { [weak self] in
                        await self?.acceptCapturedAudio(samples: samples, sampleRate: sampleRate, source: .microphone)
                    }
                }
            }

            startOrganizerWorker()
            startVolumePolling()
            startDynamicIdleFlushWorker()

            do {
                if audioInputSelection.systemAudioEnabled {
                    try await systemAudioCaptureEngine.start(source: .systemAudio) { [weak self] samples, sampleRate in
                        Task { [weak self] in
                            await self?.acceptCapturedAudio(samples: samples, sampleRate: sampleRate, source: .systemAudio)
                        }
                    }
                }
                if audioInputSelection.microphoneEnabled {
                    try speechEngine.start()
                    micDeviceName = speechEngine.micDeviceName
                } else {
                    micDeviceName = ""
                    micVolume = 0
                }
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
        sessionGeneration &+= 1
        isRunning = false
        isRecording = false
        if wasRecording {
            beginSessionFinalization()
        } else {
            canRestart = false
        }

        cancelWorkerTasks(cancelPipeline: false)
        stopAudioCapture()
        finalizeSessionAudioPipeline()
        setStatus(.idle)
        statusMessage = wasRecording ? "正在整理详细总结..." : "麦克风已断开"
        renderUI(force: true)

        Task { [weak self, livePipeline] in
            let pending = await livePipeline.finish()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.degradePendingWorkForFinalNote(pending)
                if wasRecording {
                    for i in self.dynamicItems.indices { self.dynamicItems[i].zone = .history }
                    self.historyItems.append(contentsOf: self.dynamicItems)
                    _ = self.applyLocalHistoryCleanup()
                    self.historyItems.forEach(self.persistLiveSegment)
                    self.queueNoteWrite()
                }
                self.dynamicItems = []
                self.draftText = ""
                self.clearAppleRealtimeTranslations()
                if wasRecording {
                    self.runFinalSpeakerCorrectionThenSummarize(
                        snapshot: self.sessionAudioStore.finalizeSnapshot()
                    )
                }
                self.renderUI(force: true)
            }
        }
    }

    private func runFinalSpeakerCorrectionThenSummarize(
        snapshot: SessionAudioSnapshot?
    ) {
        guard let snapshot else {
            startFinalSessionSummaryAndWriteNotes()
            return
        }
        let service = speakerDiarizationService
        speakerDiarizationTask = Task { [weak self] in
            let labels = await service.diarizeSession(snapshot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.speakerDiarizationTask = nil
                self.applySpeakerLabels(labels)
                self.applyFinalLectureSpeakerFocus()
                self.startFinalSessionSummaryAndWriteNotes()
            }
        }
    }

    private func beginSessionFinalization() {
        finalSummaryTask?.cancel()
        finalSummaryTask = nil
        isFinalizingSession = true
        finalPersistenceSucceeded = true
        canRestart = false
        isLiveSummaryUpdating = false
        liveSummaryStatus = liveSummaryReady ? "整理最终总结中" : "写入笔记中"
    }

    private func startFinalSessionSummaryAndWriteNotes() {
        let credential = LLMProviderCatalog.omniRouteSummaryCredential(
            from: providerAPIKeys,
            baseURL: omniRouteBaseURL
        )
        let previousSummary = liveSummaryText
        let fullContent = liveSummarySourceUnits(includeUntranslated: true)
            .map(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldRequestDetailedSummary = liveSummaryReady && credential != nil && !fullContent.isEmpty
        let summaryService = omniRouteSummaryService
        let template = summaryWorkspace?.selectedTemplate
        let persistenceSession = livePersistenceSession
        let summaryWorkspace = summaryWorkspace

        finalSummaryTask = Task { [weak self] in
            let agnesFinalTask = Task { [weak self] in
                await self?.runFinalAgnesHistoryOrganizationIfAvailable()
            }
            var finalSummary: String?
            if shouldRequestDetailedSummary,
               let credential, let template, let persistenceSession, let summaryWorkspace {
                let revision = try? await summaryWorkspace.generate(
                    meetingID: persistenceSession.meetingID,
                    transcriptRevisionID: persistenceSession.revisionID,
                    translationRevisionID: nil,
                    template: template,
                    provider: credential.provider.displayName,
                    model: credential.provider.modelName,
                    previousSummary: previousSummary,
                    sourceContent: fullContent,
                    isFinal: true
                ) { prompt in
                    try await summaryService.summarize(prompt: prompt, credential: credential, isFinal: true)
                }
                if revision?.status == .succeeded { finalSummary = revision?.body }
            }
            await agnesFinalTask.value

            let persistenceSucceeded = await self?.completeLiveSessionPersistence() ?? false

            guard !Task.isCancelled, let self else { return }
            self.finalPersistenceSucceeded = persistenceSucceeded
            if let finalSummary {
                self.liveSummaryText = finalSummary
                self.liveSummaryStatus = "正在写入笔记"
            } else if shouldRequestDetailedSummary {
                self.liveSummaryStatus = self.liveSummaryText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                    ? "总结失败，正在写入笔记"
                    : "总结失败，保留已有总结"
            } else {
                self.liveSummaryStatus = "正在写入笔记"
            }

            let noteResult = await self.writeLatestNote()
            if case .written = noteResult, persistenceSucceeded {
                try? self.sessionRecoveryJournal.markCompleted()
                self.sessionRecoveryJournal.close()
                self.sessionAudioStore.cleanupCurrentSession()
                self.refreshNoteRecords()
                self.finalSummaryTask = nil
                self.isFinalizingSession = false
                self.canRestart = true
                self.statusMessage = "笔记已完成"
                self.liveSummaryStatus = finalSummary == nil && shouldRequestDetailedSummary
                    ? "总结失败，笔记已写入"
                    : "已写入笔记"
            } else {
                self.liveSummaryStatus = persistenceSucceeded ? "笔记写入失败，可重试" : "会话保存失败，恢复数据已保留"
                self.statusMessage = persistenceSucceeded
                    ? (self.noteWriteError ?? "笔记写入失败，可重试")
                    : self.meetingLibraryStatus
                self.finalSummaryTask = nil
                self.isFinalizingSession = false
                self.canRestart = true
            }
            self.renderUI(force: true)
        }
    }

    private func handleStartFailure(_ message: String) {
        sessionGeneration &+= 1
        isRunning = false
        isRecording = false
        canRestart = false
        cancelWorkerTasks()
        stopAudioCapture()
        sessionRecoveryJournal.close()
        sessionAudioStore.cleanupCurrentSession()
        let failedContext = sessionContext
        sessionContext = nil
        livePersistenceSession = nil
        Task { if let failedContext { await sessionCoordinator?.fail(failedContext) } }
        setStatus(.error(message))
        renderUI(force: true)
    }

    private func stopAudioCapture() {
        speechEngine.stop()
        Task { [systemAudioCaptureEngine] in
            await systemAudioCaptureEngine.stop()
        }
    }

    private func acceptCapturedAudio(samples: [Float], sampleRate: Int32, source: AudioChunkSource) async {
        guard isRunning, sessionContext != nil else { return }
        let elapsed = Self.elapsedSeconds(since: sessionCaptureStartedAt)
        await livePipeline.accept(AudioChunk(
            source: source,
            samples: samples,
            sampleRate: Int(sampleRate),
            sessionStartTime: elapsed
        ))
    }

    private func finalizeSessionAudioPipeline() {
        guard let context = sessionContext else { return }
        sessionCoordinator?.finalizeAudio(context)
    }

    private func completeLiveSessionPersistence() async -> Bool {
        guard let coordinator = sessionCoordinator, let context = sessionContext else { return true }
        let segments = historyItems.compactMap { item -> (UUID, TimeInterval, TimeInterval, String?, String, String?, PersistenceStatus)? in
            guard let timing = timedSegments[item.id] else { return nil }
            return (item.id, timing.start, timing.end, timing.draft, item.english, item.speakerID, item.isVisible && item.status != .dropped ? .succeeded : .cancelled)
        }
        do {
            try await coordinator.finish(context, finalSegments: segments)
        } catch {
            meetingLibraryStatus = "会话持久化收尾失败：\(error.localizedDescription)"
            livePersistenceSession = nil
            sessionContext = nil
            refreshMeetingLibrary()
            return false
        }
        livePersistenceSession = nil
        sessionContext = nil
        refreshMeetingLibrary()
        return true
    }

    private func cleanupCancelledStart(generation: UInt64) async {
        guard sessionGeneration != generation else { return }
        sessionRecoveryJournal.close()
        sessionAudioStore.cleanupCurrentSession()
        if let context = sessionContext { try? await sessionCoordinator?.abort(context) }
        sessionContext = nil; livePersistenceSession = nil
    }

    private func clearSelectedMeeting() {
        meetingLibraryController?.clearSelection()
        meetingPlayback.unload()
        selectedMeeting = nil
        selectedMeetingSegments = []
        selectedMeetingAudioURL = nil
        selectedMeetingRevisions = []
        selectedTranslationRevisions = []
        selectedMeetingRevisionID = nil
        selectedTranslationRevisionID = nil
        selectedMeetingTranslations = [:]
        selectedMeetingSpeakerAliases = [:]
        summaryWorkspace?.load(meeting: nil)
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant?) -> TimeInterval {
        guard let start else { return 0 }
        let components = start.duration(to: .now).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    nonisolated private static func sessionAssetsRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HySimulatranslate/Sessions", isDirectory: true)
    }

    private func cancelWorkerTasks(cancelPipeline: Bool = true) {
        organizerWorkerTask?.cancel()
        volumePollTask?.cancel()
        dynamicIdleFlushTask?.cancel()
        summaryTask?.cancel()
        agnesOrganizationTask?.cancel()
        translationOnlyOrganizationTask?.cancel()
        speakerDiarizationTask?.cancel()
        draftAppleTranslationTask?.cancel()
        for task in appleRealtimeTranslationTasks.values {
            task.cancel()
        }

        organizerWorkerTask = nil
        volumePollTask = nil
        dynamicIdleFlushTask = nil
        summaryTask = nil
        agnesOrganizationTask = nil
        translationOnlyOrganizationTask = nil
        speakerDiarizationTask = nil
        draftAppleTranslationTask = nil
        appleRealtimeTranslationTasks.removeAll()
        isLiveSummaryUpdating = false
        isAgnesOrganizing = false
        pendingAgnesOrganization = false
        if cancelPipeline {
            Task { [livePipeline] in await livePipeline.cancel() }
        }
    }

    func prepareRestart() {
        guard !isFinalizingSession else { return }
        canRestart = false
        historyItems = []
        dynamicItems = []
        translationOnlyHistoryBlocks = []
        organizerQueue = []
        draftText = ""
        clearAppleRealtimeTranslations()
        liveSummaryText = ""
        liveSummaryStatus = liveSummaryReady ? "等待历史内容" : "未配置"
        liveSummaryCursor.reset()
        refinementLoadState = .normal
        resetAgnesOrganizationState()
        lastTranslationOnlyDisplaySignature = ""
        lastTranslationOnlyOrganizationSignature = ""
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
        translationOnlyHistoryBlocks = []
        organizerQueue = []
        draftText = ""
        clearAppleRealtimeTranslations()
        liveSummaryText = ""
        liveSummaryStatus = liveSummaryReady ? "等待历史内容" : "未配置"
        liveSummaryCursor.reset()
        refinementLoadState = .normal
        resetAgnesOrganizationState()
        lastTranslationOnlyDisplaySignature = ""
        lastTranslationOnlyOrganizationSignature = ""
        canRestart = false
        renderUI(force: true)
    }

    func publishSelfCheckSummary(
        microphone: Bool,
        audioSourceName: String? = nil,
        audioSourceReady: Bool? = nil,
        sherpa: Bool,
        whisper: Bool,
        speakerKit: Bool? = nil,
        appleTranslation: Bool? = nil,
        providerResults: [LLMProviderCheckResult]
    ) {
        historyItems.removeAll { $0.isSystemMessage }
        let systemInputReady = audioSourceReady ?? systemAudioReady
        var messages: [String] = []
        if audioInputSelection.microphoneEnabled {
            messages.append("[自检] 麦克风: \(microphone ? "通过" : "未通过")")
        }
        if audioInputSelection.systemAudioEnabled {
            messages.append("[自检] 电脑音频: \(systemInputReady ? "通过" : "未通过")")
        }
        if !audioInputSelection.hasEnabledInput {
            messages.append("[自检] 音频输入: 未选择")
        }
        messages.append(contentsOf: [
            "[自检] Sherpa: \(sherpa ? "通过" : "未通过")",
            "[自检] WhisperKit 本地灾备: \(whisper ? "通过" : "未通过")"
        ])
        if let speakerKit {
            messages.append("[自检] SpeakerKit: \(speakerKit ? "通过" : "未通过")")
        }
        if let appleTranslation {
            messages.append("[自检] Apple 系统翻译: \(appleTranslation ? "通过" : "未安装")")
        }
        messages.append(contentsOf: providerResults.filter { result in
            if result.provider.id == .agnes, result.status == .notConfigured {
                return false
            }
            return true
        }.map {
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

    func updateSherpaDraftForTesting(_ text: String) {
        updateSherpaDraft(text)
    }

    private func updateSherpaDraft(_ text: String) {
        noteDynamicInput()
        draftText = text
        draftAppleTranslationTask?.cancel()
        draftAppleTranslationTask = nil
        draftAppleTranslation = ""

        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard translationEnabled,
              appleTranslationReady,
              SmartWhisperRouting.containsLexicalContent(source)
        else { return }

        let translator = appleTranslationService
        draftAppleTranslationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled,
                  let translated = await translator.translate(source),
                  !Task.isCancelled,
                  let self,
                  self.isRecording,
                  self.draftText.trimmingCharacters(in: .whitespacesAndNewlines) == source
            else { return }
            self.draftAppleTranslation = translated
        }
    }

    private func requestAppleRealtimeTranslation(uid: UUID, sherpaText: String) {
        guard translationEnabled,
              appleTranslationReady,
              SmartWhisperRouting.containsLexicalContent(sherpaText)
        else { return }

        appleRealtimeTranslationTasks[uid]?.cancel()
        let translator = appleTranslationService
        appleRealtimeTranslationTasks[uid] = Task { [weak self] in
            let translated = await translator.translate(sherpaText)
            guard !Task.isCancelled, let self else { return }
            self.appleRealtimeTranslationTasks[uid] = nil
            guard let translated,
                  self.dynamicItems.contains(where: { $0.id == uid && $0.zone == .dynamic })
            else { return }
            self.appleRealtimeTranslations[uid] = translated
        }
    }

    private func clearDraftAppleTranslation() {
        draftAppleTranslationTask?.cancel()
        draftAppleTranslationTask = nil
        draftAppleTranslation = ""
    }

    private func removeAppleRealtimeTranslation(for uid: UUID) {
        appleRealtimeTranslationTasks.removeValue(forKey: uid)?.cancel()
        appleRealtimeTranslations.removeValue(forKey: uid)
    }

    private func clearAppleRealtimeTranslations() {
        clearDraftAppleTranslation()
        for task in appleRealtimeTranslationTasks.values {
            task.cancel()
        }
        appleRealtimeTranslationTasks.removeAll()
        appleRealtimeTranslations.removeAll()
    }

    private func admitLiveSegment(
        _ segment: SherpaSegment,
        queue: LivePipelineQueueSnapshot,
        generation: UInt64
    ) -> RefinementAdmission {
        guard sessionGeneration == generation else { return .drop }
        timedSegments[segment.id] = (segment.startTime, segment.endTime, segment.text)
        if let context = sessionContext {
            Task { [sessionCoordinator, context] in
                try? await sessionCoordinator?.upsert(
                    context: context,
                    id: segment.id,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    draft: segment.text,
                    refined: segment.text,
                    speakerID: nil
                )
            }
        }
        if moveReadyDynamicItemsToHistory(forceLeadingCompleted: true) {
            queueNoteWrite()
        }
        noteDynamicInput()
        draftText = ""
        clearDraftAppleTranslation()

        let metrics = LectureSegmentMetrics.make(pcmData: segment.pcmData, text: segment.text)
        if !WhisperKitService.isAccentAnalysisPlaceholder(segment.text) {
            let decision = lectureFocusFilter.evaluate(
                metrics,
                elapsed: Date().timeIntervalSince1970 - recordingStartedAt
            )
            guard decision != .drop else {
                renderUI(force: true)
                return .drop
            }
        }
        let admission = RefinementBackpressurePolicy.admission(
            for: metrics,
            state: queue.loadState,
            pendingCount: queue.whisperCount,
            pendingAudioSeconds: queue.pendingAudioSeconds
        )
        if admission != .drop {
            lectureMetricsByItemID[segment.id] = metrics
            recordAcceptedAudioSegment(uid: segment.id, pcm: segment.pcmData, sherpaText: segment.text)
        }
        return admission
    }

    private func handleLivePipelineEvent(_ event: LivePipelineEvent, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        switch event {
        case .draft(let text):
            guard isRunning else { return }
            updateSherpaDraft(text)
        case .segmentAccepted(let segment, let admission):
            let status: ItemStatus = admission == .useSherpa ? .llmFormatting : .whispering
            dynamicItems.append(TranscriptionItem(id: segment.id, english: segment.text, status: status, zone: .dynamic))
            requestAppleRealtimeTranslation(uid: segment.id, sherpaText: segment.text)
            renderUI(force: true)
        case .segmentMerged:
            draftText = ""
            clearDraftAppleTranslation()
            renderUI(force: true)
        case .refined(let id, let text, _):
            guard let index = dynamicItems.firstIndex(where: { $0.id == id }) else { return }
            dynamicItems[index].english = text
            dynamicItems[index].status = .llmFormatting
            try? sessionRecoveryJournal.recordRefinement(uid: id, english: text)
            renderUI(force: true)
        case .formatted(let id, let text, let sourceIDs):
            postProcessResult(uid: id, finalText: text, sourceIDs: sourceIDs)
        case .translated(let id, let text):
            applyTranslation(uid: id, zhText: text)
        case .dropped(let id):
            markAsDropped(uid: id)
        case .status(let queue):
            whisperQueueSize = queue.whisperCount
            llmQueueSize = queue.llmCount
            refinementLoadState = queue.loadState
        case .diagnostics(let snapshot):
            diagnosticsLogger.record(snapshot)
        case .error(let message):
            print("[LiveTranscriptionPipeline] \(message)")
        }
    }

    private func recordAcceptedAudioSegment(uid: UUID, pcm: Data, sherpaText: String) {
        _ = try? sessionAudioStore.appendSegment(uid: uid, pcmData: pcm)
        try? sessionRecoveryJournal.recordSegment(uid: uid, sherpaText: sherpaText)
    }

    func enqueueWhisperItemForTesting(uid: UUID, pcm: Data, sherpaText: String) async {
        let queue = await livePipeline.state()
        let segment = SherpaSegment(id: uid, pcmData: pcm, text: sherpaText, startTime: 0, endTime: 1)
        let admission = admitLiveSegment(segment, queue: queue, generation: sessionGeneration)
        guard admission != .drop else { return }
        if admission == .refine {
            let merged = await livePipeline.enqueueRefinementForTesting(
                WhisperQueueItem(uid: uid, pcmData: pcm, sherpaTextBackup: sherpaText)
            )
            if merged {
                handleLivePipelineEvent(.segmentMerged, generation: sessionGeneration)
                handleLivePipelineEvent(.status(await livePipeline.state()), generation: sessionGeneration)
                return
            }
        } else {
            await livePipeline.enqueueLLM(
                id: uid,
                text: sherpaText,
                sherpaText: sherpaText,
                forceBatch: !apiReady
            )
        }
        handleLivePipelineEvent(.segmentAccepted(segment, admission), generation: sessionGeneration)
        handleLivePipelineEvent(.status(await livePipeline.state()), generation: sessionGeneration)
    }

    private func applySpeakerLabels(_ labels: [UUID: String]) {
        guard !labels.isEmpty else { return }
        var changed = false

        for idx in dynamicItems.indices {
            if let label = labels[dynamicItems[idx].id],
               dynamicItems[idx].speakerID != label {
                dynamicItems[idx].speakerID = label
                persistLiveSegment(dynamicItems[idx])
                changed = true
            }
        }

        for idx in historyItems.indices {
            if let label = labels[historyItems[idx].id],
               historyItems[idx].speakerID != label {
                historyItems[idx].speakerID = label
                persistLiveSegment(historyItems[idx])
                changed = true
            }
        }

        if changed {
            refreshTranslationOnlyHistoryBlocks(forceAgnes: true)
            renderUI(force: true)
        }
    }

    private func persistLiveSegment(_ item: TranscriptionItem) {
        guard let timing = timedSegments[item.id], let context = sessionContext else { return }
        Task { [sessionCoordinator, context] in
            try? await sessionCoordinator?.upsert(
                context: context,
                id: item.id,
                startTime: timing.start,
                endTime: timing.end,
                draft: timing.draft,
                refined: item.english,
                speakerID: item.speakerID,
                status: item.isVisible && item.status != .dropped ? .succeeded : .cancelled
            )
        }
    }

    private func applyFinalLectureSpeakerFocus() {
        let samples = historyItems.compactMap { item -> LectureSpeakerSample? in
            guard item.isVisible,
                  let speakerID = item.speakerID,
                  let metrics = lectureMetricsByItemID[item.id]
            else { return nil }
            return LectureSpeakerSample(
                id: item.id,
                speakerID: speakerID,
                metrics: metrics
            )
        }
        let result = LectureSpeakerFocusReducer.reduce(samples: samples)
        guard !result.droppedIDs.isEmpty else { return }
        let dropped = Set(result.droppedIDs)
        for idx in historyItems.indices where dropped.contains(historyItems[idx].id) {
            historyItems[idx].isVisible = false
            historyItems[idx].status = .dropped
        }
        refreshTranslationOnlyHistoryBlocks(forceAgnes: true)
    }

    func enqueueLLMFormatCandidateForTesting(uid: UUID, text: String, sherpaText: String = "") async {
        await livePipeline.enqueueLLM(
            id: uid,
            text: text,
            sherpaText: sherpaText,
            forceBatch: !apiReady
        )
        handleLivePipelineEvent(.status(await livePipeline.state()), generation: sessionGeneration)
    }

    func flushPendingLLMFormatBatchForTesting(force: Bool = true) async {
        await livePipeline.flushPendingLLM(force: force)
        handleLivePipelineEvent(.status(await livePipeline.state()), generation: sessionGeneration)
    }

    func queuedLLMItemsForTesting() async -> [LLMQueueItem] {
        await livePipeline.queuedLLMItems()
    }

    private func enqueueLLMItem(
        uid: UUID,
        text: String,
        sherpaText: String = "",
        taskType: LLMTaskType
    ) {
        if let idx = dynamicItems.firstIndex(where: { $0.id == uid }) {
            dynamicItems[idx].english = text
            dynamicItems[idx].status = taskType == .format ? .llmFormatting : .llmAggregating
        }
        Task { [livePipeline] in
            await livePipeline.enqueueLLM(id: uid, text: text, sherpaText: sherpaText, taskType: taskType)
        }
        renderUI(force: true)
    }

    private func enqueueTranslation(uid: UUID, text: String) {
        Task { [livePipeline] in await livePipeline.enqueueTranslation(id: uid, text: text) }
    }

    // MARK: - Workers

    private func degradePendingWorkForFinalNote(_ pendingItems: [WhisperQueueItem]) {
        whisperQueueSize = 0

        let now = Date().timeIntervalSince1970
        for pending in pendingItems {
            guard let idx = dynamicItems.firstIndex(where: { $0.id == pending.uid }) else {
                continue
            }
            let text = pending.sherpaTextBackup.trimmingCharacters(in: .whitespacesAndNewlines)
            if whisperKitService.shouldDropASRSegment(text, isSessionEnding: true) {
                dynamicItems[idx].isVisible = false
                dynamicItems[idx].status = .dropped
                continue
            }
            dynamicItems[idx].english = text
            dynamicItems[idx].status = .done
            dynamicItems[idx].doneTime = now
            try? sessionRecoveryJournal.recordRefinement(uid: pending.uid, english: text)
        }

        for idx in dynamicItems.indices
        where dynamicItems[idx].isVisible &&
              dynamicItems[idx].status != .done &&
              dynamicItems[idx].status != .dropped {
            let text = dynamicItems[idx].english.trimmingCharacters(in: .whitespacesAndNewlines)
            if whisperKitService.shouldDropASRSegment(text, isSessionEnding: true) {
                dynamicItems[idx].isVisible = false
                dynamicItems[idx].status = .dropped
            } else {
                dynamicItems[idx].status = .done
                dynamicItems[idx].doneTime = now
                try? sessionRecoveryJournal.recordRefinement(
                    uid: dynamicItems[idx].id,
                    english: text
                )
            }
        }

        organizerQueue.removeAll()
        llmQueueSize = 0
        refinementLoadState = .normal
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
        removeAppleRealtimeTranslation(for: uid)
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
        persistLiveSegment(dynamicItems[idx])
        try? sessionRecoveryJournal.recordRefinement(uid: uid, english: text)
        dynamicItems[idx].doneTime = now
        if translationEnabled {
            dynamicItems[idx].status = .translating
            enqueueTranslation(uid: uid, text: text)
        } else {
            dynamicItems[idx].status = .done
        }
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

    private func handleResourcePressure(_ level: ResourcePressureLevel) {
        guard ResourcePressurePolicy.action(for: level) == .shedHeavyWork else { return }

        speakerDiarizationTask?.cancel()
        if isRecording {
            Task { [weak self, livePipeline] in
                let pending = await livePipeline.shedRefinementWork()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.degradePendingWorkForFinalNote(pending)
                    self.refinementLoadState = .protecting
                    self.queueNoteWrite()
                }
            }
        }
        Task { [speakerDiarizationService, whisperKitService] in
            await speakerDiarizationService.unloadModels()
            await whisperKitService.unloadModel()
        }
    }

    // MARK: - 结果处理

    func postProcessResult(uid: UUID, finalText: String, sourceIDs: [UUID]? = nil) {
        let consumedSourceIDs = sourceIDs ?? [uid]
        for sourceID in consumedSourceIDs where sourceID != uid {
            hideOrganizerItem(uid: sourceID)
        }

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
        persistLiveSegment(dynamicItems[idx])
        dynamicItems[idx].status = .organizing
        let now = Date().timeIntervalSince1970
        dynamicItems[idx].doneTime = now
        organizerQueue.append(OrganizerQueueItem(uid: uid, text: t, timestamp: now))
        renderUI(force: true)
    }

    func applyTranslation(uid: UUID, zhText: String) {
        removeAppleRealtimeTranslation(for: uid)
        let now = Date().timeIntervalSince1970
        if let idx = dynamicItems.firstIndex(where: { $0.id == uid }) {
            dynamicItems[idx].chinese = zhText
            try? sessionRecoveryJournal.recordTranslation(uid: uid, chinese: zhText)
            dynamicItems[idx].status = .done
            dynamicItems[idx].doneTime = now
            renderUI(force: true)
            return
        }

        guard let idx = historyItems.firstIndex(where: { $0.id == uid }) else { return }
        historyItems[idx].chinese = zhText
        try? sessionRecoveryJournal.recordTranslation(uid: uid, chinese: zhText)
        historyItems[idx].status = .done
        historyItems[idx].doneTime = now
        queueNoteWrite()
        maybeRequestLiveSummary()
        renderUI(force: true)
    }

    private func markAsDropped(uid: UUID) {
        removeAppleRealtimeTranslation(for: uid)
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
            clearDraftAppleTranslation()
        }

        if movedToHistory {
            queueNoteWrite()
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
            queueNoteWrite()
        }
        refreshTranslationOnlyHistoryBlocks(forceAgnes: false)
    }

    private func refreshTranslationOnlyHistoryBlocks(forceAgnes: Bool) {
        let fallback = TranslationOnlyHistoryBuilder.blocks(from: historyItems)
        let items = historyItems
            .filter {
                $0.isVisible &&
                !$0.isSystemMessage &&
                $0.status == .done &&
                !($0.chinese ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map {
                AgnesTranslationOnlyItem(
                    id: $0.id.uuidString,
                    speakerID: $0.speakerID,
                    chinese: $0.chinese?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            }
        let signature = items
            .map { "\($0.id)|\($0.speakerID ?? "")|\($0.chinese)" }
            .joined(separator: "\n")

        if signature != lastTranslationOnlyDisplaySignature {
            translationOnlyHistoryBlocks = fallback
            lastTranslationOnlyDisplaySignature = signature
        }

        guard historyDisplayMode == .translationOnly,
              let credential = agnesOrganizerCredential(),
              !items.isEmpty
        else { return }

        guard forceAgnes || signature != lastTranslationOnlyOrganizationSignature else { return }
        lastTranslationOnlyOrganizationSignature = signature

        translationOnlyOrganizationTask?.cancel()
        let service = agnesHistoryOrganizerService
        let course = currentCourse
        translationOnlyOrganizationTask = Task { [weak self] in
            let blocks = await service.organizeTranslationOnlyParagraphs(
                items: items,
                credential: credential,
                course: course
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.lastTranslationOnlyOrganizationSignature == signature,
                      let blocks
                else { return }
                self.translationOnlyHistoryBlocks = blocks
            }
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
        removeAppleRealtimeTranslation(for: item.id)
        item.zone = .history
        if item.status == .translating {
            item.status = .done
            if item.doneTime == 0 {
                item.doneTime = Date().timeIntervalSince1970
            }
        }
        historyItems.append(item)
        dynamicItems.remove(at: index)
        noteHistoryItemMovedForAgnesOrganization()
        maybeRequestLiveSummary()
    }

    private func noteHistoryItemMovedForAgnesOrganization() {
        _ = applyLocalHistoryCleanup()
        historyItemsAddedSinceAgnesOrganization += 1
        scheduleAgnesHistoryOrganizationIfNeeded()
    }

    @discardableResult
    private func applyLocalHistoryCleanup() -> Bool {
        let before = historyCleanupSnapshot()
        historyItems = HistoryWallCleaner.clean(historyItems)
        return before != historyCleanupSnapshot()
    }

    private func historyCleanupSnapshot() -> [String] {
        historyItems.map {
            "\($0.id.uuidString)|\($0.english)|\($0.chinese ?? "")|\($0.status.rawValue)|\($0.isVisible)"
        }
    }

    private func scheduleAgnesHistoryOrganizationIfNeeded(force: Bool = false) {
        guard force || historyItemsAddedSinceAgnesOrganization >= agnesOrganizationTriggerCount else { return }
        guard let credential = agnesOrganizerCredential() else { return }

        if isAgnesOrganizing {
            pendingAgnesOrganization = true
            return
        }

        let snapshot = agnesOrganizerItems(finalPass: false)
        guard snapshot.count >= 2 else { return }

        historyItemsAddedSinceAgnesOrganization = 0
        isAgnesOrganizing = true
        pendingAgnesOrganization = false
        let course = currentCourse
        let service = agnesHistoryOrganizerService

        agnesOrganizationTask = Task { [weak self] in
            let updates = await service.organizeHistory(
                items: snapshot,
                credential: credential,
                course: course,
                polishTranslations: false
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finishAgnesHistoryOrganization(updates: updates)
            }
        }
    }

    private func finishAgnesHistoryOrganization(updates: [AgnesHistoryOrganizerUpdate]?) {
        isAgnesOrganizing = false
        agnesOrganizationTask = nil
        if let updates, applyAgnesHistoryUpdates(updates) {
            queueNoteWrite()
            renderUI(force: true)
        }

        if pendingAgnesOrganization {
            pendingAgnesOrganization = false
            scheduleAgnesHistoryOrganizationIfNeeded(force: true)
        }
    }

    private func runFinalAgnesHistoryOrganizationIfAvailable() async {
        guard let credential = agnesOrganizerCredential() else { return }
        _ = applyLocalHistoryCleanup()
        let snapshot = agnesOrganizerItems(finalPass: true)
        guard !snapshot.isEmpty else { return }

        let updates = await agnesHistoryOrganizerService.organizeHistory(
            items: snapshot,
            credential: credential,
            course: currentCourse,
            polishTranslations: true
        )
        guard !Task.isCancelled else { return }
        if let updates, applyAgnesHistoryUpdates(updates) {
            queueNoteWrite()
            renderUI(force: true)
        }
    }

    private func agnesOrganizerItems(finalPass: Bool) -> [AgnesHistoryOrganizerItem] {
        let items = historyItems.filter {
            $0.zone == .history &&
                $0.isVisible &&
                !$0.isSystemMessage &&
                $0.status != .dropped &&
                !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let selected = finalPass ? items : Array(items.suffix(agnesRealtimeWindowSize))
        return selected.map {
            AgnesHistoryOrganizerItem(
                id: $0.id.uuidString,
                english: $0.english,
                chinese: $0.chinese
            )
        }
    }

    @discardableResult
    private func applyAgnesHistoryUpdates(_ updates: [AgnesHistoryOrganizerUpdate]) -> Bool {
        var changed = false
        for update in updates {
            guard let id = UUID(uuidString: update.id),
                  let idx = historyItems.firstIndex(where: { $0.id == id }),
                  !historyItems[idx].isSystemMessage
            else { continue }

            if update.drop == true {
                if historyItems[idx].isVisible || historyItems[idx].status != .dropped {
                    historyItems[idx].isVisible = false
                    historyItems[idx].status = .dropped
                    changed = true
                }
                continue
            }

            if let english = update.english?.trimmingCharacters(in: .whitespacesAndNewlines),
               !english.isEmpty,
               english != historyItems[idx].english {
                historyItems[idx].english = english
                changed = true
            }

            if let chinese = update.chinese?.trimmingCharacters(in: .whitespacesAndNewlines),
               !chinese.isEmpty,
               historyItems[idx].chinese != nil,
               chinese != historyItems[idx].chinese {
                historyItems[idx].chinese = chinese
                changed = true
            }
        }

        return applyLocalHistoryCleanup() || changed
    }

    private func resetAgnesOrganizationState() {
        agnesOrganizationTask?.cancel()
        agnesOrganizationTask = nil
        isAgnesOrganizing = false
        pendingAgnesOrganization = false
        historyItemsAddedSinceAgnesOrganization = 0
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

    nonisolated static func scanNoteRecords(in directory: URL) -> [NoteRecord] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url -> NoteRecord? in
            guard let format = NoteFileFormat.fromFileExtension(url.pathExtension),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }

            return NoteRecord(
                url: url.standardizedFileURL,
                fileName: url.lastPathComponent,
                format: format,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                fileSize: Int64(values.fileSize ?? 0),
                previewSummary: notePreviewSummary(for: url)
            )
        }
        .sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    nonisolated private static func notePreviewSummary(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let text = String(data: data.prefix(2048), encoding: .utf8)
        else { return nil }

        let compact = text
            .components(separatedBy: .newlines)
            .compactMap { notePreviewSummaryLine(from: $0, format: NoteFileFormat.fromFileExtension(url.pathExtension)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(140))
    }

    nonisolated private static func notePreviewSummaryLine(from line: String, format: NoteFileFormat?) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard format == .markdown else { return trimmed }
        if trimmed == "---" { return nil }
        if trimmed.hasPrefix("#") {
            return String(trimmed.drop { $0 == "#" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    func chooseNoteDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择同声传译笔记保存位置"
        panel.directoryURL = Self.noteDirectory(from: noteDirectoryPath)

        if panel.runModal() == .OK, let selected = panel.url {
            noteDirectoryPath = selected.standardizedFileURL.path
            refreshNoteRecords()
        }
    }

    func resetNoteDirectoryToDesktop() {
        noteDirectoryPath = ""
        refreshNoteRecords()
    }

    func retryNoteWrite() {
        Task { [weak self] in
            guard let self else { return }
            if case .written = await writeLatestNote() {
                guard finalPersistenceSucceeded else {
                    statusMessage = meetingLibraryStatus
                    liveSummaryStatus = "会话保存失败，恢复数据已保留"
                    renderUI(force: true)
                    return
                }
                try? sessionRecoveryJournal.markCompleted()
                sessionRecoveryJournal.close()
                sessionAudioStore.cleanupCurrentSession()
                statusMessage = "笔记已完成"
                liveSummaryStatus = "已写入笔记"
                refreshNoteRecords()
                renderUI(force: true)
            }
        }
    }

    private func setupFilePath() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        let dateStr = df.string(from: Date())
        guard let course = currentCourse else { return }
        let directory = Self.ensureWritableNoteDirectory(noteDirectoryPath)
        filePath = directory.appendingPathComponent(Self.noteFileName(course: course, dateString: dateStr, format: noteFileFormat))
    }

    nonisolated static func noteFileName(course: CourseSubject, dateString: String, format: NoteFileFormat) -> String {
        "\(course.abbrev)_Session_\(dateString).\(format.fileExtension)"
    }

    nonisolated static func noteDirectory(from storedPath: String) -> URL {
        let trimmed = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultNoteDirectory() }
        return expandedUserPath(trimmed).standardizedFileURL
    }

    nonisolated private static func ensureWritableNoteDirectory(_ storedPath: String) -> URL {
        let candidate = noteDirectory(from: storedPath)
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            return candidate
        } catch {
            let fallback = defaultNoteDirectory()
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
    }

    nonisolated private static func defaultNoteDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    nonisolated private static func expandedUserPath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func queueNoteWrite() {
        guard let write = makeNoteWrite() else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await noteWriteCoordinator.write(content: write.content, to: write.url, revision: write.revision)
            handleNoteWriteResult(result)
        }
    }

    private func writeLatestNote() async -> NoteWriteResult {
        guard let write = makeNoteWrite() else {
            let url = filePath ?? Self.defaultNoteDirectory()
            return .failed(url, "缺少课程或笔记路径")
        }
        let result = await noteWriteCoordinator.write(content: write.content, to: write.url, revision: write.revision)
        handleNoteWriteResult(result)
        return result
    }

    private func makeNoteWrite() -> (content: String, url: URL, revision: UInt64)? {
        guard let course = currentCourse, let filePath else { return nil }
        noteWriteRevision &+= 1
        return (
            SessionNoteRenderer.render(
                course: course,
                translationEnabled: translationEnabled,
                items: historyItems + dynamicItems,
                finalSummary: liveSummaryText,
                speakerAliases: currentSessionSpeakerAliases(),
                format: noteFileFormat
            ),
            filePath,
            noteWriteRevision
        )
    }

    private func handleNoteWriteResult(_ result: NoteWriteResult) {
        switch result {
        case .written:
            noteWriteError = nil
        case .skipped:
            break
        case .failed(let url, let detail):
            noteWriteError = "无法写入 \(url.path)：\(detail)"
            statusMessage = noteWriteError ?? "笔记写入失败"
        }
    }

    private func currentSessionSpeakerAliases() -> [String: String] {
        let meetingID = livePersistenceSession?.meetingID ?? selectedMeeting?.id
        guard let meetingID else { return selectedMeetingSpeakerAliases }
        return (try? meetingLibraryController?.aliases(meetingID: meetingID)) ?? selectedMeetingSpeakerAliases
    }

    private func maybeRequestLiveSummary() {
        guard liveSummaryReady,
              !isFinalizingSession,
              !isLiveSummaryUpdating,
              let credential = LLMProviderCatalog.omniRouteSummaryCredential(
                from: providerAPIKeys,
                baseURL: omniRouteBaseURL
              )
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
        let summaryService = omniRouteSummaryService
        guard let template = summaryWorkspace?.selectedTemplate else { return }
        guard let persistenceSession = livePersistenceSession, let summaryWorkspace else { return }
        isLiveSummaryUpdating = true
        liveSummaryStatus = "总结中"

        summaryTask = Task { [weak self] in
            let revision = try? await summaryWorkspace.generate(
                meetingID: persistenceSession.meetingID,
                transcriptRevisionID: persistenceSession.revisionID,
                translationRevisionID: nil,
                template: template,
                provider: credential.provider.displayName,
                model: credential.provider.modelName,
                previousSummary: previousSummary,
                sourceContent: newContent,
                isFinal: false
            ) { prompt in
                try await summaryService.summarize(prompt: prompt, credential: credential, isFinal: false)
            }
            let summary = revision?.status == .succeeded ? revision?.body : nil
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLiveSummaryUpdating = false
                self.summaryTask = nil
                if let summary {
                    self.liveSummaryText = summary
                    self.liveSummaryStatus = "已更新"
                    self.liveSummaryCursor.markSummarized(upTo: countAtRequest)
                    self.queueNoteWrite()
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
        let speakerPrefix: String = {
            guard let speakerID = item.speakerID else { return "" }
            let aliases: [String: String]
            if let session = livePersistenceSession {
                aliases = (try? meetingLibraryController?.aliases(meetingID: session.meetingID)) ?? [:]
            } else { aliases = selectedMeetingSpeakerAliases }
            return "\(aliases[speakerID] ?? SpeakerDisplayName.displayName(for: speakerID))："
        }()
        if translationEnabled, block.chineseLines.isEmpty, !includeUntranslated {
            return []
        }

        if block.canInterleaveLineByLine {
            return block.englishLines.indices.map { idx in
                LiveSummarySourceUnit(text: """
                \(speakerPrefix)英文原文：\(block.englishLines[idx])
                中文译文：\(block.chineseLines[idx])
                """)
            }
        }

        let english = block.englishLines.joined(separator: " ")
        let chinese = block.chineseLines.joined(separator: " ")
        if translationEnabled {
            guard !chinese.isEmpty else {
                return includeUntranslated ? [LiveSummarySourceUnit(text: "\(speakerPrefix)英文原文：\(english)")] : []
            }
            return [LiveSummarySourceUnit(text: """
            \(speakerPrefix)英文原文：\(english)
            中文译文：\(chinese)
            """)]
        }
        return [LiveSummarySourceUnit(text: "\(speakerPrefix)英文原文：\(english)")]
    }

    private func groqCoreCredential() -> LLMProviderCredential? {
        guard apiReady else { return nil }
        return LLMProviderCatalog.groqCoreCredential(
            from: providerAPIKeys,
            selectedModelNames: selectedProviderModelNames
        )
    }

    private func agnesOrganizerCredential() -> LLMProviderCredential? {
        guard providerCheckResults.first(where: { $0.provider.id == .agnes })?.passed == true else {
            return nil
        }
        return LLMProviderCatalog.agnesOrganizerCredential(
            from: providerAPIKeys,
            selectedModelNames: selectedProviderModelNames
        )
    }

    private func groqAPIKey() -> String {
        providerAPIKeys[.groq, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistAudioInputSelection() {
        selectedAudioCaptureSource = Self.mirroredAudioCaptureSource(for: audioInputSelection)
        audioInputSelectionStorage = audioInputSelection.storageValue
        audioCaptureSourceStorage = selectedAudioCaptureSource.storageValue
        availableAudioCaptureSources = Self.supportedAudioCaptureSources(selected: selectedAudioCaptureSource)
    }

    private static func mirroredAudioCaptureSource(for selection: AudioInputSelection) -> AudioCaptureSource {
        selection.systemAudioEnabled ? .systemAudio : .microphone
    }

    private static func supportedAudioCaptureSources(selected: AudioCaptureSource) -> [AudioCaptureSource] {
        let normalizedSelected = normalizeAudioCaptureSource(selected)
        var sources = [AudioCaptureSource.microphone, .systemAudio]
        if !sources.contains(normalizedSelected) {
            sources.append(normalizedSelected)
        }
        return sources.sorted { lhs, rhs in
            rankAudioSource(lhs) < rankAudioSource(rhs)
        }
    }

    private static func normalizeAudioCaptureSource(_ source: AudioCaptureSource) -> AudioCaptureSource {
        switch source.kind {
        case .applicationAudio:
            return .systemAudio
        case .microphone, .systemAudio:
            return source
        }
    }

    private static func rankAudioSource(_ source: AudioCaptureSource) -> String {
        switch source.kind {
        case .microphone:
            return "0"
        case .systemAudio:
            return "1"
        case .applicationAudio:
            return "9"
        }
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

func groqWhisperAPI(pcmData: Data, apiKey: String) async -> String? {
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
