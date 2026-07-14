import Foundation
import Testing
import AVFoundation
@testable import HySimulatranslate

@Suite("Import coordinator")
struct ImportCoordinatorTests {
    @Test("segmenter splits at silence while preserving source time")
    func silenceSegmentation() {
        let audio = DecodedAudio(samples: Array(repeating: 0.2, count: 16_000) + Array(repeating: 0, count: 8_000) + Array(repeating: 0.2, count: 16_000), sampleRate: 16_000, duration: 2.5)
        let ranges = AudioTimelineSegmenter.ranges(audio: audio, maximumDuration: 20)
        #expect(ranges.count == 2)
        #expect(abs(ranges[0].start - 0) < 0.001)
        #expect(abs(ranges[1].end - 2.5) < 0.001)
        #expect(ranges[0].end <= ranges[1].start)
    }
    @Test("supported formats are explicit and corrupt audio has readable error")
    func decoderValidation() async {
        #expect(AudioImportDecoder.supportedExtensions == ["wav", "m4a", "mp3", "aac", "caf"])
        do {
            _ = try await AudioImportDecoder().decode(url: URL(fileURLWithPath: "/tmp/not-audio.wav"))
            Issue.record("expected decoding to fail")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
            #expect(error.localizedDescription.contains("无法读取"))
        }
    }

    @Test("all supported extensions decode valid temporary audio")
    func allSupportedFixtures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("tone.wav")
        func writeFixture() throws {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let file = try AVAudioFile(forWriting: canonical, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            for index in 0..<1_600 { buffer.floatChannelData?[0][index] = sin(Float(index) * 0.05) * 0.1 }
            try file.write(from: buffer)
        }
        try writeFixture()
        for ext in AudioImportDecoder.supportedExtensions.sorted() {
            let fixture = directory.appendingPathComponent("fixture.\(ext)")
            if ext == "wav" {
                try FileManager.default.copyItem(at: canonical, to: fixture)
            } else if ext == "mp3" {
                // Genuine LAME-encoded speech excerpt (CC-licensed test audio, truncated on frame boundary).
                let encoded = "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"
                try #require(Data(base64Encoded: encoded)).write(to: fixture)
            } else {
                let settings: [String: [String]] = [
                    "m4a": ["-f", "m4af", "-d", "aac"],
                    "aac": ["-f", "adts", "-d", "aac"],
                    "caf": ["-f", "caff", "-d", "LEI16"],
                ]
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                process.arguments = [canonical.path, fixture.path] + (settings[ext] ?? [])
                try process.run(); process.waitUntilExit()
                #expect(process.terminationStatus == 0, "afconvert must create a real \(ext) fixture")
            }
            let decoded = try await AudioImportDecoder().decode(url: fixture)
            #expect(decoded.sampleRate > 0)
            #expect(decoded.duration > 0)
            #expect(!decoded.samples.isEmpty)
            if ext == "mp3" { #expect(decoded.samples.contains { abs($0) > 0.0001 }) }
        }
    }

    @Test("successful import preserves timeline and becomes current")
    func successfulImport() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: db)
        let transcripts = TranscriptRepository(database: db)
        let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "Imported", source: .imported)
        let decoded = DecodedAudio(samples: Array(repeating: 0.2, count: 48_000), sampleRate: 16_000, duration: 3)
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs,
            decoder: StubDecoder(audio: decoded), transcriber: StubTranscriber())

        let job = try await coordinator.importAudio(from: URL(fileURLWithPath: "/tmp/example.wav"), meetingID: meeting.id,
            options: .init(subjectID: nil, sourceLanguage: "en", translate: false, targetLanguage: "zh", whisperModel: "test", diarize: false, maximumSegmentDuration: 1))

        #expect(job.status == .succeeded)
        let current = try #require(meetings.fetch(id: meeting.id)?.currentTranscriptRevisionID)
        let segments = try transcripts.fetchSegments(revisionID: current)
        #expect(segments.count == 3)
        #expect(segments.map(\.startTime) == [0, 1, 2])
        #expect(segments.map(\.endTime) == [1, 2, 3])
    }

    @Test("cancelled import records status without replacing current revision")
    func cancellationPreservesCurrent() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db)
        let transcripts = TranscriptRepository(database: db); let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "Imported", source: .imported)
        let old = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .imported, model: "old", language: "en", status: .succeeded)
        try transcripts.setCurrentTranscriptRevision(old.id, for: meeting.id)
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs,
            decoder: StubDecoder(audio: .init(samples: Array(repeating: 0.1, count: 32_000), sampleRate: 16_000, duration: 2)),
            transcriber: CancellingTranscriber())
        let result = try await coordinator.importAudio(from: URL(fileURLWithPath: "/tmp/cancel.wav"), meetingID: meeting.id,
            options: .init(subjectID: nil, sourceLanguage: "en", translate: false, targetLanguage: "zh", whisperModel: "test", diarize: false, maximumSegmentDuration: 1))
        #expect(result.status == .cancelled)
        #expect(try meetings.fetch(id: meeting.id)?.currentTranscriptRevisionID == old.id)
    }

    @Test("processing jobs recover as interrupted after restart")
    func restartRecovery() throws {
        let db = try AppDatabase.inMemory(); let repository = ImportJobRepository(database: db)
        let meeting = try MeetingRepository(database: db).create(title: "x", source: .imported)
        _ = try repository.create(meetingID: meeting.id, sourcePath: "/tmp/x.wav", options: .init(subjectID: nil, sourceLanguage: "en", translate: false, targetLanguage: "zh", whisperModel: "m", diarize: false))
        #expect(try repository.recoverInterruptedJobs() == 1)
        #expect(try repository.fetch(meetingID: meeting.id).first?.status == .processing)
    }

    @Test("retranslation creates independent revisions and switches only successful one")
    func retranslationRevisions() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db)
        let transcripts = TranscriptRepository(database: db); let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "x", source: .imported)
        let revision = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .imported, model: "m", language: "en", status: .succeeded)
        try transcripts.insert(.init(revisionID: revision.id, sequence: 0, startTime: 0, endTime: 1, refinedText: "hello", status: .succeeded))
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs,
            decoder: StubDecoder(audio: .init(samples: [], sampleRate: 16_000, duration: 0)), transcriber: StubTranscriber(), translator: StubTranslator())
        let first = try await coordinator.retranslate(meetingID: meeting.id, transcriptRevisionID: revision.id, targetLanguage: "zh", provider: "test", model: "a")
        let second = try await coordinator.retranslate(meetingID: meeting.id, transcriptRevisionID: revision.id, targetLanguage: "zh", provider: "test", model: "b")
        #expect(first.id != second.id)
        #expect(try transcripts.fetchTranslationRevisions(meetingID: meeting.id).count == 2)
        #expect(try meetings.fetch(id: meeting.id)?.currentTranslationRevisionID == second.id)
    }

    @Test("retranslation does not require a transcription model")
    func retranslationWithoutTranscriber() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db)
        let transcripts = TranscriptRepository(database: db); let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "x", source: .imported)
        let revision = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .imported, model: "m", language: "en", status: .succeeded)
        try transcripts.insert(.init(revisionID: revision.id, sequence: 0, startTime: 0, endTime: 1, refinedText: "hello", status: .succeeded))
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs, translator: StubTranslator())
        let translated = try await coordinator.retranslate(meetingID: meeting.id, transcriptRevisionID: revision.id, targetLanguage: "zh", provider: "test", model: "translation")
        #expect(translated.status == .succeeded)
    }

    @Test("failed retranslation exposes its error and preserves current revision")
    func failedRetranslationPreservesCurrent() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db)
        let transcripts = TranscriptRepository(database: db); let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "x", source: .imported)
        let source = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .imported, model: "m", language: "en", status: .succeeded)
        try transcripts.insert(.init(revisionID: source.id, sequence: 0, startTime: 0, endTime: 1, refinedText: "hello", status: .succeeded))
        let prior = try transcripts.createTranslationRevision(meetingID: meeting.id, transcriptRevisionID: source.id, targetLanguage: "zh", provider: "old", model: "old", status: .succeeded)
        try transcripts.setCurrentTranslationRevision(prior.id, for: meeting.id)
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs, translator: FailingTranslator())
        let failed = try await coordinator.retranslate(meetingID: meeting.id, transcriptRevisionID: source.id, targetLanguage: "zh", provider: "test", model: "new")
        #expect(failed.status == .failed)
        #expect(failed.errorMessage?.contains("translation failed") == true)
        #expect(try meetings.fetch(id: meeting.id)?.currentTranslationRevisionID == prior.id)
    }

    @Test("import runs selected translation diarization and export hooks")
    func postImportHooks() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db)
        let transcripts = TranscriptRepository(database: db); let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "x", source: .imported); let recorder = HookRecorder()
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs,
            decoder: StubDecoder(audio: .init(samples: Array(repeating: 0.2, count: 16_000), sampleRate: 16_000, duration: 1)),
            transcriber: StubTranscriber(), translator: StubTranslator(), postProcessor: recorder)
        let job = try await coordinator.importAudio(from: URL(fileURLWithPath: "/tmp/x.wav"), meetingID: meeting.id,
            options: .init(subjectID: nil, sourceLanguage: "en", translate: true, targetLanguage: "zh", whisperModel: "m", diarize: true))
        #expect(job.translationRevisionID != nil)
        #expect(await recorder.calls == ["diarize", "export"])
    }

    @Test("postprocess failure preserves previous current pointers")
    func postprocessFailurePreservesCurrent() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db)
        let transcripts = TranscriptRepository(database: db); let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "x", source: .imported)
        let old = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .imported, model: "old", language: "en", status: .succeeded)
        try transcripts.setCurrentTranscriptRevision(old.id, for: meeting.id)
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs,
            decoder: StubDecoder(audio: .init(samples: Array(repeating: 0.2, count: 16_000), sampleRate: 16_000, duration: 1)),
            transcriber: StubTranscriber(), postProcessor: FailingPostProcessor())
        let job = try await coordinator.importAudio(from: URL(fileURLWithPath: "/tmp/x.wav"), meetingID: meeting.id,
            options: .init(subjectID: nil, sourceLanguage: "en", translate: false, targetLanguage: "zh", whisperModel: "m", diarize: false))
        #expect(job.status == .failed)
        #expect(try meetings.fetch(id: meeting.id)?.currentTranscriptRevisionID == old.id)
    }
    @Test("48k input is statefully resampled to 16k before transcription")
    func resamplesBeforeWhisper() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db); let transcripts = TranscriptRepository(database: db)
        let meeting = try meetings.create(title: "x", source: .imported); let spy = TranscriberSpy()
        let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: ImportJobRepository(database: db),
            decoder: StubDecoder(audio: .init(samples: Array(repeating: 0.2, count: 48_000), sampleRate: 48_000, duration: 1)), transcriber: spy)
        _ = try await coordinator.importAudio(from: URL(fileURLWithPath: "/tmp/x.wav"), meetingID: meeting.id,
            options: .init(subjectID: nil, sourceLanguage: "fr", translate: false, targetLanguage: "zh", whisperModel: "chosen", diarize: false))
        #expect(await spy.lastRate == 16_000)
        #expect(await spy.lastCount == 16_000)
        #expect(await spy.lastLanguage == "fr")
        #expect(await spy.lastModel == "chosen")
    }
    @Test("resume skips checkpointed segments and completes existing revision")
    func resumesCheckpoint() async throws {
        let db = try AppDatabase.inMemory(); let meetings = MeetingRepository(database: db); let transcripts = TranscriptRepository(database: db); let jobs = ImportJobRepository(database: db)
        let meeting = try meetings.create(title: "x", source: .imported)
        let options = ImportOptions(subjectID: nil, sourceLanguage: "en", translate: false, targetLanguage: "zh", whisperModel: "m", diarize: false, maximumSegmentDuration: 1)
        var (job, revision) = try jobs.createWithRevision(meetingID: meeting.id, sourcePath: "/tmp/resume.wav", options: options)
        try transcripts.insert(.init(revisionID: revision.id, sequence: 0, startTime: 0, endTime: 1, refinedText: "existing", status: .succeeded))
        job.nextSegmentSequence = 1; try jobs.save(job)
        let spy = TranscriberSpy(); let coordinator = ImportCoordinator(meetings: meetings, transcripts: transcripts, jobs: jobs,
            decoder: StubDecoder(audio: .init(samples: Array(repeating: 0.2, count: 32_000), sampleRate: 16_000, duration: 2)), transcriber: spy)
        let result = try await coordinator.resume(job)
        #expect(result.status == .succeeded)
        #expect(await spy.callCount == 1)
        #expect(try transcripts.fetchSegments(revisionID: revision.id).count == 2)
    }
}

private struct StubDecoder: AudioImportDecoding {
    let audio: DecodedAudio
    func decode(url: URL) async throws -> DecodedAudio { audio }
}
private struct StubTranscriber: ImportedAudioTranscribing {
    func transcribe(samples: [Float], sampleRate: Double, language: String, model: String) async throws -> String { "segment" }
}
private struct CancellingTranscriber: ImportedAudioTranscribing {
    func transcribe(samples: [Float], sampleRate: Double, language: String, model: String) async throws -> String { throw CancellationError() }
}
private struct StubTranslator: ImportedAudioTranslating {
    func translate(_ text: String, targetLanguage: String) async throws -> String { "译：\(text)" }
}
private struct FailingTranslator: ImportedAudioTranslating {
    func translate(_ text: String, targetLanguage: String) async throws -> String { throw AudioImportError.unreadable("translation failed") }
}
private actor HookRecorder: ImportedAudioPostProcessing {
    var calls: [String] = []
    func diarize(meetingID: UUID, transcriptRevisionID: UUID, snapshot: SessionAudioSnapshot) async throws { calls.append("diarize") }
    func export(meetingID: UUID, transcriptRevisionID: UUID, translationRevisionID: UUID?) async throws { calls.append("export") }
}
private struct FailingPostProcessor: ImportedAudioPostProcessing {
    func diarize(meetingID: UUID, transcriptRevisionID: UUID, snapshot: SessionAudioSnapshot) async throws {}
    func export(meetingID: UUID, transcriptRevisionID: UUID, translationRevisionID: UUID?) async throws { throw AudioImportError.unreadable("export failed") }
}
private actor TranscriberSpy: ImportedAudioTranscribing {
    var lastRate: Double = 0; var lastCount = 0; var lastLanguage = ""; var lastModel = ""; var callCount = 0
    func transcribe(samples: [Float], sampleRate: Double, language: String, model: String) async throws -> String {
        callCount += 1; lastRate = sampleRate; lastCount = samples.count; lastLanguage = language; lastModel = model; return "ok"
    }
}
