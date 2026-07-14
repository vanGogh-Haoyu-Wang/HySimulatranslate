import Foundation

@MainActor
final class MeetingLibraryController {
    struct Selection {
        let meeting: MeetingRecord
        let segments: [TranscriptSegmentRecord]
        let revisions: [TranscriptRevisionRecord]
        let translationRevisions: [TranslationRevisionRecord]
        let translations: [UUID: String]
        let audioURL: URL?
        let speakerAliases: [String: String]
    }

    let database: AppDatabase
    private let meetings: MeetingRepository
    private let transcripts: TranscriptRepository
    let playback: MeetingPlaybackController
    private(set) var selectedMeeting: MeetingRecord?

    convenience init(database: AppDatabase) {
        self.init(database: database, playback: MeetingPlaybackController())
    }

    init(database: AppDatabase, playback: MeetingPlaybackController) {
        self.database = database
        meetings = MeetingRepository(database: database)
        transcripts = TranscriptRepository(database: database)
        self.playback = playback
    }

    func indexLegacyNotes(in directory: URL) throws -> Int { try meetings.indexLegacyNotes(in: directory) }
    func purgeDeleted(olderThan date: Date) throws -> [UUID] { try meetings.purgeDeleted(olderThan: date) }
    func refresh() throws -> [MeetingRecord] { try meetings.fetchActive() }
    func fetch(id: UUID) throws -> MeetingRecord? { try meetings.fetch(id: id) }
    func createMeeting(title: String, source: MeetingSource, subjectID: UUID?) throws -> MeetingRecord {
        try meetings.create(title: title, source: source, subjectID: subjectID)
    }
    func saveAudioAsset(_ asset: AudioAssetRecord) throws { try meetings.saveAudioAsset(asset) }

    func select(_ meeting: MeetingRecord) throws -> Selection {
        playback.unload()
        selectedMeeting = meeting
        let revisions = try transcripts.fetchRevisions(meetingID: meeting.id)
        let translationRevisions = try transcripts.fetchTranslationRevisions(meetingID: meeting.id)
        let segments = try meeting.currentTranscriptRevisionID.map { try transcripts.fetchSegments(revisionID: $0) } ?? []
        let translations = try meeting.currentTranslationRevisionID.map {
            Dictionary(uniqueKeysWithValues: try transcripts.fetchTranslations(revisionID: $0).map { ($0.segmentID, $0.text) })
        } ?? [:]
        let asset = try meetings.fetchAudioAssets(meetingID: meeting.id).first {
            ($0.track == .mixed || $0.track == .imported) && FileManager.default.fileExists(atPath: $0.path)
        }
        let audioURL = asset.map { URL(fileURLWithPath: $0.path) }
        if let audioURL { try playback.load(url: audioURL, segments: segments) }
        let aliases = try SpeakerRepository(database: database).aliases(meetingID: meeting.id)
        return Selection(meeting: meeting, segments: segments, revisions: revisions, translationRevisions: translationRevisions, translations: translations, audioURL: audioURL, speakerAliases: aliases)
    }

    func softDelete(_ meeting: MeetingRecord) throws {
        try meetings.softDelete(id: meeting.id)
        if selectedMeeting?.id == meeting.id { clearSelection() }
    }
    func clearSelection() { playback.unload(); selectedMeeting = nil }
    func setAlias(meetingID: UUID, speakerID: String, displayName: String) throws -> [String: String] {
        let speakers = SpeakerRepository(database: database)
        try speakers.setAlias(meetingID: meetingID, speakerID: speakerID, displayName: displayName)
        return try speakers.aliases(meetingID: meetingID)
    }
    func aliases(meetingID: UUID) throws -> [String: String] { try SpeakerRepository(database: database).aliases(meetingID: meetingID) }
    func setCurrentTranscript(_ revisionID: UUID, meetingID: UUID) throws { try transcripts.setCurrentTranscriptRevision(revisionID, for: meetingID) }
    func setCurrentTranslation(_ revisionID: UUID, meetingID: UUID) throws { try transcripts.setCurrentTranslationRevision(revisionID, for: meetingID) }
}
