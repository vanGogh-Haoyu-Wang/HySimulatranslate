import Foundation

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

    init(
        id: UUID = UUID(),
        english: String,
        chinese: String? = nil,
        status: ItemStatus = .whispering,
        isVisible: Bool = true,
        isAggregated: Bool = false,
        zone: ItemZone = .dynamic,
        doneTime: TimeInterval = 0,
        isSystemMessage: Bool = false
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
struct CourseSubject: Identifiable, Codable, Equatable {
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
    case localFirst
    case cloudFirst
    case localOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localFirst: return "本地优先"
        case .cloudFirst: return "云端优先"
        case .localOnly: return "仅本地"
        }
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
    var denoisedPCMData: Data? = nil
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
