import Foundation
@preconcurrency import AVFoundation

struct DecodedAudio: Sendable, Equatable { var samples: [Float]; var sampleRate: Double; var duration: Double }
struct DecodedAudioChunk: Sendable { var samples: [Float]; var sampleRate: Double; var startTime: Double; var totalDuration: Double }
struct AudioImportMetadata: Sendable, Equatable { var sampleRate: Double; var channelCount: Int; var duration: Double }
protocol AudioImportDecoding: Sendable {
    func decode(url: URL) async throws -> DecodedAudio
    func stream(url: URL, framesPerChunk: AVAudioFrameCount) -> AsyncThrowingStream<DecodedAudioChunk, Error>
}
extension AudioImportDecoding {
    func stream(url: URL, framesPerChunk: AVAudioFrameCount = 16_384) -> AsyncThrowingStream<DecodedAudioChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do { let audio = try await decode(url: url); continuation.yield(.init(samples: audio.samples, sampleRate: audio.sampleRate, startTime: 0, totalDuration: audio.duration)); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
        }
    }
}

enum AudioImportError: LocalizedError {
    case unsupportedFormat(String), unreadable(String), empty
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "不支持的音频格式：\(ext)。请选择 WAV、M4A、MP3、AAC 或 CAF。"
        case .unreadable(let reason): return "无法读取音频文件：\(reason)"
        case .empty: return "音频文件不包含可转写的声音。"
        }
    }
}

struct AudioImportDecoder: AudioImportDecoding {
    static let supportedExtensions: Set<String> = ["wav", "m4a", "mp3", "aac", "caf"]
    func inspectMetadata(url: URL) throws -> AudioImportMetadata {
        let file = try AVAudioFile(forReading: url); let format = file.fileFormat
        return .init(sampleRate: format.sampleRate, channelCount: Int(format.channelCount), duration: Double(file.length) / max(1, format.sampleRate))
    }
    func decode(url: URL) async throws -> DecodedAudio {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw AudioImportError.unsupportedFormat(ext) }
        if ext != "wav", isWaveContainer(url) { return try decodeWaveContainerWithCanonicalSuffix(url) }
        do { return try decodeFile(url) }
        catch let error as AudioImportError { throw error }
        catch {
            // Some file providers preserve a PCM/WAVE container while changing the extension.
            // AVFoundation chooses its parser partly from the suffix, so retry a signature-verified
            // RIFF/WAVE payload through a temporary canonical suffix.
            if isWaveContainer(url) { return try decodeWaveContainerWithCanonicalSuffix(url) }
            throw AudioImportError.unreadable(error.localizedDescription)
        }
    }

    func stream(url: URL, framesPerChunk: AVAudioFrameCount = 16_384) -> AsyncThrowingStream<DecodedAudioChunk, Error> {
        AsyncThrowingStream { continuation in
            do {
                let ext = url.pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { throw AudioImportError.unsupportedFormat(ext) }
                let sourceURL: URL
                var temporary: URL?
                if ext != "wav", isWaveContainer(url) {
                    let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
                    try Data(contentsOf: url).write(to: canonical); sourceURL = canonical; temporary = canonical
                } else { sourceURL = url }
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                let file = try AVAudioFile(forReading: sourceURL); let format = file.processingFormat
                let duration = Double(file.length) / format.sampleRate; var frameOffset: AVAudioFramePosition = 0
                while frameOffset < file.length {
                    let capacity = AVAudioFrameCount(min(AVAudioFramePosition(framesPerChunk), file.length - frameOffset))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AudioImportError.empty }
                    try file.read(into: buffer, frameCount: capacity)
                    guard buffer.frameLength > 0 else { break }
                    let samples = Self.monoSamples(buffer)
                    continuation.yield(.init(samples: samples, sampleRate: format.sampleRate, startTime: Double(frameOffset) / format.sampleRate, totalDuration: duration))
                    frameOffset += AVAudioFramePosition(buffer.frameLength)
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error is AudioImportError ? error : AudioImportError.unreadable(error.localizedDescription)) }
        }
    }

    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength); let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, count > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: count)) }
        return (0..<count).map { index in (0..<channels).reduce(Float.zero) { $0 + data[$1][index] } / Float(channels) }
    }

    private func isWaveContainer(_ url: URL) -> Bool {
        guard let header = try? Data(contentsOf: url, options: .mappedIfSafe).prefix(12), header.count == 12 else { return false }
        return String(data: header.prefix(4), encoding: .ascii) == "RIFF" && String(data: header.suffix(4), encoding: .ascii) == "WAVE"
    }
    private func decodeWaveContainerWithCanonicalSuffix(_ url: URL) throws -> DecodedAudio {
        let canonical = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: canonical) }
        do { try Data(contentsOf: url).write(to: canonical); return try decodeFile(canonical) }
        catch { throw AudioImportError.unreadable(error.localizedDescription) }
    }

    private func decodeFile(_ url: URL) throws -> DecodedAudio {
        do {
            let file = try AVAudioFile(forReading: url)
            let source = file.processingFormat
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: mono) else { throw AudioImportError.unreadable("无法创建音频转换器") }
            let capacity = AVAudioFrameCount(max(1, file.length))
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: capacity) else { throw AudioImportError.empty }
            try file.read(into: input)
            guard let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { throw AudioImportError.empty }
            var supplied = false; var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            if let conversionError { throw conversionError }
            guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { throw AudioImportError.empty }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            return DecodedAudio(samples: samples, sampleRate: mono.sampleRate, duration: Double(samples.count) / mono.sampleRate)
        } catch let error as AudioImportError { throw error }
        catch { throw error }
    }
}
