import Foundation

struct SessionAudioSnapshot: Equatable, Sendable {
    let sessionDirectory: URL
    let audioURL: URL
    let spans: [SpeakerAudioSpan]
    let totalSamples: Int
}

final class SessionAudioStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var sessionDirectory: URL?
    private var audioURL: URL?
    private var spans: [SpeakerAudioSpan] = []
    private var totalSamples = 0

    init(rootDirectory: URL = SessionAudioStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    deinit {
        try? fileHandle?.close()
    }

    func beginSession(sessionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        try? fileHandle?.close()
        let directory = rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let audio = directory.appendingPathComponent("session-int16.pcm")
        FileManager.default.createFile(atPath: audio.path, contents: nil)

        fileHandle = try FileHandle(forWritingTo: audio)
        sessionDirectory = directory
        audioURL = audio
        spans = []
        totalSamples = 0
    }

    @discardableResult
    func appendSegment(uid: UUID, pcmData: Data) throws -> SpeakerAudioSpan {
        lock.lock()
        defer { lock.unlock() }

        guard let fileHandle else {
            throw NSError(
                domain: "SessionAudioStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "会话音频文件尚未初始化"]
            )
        }
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        let span = SpeakerAudioSpan(
            itemID: uid,
            startSample: totalSamples,
            endSample: totalSamples + sampleCount
        )
        try fileHandle.write(contentsOf: pcmData)
        spans.append(span)
        totalSamples += sampleCount
        return span
    }

    func finalizeSnapshot() -> SessionAudioSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let sessionDirectory, let audioURL else { return nil }
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        return SessionAudioSnapshot(
            sessionDirectory: sessionDirectory,
            audioURL: audioURL,
            spans: spans,
            totalSamples: totalSamples
        )
    }

    func currentSessionDirectory() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return sessionDirectory
    }

    func cleanupCurrentSession() {
        lock.lock()
        defer { lock.unlock() }

        try? fileHandle?.close()
        fileHandle = nil
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        self.sessionDirectory = nil
        audioURL = nil
        spans = []
        totalSamples = 0
    }

    static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("HySimulatranslate", isDirectory: true)
            .appendingPathComponent("SessionRecovery", isDirectory: true)
    }
}
