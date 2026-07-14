import Foundation
import GRDB

final class SpeakerRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }

    func setAlias(meetingID: UUID, speakerID: String, displayName: String) throws {
        try database.writer.write { db in
            if var record = try SpeakerAliasRecord.filter(Column("meetingID") == meetingID && Column("speakerID") == speakerID).fetchOne(db) {
                record.displayName = displayName; try record.update(db)
            } else { try SpeakerAliasRecord(meetingID: meetingID, speakerID: speakerID, displayName: displayName).insert(db) }
        }
    }
    func aliases(meetingID: UUID) throws -> [String: String] {
        try database.writer.read { db in Dictionary(uniqueKeysWithValues: try SpeakerAliasRecord.filter(Column("meetingID") == meetingID).fetchAll(db).map { ($0.speakerID, $0.displayName) }) }
    }

    func displayName(meetingID: UUID, speakerID: String) throws -> String {
        try aliases(meetingID: meetingID)[speakerID] ?? SpeakerDisplayName.displayName(for: speakerID)
    }
}
