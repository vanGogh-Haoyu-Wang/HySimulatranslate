import Foundation

final class SessionAudioPipeline: @unchecked Sendable {
    let outputSampleRate: Int
    private let enabledSources: Set<AudioChunkSource>
    private let maximumAlignmentLatencySamples: Int
    private let assetStore: AudioAssetStore
    private let lock = NSLock()
    private var tracks: [AudioChunkSource: PendingAudioTrack] = [:]
    private var receivedEnds: [AudioChunkSource: Int] = [:]
    private var committedSampleCount = 0
    private var finalizedAssets: SessionAudioAssets?
    private var resamplingStates: [AudioChunkSource: SourceResamplingState] = [:]

    init(
        sessionID: UUID,
        rootDirectory: URL,
        enabledSources: Set<AudioChunkSource>,
        outputSampleRate: Int = 16_000,
        maximumAlignmentLatency: TimeInterval = 0.5
    ) throws {
        precondition(outputSampleRate > 0)
        precondition(!enabledSources.isEmpty)
        self.outputSampleRate = outputSampleRate
        self.enabledSources = enabledSources
        maximumAlignmentLatencySamples = max(0, Int((maximumAlignmentLatency * Double(outputSampleRate)).rounded()))
        assetStore = try AudioAssetStore(
            sessionID: sessionID,
            rootDirectory: rootDirectory,
            sampleRate: outputSampleRate,
            enabledSources: enabledSources
        )
        for source in enabledSources {
            tracks[source] = PendingAudioTrack()
            receivedEnds[source] = 0
        }
    }

    func accept(_ chunk: AudioChunk) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard finalizedAssets == nil else { throw PipelineError.alreadyFinalized }
        guard enabledSources.contains(chunk.source) else { throw PipelineError.disabledSource }
        guard chunk.sampleRate > 0, chunk.sessionStartTime >= 0 else { throw PipelineError.invalidChunk }

        var state = resamplingState(for: chunk)
        let startBeforeCropping = state.outputTimelineOrigin + state.resampler.outputSampleCount
        var converted = state.resampler.process(chunk.samples)
        state.expectedNextInputTime = chunk.sessionStartTime + Double(chunk.samples.count) / Double(chunk.sampleRate)
        resamplingStates[chunk.source] = state

        var start = startBeforeCropping
        if start < committedSampleCount {
            let committedPrefix = min(converted.count, committedSampleCount - start)
            converted.removeFirst(committedPrefix)
            start += committedPrefix
        }
        guard !converted.isEmpty else { return [] }

        tracks[chunk.source, default: PendingAudioTrack()].write(converted, at: start)
        receivedEnds[chunk.source] = max(receivedEnds[chunk.source] ?? 0, start + converted.count)
        try assetStore.persist(source: chunk.source, samples: converted, at: start)

        let normalWatermark = enabledSources.compactMap { receivedEnds[$0] }.min() ?? 0
        let furthestReceived = receivedEnds.values.max() ?? 0
        let boundedWatermark = max(0, furthestReceived - maximumAlignmentLatencySamples)
        let commitEnd = min(furthestReceived, max(normalWatermark, boundedWatermark))
        return try commit(upTo: commitEnd)
    }

    func finalize() throws -> SessionAudioAssets {
        lock.lock(); defer { lock.unlock() }
        if let finalizedAssets { return finalizedAssets }
        _ = try commit(upTo: receivedEnds.values.max() ?? 0)
        let assets = try assetStore.finalize(totalSamples: committedSampleCount)
        finalizedAssets = assets
        return assets
    }

    var bufferedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tracks.values.reduce(0) { $0 + $1.samples.count }
    }

    private func commit(upTo end: Int) throws -> [Float] {
        guard end > committedSampleCount else { return [] }
        var emitted: [Float] = []
        emitted.reserveCapacity(end - committedSampleCount)
        for index in committedSampleCount..<end {
            let sum = enabledSources.reduce(Float.zero) { partial, source in
                partial + (tracks[source]?.sample(at: index) ?? 0)
            }
            emitted.append(max(-1, min(1, sum)))
        }
        try assetStore.persistMixed(samples: emitted, at: committedSampleCount)
        committedSampleCount = end
        for source in enabledSources {
            tracks[source]?.discard(before: committedSampleCount)
        }
        return emitted
    }

    private func resamplingState(for chunk: AudioChunk) -> SourceResamplingState {
        if let existing = resamplingStates[chunk.source],
           existing.resampler.sourceRate == chunk.sampleRate,
           abs(existing.expectedNextInputTime - chunk.sessionStartTime) <= 0.5 / Double(chunk.sampleRate) {
            return existing
        }
        return SourceResamplingState(
            resampler: StreamingAudioResampler(sourceRate: chunk.sampleRate, targetRate: outputSampleRate),
            outputTimelineOrigin: Int((chunk.sessionStartTime * Double(outputSampleRate)).rounded()),
            expectedNextInputTime: chunk.sessionStartTime
        )
    }

    enum PipelineError: LocalizedError {
        case alreadyFinalized, disabledSource, invalidChunk
        var errorDescription: String? {
            switch self {
            case .alreadyFinalized: return "会话音频已经完成"
            case .disabledSource: return "音频来源未启用"
            case .invalidChunk: return "音频块参数无效"
            }
        }
    }
}

private struct PendingAudioTrack {
    private(set) var origin = 0
    private(set) var samples: [Float] = []

    mutating func write(_ values: [Float], at start: Int) {
        guard !values.isEmpty else { return }
        if samples.isEmpty {
            origin = start
            samples = values
            return
        }
        if start < origin {
            samples.insert(contentsOf: repeatElement(0, count: origin - start), at: 0)
            origin = start
        }
        let offset = start - origin
        if samples.count < offset + values.count {
            samples.append(contentsOf: repeatElement(0, count: offset + values.count - samples.count))
        }
        samples.replaceSubrange(offset..<(offset + values.count), with: values)
    }

    func sample(at index: Int) -> Float? {
        let offset = index - origin
        return samples.indices.contains(offset) ? samples[offset] : nil
    }

    mutating func discard(before index: Int) {
        let count = min(samples.count, max(0, index - origin))
        guard count > 0 else { return }
        samples.removeFirst(count)
        origin += count
        if samples.isEmpty { origin = index }
    }
}

private struct SourceResamplingState: Sendable {
    var resampler: StreamingAudioResampler
    let outputTimelineOrigin: Int
    var expectedNextInputTime: TimeInterval
}
