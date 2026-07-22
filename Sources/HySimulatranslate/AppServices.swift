import Foundation

@MainActor final class AppServices {
    let modelResources: ModelResourceService
    let modelUsage: ModelUsageCoordinator
    let playback = MeetingPlaybackController()
    let selfCheck: SelfCheckCoordinator
    init(modelResources: ModelResourceService, modelUsage: ModelUsageCoordinator) {
        self.modelResources = modelResources; self.modelUsage = modelUsage; selfCheck = SelfCheckCoordinator(modelUsage: modelUsage)
    }
}

final class SelfCheckCoordinator {
    private let modelUsage: ModelUsageCoordinator
    init(modelUsage: ModelUsageCoordinator) { self.modelUsage = modelUsage }
    func beginModelLoading() throws -> ModelResourceLease { try modelUsage.begin(owner: "model loading", resourceIDs: ["sherpa", "vad", "whisperkit", "speakerkit"]) }
}

@MainActor
struct WorkspaceCompositionRoot {
    struct Workspace {
        let meetingLibrary: MeetingLibraryController
        let imports: ImportWorkspaceController
        let sessions: SessionCoordinator
        let summaries: SummaryWorkspaceController
        let revisions: RevisionWorkspaceController
    }

    static func compose(database: AppDatabase, app: AppServices, translationService: TranslationService, appleTranslator: any AppleSystemTranslating, noteDirectory: URL, sessionsRoot: URL, playback: MeetingPlaybackController) -> Workspace {
        Workspace(
            meetingLibrary: MeetingLibraryController(database: database, playback: playback),
            imports: ImportWorkspaceController(database: database, translationService: translationService, appleTranslator: appleTranslator, modelUsage: app.modelUsage, noteDirectory: noteDirectory),
            sessions: SessionCoordinator(database: database, modelUsage: app.modelUsage, sessionsRoot: sessionsRoot),
            summaries: SummaryWorkspaceController(database: database),
            revisions: RevisionWorkspaceController(database: database)
        )
    }

    nonisolated static func prepare(noteDirectory: URL) throws -> (AppDatabase, [MeetingRecord], [UUID]) {
        let database = try AppDatabase.open(); let meetings = MeetingRepository(database: database)
        if FileManager.default.fileExists(atPath: noteDirectory.path) { _ = try meetings.indexLegacyNotes(in: noteDirectory) }
        _ = try meetings.reconcileLegacyExports()
        let purged = try meetings.purgeDeleted(olderThan: Date().addingTimeInterval(-30 * 24 * 60 * 60))
        return (database, try meetings.fetchActive(), purged)
    }
}
