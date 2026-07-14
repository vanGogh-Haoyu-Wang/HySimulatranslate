import Foundation
import Testing
@testable import HySimulatranslate

@Suite("Workspace controller characterization")
struct WorkspaceControllerTests {
    @MainActor @Test("meeting library selects, filters, and soft deletes through one owner")
    func meetingLibraryLifecycle() throws {
        let db = try AppDatabase.inMemory()
        let controller = MeetingLibraryController(database: db)
        let meeting = try controller.createMeeting(title: "History", source: .live, subjectID: nil)
        let active = try controller.refresh()
        #expect(active.map(\.id) == [meeting.id])
        let selection = try controller.select(meeting)
        #expect(selection.meeting.id == meeting.id)
        try controller.softDelete(meeting)
        let remaining = try controller.refresh()
        #expect(remaining.isEmpty)
        #expect(controller.selectedMeeting == nil)
    }

    @Test("note export writes the renderer output atomically")
    func noteExportWritesRenderedContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("note.md")
        let item = TranscriptionItem(english: "Hello", chinese: "你好", status: .done, zone: .history)
        try NoteExportService().export(course: .init(name: "Test", abbrev: "T", keywords: "", meetingFocus: ""), translationEnabled: true, items: [item], finalSummary: "Done", speakerAliases: [:], format: .markdown, to: url)
        let body = try String(contentsOf: url)
        #expect(body.contains("Hello"))
        #expect(body.contains("Done"))
    }

    @MainActor @Test("session coordinator owns generation, persistence and recording lease")
    func sessionCoordinatorLifecycle() async throws {
        let db = try AppDatabase.inMemory()
        let resources = ModelResourceService(resources: [])
        let coordinator = SessionCoordinator(database: db, modelUsage: ModelUsageCoordinator(resources: resources), sessionsRoot: FileManager.default.temporaryDirectory)
        let context = try await coordinator.begin(title: "Live", subjectID: nil, enabledSources: [.microphone])
        #expect(context.generation > 0)
        try await coordinator.abort(context)
        #expect(try MeetingRepository(database: db).fetch(id: context.persistence.meetingID)?.status == .cancelled)
    }

    @MainActor @Test("failed initial import removes managed meeting and copied asset but preserves source")
    func failedInitialImportRollsBack() async throws {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        try Data("not audio".utf8).write(to: source)
        let resources = ModelResourceService(resources: [])
        let apple = WorkspaceAppleTranslator()
        let controller = ImportWorkspaceController(database: db, translationService: TranslationService(appleTranslator: apple), appleTranslator: apple, modelUsage: ModelUsageCoordinator(resources: resources), noteDirectory: root)
        await #expect(throws: (any Error).self) {
            _ = try await controller.importAudio(from: source, options: .init(subjectID: nil, sourceLanguage: "en", translate: false, targetLanguage: "zh", whisperModel: "missing", diarize: false), sessionsRoot: root, credential: nil)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try MeetingRepository(database: db).fetchActive().isEmpty)
        let managedEntries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        #expect(managedEntries.isEmpty)
    }
}

private struct WorkspaceAppleTranslator: AppleSystemTranslating {
    func prepare() async -> Bool { false }
    func translate(_ text: String) async -> String? { nil }
}
