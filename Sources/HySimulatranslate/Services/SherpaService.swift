import Foundation
import CSherpaOnnx

// MARK: - 🚀 Sherpa-onnx 流式识别引擎（C API 封装，对应 Python sherpa_recognizer）

actor SherpaService {
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var isConfigured = false

    nonisolated let forbiddenEnds: Set<String> = [
        "of", "the", "and", "or", "a", "an", "is", "are", "in", "on", "at",
        "to", "with", "that", "as", "for", "by", "from", "about", "but", "because"
    ]

    typealias SegmentHandler = @Sendable (UUID, Data, String) -> Void
    typealias DraftHandler = @Sendable (String) -> Void
    private var onSegment: SegmentHandler?
    private var onDraft: DraftHandler?

    private var audioBuffer = Data()
    private var lastTextTime = Date()
    private var lastAcousticTime = Date()
    private var lastPartialText = ""
    private var isRunning = false
    private var workerTask: Task<Void, Never>?
    private var sfsProducedTextInSegment = false

    nonisolated static let noTextCutMinimumAudioSec: Double = 2.0

    nonisolated(unsafe) var pauseVal: Double = 0.6
    nonisolated(unsafe) var limitVal: Double = 20.0

    // MARK: - 配置与销毁

    func configure(modelDir: String) -> Bool {
        let encoderPath = findFile(in: modelDir, pattern: "encoder*.onnx")
        let decoderPath = findFile(in: modelDir, pattern: "decoder*.onnx")
        let joinerPath  = findFile(in: modelDir, pattern: "joiner*.onnx")
        let tokensPath  = modelDir + "/tokens.txt"
        let bpePath     = modelDir + "/bpe.model"

        guard let enc = encoderPath,
              let dec = decoderPath,
              let joi = joinerPath,
              FileManager.default.fileExists(atPath: tokensPath) else {
            print("[SherpaService] Missing model files in: \(modelDir)")
            return false
        }

        var config = SherpaOnnxOnlineRecognizerConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOnlineRecognizerConfig>.size)

        config.feat_config.sample_rate   = 16000
        config.feat_config.feature_dim   = 80
        config.model_config.transducer.encoder = UnsafePointer(strdup(enc))
        config.model_config.transducer.decoder = UnsafePointer(strdup(dec))
        config.model_config.transducer.joiner  = UnsafePointer(strdup(joi))
        config.model_config.tokens       = UnsafePointer(strdup(tokensPath))
        config.model_config.num_threads  = 2
        config.model_config.provider     = UnsafePointer(strdup("cpu"))
        if FileManager.default.fileExists(atPath: bpePath) {
            config.model_config.modeling_unit = UnsafePointer(strdup("bpe"))
            config.model_config.bpe_vocab = UnsafePointer(strdup(bpePath))
        } else {
            config.model_config.modeling_unit = UnsafePointer(strdup("cjkchar"))
        }

        guard let rec = SherpaOnnxCreateOnlineRecognizer(&config) else {
            print("[SherpaService] Failed to create recognizer")
            return false
        }
        self.recognizer = rec
        self.isConfigured = true
        print("[SherpaService] Recognizer created")
        return true
    }

    func destroy() {
        isRunning = false
        workerTask?.cancel()
        if let s = stream { SherpaOnnxDestroyOnlineStream(s); self.stream = nil }
        if let r = recognizer { SherpaOnnxDestroyOnlineRecognizer(r); self.recognizer = nil }
        isConfigured = false
        audioBuffer = Data()
    }

    // MARK: - 流式 Worker

    func startStreaming(
        onSegment: @escaping SegmentHandler,
        onDraft: @escaping DraftHandler
    ) {
        guard isConfigured, recognizer != nil else {
            print("[SherpaService] Not configured")
            return
        }
        self.onSegment = onSegment
        self.onDraft = onDraft
        self.isRunning = true

        audioBuffer = Data()
        lastTextTime = Date()
        lastAcousticTime = Date()
        lastPartialText = ""
        sfsProducedTextInSegment = false

        if stream != nil { SherpaOnnxDestroyOnlineStream(stream!) }
        stream = SherpaOnnxCreateOnlineStream(recognizer!)

        workerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let running = await self.isRunning
                guard running else { break }
                await self.checkBoundary()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopStreaming() {
        isRunning = false
        workerTask?.cancel()
        workerTask = nil
    }

    // MARK: - 喂入音频

    func acceptWaveform(samples: [Float], sampleRate: Int32) {
        guard isRunning, let s = stream, let _ = recognizer else { return }

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
        if rms > 0.01 {
            lastAcousticTime = Date()
        }

        let int16Samples = samples.map { Int16(max(-32768, min(32767, $0 * 32768))) }
        int16Samples.withUnsafeBufferPointer { buf in
            audioBuffer.append(Data(buffer: buf))
        }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(s, sampleRate, buf.baseAddress, Int32(buf.count))
        }

        while SherpaOnnxIsOnlineStreamReady(recognizer!, s) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer!, s)
        }

        let result = SherpaOnnxGetOnlineStreamResult(recognizer!, s)
        var currentDisplay = ""
        if let textPtr = result?.pointee.text {
            currentDisplay = String(cString: textPtr).trimmingCharacters(in: .whitespaces)
        }
        SherpaOnnxDestroyOnlineRecognizerResult(result)

        if currentDisplay != lastPartialText && !currentDisplay.isEmpty {
            lastTextTime = Date()
            lastPartialText = currentDisplay
            let draft = currentDisplay.prefix(1).capitalized + currentDisplay.dropFirst()
            let handler = onDraft
            Task { @MainActor in
                handler?(draft)
            }
        }
    }

    // MARK: - 语段边界检测

    private func checkBoundary() {
        guard isRunning, let _ = recognizer else { return }

        let now = Date()
        let textSil = now.timeIntervalSince(lastTextTime)
        let acousticSil = now.timeIntervalSince(lastAcousticTime)
        let sil = min(textSil, acousticSil)
        let audioSec = Double(audioBuffer.count) / 32000.0

        let words = lastPartialText.split(separator: " ")
        let lastWord = words.last.map { String($0).lowercased() } ?? ""
        let endsDangling = forbiddenEnds.contains(lastWord)

        let normalCut    = (sil >= pauseVal) && (audioSec >= 4.0) && !endsDangling
        let longPauseCut = (sil >= pauseVal * 2.5) && (audioSec >= 1.0)
        let breathCut    = (textSil >= max(1.0, pauseVal * 1.6)) && (audioSec >= 4.0) && !endsDangling
        let noTextCut    = Self.shouldCutNoTextSegment(text: lastPartialText, audioSec: audioSec)
        let softLimitCut = audioSec >= limitVal

        guard normalCut || longPauseCut || breathCut || noTextCut || softLimitCut else { return }

        var displayText = lastPartialText.trimmingCharacters(in: .whitespaces)
        if !displayText.isEmpty {
            displayText = displayText.prefix(1).capitalized + displayText.dropFirst()
        }

        if displayText.isEmpty {
            if audioSec < Self.noTextCutMinimumAudioSec {
                audioBuffer = Data()
                lastPartialText = ""
                lastTextTime = Date()
                lastAcousticTime = Date()
                resetStream()
                return
            } else {
                displayText = "[🎤 捕获到口音音频，分析中...]"
            }
        }

        let overlapBytes = 32000
        let pcmCopy = Data(audioBuffer)
        if audioBuffer.count > overlapBytes {
            let overlap = Data(audioBuffer.suffix(overlapBytes))
            resetStream()
            if let newStream = stream {
                let floatSamples = overlap.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float] in
                    let int16Ptr = ptr.bindMemory(to: Int16.self)
                    return (0..<min(int16Ptr.count, overlapBytes / 2)).map { Float(int16Ptr[$0]) / 32768.0 }
                }
                floatSamples.withUnsafeBufferPointer { buf in
                    SherpaOnnxOnlineStreamAcceptWaveform(newStream, 16000, buf.baseAddress, Int32(buf.count))
                }
            }
            audioBuffer = Data(overlap)
        } else {
            audioBuffer = Data()
            resetStream()
        }

        lastPartialText = ""
        lastTextTime = Date()
        lastAcousticTime = Date()
        sfsProducedTextInSegment = false

        let uid = UUID()
        print("[SherpaService] segment: \"\(displayText.prefix(60))\" pcm=\(pcmCopy.count)B sil=\(String(format: "%.2f", sil))s textSil=\(String(format: "%.2f", textSil))s audio=\(String(format: "%.2f", audioSec))s")
        onSegment?(uid, pcmCopy, displayText)
    }

    private func resetStream() {
        if let old = stream {
            SherpaOnnxDestroyOnlineStream(old)
            stream = nil
        }
        if let rec = recognizer {
            stream = SherpaOnnxCreateOnlineStream(rec)
        }
    }

    // MARK: - Helpers

    nonisolated static func shouldCutNoTextSegment(text: String, audioSec: Double) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        audioSec >= noTextCutMinimumAudioSec
    }

    private func findFile(in dir: String, pattern: String) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let prefix = pattern.components(separatedBy: "*").first ?? pattern
        return files.filter { $0.hasPrefix(prefix) }
                    .sorted()
                    .first
                    .map { dir + "/" + $0 }
    }
}
