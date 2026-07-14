import Foundation

@MainActor
final class ImportWorkspaceController: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isWorking = false
    @Published private(set) var pendingJobs: [ImportJobRecord] = []
    @Published private(set) var resumedProgress: [UUID: Double] = [:]
    private let database: AppDatabase
    private let meetings: MeetingRepository
    private let transcripts: TranscriptRepository
    private let jobs: ImportJobRepository
    private let translationService: TranslationService
    private let appleTranslator: any AppleSystemTranslating
    private let modelUsage: ModelUsageCoordinator
    private let noteDirectory: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(database: AppDatabase, translationService: TranslationService, appleTranslator: any AppleSystemTranslating, modelUsage: ModelUsageCoordinator, noteDirectory: URL) {
        self.database = database; meetings = MeetingRepository(database: database); transcripts = TranscriptRepository(database: database)
        jobs = ImportJobRepository(database: database); self.translationService = translationService; self.appleTranslator = appleTranslator
        self.modelUsage = modelUsage; self.noteDirectory = noteDirectory
        _ = try? jobs.recoverInterruptedJobs(); pendingJobs = (try? jobs.fetchProcessing()) ?? []
    }

    private func coordinator(model: String, credential: LLMProviderCredential?) async throws -> ImportCoordinator {
        let whisper = WhisperKitService(model: model)
        guard await whisper.configure(allowDownload: false) else { throw AudioImportError.unreadable("所选 WhisperKit 模型尚未安装：\(model)") }
        let translator = TranslationServiceImportAdapter(service: translationService, appleTranslator: appleTranslator, credential: credential)
        let post = ImportedAudioPostProcessor(transcripts: transcripts, speakers: SpeakerRepository(database: database), exportDirectory: noteDirectory)
        return ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs, transcriber: WhisperKitImportTranscriber(service: whisper), translator: translator, postProcessor: post, modelUsage: modelUsage)
    }

    private func translationCoordinator(credential: LLMProviderCredential?) -> ImportCoordinator {
        let translator = TranslationServiceImportAdapter(service: translationService, appleTranslator: appleTranslator, credential: credential)
        return ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs, translator: translator, modelUsage: modelUsage)
    }

    func importAudio(from source: URL, options: ImportOptions, sessionsRoot: URL, credential: LLMProviderCredential?) async throws -> MeetingRecord {
        isWorking = true; progress = 0; defer { isWorking = false }
        let meeting = try meetings.create(title: source.deletingPathExtension().lastPathComponent, source: .imported, subjectID: options.subjectID)
        let directory = sessionsRoot.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        var completed = false
        defer {
            if !completed {
                try? meetings.purge(id: meeting.id)
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let managed = directory.appendingPathComponent("imported-original").appendingPathExtension(source.pathExtension.lowercased())
        let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: managed.path) { try FileManager.default.removeItem(at: managed) }
        try FileManager.default.copyItem(at: source, to: managed)
        let metadata = try AudioImportDecoder().inspectMetadata(url: managed)
        try meetings.saveAudioAsset(.init(meetingID: meeting.id, track: .imported, path: managed.path, format: managed.pathExtension.lowercased(), sampleRate: metadata.sampleRate, channelCount: metadata.channelCount, duration: metadata.duration, status: .ready))
        let coordinator = try await coordinator(model: options.whisperModel, credential: credential)
        let job = try await coordinator.importAudio(from: managed, meetingID: meeting.id, options: options) { [weak self] value in Task { @MainActor in self?.progress = value } }
        guard job.status == .succeeded else { throw AudioImportError.unreadable(job.errorMessage ?? "导入未完成") }
        completed = true
        return try meetings.fetch(id: meeting.id) ?? meeting
    }

    func retranscribe(meeting: MeetingRecord, audioURL: URL, options: ImportOptions, credential: LLMProviderCredential?) async throws -> MeetingRecord {
        isWorking = true; defer { isWorking = false }
        let coordinator = try await coordinator(model: options.whisperModel, credential: credential)
        _ = try await coordinator.importAudio(from: audioURL, meetingID: meeting.id, options: options) { [weak self] value in Task { @MainActor in self?.progress = value } }
        return try meetings.fetch(id: meeting.id) ?? meeting
    }

    func retranslate(meeting: MeetingRecord, transcriptRevisionID: UUID, credential: LLMProviderCredential?) async throws -> MeetingRecord {
        let coordinator = translationCoordinator(credential: credential)
        let revision = try await coordinator.retranslate(meetingID: meeting.id, transcriptRevisionID: transcriptRevisionID, targetLanguage: "zh", provider: "automatic", model: "translation-fallback")
        guard revision.status == .succeeded else { throw AudioImportError.unreadable(revision.errorMessage ?? "重新翻译失败") }
        return try meetings.fetch(id: meeting.id) ?? meeting
    }

    func resume(_ job: ImportJobRecord, credential: LLMProviderCredential?) async {
        guard let options = try? JSONDecoder().decode(ImportOptions.self, from: job.optionsJSON),
              let coordinator = try? await coordinator(model: options.whisperModel, credential: credential) else { return }
        _ = try? await coordinator.resume(job) { [weak self] value in Task { @MainActor in self?.resumedProgress[job.id] = value } }
        pendingJobs = (try? jobs.fetchProcessing()) ?? []; resumedProgress[job.id] = nil; tasks[job.id] = nil
    }
    func startResume(_ job: ImportJobRecord, credential: LLMProviderCredential?) {
        guard tasks[job.id] == nil else { return }; resumedProgress[job.id] = job.progress
        tasks[job.id] = Task { [weak self] in await self?.resume(job, credential: credential) }
    }
    func cancel(jobID: UUID) { tasks[jobID]?.cancel() }
}
