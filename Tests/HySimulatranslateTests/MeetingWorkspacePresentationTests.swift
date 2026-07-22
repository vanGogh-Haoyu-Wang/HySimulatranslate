import Foundation
import Testing
@testable import HySimulatranslate

@Suite("Meeting workspace presentation")
struct MeetingWorkspacePresentationTests {
    @MainActor @Test("indexed legacy meeting loads its source file into the shared note preview")
    func indexedLegacyMeetingLoadsPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.md")
        try "# Restored preview\n\nBody".write(to: url, atomically: true, encoding: .utf8)
        let meeting = MeetingRecord(title: "Legacy", source: .legacyImported, legacyNotePath: url.path)
        let vm = TranscriptionViewModel()

        await vm.selectMeetingForNavigation(meeting)

        #expect(vm.selectedMeeting?.id == meeting.id)
        #expect(vm.selectedNoteRecord?.url.standardizedFileURL == url.standardizedFileURL)
        #expect(vm.notePreviewText.contains("Restored preview"))
        #expect(vm.notePreviewStatus == "已载入")
    }

    @MainActor @Test("linked live meeting keeps meeting selection and loads note while defaulting to summary")
    func linkedLiveMeetingLoadsNoteWithoutReplacingMeeting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("linked.md")
        try "# Linked note".write(to: url, atomically: true, encoding: .utf8)
        let meeting = MeetingRecord(title: "Live", source: .live, exportedNotePath: url.path)
        let vm = TranscriptionViewModel()

        await vm.selectMeetingForNavigation(meeting)

        #expect(vm.selectedMeeting?.id == meeting.id)
        #expect(vm.selectedNoteRecord?.url.standardizedFileURL == url.standardizedFileURL)
        #expect(vm.meetingRightPanelMode == .summary)
        vm.meetingRightPanelMode = .note
        #expect(vm.selectedMeeting?.id == meeting.id)
        #expect(vm.notePreviewText.contains("Linked note"))
    }

    @MainActor @Test("missing linked note can be re-exported without replacing the meeting")
    func missingLinkedNoteCanBeReexported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missing.md")
        let meeting = MeetingRecord(title: "Recovered", source: .live, exportedNotePath: url.path)
        let vm = TranscriptionViewModel()
        await vm.selectMeetingForNavigation(meeting)
        #expect(vm.notePreviewStatus.contains("读取失败"))

        await vm.reexportSelectedMeetingNote()

        #expect(vm.selectedMeeting?.id == meeting.id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(vm.notePreviewStatus == "已载入")
        #expect(vm.notePreviewText.contains("Recovered"))
    }

    @Test("meeting actions reflect actual audio and successful transcript availability")
    func meetingActionsReflectAvailableData() {
        let meeting = MeetingRecord(title: "Legacy", source: .legacyImported, legacyNotePath: "/tmp/note.md")
        let revision = TranscriptRevisionRecord(meetingID: meeting.id, number: 1, source: .imported, model: "m", language: "en", status: .succeeded)

        let previewOnly = MeetingDetailCapabilities(meeting: meeting, hasPlayableAudio: false, revisions: [], selectedRevisionID: nil)
        #expect(previewOnly.isLegacyPreviewOnly)
        #expect(!previewOnly.canRetranscribe)
        #expect(!previewOnly.canRetranslate)

        let processable = MeetingDetailCapabilities(meeting: meeting, hasPlayableAudio: true, revisions: [revision], selectedRevisionID: revision.id)
        #expect(!processable.isLegacyPreviewOnly)
        #expect(processable.canRetranscribe)
        #expect(processable.canRetranslate)
    }

    @Test("audio import defaults use localized language and typed local model options")
    func audioImportLanguageAndModelDefaults() {
        let state = AudioImportFormState()
        #expect(state.sourceLanguage == .english)
        #expect(state.targetLanguage == .chinese)
        #expect(AudioImportLanguageOption.english.title == "英语")
        #expect(AudioImportLanguageOption.chinese.title == "中文")
        #expect(AudioImportLanguageOption.english.code == "en")
        #expect(AudioImportLanguageOption.chinese.code == "zh")
        #expect(state.makeOptions().sourceLanguage == "en")
        #expect(state.makeOptions().targetLanguage == "zh")
        #expect(state.makeOptions().whisperModel == WhisperKitService.defaultModel)
    }

    @Test("audio import selection accepts only supported audio and start is gated while running")
    func audioImportSelectionAndStartGate() {
        let supported = URL(fileURLWithPath: "/tmp/meeting.M4A")
        let unsupported = URL(fileURLWithPath: "/tmp/notes.pdf")

        #expect(AudioImportFormState.firstSupportedURL(in: [unsupported, supported]) == supported)
        #expect(AudioImportFormState.firstSupportedURL(in: [unsupported]) == nil)
        #expect(AudioImportFormState.canStart(selectedURL: supported, isImporting: false))
        #expect(!AudioImportFormState.canStart(selectedURL: supported, isImporting: true))
        #expect(!AudioImportFormState.canStart(selectedURL: nil, isImporting: false))
    }

    @Test("workspace column sizing never produces negative geometry during transitions")
    func workspaceColumnSizingIsNonnegative() {
        #expect(WorkspaceColumnLayout.rightWidth(totalWidth: 0, spacing: 12) == 0)
        #expect(WorkspaceColumnLayout.rightWidth(totalWidth: 500, spacing: 12) >= 0)
        let normal = WorkspaceColumnLayout.rightWidth(totalWidth: 1_000, spacing: 12)
        #expect(normal >= 280)
        #expect(normal <= 1_000 - 12 - 320)
    }
}
