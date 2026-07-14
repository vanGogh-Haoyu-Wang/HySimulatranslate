import Foundation
import GRDB

final class ImportJobRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func create(meetingID: UUID, sourcePath: String, options: ImportOptions) throws -> ImportJobRecord {
        let job = ImportJobRecord(meetingID: meetingID, sourcePath: sourcePath, optionsJSON: try JSONEncoder().encode(options))
        try database.writer.write { try job.insert($0) }; return job
    }
    func createWithRevision(meetingID: UUID, sourcePath: String, options: ImportOptions) throws -> (ImportJobRecord, TranscriptRevisionRecord) {
        try database.writer.write { db in
            let number = (try Int.fetchOne(db, sql: "SELECT MAX(number) FROM transcriptRevisions WHERE meetingID = ?", arguments: [meetingID]) ?? 0) + 1
            let revision = TranscriptRevisionRecord(meetingID: meetingID, number: number, source: .imported, model: options.whisperModel, language: options.sourceLanguage, status: .processing)
            try revision.insert(db)
            var job = ImportJobRecord(meetingID: meetingID, sourcePath: sourcePath, optionsJSON: try JSONEncoder().encode(options))
            job.transcriptRevisionID = revision.id; try job.insert(db)
            return (job, revision)
        }
    }
    func save(_ job: ImportJobRecord) throws { try database.writer.write { try job.save($0) } }
    func fetch(meetingID: UUID) throws -> [ImportJobRecord] {
        try database.writer.read { try ImportJobRecord.filter(Column("meetingID") == meetingID).order(Column("createdAt").desc).fetchAll($0) }
    }
    func fetchProcessing() throws -> [ImportJobRecord] { try database.writer.read { try ImportJobRecord.filter(Column("status") == PersistenceStatus.processing).fetchAll($0) } }
    @discardableResult func recoverInterruptedJobs() throws -> Int {
        try database.writer.read { db in
            try ImportJobRecord.filter(Column("status") == PersistenceStatus.processing).fetchCount(db)
        }
    }
}
