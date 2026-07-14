import Foundation
import GRDB

final class SummaryTemplateRepository {
    private let database: AppDatabase
    init(database: AppDatabase) { self.database = database }
    func fetchAll() throws -> [SummaryTemplateRecord] {
        try database.writer.read { try SummaryTemplateRecord.filter(Column("deletedAt") == nil).order(Column("name")).fetchAll($0) }
    }
    func fetch(id: UUID, includingDeleted: Bool = false) throws -> SummaryTemplateRecord? {
        try database.writer.read { db in
            var request = SummaryTemplateRecord.filter(Column("id") == id)
            if !includingDeleted { request = request.filter(Column("deletedAt") == nil) }
            return try request.fetchOne(db)
        }
    }
    @discardableResult
    func create(_ template: SummaryTemplateRecord) throws -> SummaryTemplateRecord {
        var template = template; template.isBuiltIn = false
        try database.writer.write { try template.insert($0) }
        return template
    }
    func update(_ template: SummaryTemplateRecord) throws {
        guard !template.isBuiltIn else { throw PersistenceRepositoryError.builtInTemplateReadOnly }
        try database.writer.write { db in
            guard let stored = try SummaryTemplateRecord.fetchOne(db, key: template.id) else { throw PersistenceRepositoryError.missingRecord }
            guard !stored.isBuiltIn else { throw PersistenceRepositoryError.builtInTemplateReadOnly }
            try template.update(db)
        }
    }
    func delete(id: UUID) throws {
        try database.writer.write { db in
            guard let template = try SummaryTemplateRecord.fetchOne(db, key: id) else { return }
            guard !template.isBuiltIn else { throw PersistenceRepositoryError.builtInTemplateReadOnly }
            try db.execute(sql: "UPDATE summaryTemplates SET deletedAt = ?, updatedAt = ? WHERE id = ?", arguments: [Date(), Date(), id])
        }
    }

    func restore(id: UUID) throws {
        try database.writer.write { db in
            guard try SummaryTemplateRecord.fetchOne(db, key: id) != nil else { throw PersistenceRepositoryError.missingRecord }
            try db.execute(sql: "UPDATE summaryTemplates SET deletedAt = NULL, updatedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
    }

    @discardableResult
    func copy(id: UUID, name: String? = nil) throws -> SummaryTemplateRecord {
        try database.writer.write { db in
            guard let source = try SummaryTemplateRecord.fetchOne(db, key: id) else { throw PersistenceRepositoryError.missingRecord }
            var duplicate = source
            duplicate.id = UUID()
            duplicate.name = name ?? "\(source.name) Copy"
            duplicate.isBuiltIn = false
            duplicate.updatedAt = Date()
            try duplicate.insert(db)
            return duplicate
        }
    }
}
