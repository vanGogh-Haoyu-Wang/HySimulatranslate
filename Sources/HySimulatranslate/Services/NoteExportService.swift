import Foundation

struct NoteExportService {
    func export(course: CourseSubject, translationEnabled: Bool, items: [TranscriptionItem], finalSummary: String, speakerAliases: [String: String], format: NoteFileFormat, to url: URL) throws {
        let content = SessionNoteRenderer.render(course: course, translationEnabled: translationEnabled, items: items, finalSummary: finalSummary, speakerAliases: speakerAliases, format: format)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
