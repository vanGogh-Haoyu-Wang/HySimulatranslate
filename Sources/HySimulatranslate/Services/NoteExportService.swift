import Foundation

struct NoteExportService {
    func export(course: CourseSubject, translationEnabled: Bool, items: [TranscriptionItem], finalSummary: String, speakerAliases: [String: String], format: NoteFileFormat, to url: URL) throws {
        let content = SessionNoteRenderer.render(course: course, translationEnabled: translationEnabled, items: items, finalSummary: finalSummary, speakerAliases: speakerAliases, format: format)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum NoteWriteResult: Equatable, Sendable {
    case written(URL)
    case skipped
    case failed(URL, String)
}

actor NoteWriteCoordinator {
    private var newestRevision: UInt64 = 0

    func write(content: String, to url: URL, revision: UInt64) -> NoteWriteResult {
        guard revision >= newestRevision else { return .skipped }
        newestRevision = revision
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .written(url)
        } catch {
            return .failed(url, error.localizedDescription)
        }
    }
}
