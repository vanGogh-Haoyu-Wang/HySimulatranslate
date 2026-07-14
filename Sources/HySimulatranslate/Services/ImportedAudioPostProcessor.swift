import Foundation

actor ImportedAudioPostProcessor: ImportedAudioPostProcessing {
    private let transcripts: TranscriptRepository
    private let diarization: SpeakerDiarizationService
    private let exportDirectory: URL
    private let speakers: SpeakerRepository?
    init(transcripts: TranscriptRepository, speakers: SpeakerRepository? = nil, diarization: SpeakerDiarizationService = SpeakerDiarizationService(), exportDirectory: URL) {
        self.transcripts = transcripts; self.speakers = speakers; self.diarization = diarization; self.exportDirectory = exportDirectory
    }
    func diarize(meetingID: UUID, transcriptRevisionID: UUID, snapshot: SessionAudioSnapshot) async throws {
        let segments = try transcripts.fetchSegments(revisionID: transcriptRevisionID)
        let labels = await diarization.diarizeSession(snapshot)
        for var segment in segments where labels[segment.id] != nil { segment.speakerID = labels[segment.id]; try transcripts.save(segment) }
    }
    func export(meetingID: UUID, transcriptRevisionID: UUID, translationRevisionID: UUID?) async throws {
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let segments = try transcripts.fetchSegments(revisionID: transcriptRevisionID)
        let translations = translationRevisionID.map { try? transcripts.fetchTranslations(revisionID: $0) } ?? nil
        let bySegment = Dictionary(uniqueKeysWithValues: (translations ?? []).map { ($0.segmentID, $0.text) })
        let aliases = (try? speakers?.aliases(meetingID: meetingID)) ?? [:]
        let items = segments.map { segment in
            TranscriptionItem(id: segment.id, english: segment.refinedText, chinese: bySegment[segment.id], status: .done, zone: .history, doneTime: segment.endTime, speakerID: segment.speakerID)
        }
        let course = CourseSubject(name: "Imported Audio", abbrev: "Import", keywords: "", meetingFocus: "")
        let body = SessionNoteRenderer.render(course: course, translationEnabled: translationRevisionID != nil, items: items, finalSummary: "", speakerAliases: aliases, format: .markdown)
        let url = exportDirectory.appendingPathComponent("Imported-\(meetingID.uuidString).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
