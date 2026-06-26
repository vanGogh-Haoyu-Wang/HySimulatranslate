import Foundation
import SpeakerKit

actor SpeakerDiarizationService {
    private let sampleRate = 16_000
    private var speakerKit: SpeakerKit?
    private var isReady = false
    private var sessionSamples: [Float] = []
    private var spans: [SpeakerAudioSpan] = []
    private var labelMapper = SpeakerLabelMapper()

    func configure(allowDownload: Bool = true) async -> Bool {
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
        sessionSamples = []
        spans = []
        labelMapper = SpeakerLabelMapper()
    }

    func recordSegment(uid: UUID, pcmData: Data) -> Bool {
        guard isReady else { return false }
        let samples = Self.floatSamples(fromInt16PCM: pcmData)
        guard !samples.isEmpty else { return false }

        let start = sessionSamples.count
        sessionSamples.append(contentsOf: samples)
        let end = sessionSamples.count
        spans.append(SpeakerAudioSpan(itemID: uid, startSample: start, endSample: end))
        return true
    }

    func diarizeCurrentSession() async -> [UUID: String] {
        guard isReady,
              let speakerKit,
              !sessionSamples.isEmpty,
              !spans.isEmpty
        else { return [:] }

        do {
            let result = try await speakerKit.diarize(
                audioArray: sessionSamples,
                options: PyannoteDiarizationOptions(useExclusiveReconciliation: true)
            )
            let segments = result.segments.compactMap { segment -> SpeakerDiarizationSegment? in
                guard let rawSpeakerID = segment.speaker.speakerId else { return nil }
                return SpeakerDiarizationSegment(
                    rawSpeakerID: "speaker_\(rawSpeakerID)",
                    startSample: max(0, Int(segment.startTime * Float(sampleRate))),
                    endSample: max(0, Int(segment.endTime * Float(sampleRate)))
                )
            }
            guard !segments.isEmpty else { return [:] }
            return labelMapper.assignLabels(for: spans, diarizationSegments: segments)
        } catch {
            return [:]
        }
    }

    private static func floatSamples(fromInt16PCM data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { Float($0) / 32768.0 }
        }
    }
}
