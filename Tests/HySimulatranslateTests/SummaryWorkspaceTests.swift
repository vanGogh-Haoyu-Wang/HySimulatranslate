import XCTest
@testable import HySimulatranslate

@MainActor
final class SummaryWorkspaceTests: XCTestCase {
    func testWorkspaceRestoresSelectedTemplateAndSupportsCustomCRUDAndCopy() throws {
        let database = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let workspace = SummaryWorkspaceController(database: database, userDefaults: defaults)
        workspace.loadTemplates()
        let builtIn = try XCTUnwrap(workspace.templates.first(where: \.isBuiltIn))
        workspace.selectTemplate(builtIn.id)
        XCTAssertThrowsError(try workspace.updateSelectedTemplate(name: "Changed", language: "en", systemInstruction: "x", sections: ["One"]))

        let custom = try workspace.createTemplate(name: "My Template", language: "zh-CN", systemInstruction: "严谨总结", sections: ["重点"])
        workspace.selectTemplate(custom.id)
        try workspace.updateSelectedTemplate(name: "My Updated", language: "zh-CN", systemInstruction: "只按内容总结", sections: ["重点", "行动"])
        let copied = try workspace.copySelectedTemplate()
        XCTAssertFalse(copied.isBuiltIn)
        XCTAssertNotEqual(copied.id, custom.id)

        let restored = SummaryWorkspaceController(database: database, userDefaults: defaults)
        restored.loadTemplates()
        XCTAssertEqual(restored.selectedTemplateID, copied.id)
        try restored.deleteSelectedTemplate()
        XCTAssertFalse(restored.templates.contains(where: { $0.id == copied.id }))
    }

    func testWorkspaceLoadsAndSelectsSuccessfulSummaryRevisions() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let transcript = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "asr", language: "en", status: .succeeded)
        let workspace = SummaryWorkspaceController(database: database, userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.loadTemplates()
        let template = try XCTUnwrap(workspace.selectedTemplate)
        let failed = try workspace.recordGeneration(meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil, template: template, provider: "nvidia", model: "model", body: nil)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNil(try meetings.fetch(id: meeting.id)?.currentSummaryRevisionID)
        let successful = try workspace.recordGeneration(meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil, template: template, provider: "nvidia", model: "model", body: "Useful summary")
        XCTAssertEqual(try meetings.fetch(id: meeting.id)?.currentSummaryRevisionID, successful.id)

        workspace.load(meeting: try XCTUnwrap(meetings.fetch(id: meeting.id)))
        XCTAssertEqual(workspace.summaryRevisions.map(\.id), [failed.id, successful.id])
        XCTAssertEqual(workspace.displayedSummary, "Useful summary")
        XCTAssertThrowsError(try workspace.selectSummaryRevision(failed.id, meetingID: meeting.id))
        try workspace.selectSummaryRevision(successful.id, meetingID: meeting.id)
        XCTAssertEqual(workspace.displayedSummary, "Useful summary")
    }

    func testTemplatePromptContainsInstructionLanguageSectionsAndFinalMode() throws {
        let template = SummaryTemplateRecord(name: "Class", language: "zh-CN", systemInstruction: "只总结课程", structureJSON: "[\"概念\",\"复习\"]")
        let prompt = try OmniRouteSummaryService.makePrompt(template: template, previousSummary: "旧总结", content: "新内容", isFinal: true)
        XCTAssertTrue(prompt.contains("只总结课程"))
        XCTAssertTrue(prompt.contains("zh-CN"))
        XCTAssertTrue(prompt.contains("概念、复习"))
        XCTAssertTrue(prompt.contains("最终总结"))
        XCTAssertTrue(prompt.contains("旧总结"))
        XCTAssertTrue(prompt.contains("新内容"))
    }

    func testDeletingUsedCustomTemplateSoftDeletesAndPreservesHistoricalTrace() async throws {
        let database = try AppDatabase.inMemory()
        let templates = SummaryTemplateRepository(database: database)
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let custom = try templates.create(.init(name: "Used", language: "zh-CN", systemInstruction: "总结", structureJSON: "[\"重点\"]"))
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let transcript = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "asr", language: "en", status: .succeeded)
        _ = try await SummaryCoordinator(transcripts: transcripts).generate(
            meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil,
            template: custom, provider: "NVIDIA", model: "m", sourceContent: "content"
        ) { _ in "historical summary" }

        try templates.delete(id: custom.id)

        XCTAssertFalse(try templates.fetchAll().contains(where: { $0.id == custom.id }))
        XCTAssertNotNil(try templates.fetch(id: custom.id, includingDeleted: true)?.deletedAt)
        XCTAssertEqual(try transcripts.fetchSummaryRevisions(meetingID: meeting.id).first?.templateID, custom.id)
        try templates.restore(id: custom.id)
        XCTAssertTrue(try templates.fetchAll().contains(where: { $0.id == custom.id }))
    }

    func testLiveFailureIsRecordedWhileSuccessfulAndFinalSummariesRemainSelectable() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let transcript = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "asr", language: "en", status: .succeeded)
        let workspace = SummaryWorkspaceController(database: database, userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.loadTemplates()
        let template = try XCTUnwrap(workspace.selectedTemplate)

        let live = try await workspace.generate(
            meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil,
            template: template, provider: "OmniRoute", model: "auto", previousSummary: "", sourceContent: "live content", isFinal: false
        ) { prompt in XCTAssertTrue(prompt.contains("实时更新")); return "live summary" }
        let failed = try await workspace.generate(
            meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil,
            template: template, provider: "OmniRoute", model: "auto", previousSummary: live.body, sourceContent: "more", isFinal: false
        ) { _ in nil }
        let final = try await workspace.generate(
            meetingID: meeting.id, transcriptRevisionID: transcript.id, translationRevisionID: nil,
            template: template, provider: "OmniRoute", model: "auto", previousSummary: live.body, sourceContent: "all content", isFinal: true
        ) { prompt in XCTAssertTrue(prompt.contains("最终总结")); return "final summary" }

        workspace.load(meeting: try meetings.fetch(id: meeting.id))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(workspace.summaryRevisions.map(\.id), [live.id, failed.id, final.id])
        XCTAssertEqual(workspace.selectableSummaryRevisions.map(\.id), [live.id, final.id])
        XCTAssertEqual(workspace.failedSummaryRevisions.map(\.id), [failed.id])
        XCTAssertEqual(try meetings.fetch(id: meeting.id)?.currentSummaryRevisionID, final.id)
    }

    func testImportedExportUsesMeetingLocalSpeakerAliasesWithoutDuplicatingLabels() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let speakers = SpeakerRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .imported)
        let revision = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .imported, model: "asr", language: "en", status: .succeeded)
        try transcripts.insert(.init(revisionID: revision.id, sequence: 0, startTime: 0, endTime: 1, draftText: nil, refinedText: "Hello", speakerID: "speaker_0", confidence: nil, status: .succeeded))
        try speakers.setAlias(meetingID: meeting.id, speakerID: "speaker_0", displayName: "Alice")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let processor = ImportedAudioPostProcessor(transcripts: transcripts, speakers: speakers, exportDirectory: directory)

        _ = try await processor.export(meetingID: meeting.id, transcriptRevisionID: revision.id, translationRevisionID: nil)

        let output = try String(contentsOf: directory.appendingPathComponent("Imported-\(meeting.id.uuidString).md"))
        XCTAssertTrue(output.contains("Alice: Hello"))
        XCTAssertFalse(output.contains("[Alice]"))
        XCTAssertFalse(output.contains("Speaker 1"))
    }
}
