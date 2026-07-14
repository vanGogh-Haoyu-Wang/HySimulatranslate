import Foundation
import GRDB

enum PersistenceRepositoryError: Error, Equatable { case missingRecord, revisionNotSuccessful, ownershipMismatch, builtInTemplateReadOnly }

final class MeetingRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func create(title: String, source: MeetingSource, subjectID: UUID? = nil, legacyNotePath: String? = nil, preview: String? = nil) throws -> MeetingRecord {
        let record = MeetingRecord(title: title, subjectID: subjectID, source: source, legacyNotePath: legacyNotePath, preview: preview)
        try database.writer.write { try record.insert($0) }
        return record
    }

    func fetch(id: UUID) throws -> MeetingRecord? { try database.writer.read { try MeetingRecord.fetchOne($0, key: id) } }
    func fetchActive() throws -> [MeetingRecord] { try database.writer.read { try MeetingRecord.filter(Column("deletedAt") == nil).order(Column("createdAt").desc).fetchAll($0) } }
    func fetchDeleted() throws -> [MeetingRecord] { try database.writer.read { try MeetingRecord.filter(Column("deletedAt") != nil).order(Column("deletedAt")).fetchAll($0) } }

    func softDelete(id: UUID, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE meetings SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [date, date, id])
        }
    }

    func purgeDeleted(olderThan cutoff: Date) throws -> [UUID] {
        try database.writer.write { db in
            let records = try MeetingRecord.filter(Column("deletedAt") != nil && Column("deletedAt") < cutoff).fetchAll(db)
            for record in records { _ = try record.delete(db) }
            return records.map(\.id)
        }
    }

    func purge(id: UUID) throws {
        try database.writer.write { db in
            guard let record = try MeetingRecord.fetchOne(db, key: id) else { return }
            _ = try record.delete(db)
        }
    }

    @discardableResult func indexLegacyNotes(in directory: URL) throws -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            .filter {
                guard ["md", "txt"].contains($0.pathExtension.lowercased()) else { return false }
                return (try? $0.resourceValues(forKeys: keys).isRegularFile) == true
            }
        let candidates: [MeetingRecord] = files.map { file in
            let path = file.standardizedFileURL.path
            let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let preview = String(contents.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            var record = MeetingRecord(title: file.deletingPathExtension().lastPathComponent, source: .legacyImported, legacyNotePath: path, preview: preview)
            if let values = try? file.resourceValues(forKeys: keys), let date = values.contentModificationDate {
                record.createdAt = date; record.updatedAt = date
            }
            return record
        }
        return try database.writer.write { db in
            var inserted = 0
            for record in candidates {
                try record.insert(db, onConflict: .ignore)
                inserted += db.changesCount
            }
            return inserted
        }
    }

    func saveAudioAsset(_ asset: AudioAssetRecord) throws { try database.writer.write { try asset.save($0) } }
    func fetchAudioAssets(meetingID: UUID) throws -> [AudioAssetRecord] {
        try database.writer.read { try AudioAssetRecord.filter(Column("meetingID") == meetingID).order(Column("track")).fetchAll($0) }
    }

    func updateSession(id: UUID, duration: Double, status: PersistenceStatus) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET duration = ?, status = ?, updatedAt = ? WHERE id = ?",
                arguments: [duration, status, Date(), id]
            )
        }
    }
}
