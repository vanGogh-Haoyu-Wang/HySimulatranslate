import Foundation
import GRDB

struct LivePersistenceSession: Equatable, Sendable {
    let meetingID: UUID
    let revisionID: UUID
}

enum LiveSessionPersistenceError: Error, Equatable {
    case staleSession
    case sessionAlreadyActive
}

actor LiveSessionPersistence {
    private let database: AppDatabase
    private let meetings: MeetingRepository
    private let transcripts: TranscriptRepository
    private var session: LivePersistenceSession?
    private var nextSequence = 0

    init(database: AppDatabase) {
        self.database = database
        meetings = MeetingRepository(database: database)
        transcripts = TranscriptRepository(database: database)
    }

    @discardableResult
    func start(title: String, subjectID: UUID?) throws -> LivePersistenceSession {
        guard session == nil else { throw LiveSessionPersistenceError.sessionAlreadyActive }
        var meeting = MeetingRecord(title: title, subjectID: subjectID, source: .live)
        let revision = TranscriptRevisionRecord(
            meetingID: meeting.id,
            number: 1,
            source: .live,
            model: "sherpa-live",
            language: "auto",
            status: .succeeded
        )
        meeting.currentTranscriptRevisionID = revision.id
        try database.writer.write { db in
            try meeting.insert(db)
            try revision.insert(db)
        }
        let newSession = LivePersistenceSession(meetingID: meeting.id, revisionID: revision.id)
        session = newSession
        nextSequence = 0
        return newSession
    }

    func upsertSegment(
        session expectedSession: LivePersistenceSession? = nil,
        id: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        draft: String?,
        refined: String,
        speakerID: String?,
        status: PersistenceStatus = .succeeded
    ) throws {
        guard let session else { throw LiveSessionPersistenceError.staleSession }
        if let expectedSession, expectedSession != session {
            throw LiveSessionPersistenceError.staleSession
        }
        let existing = try database.writer.read { db in
            try TranscriptSegmentRecord.fetchOne(db, key: id)
        }
        let record = TranscriptSegmentRecord(
            id: id,
            revisionID: session.revisionID,
            sequence: existing?.sequence ?? nextSequence,
            startTime: max(0, startTime),
            endTime: max(startTime, endTime),
            draftText: draft ?? existing?.draftText,
            refinedText: refined,
            speakerID: speakerID,
            confidence: existing?.confidence,
            status: status
        )
        try transcripts.save(record)
        if existing == nil { nextSequence += 1 }
    }

    func finish(session expectedSession: LivePersistenceSession? = nil, assets: SessionAudioAssets, sampleRate: Int) throws {
        guard let session else { throw LiveSessionPersistenceError.staleSession }
        if let expectedSession, expectedSession != session {
            throw LiveSessionPersistenceError.staleSession
        }
        let duration = Double(assets.totalSamples) / Double(max(1, sampleRate))
        let candidates: [(AudioTrack, URL?)] = [
            (.microphone, assets.microphoneWAV),
            (.system, assets.systemWAV),
            (.mixed, assets.m4aURL ?? assets.mixedWAV)
        ]
        for (track, url) in candidates {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            try meetings.saveAudioAsset(AudioAssetRecord(
                meetingID: session.meetingID,
                track: track,
                path: url.path,
                format: url.pathExtension.lowercased(),
                sampleRate: Double(sampleRate),
                channelCount: 1,
                duration: duration,
                status: .ready
            ))
        }
        try meetings.updateSession(id: session.meetingID, duration: duration, status: .ready)
        self.session = nil
    }

    func fail(session expectedSession: LivePersistenceSession? = nil) throws {
        guard let session else { return }
        if let expectedSession, expectedSession != session {
            throw LiveSessionPersistenceError.staleSession
        }
        try meetings.updateSession(id: session.meetingID, duration: 0, status: .failed)
        self.session = nil
    }

    func abort(session expectedSession: LivePersistenceSession) throws {
        guard let session, session == expectedSession else {
            throw LiveSessionPersistenceError.staleSession
        }
        try meetings.updateSession(id: session.meetingID, duration: 0, status: .cancelled)
        self.session = nil
    }
}
