import Foundation
import GRDB

enum MeetingSource: String, Codable, DatabaseValueConvertible { case live, imported, legacyImported }
enum PersistenceStatus: String, Codable, DatabaseValueConvertible { case draft, processing, succeeded, failed, cancelled, ready }
enum AudioTrack: String, Codable, DatabaseValueConvertible { case microphone, system, mixed, imported }

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "meetings"
    var id: UUID = UUID()
    var title: String
    var subjectID: UUID?
    var source: MeetingSource
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var duration: Double = 0
    var status: PersistenceStatus = .draft
    var currentTranscriptRevisionID: UUID?
    var currentTranslationRevisionID: UUID?
    var currentSummaryRevisionID: UUID?
    var legacyNotePath: String?
    var exportedNotePath: String?
    var preview: String?
    var deletedAt: Date?
}

struct AudioAssetRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "audioAssets"
    var id: UUID = UUID()
    var meetingID: UUID
    var track: AudioTrack
    var path: String
    var format: String
    var sampleRate: Double
    var channelCount: Int
    var duration: Double
    var status: PersistenceStatus
}

struct TranscriptRevisionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "transcriptRevisions"
    var id: UUID = UUID(); var meetingID: UUID; var number: Int; var source: MeetingSource
    var model: String; var language: String; var status: PersistenceStatus
    var createdAt: Date = Date(); var errorMessage: String?
}

struct TranscriptSegmentRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "transcriptSegments"
    var id: UUID = UUID(); var revisionID: UUID; var sequence: Int
    var startTime: Double; var endTime: Double; var draftText: String?
    var refinedText: String; var speakerID: String?; var confidence: Double?
    var status: PersistenceStatus
}

struct TranslationRevisionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "translationRevisions"
    var id: UUID = UUID(); var meetingID: UUID; var transcriptRevisionID: UUID
    var targetLanguage: String; var provider: String; var model: String
    var status: PersistenceStatus; var createdAt: Date = Date(); var errorMessage: String?
}

struct SegmentTranslationRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "segmentTranslations"
    var id: UUID = UUID(); var translationRevisionID: UUID; var segmentID: UUID; var text: String
}

struct SpeakerAliasRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "speakerAliases"
    var id: UUID = UUID(); var meetingID: UUID; var speakerID: String; var displayName: String
}

struct SummaryRevisionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "summaryRevisions"
    var id: UUID = UUID(); var meetingID: UUID; var transcriptRevisionID: UUID
    var translationRevisionID: UUID?; var templateID: UUID; var provider: String
    var model: String; var body: String; var status: PersistenceStatus
    var createdAt: Date = Date(); var errorMessage: String?
}

struct SummaryTemplateRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "summaryTemplates"
    var id: UUID = UUID(); var name: String; var language: String
    var systemInstruction: String; var structureJSON: String
    var isBuiltIn: Bool = false; var updatedAt: Date = Date(); var deletedAt: Date?
}

struct ImportOptions: Codable, Equatable, Sendable {
    var subjectID: UUID?; var sourceLanguage: String; var translate: Bool; var targetLanguage: String
    var whisperModel: String; var diarize: Bool; var maximumSegmentDuration: Double = 20
}

struct ImportJobRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "importJobs"
    var id: UUID = UUID(); var meetingID: UUID; var sourcePath: String; var optionsJSON: Data
    var status: PersistenceStatus = .processing; var progress: Double = 0
    var transcriptRevisionID: UUID?; var translationRevisionID: UUID?
    var createdAt: Date = Date(); var updatedAt: Date = Date(); var errorMessage: String?
    var nextSegmentSequence: Int = 0
}
