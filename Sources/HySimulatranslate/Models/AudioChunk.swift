import Foundation

enum AudioChunkSource: String, CaseIterable, Hashable, Sendable {
    case microphone
    case systemAudio
}

struct AudioChunk: Equatable, Sendable {
    let source: AudioChunkSource
    let samples: [Float]
    let sampleRate: Int
    let sessionStartTime: TimeInterval

    init(source: AudioChunkSource, samples: [Float], sampleRate: Int, sessionStartTime: TimeInterval) {
        self.source = source
        self.samples = samples
        self.sampleRate = sampleRate
        self.sessionStartTime = sessionStartTime
    }
}
