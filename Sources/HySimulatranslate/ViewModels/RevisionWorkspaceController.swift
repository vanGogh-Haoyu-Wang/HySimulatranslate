import Foundation

@MainActor final class RevisionWorkspaceController {
    private let transcripts: TranscriptRepository
    private let meetings: MeetingRepository
    init(database: AppDatabase) { transcripts = TranscriptRepository(database: database); meetings = MeetingRepository(database: database) }
    func selectTranscript(_ id: UUID, meetingID: UUID) throws -> MeetingRecord? { try transcripts.setCurrentTranscriptRevision(id, for: meetingID); return try meetings.fetch(id: meetingID) }
    func selectTranslation(_ id: UUID, meetingID: UUID) throws { try transcripts.setCurrentTranslationRevision(id, for: meetingID) }
    func translations(_ id: UUID) throws -> [UUID: String] { Dictionary(uniqueKeysWithValues: try transcripts.fetchTranslations(revisionID: id).map { ($0.segmentID, $0.text) }) }
}
