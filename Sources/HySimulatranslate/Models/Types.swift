import Foundation

// MARK: - 笔记历史
struct NoteRecord: Identifiable, Equatable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    let fileName: String
    let format: NoteFileFormat
    let modifiedAt: Date
    let fileSize: Int64
    let previewSummary: String?
}

enum NoteFileFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case markdown
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown (.md)"
        case .text: "Text (.txt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .text: "txt"
        }
    }

    static func fromFileExtension(_ fileExtension: String) -> NoteFileFormat? {
        switch fileExtension.lowercased() {
        case "md", "markdown": .markdown
        case "txt": .text
        default: nil
        }
    }
}

enum WorkspaceMode: Equatable {
    case transcription
    case courseSelection
    case audioImport
    case settings
}

enum HistoryDisplayMode: String, CaseIterable, Identifiable {
    case bilingual
    case translationOnly

    static let defaultMode: HistoryDisplayMode = .bilingual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bilingual: "原文+译文"
        case .translationOnly: "仅译文"
        }
    }
}

// MARK: - 同传条目
struct TranscriptionItem: Identifiable, Equatable {
    let id: UUID
    var english: String
    var chinese: String?
    var status: ItemStatus
    var isVisible: Bool
    var isAggregated: Bool
    var zone: ItemZone
    var doneTime: TimeInterval
    var addedToHistory: Bool
    var isSystemMessage: Bool
    var speakerID: String?

    var speakerDisplayName: String {
        SpeakerDisplayName.displayName(for: speakerID)
    }

    init(
        id: UUID = UUID(),
        english: String,
        chinese: String? = nil,
        status: ItemStatus = .whispering,
        isVisible: Bool = true,
        isAggregated: Bool = false,
        zone: ItemZone = .dynamic,
        doneTime: TimeInterval = 0,
        isSystemMessage: Bool = false,
        speakerID: String? = nil
    ) {
        self.id = id
        self.english = english
        self.chinese = chinese
        self.status = status
        self.isVisible = isVisible
        self.isAggregated = isAggregated
        self.zone = zone
        self.doneTime = doneTime
        self.addedToHistory = false
        self.isSystemMessage = isSystemMessage
        self.speakerID = speakerID
    }

    static func == (lhs: TranscriptionItem, rhs: TranscriptionItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum ItemStatus: String {
    case whispering = "whispering"
    case llmFormatting = "llm_formatting"
    case llmAggregating = "llm_aggregating"
    case organizing = "organizing"
    case translating = "translating"
    case done = "done"
    case dropped = "dropped"
}

enum ItemZone: String {
    case dynamic
    case history
}

// MARK: - 强化专项
struct CourseSubject: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var abbrev: String
    var keywords: String
    var meetingFocus: String

    static func == (lhs: CourseSubject, rhs: CourseSubject) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - LLM Format Queue Item
enum LLMTaskType: String {
    case format
    case aggregate
}

enum WhisperRefinementMode: String, CaseIterable, Identifiable {
    case smartHybrid

    var id: String { rawValue }

    var title: String { "智能混合" }

    static func fromStorageValue(_ value: String?) -> WhisperRefinementMode {
        .smartHybrid
    }
}

struct LLMQueueItem {
    let priority: Int
    let timestamp: TimeInterval
    let taskType: LLMTaskType
    let uid: UUID
    let sourceIDs: [UUID]
    let rawText: String
    let whisperText: String
    let sherpaText: String
}

// MARK: - Whisper Queue Item
struct WhisperQueueItem {
    let uid: UUID
    var pcmData: Data
    let sherpaTextBackup: String
    var whisperText: String? = nil
    var vadSpeechRatio: Double? = nil
}

// MARK: - 引擎状态
enum EngineStatus {
    case idle
    case checking(String)
    case ready(String)
    case running(String)
    case error(String)
}
