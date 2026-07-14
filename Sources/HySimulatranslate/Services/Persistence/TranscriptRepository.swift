import Foundation
import GRDB

final class TranscriptRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func createRevision(meetingID: UUID, number: Int, source: MeetingSource, model: String, language: String, status: PersistenceStatus) throws -> TranscriptRevisionRecord {
        let record = TranscriptRevisionRecord(meetingID: meetingID, number: number, source: source, model: model, language: language, status: status)
        try database.writer.write { try record.insert($0) }; return record
    }
    func fetchRevisions(meetingID: UUID) throws -> [TranscriptRevisionRecord] {
        try database.writer.read { try TranscriptRevisionRecord.filter(Column("meetingID") == meetingID).order(Column("number")).fetchAll($0) }
    }
    func fetchRevision(id: UUID) throws -> TranscriptRevisionRecord? { try database.writer.read { try TranscriptRevisionRecord.fetchOne($0, key: id) } }
    func saveRevision(_ revision: TranscriptRevisionRecord) throws { try database.writer.write { try revision.save($0) } }
    func fetchTranslationRevisions(meetingID: UUID) throws -> [TranslationRevisionRecord] {
        try database.writer.read { try TranslationRevisionRecord.filter(Column("meetingID") == meetingID).order(Column("createdAt")).fetchAll($0) }
    }
    func saveTranslationRevision(_ revision: TranslationRevisionRecord) throws { try database.writer.write { try revision.save($0) } }
    func insert(_ segment: TranscriptSegmentRecord) throws { try database.writer.write { try segment.insert($0) } }
    func save(_ segment: TranscriptSegmentRecord) throws { try database.writer.write { try segment.save($0) } }
    func fetchSegments(revisionID: UUID, includingDropped: Bool = false) throws -> [TranscriptSegmentRecord] {
        try database.writer.read { db in
            var request = TranscriptSegmentRecord.filter(Column("revisionID") == revisionID)
            if !includingDropped { request = request.filter(Column("status") == PersistenceStatus.succeeded) }
            return try request.order(Column("sequence")).fetchAll(db)
        }
    }

    func createTranslationRevision(meetingID: UUID, transcriptRevisionID: UUID, targetLanguage: String, provider: String, model: String, status: PersistenceStatus) throws -> TranslationRevisionRecord {
        let record = TranslationRevisionRecord(meetingID: meetingID, transcriptRevisionID: transcriptRevisionID, targetLanguage: targetLanguage, provider: provider, model: model, status: status)
        try database.writer.write { db in
            let owner = try UUID.fetchOne(db, sql: "SELECT meetingID FROM transcriptRevisions WHERE id = ?", arguments: [transcriptRevisionID])
            guard owner != nil else { throw PersistenceRepositoryError.missingRecord }
            guard owner == meetingID else { throw PersistenceRepositoryError.ownershipMismatch }
            try record.insert(db)
        }; return record
    }
    func insert(_ translation: SegmentTranslationRecord) throws {
        try database.writer.write { db in
            let valid = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM translationRevisions tr
                    JOIN transcriptSegments s ON s.revisionID = tr.transcriptRevisionID
                    WHERE tr.id = ? AND s.id = ?
                )
                """, arguments: [translation.translationRevisionID, translation.segmentID]) ?? false
            guard valid else { throw PersistenceRepositoryError.ownershipMismatch }
            try translation.insert(db)
        }
    }
    func fetchTranslations(revisionID: UUID) throws -> [SegmentTranslationRecord] {
        try database.writer.read { try SegmentTranslationRecord.filter(Column("translationRevisionID") == revisionID).fetchAll($0) }
    }
    func insert(_ summary: SummaryRevisionRecord) throws {
        try database.writer.write { db in
            let transcriptOwner = try UUID.fetchOne(db, sql: "SELECT meetingID FROM transcriptRevisions WHERE id = ?", arguments: [summary.transcriptRevisionID])
            guard transcriptOwner != nil else { throw PersistenceRepositoryError.missingRecord }
            guard transcriptOwner == summary.meetingID else { throw PersistenceRepositoryError.ownershipMismatch }
            if let translationID = summary.translationRevisionID {
                let source = try Row.fetchOne(db, sql: "SELECT meetingID, transcriptRevisionID FROM translationRevisions WHERE id = ?", arguments: [translationID])
                guard let source else { throw PersistenceRepositoryError.missingRecord }
                let sourceMeeting: UUID = source["meetingID"]
                let sourceTranscript: UUID = source["transcriptRevisionID"]
                guard sourceMeeting == summary.meetingID, sourceTranscript == summary.transcriptRevisionID else { throw PersistenceRepositoryError.ownershipMismatch }
            }
            try summary.insert(db)
        }
    }
    func fetchSummaryRevisions(meetingID: UUID) throws -> [SummaryRevisionRecord] {
        try database.writer.read { try SummaryRevisionRecord.filter(Column("meetingID") == meetingID).order(Column("createdAt")).fetchAll($0) }
    }

    func setCurrentTranscriptRevision(_ revisionID: UUID, for meetingID: UUID) throws { try setCurrent(revisionID, meetingID: meetingID, table: "transcriptRevisions", column: "currentTranscriptRevisionID") }
    func setCurrentTranslationRevision(_ revisionID: UUID, for meetingID: UUID) throws { try setCurrent(revisionID, meetingID: meetingID, table: "translationRevisions", column: "currentTranslationRevisionID") }
    func setCurrentSummaryRevision(_ revisionID: UUID, for meetingID: UUID) throws { try setCurrent(revisionID, meetingID: meetingID, table: "summaryRevisions", column: "currentSummaryRevisionID") }
    func setCurrentImportRevisions(transcriptID: UUID, translationID: UUID?, for meetingID: UUID) throws {
        try database.writer.write { db in
            let transcriptStatus = try String.fetchOne(db, sql: "SELECT status FROM transcriptRevisions WHERE id = ? AND meetingID = ?", arguments: [transcriptID, meetingID])
            guard transcriptStatus == PersistenceStatus.succeeded.rawValue else { throw PersistenceRepositoryError.revisionNotSuccessful }
            if let translationID {
                guard let row = try Row.fetchOne(db, sql: "SELECT status, transcriptRevisionID FROM translationRevisions WHERE id = ? AND meetingID = ?", arguments: [translationID, meetingID]) else { throw PersistenceRepositoryError.missingRecord }
                let status: String = row["status"]; let source: UUID = row["transcriptRevisionID"]
                guard status == PersistenceStatus.succeeded.rawValue, source == transcriptID else { throw PersistenceRepositoryError.revisionNotSuccessful }
            }
            try db.execute(sql: "UPDATE meetings SET currentTranscriptRevisionID = ?, currentTranslationRevisionID = ?, updatedAt = ? WHERE id = ?", arguments: [transcriptID, translationID, Date(), meetingID])
        }
    }

    private func setCurrent(_ revisionID: UUID, meetingID: UUID, table: String, column: String) throws {
        try database.writer.write { db in
            let status = try String.fetchOne(db, sql: "SELECT status FROM \(table) WHERE id = ? AND meetingID = ?", arguments: [revisionID, meetingID])
            guard status != nil else { throw PersistenceRepositoryError.missingRecord }
            guard status == PersistenceStatus.succeeded.rawValue else { throw PersistenceRepositoryError.revisionNotSuccessful }
            try db.execute(sql: "UPDATE meetings SET \(column) = ?, updatedAt = ? WHERE id = ?", arguments: [revisionID, Date(), meetingID])
        }
    }
}
