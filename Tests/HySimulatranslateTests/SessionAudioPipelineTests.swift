import AVFoundation
import XCTest
@testable import HySimulatranslate

final class SessionAudioPipelineTests: XCTestCase {
    func testAudioChunkCarriesSourceRateAndSessionTimestamp() {
        let chunk = AudioChunk(source: .microphone, samples: [0.25], sampleRate: 48_000, sessionStartTime: 1.5)
        XCTAssertEqual(chunk.source, .microphone)
        XCTAssertEqual(chunk.sampleRate, 48_000)
        XCTAssertEqual(chunk.sessionStartTime, 1.5)
    }

    func testPipelineAlignsSourcesMixesAndProtectsAgainstClipping() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SessionAudioPipeline(
            sessionID: UUID(), rootDirectory: root,
            enabledSources: [.microphone, .systemAudio], outputSampleRate: 16_000
        )

        XCTAssertTrue(try pipeline.accept(AudioChunk(source: .microphone, samples: [0.8, 0.8], sampleRate: 16_000, sessionStartTime: 0)).isEmpty)
        let mixed = try pipeline.accept(AudioChunk(source: .systemAudio, samples: [0.8, -0.8], sampleRate: 16_000, sessionStartTime: 0))

        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed[0], 1, accuracy: 0.0001)
        XCTAssertEqual(mixed[1], 0, accuracy: 0.0001)
    }

    func testPipelineResamplesAndPreservesTimestampGap() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SessionAudioPipeline(
            sessionID: UUID(), rootDirectory: root,
            enabledSources: [.microphone], outputSampleRate: 16_000
        )
        let emitted = try pipeline.accept(AudioChunk(
            source: .microphone, samples: [0, 1], sampleRate: 8_000,
            sessionStartTime: 2.0 / 16_000.0
        ))
        XCTAssertEqual(emitted.count, 6)
        XCTAssertEqual(Array(emitted.prefix(2)), [0, 0])
        XCTAssertEqual(emitted[2], 0, accuracy: 0.0001)
        XCTAssertEqual(emitted[3], 0.5, accuracy: 0.0001)
        XCTAssertEqual(emitted[4], 1, accuracy: 0.0001)
    }

    func testFinalizeWritesValidMonoWAVAssetsAndProvidesFallback() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SessionAudioPipeline(
            sessionID: UUID(), rootDirectory: root,
            enabledSources: [.microphone], outputSampleRate: 16_000
        )
        _ = try pipeline.accept(AudioChunk(source: .microphone, samples: [0.25, -0.25], sampleRate: 16_000, sessionStartTime: 0))
        let assets = try pipeline.finalize()

        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.microphoneWAV.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.mixedWAV.path))
        XCTAssertEqual(try Data(contentsOf: assets.mixedWAV).prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(assets.playbackURL, assets.m4aURL ?? assets.mixedWAV)
        XCTAssertEqual(assets.totalSamples, 2)
        if let m4a = assets.m4aURL {
            let readable = try AVAudioFile(forReading: m4a)
            XCTAssertGreaterThan(readable.length, 0)
            XCTAssertEqual(m4a.pathExtension, "m4a")
        }
    }

    func testWAVIsRecoverableBeforeFinalizeAndGrowsIncrementally() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let pipeline = try SessionAudioPipeline(sessionID: sessionID, rootDirectory: root, enabledSources: [.microphone])
        let wav = root.appendingPathComponent(sessionID.uuidString).appendingPathComponent("microphone.wav")
        _ = try pipeline.accept(AudioChunk(source: .microphone, samples: [0.1, 0.2], sampleRate: 16_000, sessionStartTime: 0))
        let firstSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? NSNumber).intValue
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 2)
        _ = try pipeline.accept(AudioChunk(source: .microphone, samples: [0.3, 0.4], sampleRate: 16_000, sessionStartTime: 2.0 / 16_000))
        let secondSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? NSNumber).intValue
        XCTAssertEqual(secondSize - firstSize, 4)
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 4)
    }

    func testLateChunkIsCroppedAtCommittedWatermark() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SessionAudioPipeline(sessionID: UUID(), rootDirectory: root, enabledSources: [.microphone])
        XCTAssertEqual(try pipeline.accept(AudioChunk(source: .microphone, samples: [0.1, 0.2], sampleRate: 16_000, sessionStartTime: 0)).count, 2)
        let late = try pipeline.accept(AudioChunk(source: .microphone, samples: [0.9, 0.8, 0.7], sampleRate: 16_000, sessionStartTime: 1.0 / 16_000))
        XCTAssertEqual(late, [0.8, 0.7])
        XCTAssertEqual(try pipeline.finalize().totalSamples, 4)
    }

    func testMissingDualInputAdvancesAfterBoundedLatencyWithSilence() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SessionAudioPipeline(
            sessionID: UUID(), rootDirectory: root,
            enabledSources: [.microphone, .systemAudio], outputSampleRate: 16_000,
            maximumAlignmentLatency: 0.001
        )
        let emitted = try pipeline.accept(AudioChunk(
            source: .microphone, samples: Array(repeating: 0.25, count: 32),
            sampleRate: 16_000, sessionStartTime: 0
        ))
        XCTAssertEqual(emitted.count, 16)
        XCTAssertTrue(emitted.allSatisfy { abs($0 - 0.25) < 0.0001 })
        let assets = try pipeline.finalize()
        XCTAssertEqual(try AVAudioFile(forReading: assets.mixedWAV).length, 32)
    }

    func testSherpaSegmentTimelineUsesAcceptedSampleOffsets() {
        var timeline = SherpaSegmentTimeline(sampleRate: 16_000)
        timeline.accept(sampleCount: 8_000)
        let first = timeline.finishSegment(retainedOverlapSamples: 1_600)
        timeline.accept(sampleCount: 4_000)
        let second = timeline.finishSegment(retainedOverlapSamples: 0)

        XCTAssertEqual(first.startTime, 0, accuracy: 0.0001)
        XCTAssertEqual(first.endTime, 0.5, accuracy: 0.0001)
        XCTAssertEqual(second.startTime, 0.4, accuracy: 0.0001)
        XCTAssertEqual(second.endTime, 0.75, accuracy: 0.0001)
    }

    func testSherpaTimelineConvertsNon16kAcceptedSamplesToSeconds() {
        var timeline = SherpaSegmentTimeline(sampleRate: 16_000)
        timeline.accept(sampleCount: 24_000, sampleRate: 48_000)
        let segment = timeline.finishSegment(retainedOverlapSamples: 0)
        XCTAssertEqual(segment.endTime, 0.5, accuracy: 0.0001)
    }

    func testStreamingResamplerPreservesRemainderAcrossTiny44100And48000Chunks() {
        var fortyFour = StreamingAudioResampler(sourceRate: 44_100, targetRate: 16_000)
        let output441 = (0..<441).flatMap { _ in fortyFour.process([0.25]) }
        XCTAssertEqual(output441.count, 160)

        var fortyEight = StreamingAudioResampler(sourceRate: 48_000, targetRate: 16_000)
        let output480 = (0..<480).flatMap { _ in fortyEight.process([0.25]) }
        XCTAssertEqual(output480.count, 160)
    }

    func testNormalizedSherpaTimelineOverlapUses16kSampleDurationAcrossChunks() {
        var resampler = StreamingAudioResampler(sourceRate: 48_000, targetRate: 16_000)
        var timeline = SherpaSegmentTimeline(sampleRate: 16_000)
        for _ in 0..<100 {
            timeline.accept(sampleCount: resampler.process(Array(repeating: 0.1, count: 480)).count)
        }
        let first = timeline.finishSegment(retainedOverlapSamples: 1_600)
        for _ in 0..<10 {
            timeline.accept(sampleCount: resampler.process(Array(repeating: 0.1, count: 480)).count)
        }
        let second = timeline.finishSegment(retainedOverlapSamples: 0)

        XCTAssertEqual(first.endTime, 1.0, accuracy: 0.0001)
        XCTAssertEqual(second.startTime, 0.9, accuracy: 0.0001)
        XCTAssertEqual(second.endTime, 1.1, accuracy: 0.0001)
    }

    func testPipelineTinyChunksDoNotAccumulateResamplingDrift() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SessionAudioPipeline(sessionID: UUID(), rootDirectory: root, enabledSources: [.microphone])
        var emittedCount = 0
        for index in 0..<441 {
            emittedCount += try pipeline.accept(AudioChunk(
                source: .microphone, samples: [0.2], sampleRate: 44_100,
                sessionStartTime: Double(index) / 44_100.0
            )).count
        }
        XCTAssertEqual(emittedCount, 160)
        XCTAssertEqual(try pipeline.finalize().totalSamples, 160)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioPipelineTests-\(UUID().uuidString)", isDirectory: true)
    }
}
