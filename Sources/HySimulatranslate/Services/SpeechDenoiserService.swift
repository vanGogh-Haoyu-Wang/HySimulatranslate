import Foundation
import CSherpaOnnx

actor SpeechDenoiserService {
    private var denoiser: OpaquePointer?
    private(set) var isConfigured = false

    deinit {
        if let denoiser {
            SherpaOnnxDestroyOfflineSpeechDenoiser(denoiser)
        }
    }

    func configure(modelURL: URL?) -> Bool {
        if isConfigured { return true }
        guard let modelURL else { return false }

        var config = SherpaOnnxOfflineSpeechDenoiserConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineSpeechDenoiserConfig>.size)

        let modelPath = strdup(modelURL.path)
        let provider = strdup("cpu")
        defer {
            free(modelPath)
            free(provider)
        }

        config.model.gtcrn.model = UnsafePointer(modelPath)
        config.model.num_threads = 1
        config.model.provider = UnsafePointer(provider)
        config.model.debug = 0

        guard let sd = SherpaOnnxCreateOfflineSpeechDenoiser(&config) else {
            print("[SpeechDenoiserService] Failed to create denoiser")
            return false
        }

        denoiser = sd
        isConfigured = true
        print("[SpeechDenoiserService] Denoiser ready: \(modelURL.path)")
        return true
    }

    func denoise(pcmData: Data, sampleRate: Int32 = 16_000) -> Data? {
        guard isConfigured, let denoiser else { return nil }
        let samples = pcmData.withUnsafeBytes { rawBuffer -> [Float] in
            let int16 = rawBuffer.bindMemory(to: Int16.self)
            return int16.map { Float($0) / 32768.0 }
        }
        guard !samples.isEmpty else { return nil }

        let output = samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOfflineSpeechDenoiserRun(
                denoiser,
                buffer.baseAddress,
                Int32(buffer.count),
                sampleRate
            )
        }
        guard let output else { return nil }
        defer { SherpaOnnxDestroyDenoisedAudio(output) }

        guard let outputSamples = output.pointee.samples, output.pointee.n > 0 else {
            return nil
        }
        let floats = UnsafeBufferPointer(start: outputSamples, count: Int(output.pointee.n))
        let int16Samples = floats.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(max(-32768, min(32767, clamped * 32768.0)))
        }
        return int16Samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
