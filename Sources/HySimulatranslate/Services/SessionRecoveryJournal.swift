import Foundation

struct SessionRecoveryMetadata: Codable, Equatable, Sendable {
    let notePath: String
    let courseName: String
    let courseAbbrev: String
    let translationEnabled: Bool
    let noteFormat: NoteFileFormat
}

struct RecoveredTranscriptItem: Equatable, Sendable {
    let id: UUID
    var english: String
    var chinese: String?
}

struct RecoveredSession: Equatable, Sendable {
    let metadata: SessionRecoveryMetadata
    let items: [RecoveredTranscriptItem]
}

final class SessionRecoveryJournal: @unchecked Sendable {
    static let fileName = "session.jsonl"

    private struct JournalLine: Codable {
        enum Kind: String, Codable {
            case header
            case segment
            case refinement
            case translation
            case completed
        }

        let kind: Kind
        let metadata: SessionRecoveryMetadata?
        let uid: UUID?
        let english: String?
        let chinese: String?
        let timestamp: TimeInterval
    }

    private let lock = NSLock()
    private var handle: FileHandle?
    private var journalURL: URL?
    private let encoder = JSONEncoder()

    deinit {
        try? handle?.close()
    }

    func begin(
        directory: URL,
        metadata: SessionRecoveryMetadata
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(Self.fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? handle?.close()
        handle = try FileHandle(forWritingTo: url)
        journalURL = url
        try writeLine(
            JournalLine(
                kind: .header,
                metadata: metadata,
                uid: nil,
                english: nil,
                chinese: nil,
                timestamp: Date().timeIntervalSince1970
            )
        )
    }

    func recordSegment(uid: UUID, sherpaText: String) throws {
        try append(kind: .segment, uid: uid, english: sherpaText, chinese: nil)
    }

    func recordRefinement(uid: UUID, english: String) throws {
        try append(kind: .refinement, uid: uid, english: english, chinese: nil)
    }

    func recordTranslation(uid: UUID, chinese: String) throws {
        try append(kind: .translation, uid: uid, english: nil, chinese: chinese)
    }

    func markCompleted() throws {
        try append(kind: .completed, uid: nil, english: nil, chinese: nil)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    static func loadRecoverableSession(from url: URL) throws -> RecoveredSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        let rawLines = text.split(whereSeparator: \.isNewline)
        var lines: [JournalLine] = []
        lines.reserveCapacity(rawLines.count)
        for (index, rawLine) in rawLines.enumerated() {
            do {
                lines.append(
                    try decoder.decode(JournalLine.self, from: Data(rawLine.utf8))
                )
            } catch where index == rawLines.indices.last && !text.hasSuffix("\n") {
                // A forced shutdown can truncate only the final append.
                continue
            }
        }

        guard !lines.contains(where: { $0.kind == .completed }),
              let metadata = lines.first(where: { $0.kind == .header })?.metadata
        else { return nil }

        var order: [UUID] = []
        var items: [UUID: RecoveredTranscriptItem] = [:]
        for line in lines {
            guard let uid = line.uid else { continue }
            switch line.kind {
            case .segment:
                if items[uid] == nil {
                    order.append(uid)
                }
                items[uid] = RecoveredTranscriptItem(
                    id: uid,
                    english: line.english ?? "",
                    chinese: items[uid]?.chinese
                )
            case .refinement:
                if items[uid] == nil {
                    order.append(uid)
                }
                items[uid] = RecoveredTranscriptItem(
                    id: uid,
                    english: line.english ?? items[uid]?.english ?? "",
                    chinese: items[uid]?.chinese
                )
            case .translation:
                if items[uid] == nil {
                    order.append(uid)
                }
                items[uid] = RecoveredTranscriptItem(
                    id: uid,
                    english: items[uid]?.english ?? "",
                    chinese: line.chinese
                )
            case .header, .completed:
                break
            }
        }

        return RecoveredSession(
            metadata: metadata,
            items: order.compactMap { items[$0] }
        )
    }

    static func recoverPendingSessions(rootDirectory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path),
              let enumerator = FileManager.default.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        let journalURLs = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == fileName }
            .sorted { $0.path < $1.path }

        var recoveredURLs: [URL] = []
        for journalURL in journalURLs {
            guard let session = try loadRecoverableSession(from: journalURL) else { continue }
            let recoveredItems = session.items.compactMap { item -> TranscriptionItem? in
                let english = item.english.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !english.isEmpty else { return nil }
                return TranscriptionItem(
                    id: item.id,
                    english: english,
                    chinese: item.chinese,
                    status: .done,
                    zone: .history,
                    doneTime: Date().timeIntervalSince1970
                )
            }
            guard !recoveredItems.isEmpty else { continue }

            let metadata = session.metadata
            let noteURL = URL(fileURLWithPath: metadata.notePath)
            try FileManager.default.createDirectory(
                at: noteURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let course = CourseSubject(
                name: metadata.courseName,
                abbrev: metadata.courseAbbrev,
                keywords: "",
                meetingFocus: ""
            )
            let content = SessionNoteRenderer.render(
                course: course,
                translationEnabled: metadata.translationEnabled,
                items: recoveredItems,
                finalSummary: "会话异常中断，以下内容由恢复日志重建，未完成的精校或翻译可能使用原始识别结果。",
                format: metadata.noteFormat
            )
            try content.write(to: noteURL, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(
                at: journalURL.deletingLastPathComponent()
            )
            recoveredURLs.append(noteURL)
        }
        return recoveredURLs
    }

    private func append(
        kind: JournalLine.Kind,
        uid: UUID?,
        english: String?,
        chinese: String?
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeLine(
            JournalLine(
                kind: kind,
                metadata: nil,
                uid: uid,
                english: english,
                chinese: chinese,
                timestamp: Date().timeIntervalSince1970
            )
        )
    }

    private func writeLine(_ line: JournalLine) throws {
        guard let handle else {
            throw NSError(
                domain: "SessionRecoveryJournal",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "恢复日志尚未初始化"]
            )
        }
        var data = try encoder.encode(line)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
