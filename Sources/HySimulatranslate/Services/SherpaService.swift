import Foundation
import CSherpaOnnx

struct SherpaSegment: Equatable, Sendable {
    let id: UUID
    let pcmData: Data
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct SherpaSegmentTimeline: Equatable, Sendable {
    let sampleRate: Int
    private(set) var acceptedSampleCount = 0
    private(set) var segmentStartSample = 0

    mutating func accept(sampleCount: Int) {
        acceptedSampleCount += max(0, sampleCount)
    }

    mutating func accept(sampleCount: Int, sampleRate sourceSampleRate: Int) {
        guard sourceSampleRate > 0 else { return }
        let normalized = Int((Double(max(0, sampleCount)) * Double(sampleRate) / Double(sourceSampleRate)).rounded())
        accept(sampleCount: normalized)
    }

    mutating func finishSegment(retainedOverlapSamples: Int) -> (startTime: TimeInterval, endTime: TimeInterval) {
        let start = segmentStartSample
        let end = acceptedSampleCount
        segmentStartSample = max(start, end - max(0, retainedOverlapSamples))
        return (Double(start) / Double(sampleRate), Double(end) / Double(sampleRate))
    }
}

// MARK: - 🚀 Sherpa-onnx 流式识别引擎（C API 封装，对应 Python sherpa_recognizer）

actor SherpaService {
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var isConfigured = false
    private let voiceActivityService = VoiceActivityService()
    private var voiceActivityReady = false

    nonisolated let forbiddenEnds: Set<String> = [
        "of", "the", "and", "or", "a", "an", "is", "are", "in", "on", "at",
        "to", "with", "that", "as", "for", "by", "from", "about", "but", "because"
    ]

    typealias SegmentHandler = @Sendable (UUID, Data, String) -> Void
    typealias TimedSegmentHandler = @Sendable (SherpaSegment) -> Void
    typealias DraftHandler = @Sendable (String) -> Void
    private var onSegment: SegmentHandler?
    private var onTimedSegment: TimedSegmentHandler?
    private var onDraft: DraftHandler?

    private var audioBuffer = Data()
    private var lastTextTime = Date()
    private var lastAcousticTime = Date()
    private var lastPartialText = ""
    private var isRunning = false
    private var workerTask: Task<Void, Never>?
    private var sfsProducedTextInSegment = false
    private var segmentTimeline = SherpaSegmentTimeline(sampleRate: 16_000)
    private var inputResampler: StreamingAudioResampler?

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

    func configureVoiceActivity(modelURL: URL?) -> Bool {
        guard let modelURL else {
            voiceActivityReady = false
            voiceActivityService.destroy()
            return false
        }
        voiceActivityReady = voiceActivityService.configure(modelURL: modelURL)
        return voiceActivityReady
    }

    func destroy() {
        isRunning = false
        workerTask?.cancel()
        if let s = stream { SherpaOnnxDestroyOnlineStream(s); self.stream = nil }
        if let r = recognizer { SherpaOnnxDestroyOnlineRecognizer(r); self.recognizer = nil }
        voiceActivityService.destroy()
        voiceActivityReady = false
        isConfigured = false
        audioBuffer = Data()
        inputResampler = nil
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
        self.onTimedSegment = nil
        self.onDraft = onDraft
        self.isRunning = true

        audioBuffer = Data()
        lastTextTime = Date()
        lastAcousticTime = Date()
        lastPartialText = ""
        sfsProducedTextInSegment = false
        segmentTimeline = SherpaSegmentTimeline(sampleRate: 16_000)
        inputResampler = nil
        voiceActivityService.reset()

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

    func startStreaming(
        onTimedSegment: @escaping TimedSegmentHandler,
        onDraft: @escaping DraftHandler
    ) {
        self.onTimedSegment = onTimedSegment
        startStreaming(onSegment: { _, _, _ in }, onDraft: onDraft)
        self.onTimedSegment = onTimedSegment
    }

    func stopStreaming() {
        isRunning = false
        workerTask?.cancel()
        workerTask = nil
    }

    // MARK: - 喂入音频

    func acceptWaveform(samples: [Float], sampleRate: Int32) {
        guard isRunning, let s = stream, let _ = recognizer else { return }

        if inputResampler?.sourceRate != Int(sampleRate) {
            inputResampler = StreamingAudioResampler(sourceRate: Int(sampleRate), targetRate: 16_000)
        }
        guard var resampler = inputResampler else { return }
        let normalizedSamples = resampler.process(samples)
        inputResampler = resampler
        guard !normalizedSamples.isEmpty else { return }

        let vadDetectedSpeech = voiceActivityReady
            ? voiceActivityService.acceptWaveform(samples: normalizedSamples, sampleRate: 16_000)
            : nil
        let rms = sqrt(normalizedSamples.reduce(0) { $0 + $1 * $1 } / Float(max(1, normalizedSamples.count)))
        let hasAcousticActivity = vadDetectedSpeech ?? (rms > 0.01)
        if hasAcousticActivity {
            lastAcousticTime = Date()
        }

        let int16Samples = normalizedSamples.map { Int16(max(-32768, min(32767, $0 * 32768))) }
        segmentTimeline.accept(sampleCount: int16Samples.count)
        int16Samples.withUnsafeBufferPointer { buf in
            audioBuffer.append(Data(buffer: buf))
        }

        normalizedSamples.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(s, 16_000, buf.baseAddress, Int32(buf.count))
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
                _ = segmentTimeline.finishSegment(retainedOverlapSamples: 0)
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
        let retainedOverlapSamples: Int
        if audioBuffer.count > overlapBytes {
            retainedOverlapSamples = overlapBytes / MemoryLayout<Int16>.size
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
            retainedOverlapSamples = 0
            audioBuffer = Data()
            resetStream()
        }

        lastPartialText = ""
        lastTextTime = Date()
        lastAcousticTime = Date()
        sfsProducedTextInSegment = false
        voiceActivityService.reset()

        let uid = UUID()
        let timing = segmentTimeline.finishSegment(retainedOverlapSamples: retainedOverlapSamples)
        print("[SherpaService] segment: \"\(displayText.prefix(60))\" pcm=\(pcmCopy.count)B sil=\(String(format: "%.2f", sil))s textSil=\(String(format: "%.2f", textSil))s audio=\(String(format: "%.2f", audioSec))s")
        onSegment?(uid, pcmCopy, displayText)
        onTimedSegment?(SherpaSegment(
            id: uid,
            pcmData: pcmCopy,
            text: displayText,
            startTime: timing.startTime,
            endTime: timing.endTime
        ))
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
