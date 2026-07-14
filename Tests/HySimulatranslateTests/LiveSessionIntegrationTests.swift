import Foundation
import Testing
@testable import HySimulatranslate

@Suite("Live session persistence integration")
struct LiveSessionIntegrationTests {
    @Test("start creates a draft meeting and a successful current live revision")
    func startCreatesMeetingAndRevision() async throws {
        let database = try AppDatabase.inMemory()
        let integration = LiveSessionPersistence(database: database)
        let session = try await integration.start(title: "Physics", subjectID: UUID())
        let meeting = try MeetingRepository(database: database).fetch(id: session.meetingID)
        #expect(meeting?.status == .draft)
        #expect(meeting?.currentTranscriptRevisionID == session.revisionID)
        let revisions = try TranscriptRepository(database: database).fetchRevisions(meetingID: session.meetingID)
        #expect(revisions.count == 1)
        #expect(revisions.first?.status == .succeeded)
    }

    @Test("timed segment updates preserve identity and sequence")
    func upsertsTimedSegment() async throws {
        let database = try AppDatabase.inMemory()
        let integration = LiveSessionPersistence(database: database)
        let session = try await integration.start(title: "Physics", subjectID: nil)
        let id = UUID()
        try await integration.upsertSegment(id: id, startTime: 1.25, endTime: 2.75, draft: "draft", refined: "draft", speakerID: nil)
        try await integration.upsertSegment(id: id, startTime: 1.25, endTime: 2.75, draft: "draft", refined: "refined", speakerID: "speaker-1")
        let segments = try TranscriptRepository(database: database).fetchSegments(revisionID: session.revisionID)
        #expect(segments.count == 1)
        #expect(segments[0].id == id)
        #expect(segments[0].sequence == 0)
        #expect(segments[0].startTime == 1.25)
        #expect(segments[0].endTime == 2.75)
        #expect(segments[0].refinedText == "refined")
        #expect(segments[0].speakerID == "speaker-1")
    }

    @Test("finish saves playable assets and makes the meeting ready")
    func finishMarksMeetingReady() async throws {
        let database = try AppDatabase.inMemory()
        let integration = LiveSessionPersistence(database: database)
        let session = try await integration.start(title: "Physics", subjectID: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("mixed.wav")
        try Data([0, 1, 2]).write(to: wav)
        let assets = SessionAudioAssets(sessionDirectory: root, microphoneWAV: root.appendingPathComponent("microphone.wav"), systemWAV: nil, mixedWAV: wav, m4aURL: nil, totalSamples: 32_000)
        try await integration.finish(session: session, assets: assets, sampleRate: 16_000)
        let meeting = try MeetingRepository(database: database).fetch(id: session.meetingID)
        #expect(meeting?.status == .ready)
        #expect(meeting?.duration == 2)
        let savedAssets = try MeetingRepository(database: database).fetchAudioAssets(meetingID: session.meetingID)
        #expect(savedAssets.contains { $0.track == .mixed && $0.path == wav.path && $0.status == .ready })
    }

    @Test("stale session writes cannot mutate the current session")
    func staleSessionWritesAreRejected() async throws {
        let database = try AppDatabase.inMemory()
        let integration = LiveSessionPersistence(database: database)
        let first = try await integration.start(title: "First", subjectID: nil)
        try await integration.abort(session: first)
        _ = try await integration.start(title: "Second", subjectID: nil)

        await #expect(throws: LiveSessionPersistenceError.staleSession) {
            try await integration.upsertSegment(
                session: first,
                id: UUID(),
                startTime: 0,
                endTime: 1,
                draft: "old",
                refined: "old",
                speakerID: "speaker-old"
            )
        }
    }

    @Test("speaker update is persisted before the session is finished")
    func speakerUpdateBeforeFinishPersists() async throws {
        let database = try AppDatabase.inMemory()
        let integration = LiveSessionPersistence(database: database)
        let session = try await integration.start(title: "Physics", subjectID: nil)
        let id = UUID()
        try await integration.upsertSegment(session: session, id: id, startTime: 0, endTime: 1, draft: "draft", refined: "refined", speakerID: nil)
        try await integration.upsertSegment(session: session, id: id, startTime: 0, endTime: 1, draft: "draft", refined: "refined", speakerID: "speaker-1")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("mixed.wav")
        try Data([0, 1]).write(to: wav)
        try await integration.finish(session: session, assets: .init(sessionDirectory: root, microphoneWAV: root.appendingPathComponent("microphone.wav"), systemWAV: nil, mixedWAV: wav, m4aURL: nil, totalSamples: 16_000), sampleRate: 16_000)

        let saved = try TranscriptRepository(database: database).fetchSegments(revisionID: session.revisionID)
        #expect(saved.first?.speakerID == "speaker-1")
    }

    @Test("final hidden decision is persisted as cancelled")
    func hiddenSegmentIsPersistedAsCancelled() async throws {
        let database = try AppDatabase.inMemory()
        let integration = LiveSessionPersistence(database: database)
        let session = try await integration.start(title: "Filtered", subjectID: nil)
        let id = UUID()
        try await integration.upsertSegment(session: session, id: id, startTime: 0, endTime: 1, draft: "junk", refined: "junk", speakerID: nil, status: .cancelled)
        let all = try TranscriptRepository(database: database).fetchSegments(revisionID: session.revisionID, includingDropped: true)
        let visible = try TranscriptRepository(database: database).fetchSegments(revisionID: session.revisionID)
        #expect(all.first?.status == .cancelled)
        #expect(visible.isEmpty)
    }
}

@Suite("Playback timeline")
struct PlaybackTimelineTests {
    @Test("highlight uses the segment containing the playhead")
    func highlightUsesTimeRange() {
        let first = TranscriptSegmentRecord(revisionID: UUID(), sequence: 0, startTime: 0, endTime: 1, refinedText: "a", status: .succeeded)
        let second = TranscriptSegmentRecord(revisionID: first.revisionID, sequence: 1, startTime: 1, endTime: 2, refinedText: "b", status: .succeeded)
        #expect(MeetingPlaybackController.highlightedSegmentID(at: 1.5, segments: [first, second]) == second.id)
        #expect(MeetingPlaybackController.highlightedSegmentID(at: 3, segments: [first, second]) == nil)
    }

    @MainActor @Test("unload clears playback selection state")
    func unloadClearsState() {
        let playback = MeetingPlaybackController()
        playback.seek(to: 12)
        playback.unload()
        #expect(playback.isPlaying == false)
        #expect(playback.currentTime == 0)
        #expect(playback.duration == 0)
        #expect(playback.highlightedSegmentID == nil)
    }
}

@Suite("Meeting library presentation")
struct MeetingLibraryPresentationTests {
    @Test("legacy notes already indexed in SQLite are not shown twice")
    func indexedLegacyNotesAreDeduplicated() {
        let url = URL(fileURLWithPath: "/tmp/indexed.md")
        let record = NoteRecord(url: url, fileName: "indexed.md", format: .markdown, modifiedAt: .distantPast, fileSize: 1, previewSummary: nil)
        let meeting = MeetingRecord(title: "indexed", source: .legacyImported, legacyNotePath: url.path)
        #expect(TranscriptionViewModel.deduplicatedNoteRecords([record], meetings: [meeting]).isEmpty)
    }

    @MainActor @Test("history selection is blocked while recording")
    func historySelectionBlockedWhileRecording() {
        let vm = TranscriptionViewModel()
        vm.isRecording = true
        vm.selectMeeting(MeetingRecord(title: "History", source: .live))
        #expect(vm.selectedMeeting == nil)
    }

    @MainActor @Test("database readiness participates in the start gate")
    func databaseReadinessGatesStart() {
        let vm = TranscriptionViewModel()
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.applyMeetingLibraryReadinessForTesting(false, message: "database failed")
        #expect(vm.canStartTranscription == false)
        #expect(vm.meetingLibraryStatus == "database failed")
        vm.applyMeetingLibraryReadinessForTesting(true, message: "")
        #expect(vm.canStartTranscription == true)
    }
}
