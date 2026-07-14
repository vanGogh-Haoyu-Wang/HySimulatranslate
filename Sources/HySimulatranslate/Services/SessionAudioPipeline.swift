import Foundation

final class SessionAudioPipeline: @unchecked Sendable {
    let outputSampleRate: Int
    private let enabledSources: Set<AudioChunkSource>
    private let maximumAlignmentLatencySamples: Int
    private let assetStore: AudioAssetStore
    private let lock = NSLock()
    private var tracks: [AudioChunkSource: [Float]] = [:]
    private var receivedEnds: [AudioChunkSource: Int] = [:]
    private var mixed: [Float] = []
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
        self.maximumAlignmentLatencySamples = max(0, Int((maximumAlignmentLatency * Double(outputSampleRate)).rounded()))
        self.assetStore = try AudioAssetStore(sessionID: sessionID, rootDirectory: rootDirectory, sampleRate: outputSampleRate, enabledSources: enabledSources)
        for source in enabledSources { tracks[source] = []; receivedEnds[source] = 0 }
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
        var track = tracks[chunk.source] ?? []
        if track.count < start + converted.count { track.append(contentsOf: repeatElement(0, count: start + converted.count - track.count)) }
        for index in converted.indices { track[start + index] = converted[index] }
        tracks[chunk.source] = track
        receivedEnds[chunk.source] = max(receivedEnds[chunk.source] ?? 0, start + converted.count)
        try assetStore.persist(source: chunk.source, samples: converted, at: start)

        let normalWatermark = enabledSources.compactMap { receivedEnds[$0] }.min() ?? 0
        let furthestReceived = receivedEnds.values.max() ?? 0
        let boundedWatermark = max(0, furthestReceived - maximumAlignmentLatencySamples)
        let commitEnd = min(furthestReceived, max(normalWatermark, boundedWatermark))
        guard commitEnd > committedSampleCount else { return [] }
        var emitted: [Float] = []
        emitted.reserveCapacity(commitEnd - committedSampleCount)
        for index in committedSampleCount..<commitEnd {
            let sum = enabledSources.reduce(Float.zero) { partial, source in
                partial + ((tracks[source]?.indices.contains(index) == true) ? tracks[source]![index] : 0)
            }
            emitted.append(max(-1, min(1, sum)))
        }
        mixed.append(contentsOf: emitted)
        committedSampleCount = commitEnd
        try assetStore.persistMixed(samples: emitted, at: committedSampleCount - emitted.count)
        return emitted
    }

    func finalize() throws -> SessionAudioAssets {
        lock.lock(); defer { lock.unlock() }
        if let finalizedAssets { return finalizedAssets }
        let maximumEnd = receivedEnds.values.max() ?? 0
        let previouslyPersistedMixedCount = mixed.count
        if maximumEnd > committedSampleCount {
            for index in committedSampleCount..<maximumEnd {
                let sum = enabledSources.reduce(Float.zero) { partial, source in
                    partial + ((tracks[source]?.indices.contains(index) == true) ? tracks[source]![index] : 0)
                }
                mixed.append(max(-1, min(1, sum)))
            }
            committedSampleCount = maximumEnd
        }
        if mixed.count > previouslyPersistedMixedCount {
            try assetStore.persistMixed(
                samples: Array(mixed[previouslyPersistedMixedCount..<mixed.count]),
                at: previouslyPersistedMixedCount
            )
        }
        let assets = try assetStore.finalize(mixedSamples: mixed)
        finalizedAssets = assets
        return assets
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

private struct SourceResamplingState: Sendable {
    var resampler: StreamingAudioResampler
    let outputTimelineOrigin: Int
    var expectedNextInputTime: TimeInterval
}
