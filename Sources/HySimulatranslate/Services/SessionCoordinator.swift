import Foundation

@MainActor
final class SessionCoordinator {
    struct Context: Equatable, Sendable {
        let generation: UInt64
        let persistence: LivePersistenceSession
    }
    private let persistence: LiveSessionPersistence
    private let modelUsage: ModelUsageCoordinator
    private let sessionsRoot: URL
    private var generation: UInt64 = 0
    private var context: Context?
    private var pipeline: SessionAudioPipeline?
    private var finalizeTask: Task<SessionAudioAssets?, Never>?
    private var recordingLease: ModelResourceLease?

    init(database: AppDatabase, modelUsage: ModelUsageCoordinator, sessionsRoot: URL) {
        persistence = LiveSessionPersistence(database: database); self.modelUsage = modelUsage; self.sessionsRoot = sessionsRoot
    }

    func begin(title: String, subjectID: UUID?, enabledSources: Set<AudioChunkSource>, noteURL: URL? = nil) async throws -> Context {
        generation &+= 1
        let lease = try modelUsage.begin(owner: "live recording", resourceIDs: ["sherpa", "vad", "whisperkit", "speakerkit"])
        do {
            let session = try await persistence.start(title: title, subjectID: subjectID, exportedNotePath: noteURL?.path)
            let pipeline = try SessionAudioPipeline(sessionID: session.meetingID, rootDirectory: sessionsRoot, enabledSources: enabledSources)
            let context = Context(generation: generation, persistence: session)
            self.pipeline = pipeline; self.context = context; recordingLease = lease
            return context
        } catch { lease.release(); throw error }
    }

    func accepts(_ context: Context) -> Bool { self.context == context }
    func accept(_ chunk: AudioChunk, context: Context) throws -> [Float] {
        guard accepts(context), let pipeline else { throw LiveSessionPersistenceError.staleSession }
        return try pipeline.accept(chunk)
    }
    func upsert(context: Context, id: UUID, startTime: TimeInterval, endTime: TimeInterval, draft: String?, refined: String, speakerID: String?, status: PersistenceStatus = .succeeded) async throws {
        guard accepts(context) else { throw LiveSessionPersistenceError.staleSession }
        try await persistence.upsertSegment(session: context.persistence, id: id, startTime: startTime, endTime: endTime, draft: draft, refined: refined, speakerID: speakerID, status: status)
    }
    func finalizeAudio(_ context: Context) {
        guard accepts(context), let pipeline else { return }; self.pipeline = nil
        finalizeTask = Task { try? await Task.detached(priority: .utility) { try pipeline.finalize() }.value }
    }
    func finish(_ context: Context, finalSegments: [(UUID, TimeInterval, TimeInterval, String?, String, String?, PersistenceStatus)]) async throws {
        guard accepts(context) else { throw LiveSessionPersistenceError.staleSession }
        defer { cleanup() }
        do {
            for segment in finalSegments {
                try await persistence.upsertSegment(session: context.persistence, id: segment.0, startTime: segment.1, endTime: segment.2, draft: segment.3, refined: segment.4, speakerID: segment.5, status: segment.6)
            }
            let assets = await finalizeTask?.value
            if let assets { try await persistence.finish(session: context.persistence, assets: assets, sampleRate: 16_000) }
            else { try await persistence.fail(session: context.persistence) }
        } catch {
            try? await persistence.fail(session: context.persistence)
            throw error
        }
    }
    func fail(_ context: Context) async {
        guard accepts(context) else { return }
        defer { cleanup() }
        if let pipeline { self.pipeline = nil; _ = try? await Task.detached { try pipeline.finalize() }.value }
        try? await persistence.fail(session: context.persistence)
    }
    func abort(_ context: Context) async throws {
        guard accepts(context) else { throw LiveSessionPersistenceError.staleSession }
        defer { cleanup() }
        generation &+= 1
        if let pipeline { self.pipeline = nil; _ = try? await Task.detached { try pipeline.finalize() }.value }
        try await persistence.abort(session: context.persistence)
    }
    private func cleanup() { context = nil; finalizeTask = nil; recordingLease?.release(); recordingLease = nil }
}
