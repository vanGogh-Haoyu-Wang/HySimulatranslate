import XCTest
@testable import HySimulatranslate

final class M3ProductizationTests: XCTestCase {
    func testAliasesAreMeetingLocalAndApplyToExportsAndSummaryInput() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let speakers = SpeakerRepository(database: database)
        let first = try meetings.create(title: "First", source: .live)
        let second = try meetings.create(title: "Second", source: .live)
        try speakers.setAlias(meetingID: first.id, speakerID: "A", displayName: "Alice")
        try speakers.setAlias(meetingID: second.id, speakerID: "A", displayName: "Bob")

        XCTAssertEqual(try speakers.displayName(meetingID: first.id, speakerID: "A"), "Alice")
        XCTAssertEqual(try speakers.displayName(meetingID: second.id, speakerID: "A"), "Bob")
        let item = TranscriptionItem(english: "Budget is approved.", status: .done, zone: .history, speakerID: "A")
        let course = CourseSubject(name: "Default", abbrev: "D", keywords: "", meetingFocus: "")
        let note = SessionNoteRenderer.render(course: course, translationEnabled: false, items: [item], finalSummary: "", speakerAliases: ["A": "Alice"])
        XCTAssertTrue(note.contains("Alice: Budget is approved."))
        XCTAssertTrue(SummaryInputRenderer.render(items: [item], speakerAliases: ["A": "Alice"]).contains("Alice: Budget is approved."))
    }

    func testTemplateCopyCreatesEditableCustomTemplateAndPromptUsesLanguageAndSections() throws {
        let database = try AppDatabase.inMemory()
        let repository = SummaryTemplateRepository(database: database)
        let builtIn = try XCTUnwrap(repository.fetchAll().first { $0.name == "Class Notes" })
        let copy = try repository.copy(id: builtIn.id, name: "My Notes")
        XCTAssertFalse(copy.isBuiltIn)
        var edited = copy
        edited.language = "zh-CN"
        edited.systemInstruction = "只总结给定内容。"
        edited.structureJSON = "[\"核心概念\",\"复习问题\"]"
        try repository.update(edited)

        let prompt = try SummaryPromptRenderer.make(template: edited, previousSummary: "旧摘要", content: "新内容", isFinal: true)
        XCTAssertTrue(prompt.contains("zh-CN"))
        XCTAssertTrue(prompt.contains("只总结给定内容。"))
        XCTAssertTrue(prompt.contains("核心概念"))
        XCTAssertTrue(prompt.contains("复习问题"))
        XCTAssertTrue(prompt.contains("旧摘要"))
        XCTAssertTrue(prompt.contains("新内容"))
    }

    func testSummaryCoordinatorOnlyMakesSuccessfulRevisionCurrent() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let templates = SummaryTemplateRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let transcript = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "whisper", language: "en", status: .succeeded)
        let template = try XCTUnwrap(templates.fetchAll().first)
        let coordinator = SummaryCoordinator(transcripts: transcripts)

        let failed = try await coordinator.generate(meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil, template: template, provider: "NVIDIA", model: "m") { _ in nil }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNil(try meetings.fetch(id: meeting.id)?.currentSummaryRevisionID)

        let succeeded = try await coordinator.generate(meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil, template: template, provider: "NVIDIA", model: "m") { _ in "Useful summary" }
        XCTAssertEqual(succeeded.status, .succeeded)
        XCTAssertEqual(try meetings.fetch(id: meeting.id)?.currentSummaryRevisionID, succeeded.id)
        XCTAssertEqual(try transcripts.fetchSummaryRevisions(meetingID: meeting.id).count, 2)
    }

    func testModelServiceDetectsCorruptionAndBlocksDeletionWhileLeased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("sherpa", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let service = ModelResourceService(resources: [.init(id: "sherpa", displayName: "Sherpa", location: model, requiredFiles: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"], affectedCapability: "实时转写")])

        XCTAssertEqual(service.scan().first?.state, .corrupt)
        for name in ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"] { try Data([1]).write(to: model.appendingPathComponent(name)) }
        XCTAssertEqual(service.scan().first?.state, .ready)
        let lease = service.acquireLease(owner: "recording")
        XCTAssertThrowsError(try service.delete(resourceID: "sherpa"))
        lease.release()
        try service.delete(resourceID: "sherpa")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
    }
}
