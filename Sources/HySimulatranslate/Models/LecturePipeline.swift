import Foundation

struct LectureSegmentMetrics: Equatable, Sendable {
    let duration: TimeInterval
    let rmsDBFS: Double
    let lexicalWordCount: Int

    var isLowValue: Bool {
        duration < 3 || lexicalWordCount <= 3
    }

    static func make(pcmData: Data, text: String) -> LectureSegmentMetrics {
        let duration = Double(pcmData.count) / 32_000.0
        let rms = pcmData.withUnsafeBytes { rawBuffer -> Double in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(0.0) { partial, sample in
                let normalized = Double(sample) / 32_768.0
                return partial + normalized * normalized
            }
            return sqrt(sum / Double(samples.count))
        }
        let rmsDBFS = rms > 0 ? 20 * log10(rms) : -96
        let lexicalWordCount = text.split {
            !$0.isLetter && !$0.isNumber
        }.count
        return LectureSegmentMetrics(
            duration: duration,
            rmsDBFS: rmsDBFS,
            lexicalWordCount: lexicalWordCount
        )
    }
}

enum LectureSegmentDecision: Equatable, Sendable {
    case keep
    case keepFormalQuestion
    case drop
}

struct LectureSpeakerSample: Equatable, Sendable {
    let id: UUID
    let speakerID: String
    let metrics: LectureSegmentMetrics
}

struct LectureSpeakerFocusResult: Equatable, Sendable {
    let mainSpeakerID: String?
    let droppedIDs: [UUID]
}

enum LectureSpeakerFocusReducer {
    static func reduce(samples: [LectureSpeakerSample]) -> LectureSpeakerFocusResult {
        guard !samples.isEmpty else {
            return LectureSpeakerFocusResult(mainSpeakerID: nil, droppedIDs: [])
        }

        var durations: [String: TimeInterval] = [:]
        var levels: [String: [Double]] = [:]
        for sample in samples {
            durations[sample.speakerID, default: 0] += sample.metrics.duration
            levels[sample.speakerID, default: []].append(sample.metrics.rmsDBFS)
        }

        let mainSpeakerID = durations.keys.sorted { lhs, rhs in
            let lhsDuration = durations[lhs, default: 0]
            let rhsDuration = durations[rhs, default: 0]
            if lhsDuration != rhsDuration {
                return lhsDuration > rhsDuration
            }
            let lhsMedian = median(levels[lhs, default: []])
            let rhsMedian = median(levels[rhs, default: []])
            if lhsMedian != rhsMedian {
                return lhsMedian > rhsMedian
            }
            return lhs < rhs
        }.first

        let droppedIDs = samples.compactMap { sample -> UUID? in
            guard sample.speakerID != mainSpeakerID else { return nil }
            return sample.metrics.isLowValue ? sample.id : nil
        }
        return LectureSpeakerFocusResult(
            mainSpeakerID: mainSpeakerID,
            droppedIDs: droppedIDs
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -.infinity }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

struct LectureFocusFilter: Sendable {
    private let calibrationSeconds: TimeInterval
    private let quietOffsetDB: Double
    private var calibrationLevels: [Double] = []
    private var dominantLevelDBFS: Double?

    init(calibrationSeconds: TimeInterval = 30, quietOffsetDB: Double = 12) {
        self.calibrationSeconds = calibrationSeconds
        self.quietOffsetDB = quietOffsetDB
    }

    mutating func evaluate(
        _ metrics: LectureSegmentMetrics,
        elapsed: TimeInterval
    ) -> LectureSegmentDecision {
        guard metrics.lexicalWordCount > 0 else { return .drop }

        if elapsed <= calibrationSeconds {
            if metrics.duration >= 3, metrics.lexicalWordCount >= 4 {
                calibrationLevels.append(metrics.rmsDBFS)
                dominantLevelDBFS = calibrationLevels.max()
            }
            return .keep
        }

        let quietThreshold = (dominantLevelDBFS ?? metrics.rmsDBFS) - quietOffsetDB
        let isQuiet = metrics.rmsDBFS < quietThreshold
        if isQuiet, metrics.isLowValue {
            return .drop
        }
        if isQuiet, metrics.duration >= 3, metrics.lexicalWordCount >= 4 {
            return .keepFormalQuestion
        }

        if metrics.duration >= 3, metrics.lexicalWordCount >= 4 {
            dominantLevelDBFS = max(dominantLevelDBFS ?? metrics.rmsDBFS, metrics.rmsDBFS)
        }
        return .keep
    }
}

enum RefinementLoadState: Equatable, Sendable {
    case normal
    case warning
    case protecting
    case localFallback

    var shortTitle: String {
        switch self {
        case .normal: "云端"
        case .warning: "预警"
        case .protecting: "保护"
        case .localFallback: "本地灾备"
        }
    }
}

enum RefinementAdmission: Equatable, Sendable {
    case refine
    case useSherpa
    case drop
}

enum RefinementBackpressurePolicy {
    static let warningCount = 6
    static let protectingCount = 12
    static let warningAudioSeconds: TimeInterval = 30
    static let protectingAudioSeconds: TimeInterval = 60

    static func loadState(
        pendingCount: Int,
        pendingAudioSeconds: TimeInterval
    ) -> RefinementLoadState {
        if pendingCount >= protectingCount || pendingAudioSeconds >= protectingAudioSeconds {
            return .protecting
        }
        if pendingCount >= warningCount || pendingAudioSeconds >= warningAudioSeconds {
            return .warning
        }
        return .normal
    }

    static func admission(
        for metrics: LectureSegmentMetrics,
        state: RefinementLoadState,
        pendingCount: Int = 0,
        pendingAudioSeconds: TimeInterval = 0
    ) -> RefinementAdmission {
        let wouldExceedAudioLimit =
            pendingAudioSeconds + metrics.duration > protectingAudioSeconds
        let isAtSegmentLimit = pendingCount >= protectingCount
        guard state == .protecting || isAtSegmentLimit || wouldExceedAudioLimit else {
            return .refine
        }
        return metrics.isLowValue ? .drop : .useSherpa
    }
}

enum SmartWhisperRouting {
    static func shouldUseLocalFallback(
        cloudText: String?,
        cloudRequestFailed: Bool
    ) -> Bool {
        if cloudRequestFailed { return true }
        guard let cloudText else { return true }
        return !containsLexicalContent(cloudText)
    }

    static func containsLexicalContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let junkPrompts = ["请提供需要翻译", "没有提供任何英文", "无内容需要翻译"]
        guard !junkPrompts.contains(where: { trimmed.contains($0) }) else { return false }
        return trimmed.range(of: #"[A-Za-z0-9]"#, options: .regularExpression) != nil
    }
}

struct SpeakerDiarizationWindow: Equatable, Sendable {
    let startSample: Int
    let endSample: Int

    var count: Int { endSample - startSample }
}

enum SpeakerDiarizationWindowPlanner {
    static let defaultWindowSeconds = 10 * 60
    static let defaultOverlapSeconds = 30

    static func windows(
        totalSamples: Int,
        sampleRate: Int,
        windowSeconds: Int = defaultWindowSeconds,
        overlapSeconds: Int = defaultOverlapSeconds
    ) -> [SpeakerDiarizationWindow] {
        guard totalSamples > 0, sampleRate > 0 else { return [] }
        let windowSize = max(1, windowSeconds * sampleRate)
        let overlapSize = min(max(0, overlapSeconds * sampleRate), windowSize - 1)

        var result: [SpeakerDiarizationWindow] = []
        var start = 0
        while start < totalSamples {
            let end = min(start + windowSize, totalSamples)
            result.append(SpeakerDiarizationWindow(startSample: start, endSample: end))
            guard end < totalSamples else { break }
            start = end - overlapSize
        }
        return result
    }
}
