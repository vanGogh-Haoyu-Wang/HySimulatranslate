import Foundation
import Combine

@MainActor
final class SummaryWorkspaceController: ObservableObject {
    @Published private(set) var templates: [SummaryTemplateRecord] = []
    @Published private(set) var summaryRevisions: [SummaryRevisionRecord] = []
    @Published var selectedTemplateID: UUID?
    @Published private(set) var selectedSummaryRevisionID: UUID?
    @Published private(set) var displayedSummary = ""
    @Published private(set) var statusMessage = ""

    var selectedTemplate: SummaryTemplateRecord? {
        templates.first { $0.id == selectedTemplateID }
    }
    var selectableSummaryRevisions: [SummaryRevisionRecord] { summaryRevisions.filter { $0.status == .succeeded } }
    var failedSummaryRevisions: [SummaryRevisionRecord] { summaryRevisions.filter { $0.status == .failed } }

    private let templateRepository: SummaryTemplateRepository
    private let transcriptRepository: TranscriptRepository
    private let userDefaults: UserDefaults
    private let selectionKey = "selectedSummaryTemplateID"
    private var loadedMeetingID: UUID?

    init(database: AppDatabase, userDefaults: UserDefaults = .standard) {
        templateRepository = SummaryTemplateRepository(database: database)
        transcriptRepository = TranscriptRepository(database: database)
        self.userDefaults = userDefaults
    }

    func loadTemplates() {
        do {
            templates = try templateRepository.fetchAll()
            let storedID = userDefaults.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
            selectedTemplateID = templates.contains(where: { $0.id == storedID })
                ? storedID
                : templates.first(where: { $0.name == "Standard Meeting" })?.id ?? templates.first?.id
            persistTemplateSelection()
        } catch { statusMessage = "无法载入摘要模板：\(error.localizedDescription)" }
    }

    func load(meeting: MeetingRecord?) {
        loadedMeetingID = meeting?.id
        guard let meeting else {
            summaryRevisions = []; selectedSummaryRevisionID = nil; displayedSummary = ""; return
        }
        do {
            summaryRevisions = try transcriptRepository.fetchSummaryRevisions(meetingID: meeting.id)
            selectedSummaryRevisionID = meeting.currentSummaryRevisionID
            displayedSummary = summaryRevisions.first(where: { $0.id == selectedSummaryRevisionID })?.body ?? ""
        } catch { statusMessage = "无法载入摘要版本：\(error.localizedDescription)" }
    }

    func selectTemplate(_ id: UUID?) {
        guard templates.contains(where: { $0.id == id }) else { return }
        selectedTemplateID = id
        persistTemplateSelection()
    }

    @discardableResult
    func createTemplate(name: String, language: String, systemInstruction: String, sections: [String]) throws -> SummaryTemplateRecord {
        let record = SummaryTemplateRecord(
            name: name, language: language, systemInstruction: systemInstruction,
            structureJSON: try Self.encodeSections(sections)
        )
        let created = try templateRepository.create(record)
        try reloadAndSelect(created.id)
        return created
    }

    func updateSelectedTemplate(name: String, language: String, systemInstruction: String, sections: [String]) throws {
        guard var template = selectedTemplate else { throw PersistenceRepositoryError.missingRecord }
        guard !template.isBuiltIn else { throw PersistenceRepositoryError.builtInTemplateReadOnly }
        template.name = name; template.language = language; template.systemInstruction = systemInstruction
        template.structureJSON = try Self.encodeSections(sections); template.updatedAt = Date()
        try templateRepository.update(template)
        try reloadAndSelect(template.id)
    }

    @discardableResult
    func copySelectedTemplate() throws -> SummaryTemplateRecord {
        guard let selectedTemplateID else { throw PersistenceRepositoryError.missingRecord }
        let copy = try templateRepository.copy(id: selectedTemplateID)
        try reloadAndSelect(copy.id)
        return copy
    }

    func deleteSelectedTemplate() throws {
        guard let template = selectedTemplate else { throw PersistenceRepositoryError.missingRecord }
        try templateRepository.delete(id: template.id)
        templates = try templateRepository.fetchAll()
        selectedTemplateID = templates.first(where: { $0.name == "Standard Meeting" })?.id ?? templates.first?.id
        persistTemplateSelection()
    }

    @discardableResult
    func recordGeneration(
        meetingID: UUID, transcriptRevisionID: UUID, translationRevisionID: UUID?,
        template: SummaryTemplateRecord, provider: String, model: String, body: String?
    ) throws -> SummaryRevisionRecord {
        let normalized = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = !(normalized ?? "").isEmpty
        let revision = SummaryRevisionRecord(
            meetingID: meetingID, transcriptRevisionID: transcriptRevisionID,
            translationRevisionID: translationRevisionID, templateID: template.id,
            provider: provider, model: model, body: normalized ?? "",
            status: succeeded ? .succeeded : .failed,
            errorMessage: succeeded ? nil : "摘要服务未返回有效内容"
        )
        try transcriptRepository.insert(revision)
        if succeeded { try transcriptRepository.setCurrentSummaryRevision(revision.id, for: meetingID) }
        summaryRevisions = try transcriptRepository.fetchSummaryRevisions(meetingID: meetingID)
        if succeeded { selectedSummaryRevisionID = revision.id; displayedSummary = revision.body }
        return revision
    }

    @discardableResult
    func generate(
        meetingID: UUID, transcriptRevisionID: UUID, translationRevisionID: UUID?,
        template: SummaryTemplateRecord, provider: String, model: String,
        previousSummary: String, sourceContent: String, isFinal: Bool,
        generator: (String) async throws -> String?
    ) async throws -> SummaryRevisionRecord {
        let revision = try await SummaryCoordinator(transcripts: transcriptRepository).generate(
            meetingID: meetingID, transcriptRevisionID: transcriptRevisionID,
            translationRevisionID: translationRevisionID, template: template,
            provider: provider, model: model, previousSummary: previousSummary,
            sourceContent: sourceContent, isFinal: isFinal, generator: generator
        )
        summaryRevisions = try transcriptRepository.fetchSummaryRevisions(meetingID: meetingID)
        if revision.status == .succeeded {
            selectedSummaryRevisionID = revision.id
            displayedSummary = revision.body
        }
        return revision
    }

    func selectSummaryRevision(_ id: UUID, meetingID: UUID) throws {
        try transcriptRepository.setCurrentSummaryRevision(id, for: meetingID)
        selectedSummaryRevisionID = id
        displayedSummary = summaryRevisions.first(where: { $0.id == id })?.body ?? ""
    }

    func selectSummaryRevision(_ id: UUID) throws {
        guard let loadedMeetingID else { throw PersistenceRepositoryError.missingRecord }
        try selectSummaryRevision(id, meetingID: loadedMeetingID)
    }

    private func reloadAndSelect(_ id: UUID) throws {
        templates = try templateRepository.fetchAll(); selectedTemplateID = id; persistTemplateSelection()
    }
    private func persistTemplateSelection() { userDefaults.set(selectedTemplateID?.uuidString, forKey: selectionKey) }
    private static func encodeSections(_ sections: [String]) throws -> String {
        let normalized = sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { throw SummaryTemplateError.invalidStructure }
        let data = try JSONSerialization.data(withJSONObject: normalized)
        return String(decoding: data, as: UTF8.self)
    }
}
