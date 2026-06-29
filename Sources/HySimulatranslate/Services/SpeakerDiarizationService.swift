import Foundation
import SpeakerKit

actor SpeakerDiarizationService {
    private let sampleRate = 16_000
    private var speakerKit: SpeakerKit?
    private var isReady = false
    private var isDiarizing = false
    private var labelMapper = SpeakerLabelMapper()

    func configure(allowDownload: Bool = true) async -> Bool {
        if isReady, speakerKit != nil { return true }
        do {
            let config = PyannoteConfig(download: allowDownload, load: false, verbose: false)
            speakerKit = try await SpeakerKit(config)
            isReady = true
            return true
        } catch {
            speakerKit = nil
            isReady = false
            return false
        }
    }

    func resetSession() {
        labelMapper = SpeakerLabelMapper()
    }

    func diarizeSession(_ snapshot: SessionAudioSnapshot) async -> [UUID: String] {
        guard isReady,
              let speakerKit,
              !isDiarizing,
              snapshot.totalSamples > 0,
              !snapshot.spans.isEmpty
        else { return [:] }

        isDiarizing = true
        labelMapper = SpeakerLabelMapper()
        defer { isDiarizing = false }

        guard let handle = try? FileHandle(forReadingFrom: snapshot.audioURL) else {
            return [:]
        }
        defer { try? handle.close() }

        var labels: [UUID: String] = [:]
        let windows = SpeakerDiarizationWindowPlanner.windows(
            totalSamples: snapshot.totalSamples,
            sampleRate: sampleRate
        )

        for (windowIndex, window) in windows.enumerated() {
            guard !Task.isCancelled else { break }
            do {
                try handle.seek(
                    toOffset: UInt64(window.startSample * MemoryLayout<Int16>.size)
                )
                guard let pcmData = try handle.read(
                    upToCount: window.count * MemoryLayout<Int16>.size
                ), !pcmData.isEmpty else {
                    continue
                }
                let samples = Self.floatSamples(fromInt16PCM: pcmData)
                let result = try await speakerKit.diarize(
                    audioArray: samples,
                    options: PyannoteDiarizationOptions(useExclusiveReconciliation: true)
                )
                guard !Task.isCancelled else { break }

                let segments = result.segments.compactMap { segment -> SpeakerDiarizationSegment? in
                    guard let rawSpeakerID = segment.speaker.speakerId else { return nil }
                    return SpeakerDiarizationSegment(
                        rawSpeakerID: "window_\(windowIndex)_speaker_\(rawSpeakerID)",
                        startSample: window.startSample + max(
                            0,
                            Int(segment.startTime * Float(sampleRate))
                        ),
                        endSample: window.startSample + max(
                            0,
                            Int(segment.endTime * Float(sampleRate))
                        )
                    )
                }
                guard !segments.isEmpty else { continue }
                labels = labelMapper.assignLabels(
                    for: snapshot.spans,
                    diarizationSegments: segments
                )
            } catch {
                if Task.isCancelled { break }
                continue
            }
        }

        await speakerKit.unloadModels()
        return labels
    }

    func unloadModels() async {
        await speakerKit?.unloadModels()
    }

    private static func floatSamples(fromInt16PCM data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { Float($0) / 32768.0 }
        }
    }
}
