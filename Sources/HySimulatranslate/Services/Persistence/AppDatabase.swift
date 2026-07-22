import Foundation
import GRDB

final class AppDatabase {
    let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static func inMemory() throws -> AppDatabase { try AppDatabase(writer: DatabaseQueue()) }

    static func open(at url: URL = defaultDatabaseURL()) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(writer: DatabasePool(path: url.path))
    }

    static func defaultDatabaseURL(
        applicationSupportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        applicationSupportDirectory.appendingPathComponent("HySimulatranslate/Database/hysimulatranslate.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-session-library") { db in
            try createTables(db)
        }
        migrator.registerMigration("v2-import-jobs") { db in
            try db.create(table: "importJobs") { t in
                t.column("id", .text).primaryKey(); t.column("meetingID", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("sourcePath", .text).notNull(); t.column("optionsJSON", .blob).notNull(); t.column("status", .text).notNull()
                t.column("progress", .double).notNull(); t.column("transcriptRevisionID", .text).references("transcriptRevisions", onDelete: .setNull)
                t.column("translationRevisionID", .text).references("translationRevisions", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull(); t.column("updatedAt", .datetime).notNull(); t.column("errorMessage", .text)
            }
        }
        migrator.registerMigration("v3-import-checkpoint") { db in
            try db.alter(table: "importJobs") { $0.add(column: "nextSegmentSequence", .integer).notNull().defaults(to: 0) }
        }
        migrator.registerMigration("v4-summary-template-soft-delete") { db in
            try db.alter(table: "summaryTemplates") { $0.add(column: "deletedAt", .datetime) }
            if try SummaryTemplateRecord.fetchCount(db) == 0 {
                for template in builtInTemplates { try template.insert(db) }
            }
        }
        migrator.registerMigration("v5-exported-note-path") { db in
            try db.alter(table: "meetings") { $0.add(column: "exportedNotePath", .text) }
            try db.create(index: "meetings_exportedNotePath", on: "meetings", columns: ["exportedNotePath"], unique: true)
        }
        return migrator
    }

    private static func createTables(_ db: Database) throws {
        try db.create(table: "meetings") { t in
            t.column("id", .text).primaryKey(); t.column("title", .text).notNull(); t.column("subjectID", .text)
            t.column("source", .text).notNull(); t.column("createdAt", .datetime).notNull(); t.column("updatedAt", .datetime).notNull()
            t.column("duration", .double).notNull(); t.column("status", .text).notNull()
            // Current revision pointers are ownership-validated transactionally because
            // their target tables are created after the owning meeting table.
            t.column("currentTranscriptRevisionID", .text)
            t.column("currentTranslationRevisionID", .text)
            t.column("currentSummaryRevisionID", .text)
            t.column("legacyNotePath", .text).unique(); t.column("preview", .text); t.column("deletedAt", .datetime)
        }
        try db.create(table: "audioAssets") { t in
            t.column("id", .text).primaryKey(); t.column("meetingID", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("track", .text).notNull(); t.column("path", .text).notNull(); t.column("format", .text).notNull(); t.column("sampleRate", .double).notNull()
            t.column("channelCount", .integer).notNull(); t.column("duration", .double).notNull(); t.column("status", .text).notNull()
        }
        try db.create(table: "transcriptRevisions") { t in
            t.column("id", .text).primaryKey(); t.column("meetingID", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("number", .integer).notNull(); t.column("source", .text).notNull(); t.column("model", .text).notNull(); t.column("language", .text).notNull()
            t.column("status", .text).notNull(); t.column("createdAt", .datetime).notNull(); t.column("errorMessage", .text); t.uniqueKey(["meetingID", "number"])
        }
        try db.create(table: "transcriptSegments") { t in
            t.column("id", .text).primaryKey(); t.column("revisionID", .text).notNull().references("transcriptRevisions", onDelete: .cascade)
            t.column("sequence", .integer).notNull(); t.column("startTime", .double).notNull(); t.column("endTime", .double).notNull()
            t.column("draftText", .text); t.column("refinedText", .text).notNull(); t.column("speakerID", .text); t.column("confidence", .double); t.column("status", .text).notNull()
            t.uniqueKey(["revisionID", "sequence"])
        }
        try db.create(table: "translationRevisions") { t in
            t.column("id", .text).primaryKey(); t.column("meetingID", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("transcriptRevisionID", .text).notNull().references("transcriptRevisions", onDelete: .cascade); t.column("targetLanguage", .text).notNull()
            t.column("provider", .text).notNull(); t.column("model", .text).notNull(); t.column("status", .text).notNull(); t.column("createdAt", .datetime).notNull(); t.column("errorMessage", .text)
        }
        try db.create(table: "segmentTranslations") { t in
            t.column("id", .text).primaryKey(); t.column("translationRevisionID", .text).notNull().references("translationRevisions", onDelete: .cascade)
            t.column("segmentID", .text).notNull().references("transcriptSegments", onDelete: .cascade); t.column("text", .text).notNull(); t.uniqueKey(["translationRevisionID", "segmentID"])
        }
        try db.create(table: "speakerAliases") { t in
            t.column("id", .text).primaryKey(); t.column("meetingID", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("speakerID", .text).notNull(); t.column("displayName", .text).notNull(); t.uniqueKey(["meetingID", "speakerID"])
        }
        try db.create(table: "summaryTemplates") { t in
            t.column("id", .text).primaryKey(); t.column("name", .text).notNull(); t.column("language", .text).notNull(); t.column("systemInstruction", .text).notNull()
            t.column("structureJSON", .text).notNull(); t.column("isBuiltIn", .boolean).notNull(); t.column("updatedAt", .datetime).notNull()
        }
        try db.create(table: "summaryRevisions") { t in
            t.column("id", .text).primaryKey(); t.column("meetingID", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("transcriptRevisionID", .text).notNull().references("transcriptRevisions", onDelete: .cascade)
            t.column("translationRevisionID", .text).references("translationRevisions", onDelete: .setNull)
            t.column("templateID", .text).notNull().references("summaryTemplates"); t.column("provider", .text).notNull(); t.column("model", .text).notNull()
            t.column("body", .text).notNull(); t.column("status", .text).notNull(); t.column("createdAt", .datetime).notNull(); t.column("errorMessage", .text)
        }
    }

    private static let builtInTemplates: [SummaryTemplateRecord] = [
        .init(name: "Standard Meeting", language: "en", systemInstruction: "Summarize the meeting accurately.", structureJSON: "[\"Summary\",\"Key Points\",\"Next Steps\"]", isBuiltIn: true),
        .init(name: "Class Notes", language: "en", systemInstruction: "Create structured class notes.", structureJSON: "[\"Concepts\",\"Definitions\",\"Review\"]", isBuiltIn: true),
        .init(name: "Interview", language: "en", systemInstruction: "Summarize the interview faithfully.", structureJSON: "[\"Topics\",\"Answers\",\"Follow-ups\"]", isBuiltIn: true),
        .init(name: "Action Items", language: "en", systemInstruction: "Extract concrete action items.", structureJSON: "[\"Owner\",\"Action\",\"Due Date\"]", isBuiltIn: true),
    ]
}
