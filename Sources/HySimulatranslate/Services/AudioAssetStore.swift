import AVFoundation
import Foundation

struct SessionAudioAssets: Equatable, Sendable {
    let sessionDirectory: URL
    let microphoneWAV: URL
    let systemWAV: URL?
    let mixedWAV: URL
    let m4aURL: URL?
    let totalSamples: Int

    var playbackURL: URL { m4aURL ?? mixedWAV }
}

final class AudioAssetStore: @unchecked Sendable {
    private let directory: URL
    private let sampleRate: Int
    private let enabledSources: Set<AudioChunkSource>
    private var sourceWriters: [AudioChunkSource: IncrementalMonoWAVWriter] = [:]
    private let mixedWriter: IncrementalMonoWAVWriter
    private var isFinalized = false

    init(sessionID: UUID, rootDirectory: URL, sampleRate: Int, enabledSources: Set<AudioChunkSource>) throws {
        directory = rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        self.sampleRate = sampleRate
        self.enabledSources = enabledSources
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for source in enabledSources {
            sourceWriters[source] = try IncrementalMonoWAVWriter(url: Self.wavURL(in: directory, for: source), sampleRate: sampleRate)
        }
        mixedWriter = try IncrementalMonoWAVWriter(url: directory.appendingPathComponent("mixed.wav"), sampleRate: sampleRate)
    }

    deinit {
        try? sourceWriters.values.forEach { try $0.finalize() }
        try? mixedWriter.finalize()
    }

    func persist(source: AudioChunkSource, samples: [Float], at startSample: Int) throws {
        try sourceWriters[source]?.write(samples: samples, at: startSample)
    }

    func persistMixed(samples: [Float], at startSample: Int) throws {
        try mixedWriter.write(samples: samples, at: startSample)
    }

    func finalize(mixedSamples: [Float]) throws -> SessionAudioAssets {
        if !isFinalized {
            try sourceWriters.values.forEach { try $0.finalize() }
            try mixedWriter.finalize()
            isFinalized = true
        }
        let destination = directory.appendingPathComponent("mixed.m4a")
        let encoded = try? Self.writeM4A(mixedSamples, sampleRate: sampleRate, to: destination)
        let usableM4A = encoded == true ? destination : nil
        return SessionAudioAssets(
            sessionDirectory: directory,
            microphoneWAV: Self.wavURL(in: directory, for: .microphone),
            systemWAV: enabledSources.contains(.systemAudio) ? Self.wavURL(in: directory, for: .systemAudio) : nil,
            mixedWAV: directory.appendingPathComponent("mixed.wav"),
            m4aURL: usableM4A,
            totalSamples: mixedSamples.count
        )
    }

    private static func wavURL(in directory: URL, for source: AudioChunkSource) -> URL {
        directory.appendingPathComponent(source == .microphone ? "microphone.wav" : "system.wav")
    }

    private static func writeM4A(_ samples: [Float], sampleRate: Int, to destination: URL) throws -> Bool {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let temporary = destination.deletingPathExtension().appendingPathExtension("tmp.m4a")
        try? FileManager.default.removeItem(at: temporary)
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: settings)
            try file.write(from: buffer)
        }
        let verification = try AVAudioFile(forReading: temporary)
        guard verification.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        let finalVerification = try AVAudioFile(forReading: destination)
        return finalVerification.length > 0
    }
}

private final class IncrementalMonoWAVWriter {
    private let url: URL
    private let sampleRate: Int
    private var handle: FileHandle?
    private var sampleCount = 0

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, sampleCount: 0))
        handle = try FileHandle(forUpdating: url)
    }

    deinit { try? finalize() }

    func write(samples: [Float], at startSample: Int) throws {
        guard let handle, !samples.isEmpty else { return }
        let pcm: [Int16] = samples.map { value in
            let clipped = max(-1, min(1, value))
            return Int16(clipped < 0 ? clipped * 32_768 : clipped * 32_767)
        }
        let payload = pcm.withUnsafeBufferPointer { Data(UnsafeRawBufferPointer($0)) }
        try handle.seek(toOffset: UInt64(44 + max(0, startSample) * 2))
        try handle.write(contentsOf: payload)
        sampleCount = max(sampleCount, max(0, startSample) + pcm.count)
        try updateHeaderAndSync()
    }

    func finalize() throws {
        guard let handle else { return }
        try updateHeaderAndSync()
        try handle.close()
        self.handle = nil
    }

    private func updateHeaderAndSync() throws {
        guard let handle else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, sampleCount: sampleCount))
        try handle.synchronize()
    }

    private static func header(sampleRate: Int, sampleCount: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); append(UInt32(36 + sampleCount * 2))
        data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(sampleCount * 2))
        return data
    }
}
