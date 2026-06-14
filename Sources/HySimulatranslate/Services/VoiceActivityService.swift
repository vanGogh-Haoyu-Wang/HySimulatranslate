import Foundation
import CSherpaOnnx

final class VoiceActivityService {
    private var detector: OpaquePointer?
    private(set) var isConfigured = false
    private(set) var lastDetectedSpeech = false

    deinit {
        destroy()
    }

    func configure(modelURL: URL) -> Bool {
        destroy()

        var config = SherpaOnnxVadModelConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxVadModelConfig>.size)

        let modelPath = strdup(modelURL.path)
        let provider = strdup("cpu")
        defer {
            free(modelPath)
            free(provider)
        }

        config.silero_vad.model = UnsafePointer(modelPath)
        config.silero_vad.threshold = 0.35
        config.silero_vad.min_silence_duration = 0.50
        config.silero_vad.min_speech_duration = 0.35
        config.silero_vad.window_size = 512
        config.silero_vad.max_speech_duration = 20.0
        config.sample_rate = 16_000
        config.num_threads = 1
        config.provider = UnsafePointer(provider)
        config.debug = 0

        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0) else {
            print("[VoiceActivityService] Failed to create VAD")
            return false
        }

        detector = vad
        isConfigured = true
        lastDetectedSpeech = false
        print("[VoiceActivityService] VAD ready: \(modelURL.path)")
        return true
    }

    func destroy() {
        if let detector {
            SherpaOnnxDestroyVoiceActivityDetector(detector)
            self.detector = nil
        }
        isConfigured = false
        lastDetectedSpeech = false
    }

    func reset() {
        guard let detector else { return }
        SherpaOnnxVoiceActivityDetectorClear(detector)
        lastDetectedSpeech = false
    }

    func acceptWaveform(samples: [Float], sampleRate: Int32) -> Bool? {
        guard sampleRate == 16_000, let detector else { return nil }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(
                detector,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        let detected = SherpaOnnxVoiceActivityDetectorDetected(detector) != 0
        lastDetectedSpeech = detected
        drainCompletedSegments()
        return detected
    }

    private func drainCompletedSegments() {
        guard let detector else { return }
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            if let segment = SherpaOnnxVoiceActivityDetectorFront(detector) {
                SherpaOnnxDestroySpeechSegment(segment)
            }
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
    }
}
