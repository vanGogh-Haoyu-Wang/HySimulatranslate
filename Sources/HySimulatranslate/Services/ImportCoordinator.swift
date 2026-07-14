import Foundation

protocol ImportedAudioTranscribing: Sendable {
    func transcribe(samples: [Float], sampleRate: Double, language: String, model: String) async throws -> String
}
protocol ImportedAudioTranslating: Sendable { func translate(_ text: String, targetLanguage: String) async throws -> String }
protocol ImportedAudioPostProcessing: Sendable {
    func diarize(meetingID: UUID, transcriptRevisionID: UUID, snapshot: SessionAudioSnapshot) async throws
    func export(meetingID: UUID, transcriptRevisionID: UUID, translationRevisionID: UUID?) async throws
}

struct AudioTimelineRange: Sendable, Equatable { var sampleRange: Range<Int>; var start: Double; var end: Double }
enum AudioTimelineSegmenter {
    static func ranges(audio: DecodedAudio, maximumDuration: Double, silenceThreshold: Float = 0.008) -> [AudioTimelineRange] {
        guard !audio.samples.isEmpty, audio.sampleRate > 0 else { return [] }
        let window = max(1, Int(audio.sampleRate * 0.02)); let bridge = max(1, Int(audio.sampleRate * 0.30))
        var speechWindows: [Range<Int>] = []
        var offset = 0
        while offset < audio.samples.count {
            let end = min(audio.samples.count, offset + window)
            let rms = sqrt(audio.samples[offset..<end].reduce(Float.zero) { $0 + $1 * $1 } / Float(end - offset))
            if rms >= silenceThreshold { speechWindows.append(offset..<end) }
            offset = end
        }
        var spans: [Range<Int>] = []
        for item in speechWindows {
            if let last = spans.last, item.lowerBound - last.upperBound <= bridge { spans[spans.count - 1] = last.lowerBound..<item.upperBound }
            else { spans.append(item) }
        }
        if spans.isEmpty { spans = [0..<audio.samples.count] }
        let maxSamples = max(1, Int(audio.sampleRate * max(0.1, maximumDuration)))
        return spans.flatMap { span -> [AudioTimelineRange] in
            var result: [AudioTimelineRange] = []; var start = span.lowerBound
            while start < span.upperBound {
                let end = min(span.upperBound, start + maxSamples)
                result.append(.init(sampleRange: start..<end, start: Double(start) / audio.sampleRate, end: Double(end) / audio.sampleRate)); start = end
            }
            return result
        }
    }
}

private struct StreamingImportSegmenter {
    struct Segment { var samples: [Float]; var start: Double; var end: Double }
    let sampleRate: Double; let maximumSamples: Int; private var buffer: [Float] = []; private var startSample = 0
    init(sampleRate: Double, maximumDuration: Double) { self.sampleRate = sampleRate; maximumSamples = max(1, Int(sampleRate * maximumDuration)) }
    mutating func append(_ samples: [Float]) -> [Segment] {
        buffer.append(contentsOf: samples); var output: [Segment] = []
        while buffer.count >= maximumSamples {
            output.append(remove(count: maximumSamples))
        }
        if let cut = silenceCut(), cut > 0 { output.append(remove(count: cut)) }
        return output
    }
    mutating func finish() -> [Segment] { buffer.isEmpty ? [] : [remove(count: buffer.count)] }
    private mutating func remove(count: Int) -> Segment {
        let samples = Array(buffer.prefix(count)); buffer.removeFirst(count)
        let lower = startSample; startSample += count
        return .init(samples: samples, start: Double(lower) / sampleRate, end: Double(startSample) / sampleRate)
    }
    private func silenceCut() -> Int? {
        let silence = max(1, Int(sampleRate * 0.3)); guard buffer.count > silence * 2 else { return nil }
        let tail = buffer.suffix(silence); let rms = sqrt(tail.reduce(Float.zero) { $0 + $1 * $1 } / Float(silence))
        return rms < 0.008 ? buffer.count - silence : nil
    }
}

struct WhisperKitImportTranscriber: ImportedAudioTranscribing {
    let service: WhisperKitService
    func transcribe(samples: [Float], sampleRate: Double, language: String, model: String) async throws -> String {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples { var value = Int16(max(-1, min(1, sample)) * 32767); pcm.append(Data(bytes: &value, count: 2)) }
        guard let result = await service.transcribe(pcmData: pcm, language: language), !result.isEmpty else { throw AudioImportError.unreadable("WhisperKit 未返回转写结果") }
        return result
    }
}

struct TranslationServiceImportAdapter: ImportedAudioTranslating {
    let service: TranslationService
    let appleTranslator: any AppleSystemTranslating
    let credential: LLMProviderCredential?
    func translate(_ text: String, targetLanguage: String) async throws -> String {
        let online = await service.robustTranslate(text, groqCredential: credential)
        if !TranslationService.isCompleteTranslationFailure(online) { return online }
        if let apple = await appleTranslator.translate(text) { return AppleTranslationTextNormalizer.simplifiedChinese(apple) }
        throw AudioImportError.unreadable("在线翻译与 Apple 离线翻译均不可用")
    }
}

actor ImportCoordinator {
    private let meetings: MeetingRepository; private let transcripts: TranscriptRepository; private let jobs: ImportJobRepository
    private let decoder: any AudioImportDecoding; private let transcriber: (any ImportedAudioTranscribing)?
    private let translator: (any ImportedAudioTranslating)?
    private let postProcessor: (any ImportedAudioPostProcessing)?
    private let modelUsage: ModelUsageCoordinator?
    init(meetings: MeetingRepository, transcripts: TranscriptRepository, jobs: ImportJobRepository,
         decoder: any AudioImportDecoding = AudioImportDecoder(), transcriber: (any ImportedAudioTranscribing)? = nil,
         translator: (any ImportedAudioTranslating)? = nil, postProcessor: (any ImportedAudioPostProcessing)? = nil,
         modelUsage: ModelUsageCoordinator? = nil) {
        self.meetings = meetings; self.transcripts = transcripts; self.jobs = jobs; self.decoder = decoder; self.transcriber = transcriber; self.translator = translator; self.postProcessor = postProcessor; self.modelUsage = modelUsage
    }

    func retranslate(meetingID: UUID, transcriptRevisionID: UUID, targetLanguage: String, provider: String, model: String, makeCurrent: Bool = true) async throws -> TranslationRevisionRecord {
        let providerLease = try modelUsage?.begin(owner: "retranslate", resourceIDs: [provider.lowercased()])
        defer { providerLease?.release() }
        guard let translator else { throw AudioImportError.unreadable("翻译服务不可用") }
        var revision = try transcripts.createTranslationRevision(meetingID: meetingID, transcriptRevisionID: transcriptRevisionID, targetLanguage: targetLanguage, provider: provider, model: model, status: .processing)
        do {
            for segment in try transcripts.fetchSegments(revisionID: transcriptRevisionID) {
                try Task.checkCancellation()
                let text = try await translator.translate(segment.refinedText, targetLanguage: targetLanguage)
                try transcripts.insert(.init(translationRevisionID: revision.id, segmentID: segment.id, text: text))
            }
            revision.status = .succeeded; try transcripts.saveTranslationRevision(revision)
            if makeCurrent { try transcripts.setCurrentTranslationRevision(revision.id, for: meetingID) }
        } catch is CancellationError {
            revision.status = .cancelled; revision.errorMessage = "任务已取消"; try transcripts.saveTranslationRevision(revision)
        } catch {
            revision.status = .failed; revision.errorMessage = error.localizedDescription; try transcripts.saveTranslationRevision(revision)
        }
        return revision
    }

    func importAudio(from url: URL, meetingID: UUID, options: ImportOptions, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ImportJobRecord {
        let (job, revision) = try jobs.createWithRevision(meetingID: meetingID, sourcePath: url.standardizedFileURL.path, options: options)
        return try await process(job: job, revision: revision, url: url, options: options, onProgress: onProgress)
    }

    func resume(_ job: ImportJobRecord, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ImportJobRecord {
        guard job.status == .processing, let revisionID = job.transcriptRevisionID,
              let revision = try transcripts.fetchRevision(id: revisionID) else { throw PersistenceRepositoryError.missingRecord }
        let options = try JSONDecoder().decode(ImportOptions.self, from: job.optionsJSON)
        return try await process(job: job, revision: revision, url: URL(fileURLWithPath: job.sourcePath), options: options, onProgress: onProgress)
    }

    private func process(job initialJob: ImportJobRecord, revision initialRevision: TranscriptRevisionRecord, url: URL, options: ImportOptions, onProgress: (@Sendable (Double) -> Void)?) async throws -> ImportJobRecord {
        var resourceIDs: Set<String> = ["whisperkit"]
        if options.diarize { resourceIDs.insert("speakerkit") }
        let modelLease = try modelUsage?.begin(owner: "import/retranscribe", resourceIDs: resourceIDs)
        defer { modelLease?.release() }
        var job = initialJob; var revision = initialRevision; let meetingID = initialJob.meetingID
        let existingBySequence = Dictionary(uniqueKeysWithValues: (try transcripts.fetchSegments(revisionID: revision.id)).map { ($0.sequence, $0) })
        let diarizationStore = options.diarize ? SessionAudioStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("HySimulatranslateImportDiarization")) : nil
        if let diarizationStore { try diarizationStore.beginSession(sessionID: job.id) }
        defer { diarizationStore?.cleanupCurrentSession() }
        do {
            var segmenter: StreamingImportSegmenter?; var duration = 0.0; var sequence = 0; let resumeFrom = job.nextSegmentSequence
            for try await chunk in decoder.stream(url: url, framesPerChunk: 16_384) {
                try Task.checkCancellation()
                if segmenter == nil { segmenter = StreamingImportSegmenter(sampleRate: chunk.sampleRate, maximumDuration: options.maximumSegmentDuration) }
                duration = max(duration, chunk.totalDuration)
                for segment in segmenter!.append(chunk.samples) {
                    let saved: TranscriptSegmentRecord
                    if sequence >= resumeFrom { saved = try await persist(segment: segment, sequence: sequence, revisionID: revision.id, options: options); job.nextSegmentSequence = sequence + 1; job.progress = min(0.9, segment.end / max(duration, 0.001) * 0.9); job.updatedAt = Date(); try jobs.save(job); onProgress?(job.progress) }
                    else if let existing = existingBySequence[sequence] { saved = existing } else { throw PersistenceRepositoryError.missingRecord }
                    if let diarizationStore { _ = try diarizationStore.appendSegment(uid: saved.id, pcmData: Self.pcm16(segment.samples, sourceRate: Double(segment.samples.count) / max(0.001, segment.end - segment.start))) }
                    sequence += 1
                }
            }
            if var finalizer = segmenter { for segment in finalizer.finish() { let saved: TranscriptSegmentRecord; if sequence >= resumeFrom { saved = try await persist(segment: segment, sequence: sequence, revisionID: revision.id, options: options); job.nextSegmentSequence = sequence + 1; try jobs.save(job) } else if let existing = existingBySequence[sequence] { saved = existing } else { throw PersistenceRepositoryError.missingRecord }; if let diarizationStore { _ = try diarizationStore.appendSegment(uid: saved.id, pcmData: Self.pcm16(segment.samples, sourceRate: Double(segment.samples.count) / max(0.001, segment.end - segment.start))) }; sequence += 1 } }
            revision.status = .succeeded; try transcripts.saveRevision(revision)
            try meetings.updateSession(id: meetingID, duration: duration, status: .ready)
            if options.translate, translator != nil {
                let translation = try await retranslate(meetingID: meetingID, transcriptRevisionID: revision.id, targetLanguage: options.targetLanguage, provider: "automatic", model: "translation-fallback", makeCurrent: false)
                guard translation.status == .succeeded else { throw AudioImportError.unreadable(translation.errorMessage ?? "翻译失败") }
                job.translationRevisionID = translation.id
            }
            if options.diarize, let snapshot = diarizationStore?.finalizeSnapshot() { try await postProcessor?.diarize(meetingID: meetingID, transcriptRevisionID: revision.id, snapshot: snapshot) }
            try await postProcessor?.export(meetingID: meetingID, transcriptRevisionID: revision.id, translationRevisionID: job.translationRevisionID)
            try transcripts.setCurrentImportRevisions(transcriptID: revision.id, translationID: job.translationRevisionID, for: meetingID)
            job.status = .succeeded; job.progress = 1; onProgress?(1)
        } catch is CancellationError {
            revision.status = .cancelled; revision.errorMessage = "任务已取消"; try? transcripts.saveRevision(revision)
            job.status = .cancelled; job.errorMessage = "任务已取消"
        } catch {
            revision.status = .failed; revision.errorMessage = error.localizedDescription; try? transcripts.saveRevision(revision)
            job.status = .failed; job.errorMessage = error.localizedDescription
        }
        job.updatedAt = Date(); try jobs.save(job); return job
    }

    private func persist(segment: StreamingImportSegmenter.Segment, sequence: Int, revisionID: UUID, options: ImportOptions) async throws -> TranscriptSegmentRecord {
        let whisperSamples = Self.resampleForWhisper(segment.samples, sourceRate: (segment.end - segment.start) > 0 ? Double(segment.samples.count) / (segment.end - segment.start) : 16_000)
        guard let transcriber else { throw AudioImportError.unreadable("转写服务不可用") }
        let text = try await transcriber.transcribe(samples: whisperSamples, sampleRate: 16_000, language: options.sourceLanguage, model: options.whisperModel)
        let record = TranscriptSegmentRecord(revisionID: revisionID, sequence: sequence, startTime: segment.start, endTime: segment.end, refinedText: text, status: .succeeded)
        try transcripts.insert(record); return record
    }
    private static func pcm16(_ samples: [Float], sourceRate: Double) -> Data {
        var data = Data(); for sample in resampleForWhisper(samples, sourceRate: sourceRate) { var value = Int16(max(-1, min(1, sample)) * 32767); data.append(Data(bytes: &value, count: 2)) }; return data
    }

    private static func resampleForWhisper(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard Int(sourceRate.rounded()) != 16_000 else { return samples }
        var resampler = StreamingAudioResampler(sourceRate: max(1, Int(sourceRate.rounded())), targetRate: 16_000)
        var output: [Float] = []; output.reserveCapacity(Int(Double(samples.count) * 16_000 / sourceRate))
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + 4096)
            output.append(contentsOf: resampler.process(Array(samples[offset..<end]))); offset = end
        }
        return output
    }

}
