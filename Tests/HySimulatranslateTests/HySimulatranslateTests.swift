import XCTest
@testable import HySimulatranslate

private actor StubAppleSystemTranslator: AppleSystemTranslating {
    private let prepareResult: Bool
    private let translationResult: String?
    private var translatedTexts: [String] = []

    init(prepareResult: Bool = true, translationResult: String?) {
        self.prepareResult = prepareResult
        self.translationResult = translationResult
    }

    func prepare(sourceLanguage: String, targetLanguage: String) async -> Bool {
        prepareResult
    }

    func translate(_ text: String, sourceLanguage: String, targetLanguage: String) async -> String? {
        translatedTexts.append(text)
        return translationResult
    }

    func receivedTexts() -> [String] {
        translatedTexts
    }
}

private actor ConcurrentCallProbe {
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }
}

final class HySimulatranslateTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: "audioCaptureSource")
        UserDefaults.standard.removeObject(forKey: "audioInputSelection")
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        UserDefaults.standard.removeObject(forKey: "audioCaptureSource")
        UserDefaults.standard.removeObject(forKey: "audioInputSelection")
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HySimulatranslateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    func testAppResourceInstallerCopiesBundledPayloadWithoutOverwritingUserFiles() throws {
        let root = try makeTemporaryDirectory()
        let payload = root
            .appendingPathComponent("Bundle")
            .appendingPathComponent(AppResourceLocator.payloadDirectoryName)
        let support = root.appendingPathComponent("Support")
        let sherpaRelativePath = AppResourceLocator.sherpaModelRelativePath
        let bundledSherpaModel = payload.appendingPathComponent(sherpaRelativePath)
        let installedSherpaModel = support.appendingPathComponent(sherpaRelativePath)

        try FileManager.default.createDirectory(at: bundledSherpaModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedSherpaModel, withIntermediateDirectories: true)
        try Data("bundled tokens".utf8).write(to: bundledSherpaModel.appendingPathComponent("tokens.txt"))
        try Data("user tokens".utf8).write(to: installedSherpaModel.appendingPathComponent("tokens.txt"))

        try AppResourceLocator.installBundledResourcesIfNeeded(
            supportDirectory: support,
            bundledPayloadDirectory: payload
        )

        let preservedTokens = try String(contentsOf: installedSherpaModel.appendingPathComponent("tokens.txt"))
        XCTAssertEqual(preservedTokens, "user tokens")
    }

    func testAppResourceLocatorPrefersInstalledModelsThenBundledPayload() throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("Support")
        let payload = root
            .appendingPathComponent("Bundle")
            .appendingPathComponent(AppResourceLocator.payloadDirectoryName)
        let supportSherpa = support.appendingPathComponent(AppResourceLocator.sherpaModelRelativePath)
        let payloadSherpa = payload.appendingPathComponent(AppResourceLocator.sherpaModelRelativePath)
        let supportWhisper = support.appendingPathComponent(AppResourceLocator.whisperModelRelativePath)
        let payloadWhisper = payload.appendingPathComponent(AppResourceLocator.whisperModelRelativePath)

        try FileManager.default.createDirectory(at: supportSherpa, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadSherpa, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportWhisper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadWhisper, withIntermediateDirectories: true)

        XCTAssertEqual(
            AppResourceLocator.sherpaModelDirectory(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            )?.standardizedFileURL.path,
            supportSherpa.standardizedFileURL.path
        )
        XCTAssertEqual(
            AppResourceLocator.whisperModelSearchRoots(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            ).prefix(2).map { $0.standardizedFileURL.path },
            [
                supportWhisper.standardizedFileURL.path,
                payloadWhisper.standardizedFileURL.path
            ]
        )

        try FileManager.default.removeItem(at: supportSherpa)

        XCTAssertEqual(
            AppResourceLocator.sherpaModelDirectory(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            )?.standardizedFileURL.path,
            payloadSherpa.standardizedFileURL.path
        )
    }

    func testCourseSubjectCodableRoundTrips() throws {
        let subject = CourseSubject(
            name: "Advanced Thermodynamics",
            abbrev: "Thermo",
            keywords: "entropy, enthalpy",
            meetingFocus: "Preserve technical definitions."
        )

        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(CourseSubject.self, from: data)

        XCTAssertEqual(decoded.name, subject.name)
        XCTAssertEqual(decoded.abbrev, subject.abbrev)
        XCTAssertEqual(decoded.keywords, subject.keywords)
        XCTAssertEqual(decoded.meetingFocus, subject.meetingFocus)
    }

    func testCourseDatabaseShipsOnlyProtectedDefaultSubject() throws {
        UserDefaults.standard.removeObject(forKey: "CustomSubjects")
        UserDefaults.standard.removeObject(forKey: "HiddenDefaultSubjects")
        let database = CourseDatabase()

        XCTAssertEqual(database.defaultSubjects.map(\.name), ["默认"])
        XCTAssertEqual(database.allSubjects.map(\.name), ["默认"])
        XCTAssertFalse(database.hasHiddenDefaultSubjects)

        let defaultSubject = try XCTUnwrap(database.defaultSubjects.first)
        XCTAssertFalse(database.canRemoveSubject(defaultSubject))
        XCTAssertTrue(defaultSubject.meetingFocus.lowercased().contains("do not invent"))

        database.removeSubject(defaultSubject)

        XCTAssertEqual(database.allSubjects.map(\.name), ["默认"])
        XCTAssertFalse(database.hasHiddenDefaultSubjects)
    }

    func testASRSegmentFilterDropsCommonJunk() {
        let service = WhisperKitService()

        XCTAssertTrue(service.shouldDropASRSegment("Thank you."))
        XCTAssertTrue(service.shouldDropASRSegment("Subtitles by Amara.org"))
        XCTAssertTrue(service.shouldDropASRSegment("mic test"))
        XCTAssertTrue(service.shouldDropASRSegment("I'm sorry."))
        XCTAssertTrue(service.shouldDropASRSegment("NINE I'm sorry."))
        XCTAssertTrue(service.shouldDropASRSegment("I'm sorry. I'm sorry."))
        XCTAssertTrue(service.shouldDropASRSegment("Good night."))
        XCTAssertFalse(service.shouldDropASRSegment("The polymer glass transition temperature is important."))
    }

    func testASRSegmentFilterDropsAccentAnalysisPlaceholder() {
        let service = WhisperKitService()

        XCTAssertTrue(WhisperKitService.isAccentAnalysisPlaceholder("[🎤 捕获到口音音频，分析中...]"))
        XCTAssertTrue(service.shouldDropASRSegment("[🎤 捕获到口音音频，分析中...]"))
        XCTAssertTrue(service.shouldDropASRSegment("捕获到口音音频，分析中"))
    }

    func testASRSegmentFilterDropsSymbolOnlyAndTranslationPromptJunk() {
        let service = WhisperKitService()

        XCTAssertTrue(service.shouldDropASRSegment("-"))
        XCTAssertTrue(service.shouldDropASRSegment("-."))
        XCTAssertTrue(service.shouldDropASRSegment("请提供需要翻译的英文文本。"))
        XCTAssertTrue(service.shouldDropASRSegment("无内容需要翻译。"))
    }

    func testLectureFocusFilterDropsQuietShortWhispersAfterCalibration() {
        var filter = LectureFocusFilter()
        _ = filter.evaluate(
            LectureSegmentMetrics(duration: 6, rmsDBFS: -18, lexicalWordCount: 12),
            elapsed: 10
        )
        _ = filter.evaluate(
            LectureSegmentMetrics(duration: 5, rmsDBFS: -20, lexicalWordCount: 10),
            elapsed: 25
        )

        XCTAssertEqual(
            filter.evaluate(
                LectureSegmentMetrics(duration: 1.8, rmsDBFS: -34, lexicalWordCount: 3),
                elapsed: 35
            ),
            .drop
        )
    }

    func testLectureFocusFilterKeepsDominantShortSpeechAndSustainedQuestions() {
        var filter = LectureFocusFilter()
        _ = filter.evaluate(
            LectureSegmentMetrics(duration: 6, rmsDBFS: -18, lexicalWordCount: 12),
            elapsed: 10
        )
        _ = filter.evaluate(
            LectureSegmentMetrics(duration: 5, rmsDBFS: -20, lexicalWordCount: 10),
            elapsed: 25
        )

        XCTAssertEqual(
            filter.evaluate(
                LectureSegmentMetrics(duration: 1.5, rmsDBFS: -19, lexicalWordCount: 2),
                elapsed: 35
            ),
            .keep
        )
        XCTAssertEqual(
            filter.evaluate(
                LectureSegmentMetrics(duration: 4, rmsDBFS: -35, lexicalWordCount: 7),
                elapsed: 40
            ),
            .keepFormalQuestion
        )
    }

    func testLectureSpeakerFocusReducerKeepsMainSpeakerAndFormalQuestionsOnly() {
        let mainFirst = UUID()
        let mainSecond = UUID()
        let whisper = UUID()
        let question = UUID()
        let result = LectureSpeakerFocusReducer.reduce(
            samples: [
                LectureSpeakerSample(
                    id: mainFirst,
                    speakerID: "A",
                    metrics: LectureSegmentMetrics(duration: 12, rmsDBFS: -18, lexicalWordCount: 20)
                ),
                LectureSpeakerSample(
                    id: mainSecond,
                    speakerID: "A",
                    metrics: LectureSegmentMetrics(duration: 10, rmsDBFS: -19, lexicalWordCount: 18)
                ),
                LectureSpeakerSample(
                    id: whisper,
                    speakerID: "B",
                    metrics: LectureSegmentMetrics(duration: 1.5, rmsDBFS: -34, lexicalWordCount: 3)
                ),
                LectureSpeakerSample(
                    id: question,
                    speakerID: "C",
                    metrics: LectureSegmentMetrics(duration: 5, rmsDBFS: -30, lexicalWordCount: 9)
                )
            ]
        )

        XCTAssertEqual(result.mainSpeakerID, "A")
        XCTAssertEqual(result.droppedIDs, [whisper])
        XCTAssertFalse(result.droppedIDs.contains(question))
    }

    func testRefinementBackpressureWarnsAndProtectsAtBoundedThresholds() {
        XCTAssertEqual(
            RefinementBackpressurePolicy.loadState(pendingCount: 6, pendingAudioSeconds: 20),
            .warning
        )
        XCTAssertEqual(
            RefinementBackpressurePolicy.loadState(pendingCount: 4, pendingAudioSeconds: 30),
            .warning
        )
        XCTAssertEqual(
            RefinementBackpressurePolicy.loadState(pendingCount: 12, pendingAudioSeconds: 40),
            .protecting
        )
        XCTAssertEqual(
            RefinementBackpressurePolicy.loadState(pendingCount: 8, pendingAudioSeconds: 60),
            .protecting
        )
    }

    func testRefinementBackpressureDropsLowValueAndUsesSherpaForHighValueAtCapacity() {
        XCTAssertEqual(
            RefinementBackpressurePolicy.admission(
                for: LectureSegmentMetrics(duration: 1.5, rmsDBFS: -36, lexicalWordCount: 2),
                state: .protecting
            ),
            .drop
        )
        XCTAssertEqual(
            RefinementBackpressurePolicy.admission(
                for: LectureSegmentMetrics(duration: 8, rmsDBFS: -19, lexicalWordCount: 14),
                state: .protecting
            ),
            .useSherpa
        )
    }

    func testResourcePressurePolicyShedsHeavyWorkForWarningAndCriticalPressure() {
        XCTAssertEqual(ResourcePressurePolicy.action(for: .normal), .none)
        XCTAssertEqual(ResourcePressurePolicy.action(for: .warning), .shedHeavyWork)
        XCTAssertEqual(ResourcePressurePolicy.action(for: .critical), .shedHeavyWork)
    }

    func testPipelineDiagnosticsSnapshotIncludesQueueBytesAndLoadState() {
        let snapshot = PipelineDiagnosticsSnapshot(
            timestamp: 123,
            whisperQueue: 7,
            llmQueue: 2,
            pendingPCMBytes: 640_000,
            loadState: .warning,
            speakerDiarizationActive: false,
            residentMemoryBytes: 1_048_576
        )

        XCTAssertTrue(snapshot.logLine.contains("W=7"))
        XCTAssertTrue(snapshot.logLine.contains("L=2"))
        XCTAssertTrue(snapshot.logLine.contains("pcmBytes=640000"))
        XCTAssertTrue(snapshot.logLine.contains("load=预警"))
        XCTAssertTrue(snapshot.logLine.contains("residentMB=1.0"))
    }

    func testSmartWhisperRoutingUsesLocalOnlyForExplicitCloudFailure() {
        XCTAssertFalse(
            SmartWhisperRouting.shouldUseLocalFallback(
                cloudText: "A substantially longer and valid cloud transcription.",
                cloudRequestFailed: false
            )
        )
        XCTAssertTrue(
            SmartWhisperRouting.shouldUseLocalFallback(
                cloudText: nil,
                cloudRequestFailed: true
            )
        )
        XCTAssertTrue(
            SmartWhisperRouting.shouldUseLocalFallback(
                cloudText: "-",
                cloudRequestFailed: false
            )
        )
    }

    func testSpeakerDiarizationWindowPlannerBoundsOneHourSessionToTenMinuteWindows() {
        let sampleRate = 16_000
        let windows = SpeakerDiarizationWindowPlanner.windows(
            totalSamples: sampleRate * 60 * 60,
            sampleRate: sampleRate
        )

        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.allSatisfy { $0.count <= sampleRate * 60 * 10 })
        XCTAssertEqual(windows[1].startSample, windows[0].endSample - sampleRate * 30)
        XCTAssertEqual(windows.last?.endSample, sampleRate * 60 * 60)
    }

    func testSessionAudioStoreAppendsPCMToDiskAndTracksStableSampleSpans() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionAudioStore(rootDirectory: root)
        let firstID = UUID()
        let secondID = UUID()
        try store.beginSession(sessionID: UUID())
        let first = try store.appendSegment(
            uid: firstID,
            pcmData: Data(repeating: 1, count: 32_000)
        )
        let second = try store.appendSegment(
            uid: secondID,
            pcmData: Data(repeating: 2, count: 64_000)
        )
        let snapshot = try XCTUnwrap(store.finalizeSnapshot())

        XCTAssertEqual(first, SpeakerAudioSpan(itemID: firstID, startSample: 0, endSample: 16_000))
        XCTAssertEqual(second, SpeakerAudioSpan(itemID: secondID, startSample: 16_000, endSample: 48_000))
        XCTAssertEqual(snapshot.spans, [first, second])
        XCTAssertEqual(snapshot.totalSamples, 48_000)
        XCTAssertEqual(
            try Data(contentsOf: snapshot.audioURL).count,
            96_000
        )
    }

    func testSessionAudioStoreCleanupRemovesCompletedAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAudioStoreCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionAudioStore(rootDirectory: root)
        try store.beginSession(sessionID: UUID())
        _ = try store.appendSegment(uid: UUID(), pcmData: Data(repeating: 0, count: 32_000))
        let snapshot = try XCTUnwrap(store.finalizeSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.audioURL.path))

        store.cleanupCurrentSession()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.audioURL.path))
    }

    func testSessionRecoveryJournalReplaysLatestTranscriptAndTranslationState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRecoveryJournalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let noteURL = root.appendingPathComponent("Recovered.md")
        let uid = UUID()
        let journal = SessionRecoveryJournal()
        try journal.begin(
            directory: root,
            metadata: SessionRecoveryMetadata(
                notePath: noteURL.path,
                courseName: "Project planning",
                courseAbbrev: "PP",
                translationEnabled: true,
                noteFormat: .markdown
            )
        )
        try journal.recordSegment(uid: uid, sherpaText: "Initial draft.")
        try journal.recordRefinement(uid: uid, english: "Refined lecturer sentence.")
        try journal.recordTranslation(uid: uid, chinese: "精校后的教师语句。")

        let recovered = try XCTUnwrap(
            SessionRecoveryJournal.loadRecoverableSession(
                from: root.appendingPathComponent(SessionRecoveryJournal.fileName)
            )
        )

        XCTAssertEqual(recovered.metadata.courseName, "Project planning")
        XCTAssertEqual(recovered.items.count, 1)
        XCTAssertEqual(recovered.items[0].id, uid)
        XCTAssertEqual(recovered.items[0].english, "Refined lecturer sentence.")
        XCTAssertEqual(recovered.items[0].chinese, "精校后的教师语句。")
    }

    func testSessionRecoveryJournalIgnoresTruncatedFinalLine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruncatedSessionJournalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let uid = UUID()
        let journal = SessionRecoveryJournal()
        try journal.begin(
            directory: root,
            metadata: SessionRecoveryMetadata(
                notePath: root.appendingPathComponent("Recovered.md").path,
                courseName: "Project planning",
                courseAbbrev: "PP",
                translationEnabled: true,
                noteFormat: .markdown
            )
        )
        try journal.recordSegment(uid: uid, sherpaText: "A durable complete line.")
        journal.close()

        let journalURL = root.appendingPathComponent(SessionRecoveryJournal.fileName)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"kind":"refinement""#.utf8))
        try handle.close()

        let recovered = try XCTUnwrap(
            SessionRecoveryJournal.loadRecoverableSession(from: journalURL)
        )
        XCTAssertEqual(recovered.items.map(\.english), ["A durable complete line."])
    }

    func testSessionRecoveryJournalIgnoresCompletedSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletedSessionJournalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let journal = SessionRecoveryJournal()
        try journal.begin(
            directory: root,
            metadata: SessionRecoveryMetadata(
                notePath: root.appendingPathComponent("Complete.md").path,
                courseName: "Default",
                courseAbbrev: "Default",
                translationEnabled: true,
                noteFormat: .markdown
            )
        )
        try journal.recordSegment(uid: UUID(), sherpaText: "Completed text.")
        try journal.markCompleted()

        XCTAssertNil(
            try SessionRecoveryJournal.loadRecoverableSession(
                from: root.appendingPathComponent(SessionRecoveryJournal.fileName)
            )
        )
    }

    func testSessionRecoveryJournalWritesRecoveredNoteAndCleansSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoverPendingSessionTests-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root.appendingPathComponent("session", isDirectory: true)
        let notesDirectory = root.appendingPathComponent("notes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        let noteURL = notesDirectory.appendingPathComponent("Recovered.md")
        let journal = SessionRecoveryJournal()
        try journal.begin(
            directory: sessionDirectory,
            metadata: SessionRecoveryMetadata(
                notePath: noteURL.path,
                courseName: "Critical reading",
                courseAbbrev: "CR",
                translationEnabled: true,
                noteFormat: .markdown
            )
        )
        try journal.recordSegment(uid: UUID(), sherpaText: "Evaluate the evidence critically.")
        try journal.recordTranslation(uid: UUID(), chinese: "不会匹配其他条目的译文。")
        journal.close()

        let recoveredURLs = try SessionRecoveryJournal.recoverPendingSessions(
            rootDirectory: root
        )

        XCTAssertEqual(recoveredURLs, [noteURL])
        let content = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Evaluate the evidence critically."))
        XCTAssertTrue(content.contains("会话异常中断"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    func testSherpaNoTextCutKeepsShortAccentAnalysisWindow() {
        XCTAssertFalse(SherpaService.shouldCutNoTextSegment(text: "", audioSec: 1.9))
        XCTAssertTrue(SherpaService.shouldCutNoTextSegment(text: "", audioSec: 2.0))
        XCTAssertFalse(SherpaService.shouldCutNoTextSegment(text: "actual speech", audioSec: 8.0))
    }

    @MainActor
    func testAccentAnalysisPlaceholderStillQueuesWhenOnlyInFlightPlaceholderExists() async {
        let vm = TranscriptionViewModel()
        vm.dynamicItems = [
            TranscriptionItem(
                english: "[🎤 捕获到口音音频，分析中...]",
                status: .whispering,
                zone: .dynamic
            )
        ]

        await vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 0, count: 64_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )

        XCTAssertEqual(vm.whisperQueueSize, 1)
        XCTAssertEqual(vm.dynamicItems.count, 2)
    }

    @MainActor
    func testQueuedAccentAnalysisPlaceholdersMergeWithoutDroppingAudio() async {
        let vm = TranscriptionViewModel()

        await vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 0, count: 64_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )
        await vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 1, count: 64_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )

        XCTAssertEqual(vm.whisperQueueSize, 1)
        XCTAssertEqual(vm.dynamicItems.count, 1)
    }

    @MainActor
    func testQueuedAccentAnalysisPlaceholdersSplitWhenMergedAudioWouldExceedSixSeconds() async {
        let vm = TranscriptionViewModel()

        await vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 0, count: 100_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )
        await vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 1, count: 100_000),
            sherpaText: "[🎤 捕获到口音音频，分析中...]"
        )

        XCTAssertEqual(vm.whisperQueueSize, 2)
        XCTAssertEqual(vm.dynamicItems.count, 2)
    }

    @MainActor
    func testWhisperQueueNeverExceedsProtectingCapacityAndHighValueOverflowUsesSherpa() async {
        let vm = TranscriptionViewModel()
        let fiveSecondsPCM = Data(repeating: 1, count: 160_000)

        for index in 0..<16 {
            await vm.enqueueWhisperItemForTesting(
                uid: UUID(),
                pcm: fiveSecondsPCM,
                sherpaText: "This is a meaningful lecturer sentence number \(index)."
            )
        }

        XCTAssertEqual(vm.whisperQueueSize, RefinementBackpressurePolicy.protectingCount)
        XCTAssertEqual(vm.refinementLoadState, .protecting)
        XCTAssertGreaterThan(vm.llmQueueSize, 0)
    }

    @MainActor
    func testWhisperQueueAudioNeverExceedsProtectingDuration() async {
        let vm = TranscriptionViewModel()
        let twentyFiveSecondsPCM = Data(repeating: 1, count: 800_000)
        let twentySecondsPCM = Data(repeating: 1, count: 640_000)

        for index in 0..<2 {
            await vm.enqueueWhisperItemForTesting(
                uid: UUID(),
                pcm: twentyFiveSecondsPCM,
                sherpaText: "This is sustained high value lecture content number \(index)."
            )
        }
        await vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: twentySecondsPCM,
            sherpaText: "This third substantial segment should use the Sherpa draft."
        )

        XCTAssertEqual(vm.whisperQueueSize, 2)
        XCTAssertEqual(vm.refinementLoadState, .warning)
        XCTAssertGreaterThan(vm.llmQueueSize, 0)
    }

    @MainActor
    func testStopDegradesPendingWhisperItemsToCompletedSherpaText() async {
        let vm = TranscriptionViewModel()
        vm.isRecording = true
        await vm.enqueueWhisperItemForTesting(
            uid: UUID(),
            pcm: Data(repeating: 1, count: 64_000),
            sherpaText: "Pending lecturer content must survive stopping."
        )
        XCTAssertEqual(vm.whisperQueueSize, 1)

        vm.stopTranscription()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.whisperQueueSize, 0)
        XCTAssertTrue(
            vm.historyItems.contains {
                $0.english == "Pending lecturer content must survive stopping." &&
                $0.status == .done
            }
        )
    }

    func testASRSegmentFilterKeepsThanksWhenSessionIsEnding() {
        let service = WhisperKitService()

        XCTAssertFalse(service.shouldDropASRSegment("Thank you.", isSessionEnding: true))
        XCTAssertFalse(service.shouldDropASRSegment("Thanks.", isSessionEnding: true))
        XCTAssertFalse(service.shouldDropASRSegment("Good night.", isSessionEnding: true))
        XCTAssertTrue(service.shouldDropASRSegment("Subtitles by Amara.org", isSessionEnding: true))
    }

    func testASRDisplayCasingNormalizesLongAllCapsFallbacks() {
        let raw = "AGAINST MY QUESTION AFTER THAT IS WHAT HAD TO COME TOGETHER STRATEGICALLY TO DELIVER NVIDIA API GROWTH"

        let normalized = LLMService.normalizeASRCasingForDisplay(raw)

        XCTAssertEqual(
            normalized,
            "Against my question after that is what had to come together strategically to deliver NVIDIA API growth"
        )
        XCTAssertEqual(
            LLMService.normalizeASRCasingForDisplay("A $46 billion net income quarter. So we've moved from years to quarters."),
            "A $46 billion net income quarter. So we've moved from years to quarters."
        )
    }

    func testWhisperKitCacheSearchFindsHuggingFaceSnapshotVariantFolder() throws {
        let root = try makeTemporaryDirectory()
        let variant = root
            .appendingPathComponent("models--argmaxinc--whisperkit-coreml")
            .appendingPathComponent("snapshots")
            .appendingPathComponent("abc123")
            .appendingPathComponent("openai_whisper-large-v3")
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let bundle = variant.appendingPathComponent("\(component).mlmodelc")
            try FileManager.default.createDirectory(
                at: bundle,
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: bundle.appendingPathComponent("weights.bin"))
        }
        try Data([1]).write(to: variant.appendingPathComponent("config.json"))

        let found = WhisperKitService.findCachedModel(in: [root], model: "large-v3")

        XCTAssertEqual(found?.standardizedFileURL.path, variant.standardizedFileURL.path)
    }

    func testWhisperKitCacheSearchIgnoresIncompleteHuggingFaceCache() throws {
        let root = try makeTemporaryDirectory()
        let incomplete = root
            .appendingPathComponent("models--argmaxinc--whisperkit-coreml")
            .appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("abc123".utf8).write(to: incomplete.appendingPathComponent("main"))

        let found = WhisperKitService.findCachedModel(in: [root], model: "large-v3")

        XCTAssertNil(found)
    }

    func testWhisperKitSelfCheckKeepsLocalFallbackModelUnloaded() async throws {
        let root = try makeTemporaryDirectory()
        let variant = root.appendingPathComponent(
            "openai_whisper-large-v3-v20240930_626MB",
            isDirectory: true
        )
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let bundle = variant.appendingPathComponent("\(component).mlmodelc")
            try FileManager.default.createDirectory(
                at: bundle,
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: bundle.appendingPathComponent("weights.bin"))
        }
        try Data([1]).write(to: variant.appendingPathComponent("config.json"))
        let service = WhisperKitService(
            modelSearchRoots: [root]
        )

        let ready = await service.configure(allowDownload: false)
        let state = await service.runtimeState()

        XCTAssertTrue(ready)
        XCTAssertTrue(state.isAvailable)
        XCTAssertFalse(state.isLoaded)
    }

    func testTranslationChunkingKeepsQueriesUnderLimit() {
        let text = """
        If you don't take the time to create the life you want, you will be forced to spend more time coping with the life you don't want. On the way to success, no one will wake you up and no one will pay for you. You need self-management and self-breakthrough. No flower is a flower from the beginning. If we choose comfort, we don't have envy other than for their splendour and beauty. And enrichment. If we choose stormy waves, we need to be firm and indomitable. People's potential is unlimited. Satisfied with the status quo, you will be gradually eliminated.
        """

        let chunks = TranslationService.chunkTextForTranslation(text)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TranslationService.maxTranslationQueryCharacters })
        XCTAssertTrue(chunks.joined(separator: " ").contains("People's potential is unlimited"))
    }

    func testTranslationLanguagePairNormalizesChineseLocale() {
        XCTAssertEqual(TranslationLanguagePair(source: "zh", target: "en"), .init(source: "zh-Hans", target: "en"))
    }

    func testLLMProviderCatalogSeparatesGroqCoreAndFreeLLMSummary() throws {
        let groq = try XCTUnwrap(LLMProviderCatalog.groqCoreProvider)
        let freeLLM = try XCTUnwrap(LLMProviderCatalog.freeLLMSummaryProvider())
        let agnes = try XCTUnwrap(LLMProviderCatalog.agnesOrganizerProvider)

        XCTAssertEqual(groq.displayName, "Groq")
        XCTAssertEqual(groq.modelName, "llama-3.3-70b-versatile")
        XCTAssertEqual(groq.getAPIKeyURL.absoluteString, "https://console.groq.com/keys")

        XCTAssertEqual(freeLLM.displayName, "FreeLLMAPI")
        XCTAssertEqual(freeLLM.modelName, "auto")
        XCTAssertEqual(freeLLM.chatCompletionsURL.absoluteString, "http://100.76.88.120:3001/v1/chat/completions")
        XCTAssertGreaterThanOrEqual(freeLLM.timeout, 20)

        XCTAssertEqual(agnes.displayName, "Agnes 整理")
        XCTAssertEqual(agnes.modelName, "agnes-2.0-flash")
        XCTAssertEqual(agnes.chatCompletionsURL.absoluteString, "https://apihub.agnes-ai.com/v1/chat/completions")
        XCTAssertTrue(agnes.acceptsKey("sk-test-key"))
    }

    func testAgnesConnectivityAcceptsAuthenticatedModelListing() {
        XCTAssertEqual(
            AgnesHistoryOrganizerService.connectivityStatus(
                availableModelIDs: ["agnes-1.5-flash", "agnes-2.0-flash"],
                selectedModelID: "agnes-2.0-flash"
            ),
            .passed
        )
        XCTAssertEqual(
            AgnesHistoryOrganizerService.connectivityStatus(
                availableModelIDs: ["agnes-1.5-flash"],
                selectedModelID: "agnes-2.0-flash"
            ),
            .failed("模型不可用")
        )
    }

    func testLLMProviderCredentialsKeepGroqCoreSeparateFromFreeLLMSummary() {
        let keys: [LLMProviderID: String] = [
            .groq: "gsk_test_key",
            .freeLLM: "router-test-key",
            .agnes: "sk-test-key"
        ]

        let coreCredential = LLMProviderCatalog.groqCoreCredential(from: keys)
        let summaryCredential = LLMProviderCatalog.freeLLMSummaryCredential(from: keys)
        let organizerCredential = LLMProviderCatalog.agnesOrganizerCredential(from: keys)

        XCTAssertEqual(coreCredential?.provider.id, .groq)
        XCTAssertEqual(summaryCredential?.provider.id, .freeLLM)
        XCTAssertEqual(organizerCredential?.provider.id, .agnes)
    }

    func testKeychainProviderKeysPayloadKeepsOnlyNonEmptyKnownProviders() {
        let payload = KeychainManager.providerKeysPayload([
            .groq: "  gsk_test  ",
            .freeLLM: "",
            .agnes: "sk_test"
        ])

        XCTAssertEqual(payload, [
            "groq": "gsk_test",
            "agnes": "sk_test"
        ])
    }

    func testKeychainProviderKeysAggregateJSONRoundTrips() {
        let encoded = KeychainManager.encodeProviderKeys([
            .groq: "gsk_test",
            .freeLLM: " router_test ",
            .agnes: "sk_test"
        ])

        XCTAssertEqual(KeychainManager.decodeProviderKeys(encoded), [
            .groq: "gsk_test",
            .freeLLM: "router_test",
            .agnes: "sk_test"
        ])
        XCTAssertNil(KeychainManager.decodeProviderKeys("not json"))
    }

    func testKeychainProviderKeysResolveUsesAggregateWhenPresent() {
        let aggregate = KeychainManager.encodeProviderKeys([
            .groq: "gsk_aggregate"
        ])
        let resolved = KeychainManager.resolveProviderKeys(aggregate: aggregate)

        XCTAssertEqual(resolved, [.groq: "gsk_aggregate"])
    }

    func testKeychainProviderKeysResolveReturnsEmptyWhenAggregateMissingOrInvalid() {
        XCTAssertEqual(KeychainManager.resolveProviderKeys(aggregate: nil), [:])
        XCTAssertEqual(KeychainManager.resolveProviderKeys(aggregate: "not json"), [:])
    }

    func testKeychainProviderKeysCanMigrateLegacyAccountsWhenExplicitlyRequested() {
        let legacyValues = [
            "groq_api_key": "gsk_legacy",
            "freellm_api_key": " router_legacy ",
            "agnes_api_key": "sk_legacy"
        ]
        let migrated = KeychainManager.migrateLegacyProviderKeys { account in
            legacyValues[account]
        }

        XCTAssertEqual(migrated, [
            .groq: "gsk_legacy",
            .freeLLM: "router_legacy",
            .agnes: "sk_legacy"
        ])
    }

    func testLLMProviderModelListsContainOnlyFreeDefaults() {
        let groqModels = LLMProviderCatalog.models(for: .groq)
        let freeLLMModels = LLMProviderCatalog.models(for: .freeLLM)
        let agnesModels = LLMProviderCatalog.models(for: .agnes)

        XCTAssertEqual(groqModels.first?.id, LLMProviderCatalog.defaultGroqModelName)
        XCTAssertEqual(groqModels.first?.freeStatus, .free)
        XCTAssertEqual(freeLLMModels.first?.id, LLMProviderCatalog.defaultFreeLLMSummaryModelName)
        XCTAssertEqual(freeLLMModels.first?.freeStatus, .unknown)
        XCTAssertEqual(agnesModels, [
            LLMProviderModel(
                providerID: .agnes,
                id: LLMProviderCatalog.defaultAgnesOrganizerModelName,
                freeStatus: .free,
                recommendationScore: 100
            )
        ])
        XCTAssertTrue(groqModels.allSatisfy { $0.freeStatus == .free })
    }

    func testModelDiscoveryParsesOpenAICompatibleModelIDs() throws {
        let fixture = """
        {"object":"list","data":[{"id":"llama-3.3-70b-versatile"},{"id":"whisper-large-v3"}]}
        """.data(using: .utf8)!

        XCTAssertEqual(
            try LLMModelDiscoveryService.modelIDs(from: fixture),
            ["llama-3.3-70b-versatile", "whisper-large-v3"]
        )
    }

    func testTextModelFilteringRejectsExplicitNonTextModelsAndKeepsUnknownCandidates() {
        let groq = LLMProviderCatalog.textModels(
            for: .groq,
            modelIDs: [
                "llama-3.3-70b-versatile",
                "whisper-large-v3",
                "acme/text-next",
                "acme/code-next",
                "acme/embedding-v2",
                "acme/video-gen",
                "canopylabs/orpheus-v1-english",
                "openai/gpt-oss-safeguard-20b"
            ]
        )

        XCTAssertEqual(
            Set(groq.map(\.id)),
            Set(["llama-3.3-70b-versatile", "acme/text-next", "acme/code-next"])
        )
        XCTAssertEqual(groq.first(where: { $0.id == "llama-3.3-70b-versatile" })?.freeStatus, .free)
        XCTAssertEqual(groq.first(where: { $0.id == "acme/text-next" })?.freeStatus, .unknown)
        XCTAssertEqual(LLMProviderModelFreeStatus.free.displayText, "免费")
        XCTAssertEqual(LLMProviderModelFreeStatus.unknown.displayText, "资费未知")
        XCTAssertNil(
            LLMProviderCatalog.model(
                for: .groq,
                modelID: "canopylabs/orpheus-v1-english",
                preserveUnknown: true
            )
        )
    }

    func testAgnesTextModelFilteringKeepsNewTextModelsAndRejectsImageAndVideoModels() {
        let models = LLMProviderCatalog.textModels(
            for: .agnes,
            modelIDs: [
                "agnes-1.5-flash",
                "agnes-2.0-flash",
                "agnes-video-v2.0",
                "agnes-image-2.1-flash"
            ]
        )

        XCTAssertEqual(Set(models.map(\.id)), Set(["agnes-1.5-flash", "agnes-2.0-flash"]))
        XCTAssertEqual(models.first(where: { $0.id == "agnes-1.5-flash" })?.freeStatus, .unknown)
        XCTAssertEqual(models.first(where: { $0.id == "agnes-2.0-flash" })?.freeStatus, .free)
        XCTAssertTrue(LLMProviderCatalog.isRecommended(providerID: .agnes, modelID: "agnes-2.0-flash"))
        XCTAssertFalse(LLMProviderCatalog.isRecommended(providerID: .agnes, modelID: "agnes-1.5-flash"))
    }

    func testAgnesHistoryOrganizerValidationRejectsMissingIDsAndExpansions() {
        let items = [
            AgnesHistoryOrganizerItem(id: "a", english: "The AI factory started with Nvidia.", chinese: "AI 工厂始于 Nvidia。"),
            AgnesHistoryOrganizerItem(id: "b", english: "Nvidia provided the first platform.", chinese: "Nvidia 提供了第一个平台。")
        ]
        let valid = """
        {"updates":[
          {"id":"a","english":"The AI factory started with Nvidia.","chinese":"AI 工厂始于 Nvidia。","drop":false},
          {"id":"b","english":"Nvidia provided the first platform.","chinese":"Nvidia 提供了第一个平台。","drop":false}
        ]}
        """
        let missing = """
        {"updates":[
          {"id":"a","english":"The AI factory started with Nvidia.","chinese":"AI 工厂始于 Nvidia。","drop":false}
        ]}
        """
        let expanded = """
        {"updates":[
          {"id":"a","english":"The AI factory started with Nvidia and then this model invents an entire extra explanation about markets, architecture, products, strategy, roadmap, pricing, customers, revenue, competitors, and many facts that were never in the transcript.","chinese":"AI 工厂始于 Nvidia。","drop":false},
          {"id":"b","english":"Nvidia provided the first platform.","chinese":"Nvidia 提供了第一个平台。","drop":false}
        ]}
        """

        XCTAssertEqual(AgnesHistoryOrganizerService.validatedUpdates(from: valid, originalItems: items)?.count, 2)
        XCTAssertNil(AgnesHistoryOrganizerService.validatedUpdates(from: missing, originalItems: items))
        XCTAssertNil(AgnesHistoryOrganizerService.validatedUpdates(from: expanded, originalItems: items))
    }

    func testAgnesTranslationOnlyValidationRejectsMissingDuplicateAndCrossSpeakerIDs() {
        let items = [
            AgnesTranslationOnlyItem(id: "a", speakerID: "A", chinese: "第一段来自 A。"),
            AgnesTranslationOnlyItem(id: "b", speakerID: "A", chinese: "第二段仍然来自 A。"),
            AgnesTranslationOnlyItem(id: "c", speakerID: "B", chinese: "第三段来自 B。")
        ]
        let valid = """
        {"paragraphs":[
          {"id":"a+b","speakerID":"A","text":"第一段来自 A。第二段仍然来自 A。","sourceIDs":["a","b"]},
          {"id":"c","speakerID":"B","text":"第三段来自 B。","sourceIDs":["c"]}
        ]}
        """
        let missing = """
        {"paragraphs":[
          {"id":"a","speakerID":"A","text":"第一段来自 A。","sourceIDs":["a"]},
          {"id":"c","speakerID":"B","text":"第三段来自 B。","sourceIDs":["c"]}
        ]}
        """
        let duplicate = """
        {"paragraphs":[
          {"id":"a","speakerID":"A","text":"第一段来自 A。","sourceIDs":["a"]},
          {"id":"again-a","speakerID":"A","text":"第一段来自 A。","sourceIDs":["a"]},
          {"id":"b+c","speakerID":"A","text":"第二段仍然来自 A。第三段来自 B。","sourceIDs":["b","c"]}
        ]}
        """
        let crossSpeaker = """
        {"paragraphs":[
          {"id":"a+c","speakerID":"A","text":"第一段来自 A。第三段来自 B。","sourceIDs":["a","c"]},
          {"id":"b","speakerID":"A","text":"第二段仍然来自 A。","sourceIDs":["b"]}
        ]}
        """
        let expanded = """
        {"paragraphs":[
          {"id":"a+b","speakerID":"A","text":"第一段来自 A。第二段仍然来自 A。这里额外补充了大量原文没有提到的背景、计划、数字、风险、后续行动和结论，用来测试扩写过滤。","sourceIDs":["a","b"]},
          {"id":"c","speakerID":"B","text":"第三段来自 B。","sourceIDs":["c"]}
        ]}
        """

        XCTAssertEqual(AgnesHistoryOrganizerService.validatedTranslationOnlyBlocks(from: valid, originalItems: items)?.count, 2)
        XCTAssertNil(AgnesHistoryOrganizerService.validatedTranslationOnlyBlocks(from: missing, originalItems: items))
        XCTAssertNil(AgnesHistoryOrganizerService.validatedTranslationOnlyBlocks(from: duplicate, originalItems: items))
        XCTAssertNil(AgnesHistoryOrganizerService.validatedTranslationOnlyBlocks(from: crossSpeaker, originalItems: items))
        XCTAssertNil(AgnesHistoryOrganizerService.validatedTranslationOnlyBlocks(from: expanded, originalItems: items))
    }

    func testHistoryWallCleanerDropsDuplicatesAndTrimsAdjacentBoundaryOverlap() {
        let first = TranscriptionItem(
            english: "The product roadmap is clear customer support workflow automation",
            status: .done,
            zone: .history
        )
        let second = TranscriptionItem(
            english: "support workflow automation will launch next quarter.",
            status: .done,
            zone: .history
        )
        let duplicate = TranscriptionItem(
            english: "support workflow automation will launch next quarter.",
            status: .done,
            zone: .history
        )

        let cleaned = HistoryWallCleaner.clean([first, second, duplicate])

        XCTAssertEqual(cleaned[0].english, "The product roadmap is clear customer")
        XCTAssertTrue(cleaned[1].isVisible)
        XCTAssertFalse(cleaned[2].isVisible)
        XCTAssertEqual(cleaned[2].status, .dropped)
    }

    func testFailedConnectivityRecordsSinkModelsButKeepRecommendationOrder() {
        let failed = LLMProviderModelConnectivityRecord(
            providerID: .groq,
            modelID: "openai/gpt-oss-120b",
            status: .failed,
            detail: "HTTP 404",
            testedAt: Date(timeIntervalSince1970: 0)
        )
        let records = LLMProviderCatalog.connectivityRecordsByKey([failed])
        let sorted = LLMProviderCatalog.sortedModels(
            [
                LLMProviderModel(providerID: .groq, id: "openai/gpt-oss-120b", freeStatus: .free, recommendationScore: 98),
                LLMProviderModel(providerID: .groq, id: "gemma2-9b-it", freeStatus: .free, recommendationScore: 74),
                LLMProviderModel(providerID: .groq, id: "llama-3.1-8b-instant", freeStatus: .free, recommendationScore: 88)
            ],
            connectivityRecords: records
        )

        XCTAssertEqual(sorted.map(\.id), ["llama-3.1-8b-instant", "gemma2-9b-it", "openai/gpt-oss-120b"])
    }

    func testSelectedProviderModelsOverrideCredentialModelNames() {
        let keys: [LLMProviderID: String] = [
            .groq: "gsk_test_key",
            .freeLLM: "router-test-key"
        ]
        let selected: [LLMProviderID: String] = [
            .groq: "llama-3.1-8b-instant"
        ]

        XCTAssertEqual(
            LLMProviderCatalog.groqCoreCredential(
                from: keys,
                selectedModelNames: selected
            )?.provider.modelName,
            "llama-3.1-8b-instant"
        )
        XCTAssertEqual(
            LLMProviderCatalog.freeLLMSummaryCredential(from: keys)?.provider.modelName,
            "auto"
        )
    }

    @MainActor
    func testChangingProviderModelInvalidatesPreviousConnectivityState() {
        let vm = TranscriptionViewModel()
        vm.providerAPIKeys = [.groq: "gsk_test_key", .freeLLM: "router-test-key"]
        vm.engineStatus = .ready("ready")
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.apiReady = true
        vm.translationEnabled = true
        vm.liveSummaryReady = true
        vm.groqCoreModelName = "llama-3.1-8b-instant"

        vm.noteProviderModelSelectionChanged()

        XCTAssertFalse(vm.apiReady)
        XCTAssertFalse(vm.translationEnabled)
        XCTAssertFalse(vm.liveSummaryReady)
        XCTAssertTrue(vm.providerCheckResults.contains {
            $0.provider.id == .groq && $0.provider.modelName == "llama-3.1-8b-instant"
        })
    }

    func testLiveSummaryCursorRequestsOnlyAfterEightTranslatedUnits() {
        var cursor = LiveSummaryCursor()

        XCTAssertNil(cursor.pendingRange(totalCount: 7))
        XCTAssertEqual(cursor.pendingRange(totalCount: 8), 0..<8)

        cursor.markSummarized(upTo: 8)

        XCTAssertNil(cursor.pendingRange(totalCount: 15))
        XCTAssertEqual(cursor.pendingRange(totalCount: 16), 8..<16)

        cursor.markSummarized(upTo: 16)
        XCTAssertNil(cursor.pendingRange(totalCount: 3))
        XCTAssertEqual(cursor.pendingRange(totalCount: 8), 0..<8)
    }

    func testLiveSummaryCursorDoesNotImmediatelyRetryFailedBatch() {
        var cursor = LiveSummaryCursor()

        XCTAssertEqual(cursor.pendingRange(totalCount: 8), 0..<8)
        cursor.markFailed(at: 8)

        XCTAssertNil(cursor.pendingRange(totalCount: 8))
        XCTAssertNil(cursor.pendingRange(totalCount: 15))
        XCTAssertEqual(cursor.pendingRange(totalCount: 16), 8..<16)
    }

    func testTranslationUnitsPreserveLLMLineBreaks() {
        let text = "First sentence.\nSecond sentence.\n\nThird sentence."

        XCTAssertEqual(
            TranslationService.translationUnits(for: text),
            ["First sentence.", "Second sentence.", "Third sentence."]
        )
    }

    func testTranslationExecutionModePrefersOnlineThenAppleOffline() {
        XCTAssertEqual(
            TranslationExecutionMode.resolve(apiReady: true, appleReady: true),
            .online
        )
        XCTAssertEqual(
            TranslationExecutionMode.resolve(apiReady: false, appleReady: true),
            .appleOffline
        )
        XCTAssertEqual(
            TranslationExecutionMode.resolve(apiReady: false, appleReady: false),
            .unavailable
        )
    }

    func testTranslationExecutionModeUsesDistinctStatusTitles() {
        XCTAssertEqual(TranslationExecutionMode.online.statusTitle, "在线同传")
        XCTAssertEqual(TranslationExecutionMode.appleOffline.statusTitle, "Apple 离线同传")
        XCTAssertEqual(TranslationExecutionMode.unavailable.statusTitle, "本地转录")
    }

    func testOnlineTranslationFailureRecognizesMultipleTimedOutUnits() {
        XCTAssertTrue(TranslationService.isCompleteTranslationFailure("[翻译超时]"))
        XCTAssertTrue(
            TranslationService.isCompleteTranslationFailure(
                "[翻译超时]\n[翻译超时]"
            )
        )
        XCTAssertFalse(
            TranslationService.isCompleteTranslationFailure(
                "有效译文\n[翻译超时]"
            )
        )
    }

    func testAppleTranslationRequestGateSerializesConcurrentCalls() async {
        let gate = AppleTranslationRequestGate()
        let probe = ConcurrentCallProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await gate.acquire()
                    await probe.enter()
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await probe.leave()
                    await gate.release()
                }
            }
        }

        let maximumActiveCount = await probe.maximumActiveCount
        XCTAssertEqual(maximumActiveCount, 1)
    }

    func testAppleTranslationNormalizesTraditionalChineseToSimplified() {
        XCTAssertEqual(
            AppleTranslationTextNormalizer.simplifiedChinese(
                "一個好的研究問題應該有重點和答案。"
            ),
            "一个好的研究问题应该有重点和答案。"
        )
    }

    func testOfflineFormalTranslationUsesAppleForWhisperSentence() async {
        let translator = StubAppleSystemTranslator(
            translationResult: "這是 Whisper 精校後的句子。"
        )
        let service = TranslationService(appleTranslator: translator)
        let uid = UUID()
        let resultExpectation = expectation(description: "Apple formal translation")
        await service.configure { resultUID, text in
            XCTAssertEqual(resultUID, uid)
            XCTAssertEqual(text, "这是 Whisper 精校后的句子。")
            resultExpectation.fulfill()
        }

        await service.translate(
            uid: uid,
            englishText: "This is the Whisper-refined sentence.",
            groqCredential: nil,
            mode: .appleOffline
        )

        await fulfillment(of: [resultExpectation], timeout: 1)
        let receivedTexts = await translator.receivedTexts()
        XCTAssertEqual(receivedTexts, ["This is the Whisper-refined sentence."])
    }

    @MainActor
    func testSherpaDraftAppleTranslationRemainsDisplayOnly() async {
        let translator = StubAppleSystemTranslator(
            translationResult: "项目规划需要明确的研究问题。"
        )
        let vm = TranscriptionViewModel(appleTranslationService: translator)
        await vm.prepareAppleTranslationForTesting()
        vm.isRecording = true
        vm.translationEnabled = true

        vm.updateSherpaDraftForTesting(
            "Project planning requires clear research questions."
        )
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(vm.draftAppleTranslation, "项目规划需要明确的研究问题。")
        XCTAssertTrue(vm.historyItems.isEmpty)
        XCTAssertTrue(vm.dynamicItems.isEmpty)
    }

    @MainActor
    func testSherpaSegmentApplePreviewIsRemovedWhenItemMovesToHistory() async {
        let translator = StubAppleSystemTranslator(
            translationResult: "这是 Sherpa 临时译文。"
        )
        let vm = TranscriptionViewModel(appleTranslationService: translator)
        await vm.prepareAppleTranslationForTesting()
        vm.translationEnabled = true
        let uid = UUID()

        await vm.enqueueWhisperItemForTesting(
            uid: uid,
            pcm: Data(repeating: 1, count: 64_000),
            sherpaText: "This is a meaningful Sherpa preview sentence."
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.appleRealtimeTranslations[uid], "这是 Sherpa 临时译文。")
        XCTAssertNil(vm.dynamicItems.first?.chinese)

        let now = Date().timeIntervalSince1970 + 3
        vm.dynamicItems[0].status = .done
        vm.dynamicItems[0].doneTime = now - 3
        vm.flushDynamicItemsForIdleInput(now: now)

        XCTAssertEqual(vm.historyItems.first?.id, uid)
        XCTAssertNil(vm.historyItems.first?.chinese)
        XCTAssertNil(vm.appleRealtimeTranslations[uid])
    }

    @MainActor
    func testAppleOfflineReadinessEnablesFormalTranslationWithoutAPI() {
        let vm = TranscriptionViewModel()

        vm.applyTranslationReadinessForTesting(
            apiReady: false,
            appleReady: true
        )

        XCTAssertEqual(vm.translationExecutionMode, .appleOffline)
        XCTAssertTrue(vm.translationEnabled)
        XCTAssertTrue(vm.appleTranslationReady)
    }

    func testTranscriptOrganizerMergesAdjacentTokenOverlap() {
        let first = UUID()
        let second = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(id: first, text: "NVIDIA is in a quiet period right now, but"),
                TranscriptOrganizerFragment(id: second, text: "right now, but what we want to hear from him is the bigger picture.")
            ],
            recentHistory: []
        )

        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(
            result.outputs.first?.text,
            "NVIDIA is in a quiet period right now, but what we want to hear from him is the bigger picture."
        )
        XCTAssertEqual(result.outputs.first?.consumedIDs, [first, second])
        XCTAssertTrue(result.droppedIDs.isEmpty)
    }

    func testTranscriptOrganizerDropsRecentDuplicate() {
        let duplicate = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(
                    id: duplicate,
                    text: "AI actually reinvented the computer industry."
                )
            ],
            recentHistory: [
                "The computer industry is changing.",
                "AI actually reinvented the computer industry."
            ]
        )

        XCTAssertTrue(result.outputs.isEmpty)
        XCTAssertEqual(result.droppedIDs, [duplicate])
    }

    func testTranscriptOrganizerDropsContainedNearDuplicate() {
        let duplicate = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(
                    id: duplicate,
                    text: "We invested in the infrastructure layer."
                )
            ],
            recentHistory: [
                "That's right, and we invested in the infrastructure layer, we invested in companies like CoreWeave and Nebulon."
            ]
        )

        XCTAssertTrue(result.outputs.isEmpty)
        XCTAssertEqual(result.droppedIDs, [duplicate])
    }

    func testTranscriptOrganizerFiltersContextLeaksAndSpeakerLabelsButKeepsAcronyms() {
        let context = UUID()
        let speaker = UUID()
        let acronym = UUID()
        let result = TranscriptOrganizer.organizeRuleBased(
            fragments: [
                TranscriptOrganizerFragment(
                    id: context,
                    text: "Context: capabilities one in order to think you have to generate tokens."
                ),
                TranscriptOrganizerFragment(id: speaker, text: "JAMES UNLESS"),
                TranscriptOrganizerFragment(id: acronym, text: "NVIDIA GPU demand is rising.")
            ],
            recentHistory: []
        )

        XCTAssertEqual(result.outputs.map(\.text), ["NVIDIA GPU demand is rising."])
        XCTAssertEqual(Set(result.droppedIDs), Set([context, speaker]))
    }

    func testTranscriptOrganizerRejectsUnsafeAIFallbackOutput() {
        let fragments = [
            "It creates wonderful things for you, generates a bunch of images.",
            "generates a bunch of images and then comes back with a brochure."
        ]

        XCTAssertNil(
            TranscriptOrganizer.validatedAILines(
                "Here is the cleaned transcript:\nIt creates a full marketing plan and a brochure.",
                originalFragments: fragments
            )
        )
    }

    func testTranscriptDisplayBlockKeepsMismatchedTranslationAsOneBlock() {
        let item = TranscriptionItem(
            english: "First sentence.\nSecond sentence.",
            chinese: "第一句。第二句。",
            status: .done,
            zone: .history
        )

        let block = TranscriptDisplayBlock(item: item)

        XCTAssertEqual(block.englishLines, ["First sentence.", "Second sentence."])
        XCTAssertEqual(block.chineseLines, ["第一句。第二句。"])
        XCTAssertFalse(block.canInterleaveLineByLine)
    }

    func testTranscriptDisplayBlockInterleavesMatchingTranslations() {
        let item = TranscriptionItem(
            english: "First sentence.\nSecond sentence.",
            chinese: "第一句。\n第二句。",
            status: .done,
            zone: .history
        )

        let block = TranscriptDisplayBlock(item: item)

        XCTAssertTrue(block.canInterleaveLineByLine)
    }

    func testHistoryDisplayModeDefaultsToBilingual() {
        XCTAssertEqual(HistoryDisplayMode.defaultMode, .bilingual)
        XCTAssertEqual(HistoryDisplayMode.bilingual.title, "原文+译文")
        XCTAssertEqual(HistoryDisplayMode.translationOnly.title, "仅译文")
    }

    func testTranslationOnlyHistoryBlocksMergeSameSpeakerAndSplitOnSpeakerChange() {
        let items = [
            TranscriptionItem(
                english: "First A sentence.",
                chinese: "第一句来自 A。",
                status: .done,
                zone: .history,
                speakerID: "A"
            ),
            TranscriptionItem(
                english: "Second A sentence.",
                chinese: "第二句仍然来自 A。",
                status: .done,
                zone: .history,
                speakerID: "A"
            ),
            TranscriptionItem(
                english: "First B sentence.",
                chinese: "第三句来自 B。",
                status: .done,
                zone: .history,
                speakerID: "B"
            ),
            TranscriptionItem(
                english: "Pending translation.",
                status: .done,
                zone: .history,
                speakerID: "B"
            )
        ]

        let blocks = TranslationOnlyHistoryBuilder.blocks(from: items)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].speakerID, "A")
        XCTAssertEqual(blocks[0].speakerDisplayName, "发言者 A")
        XCTAssertEqual(blocks[0].text, "第一句来自 A。第二句仍然来自 A。")
        XCTAssertEqual(blocks[0].sourceIDs.count, 2)
        XCTAssertEqual(blocks[1].speakerID, "B")
        XCTAssertEqual(blocks[1].text, "第三句来自 B。")
        XCTAssertEqual(blocks[1].sourceIDs.count, 1)
    }

    func testTranslationOnlyHistoryKeepsSystemMessagesSeparateAndSkipsUntranslatedItems() {
        let system = TranscriptionItem(
            english: "[自检] SpeakerKit: 未通过",
            status: .done,
            zone: .history,
            isSystemMessage: true
        )
        let untranslated = TranscriptionItem(
            english: "This does not have translation yet.",
            status: .done,
            zone: .history,
            speakerID: "A"
        )

        XCTAssertEqual(TranslationOnlyHistoryBuilder.systemMessages(from: [system, untranslated]).map(\.english), [system.english])
        XCTAssertTrue(TranslationOnlyHistoryBuilder.blocks(from: [system, untranslated]).isEmpty)
    }

    func testSessionNoteRendererKeepsBilingualContentWhenItemsHaveSpeakerIDs() {
        let course = CourseSubject(name: "默认", abbrev: "Default", keywords: "", meetingFocus: "")
        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: true,
            items: [
                TranscriptionItem(
                    english: "Speaker labels are display-only.",
                    chinese: "说话人标签只用于显示。",
                    status: .done,
                    zone: .history,
                    speakerID: "A"
                )
            ],
            finalSummary: "本次讨论确认标签不改变笔记格式。",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.contains("Speaker labels are display-only.\n说话人标签只用于显示。"))
        XCTAssertFalse(content.contains("发言者 A"))
    }

    func testSpeakerLabelMapperKeepsStableLabelsAcrossRollingDiarizationRuns() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let spans = [
            SpeakerAudioSpan(itemID: firstID, startSample: 0, endSample: 16000),
            SpeakerAudioSpan(itemID: secondID, startSample: 16000, endSample: 32000)
        ]
        var mapper = SpeakerLabelMapper()

        var labels = mapper.assignLabels(
            for: spans,
            diarizationSegments: [
                SpeakerDiarizationSegment(rawSpeakerID: "speaker_0", startSample: 0, endSample: 16000),
                SpeakerDiarizationSegment(rawSpeakerID: "speaker_1", startSample: 16000, endSample: 32000)
            ]
        )

        XCTAssertEqual(labels[firstID], "A")
        XCTAssertEqual(labels[secondID], "B")

        labels = mapper.assignLabels(
            for: spans + [SpeakerAudioSpan(itemID: thirdID, startSample: 32000, endSample: 48000)],
            diarizationSegments: [
                SpeakerDiarizationSegment(rawSpeakerID: "rerun_7", startSample: 0, endSample: 16000),
                SpeakerDiarizationSegment(rawSpeakerID: "rerun_3", startSample: 16000, endSample: 32000),
                SpeakerDiarizationSegment(rawSpeakerID: "rerun_9", startSample: 32000, endSample: 48000)
            ]
        )

        XCTAssertEqual(labels[firstID], "A")
        XCTAssertEqual(labels[secondID], "B")
        XCTAssertEqual(labels[thirdID], "C")
    }

    func testLiveSummaryPromptRequiresChineseOnlyAndNoInventedContent() {
        let prompt = LiveSummaryPrompt.make(
            previousSummary: "前面讨论了实验目标。",
            newContent: "The speaker said the benchmark should be repeated."
        )

        XCTAssertTrue(prompt.contains("只输出中文"))
        XCTAssertTrue(prompt.contains("不要预测"))
        XCTAssertTrue(prompt.contains("不得补充"))
        XCTAssertTrue(prompt.contains("不要写“以下是”"))
        XCTAssertTrue(prompt.contains("前面讨论了实验目标。"))
        XCTAssertTrue(prompt.contains("The speaker said the benchmark should be repeated."))
    }

    func testLiveSummaryPromptRequestsSpeakerAwareMeetingSummary() {
        let prompt = LiveSummaryPrompt.make(
            previousSummary: "",
            newContent: "Alice asked whether the budget can move. Bob said the deadline matters more."
        )

        XCTAssertTrue(prompt.contains("谁提出"))
        XCTAssertTrue(prompt.contains("谁回答"))
        XCTAssertTrue(prompt.contains("不同观点"))
        XCTAssertTrue(prompt.contains("要求"))
        XCTAssertTrue(prompt.contains("不要臆造身份"))
    }

    func testFinalDetailedSummaryPromptUsesFullTranscriptAndExistingSummary() {
        let prompt = LiveSummaryPrompt.makeFinalDetailed(
            previousSummary: "已有总结：A 认为预算可调整。",
            fullContent: "英文原文：Alice asked whether the budget can move.\n中文译文：Alice 询问预算能否调整。"
        )

        XCTAssertTrue(prompt.contains("最终详细中文总结"))
        XCTAssertTrue(prompt.contains("人物/角色与观点"))
        XCTAssertTrue(prompt.contains("问题与回答"))
        XCTAssertTrue(prompt.contains("分歧或补充观点"))
        XCTAssertTrue(prompt.contains("已有总结：A 认为预算可调整。"))
        XCTAssertTrue(prompt.contains("Alice asked whether the budget can move."))
    }

    func testFreeLLMSummaryServiceRejectsFailureSummaryText() {
        XCTAssertNil(FreeLLMSummaryService.normalizedSummaryContent("总结失败"))
        XCTAssertNil(FreeLLMSummaryService.normalizedSummaryContent("无法根据提供内容生成总结。"))
        XCTAssertEqual(
            FreeLLMSummaryService.normalizedSummaryContent("A 提出预算问题，B 回答期限优先。"),
            "A 提出预算问题，B 回答期限优先。"
        )
    }

    func testSessionNoteRendererAppendsFinalSummaryAndSkipsSystemMessages() {
        let course = CourseSubject(
            name: "默认",
            abbrev: "Default",
            keywords: "",
            meetingFocus: ""
        )
        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: true,
            items: [
                TranscriptionItem(
                    english: "[自检] Sherpa: 通过",
                    status: .done,
                    zone: .history,
                    isSystemMessage: true
                ),
                TranscriptionItem(
                    english: "AI reinvented the computer industry.",
                    chinese: "人工智能重塑了计算机行业。",
                    status: .done,
                    zone: .history
                )
            ],
            finalSummary: "人工智能带来了新的计算方式。",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.contains("逐句同传记录"))
        XCTAssertTrue(content.contains("AI reinvented the computer industry.\n人工智能重塑了计算机行业。"))
        XCTAssertTrue(content.contains("最终中文总结"))
        XCTAssertTrue(content.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("人工智能带来了新的计算方式。"))
        XCTAssertFalse(content.contains("[自检] Sherpa"))
    }

    func testSessionNoteRendererRemovesRepeatedTranscriptParagraphs() {
        let course = CourseSubject(name: "默认", abbrev: "Default", keywords: "", meetingFocus: "")
        let items = [
            TranscriptionItem(
                english: "We invested in the infrastructure layer.",
                chinese: "我们投资了基础设施层。",
                status: .done,
                zone: .history
            ),
            TranscriptionItem(
                english: "Infrastructure layer, we invested in companies like CoreWeave and Nebulon.",
                chinese: "基础设施层，我们投资了 CoreWeave 和 Nebulon 等公司。",
                status: .done,
                zone: .history
            ),
            TranscriptionItem(
                english: "We invested in the infrastructure layer.",
                chinese: "我们投资了基础设施层。",
                status: .done,
                zone: .history
            )
        ]

        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: true,
            items: items,
            finalSummary: "",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.components(separatedBy: "We invested in the infrastructure layer.").count - 1, 1)
        XCTAssertEqual(content.components(separatedBy: "我们投资了基础设施层。").count - 1, 1)
        XCTAssertTrue(content.contains("Infrastructure layer, we invested in companies like CoreWeave and Nebulon."))
    }

    func testSessionNoteRendererMarkdownUsesHeadingsAndRules() {
        let course = CourseSubject(name: "默认", abbrev: "Default", keywords: "", meetingFocus: "")
        let content = SessionNoteRenderer.render(
            course: course,
            translationEnabled: true,
            items: [
                TranscriptionItem(
                    english: "Markdown works with Obsidian.",
                    chinese: "Markdown 可以和 Obsidian 配合。",
                    status: .done,
                    zone: .history
                )
            ],
            finalSummary: "本次讨论确认支持 Markdown。",
            format: .markdown,
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.contains("# HySimulatranslate Notes"))
        XCTAssertTrue(content.contains("## 逐句同传记录"))
        XCTAssertTrue(content.contains("---"))
        XCTAssertTrue(content.contains("## 最终中文总结"))
        XCTAssertTrue(content.contains("Markdown works with Obsidian.\nMarkdown 可以和 Obsidian 配合。"))
    }

    @MainActor
    func testStartGateRequiresMicrophoneSherpaAndWhisperButAllowsOfflineAPI() {
        let vm = TranscriptionViewModel()
        vm.applyMeetingLibraryReadinessForTesting(true, message: "")
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.sherpaReady = true
        vm.whisperReady = false
        vm.apiReady = true

        XCTAssertFalse(vm.canStartTranscription)

        vm.whisperReady = true
        vm.apiReady = false
        vm.translationEnabled = false

        vm.microphoneReady = false
        XCTAssertFalse(vm.canStartTranscription)

        vm.microphoneReady = true

        XCTAssertTrue(vm.canStartTranscription)
        XCTAssertEqual(vm.startTranscriptionButtonTitle, "本地同声传译")

        vm.apiReady = true
        vm.translationEnabled = true

        XCTAssertTrue(vm.canStartTranscription)
        XCTAssertEqual(vm.startTranscriptionButtonTitle, "开始同声传译")
    }

    @MainActor
    func testAudioInputSelectionDefaultsToMicrophoneOnlyAndRequiresOneEnabledInput() {
        let selection = AudioInputSelection.defaultSelection

        XCTAssertTrue(selection.microphoneEnabled)
        XCTAssertFalse(selection.systemAudioEnabled)
        XCTAssertTrue(selection.hasEnabledInput)

        XCTAssertFalse(AudioInputSelection(microphoneEnabled: false, systemAudioEnabled: false).hasEnabledInput)
    }

    @MainActor
    func testStartGateSupportsMicrophoneOnlySystemOnlyAndCombinedInputs() {
        let vm = TranscriptionViewModel()
        vm.applyMeetingLibraryReadinessForTesting(true, message: "")
        vm.engineStatus = .ready("ready")
        vm.sherpaReady = true
        vm.whisperReady = true

        vm.setMicrophoneInputEnabled(true)
        vm.setSystemAudioInputEnabled(false)
        vm.microphoneReady = true
        vm.systemAudioReady = false
        XCTAssertTrue(vm.canStartTranscription)

        vm.setMicrophoneInputEnabled(false)
        vm.setSystemAudioInputEnabled(true)
        vm.microphoneReady = false
        vm.systemAudioReady = true
        XCTAssertTrue(vm.canStartTranscription)

        vm.setMicrophoneInputEnabled(true)
        vm.setSystemAudioInputEnabled(true)
        vm.microphoneReady = true
        vm.systemAudioReady = false
        XCTAssertFalse(vm.canStartTranscription)

        vm.systemAudioReady = true
        XCTAssertTrue(vm.canStartTranscription)

        vm.setMicrophoneInputEnabled(false)
        vm.setSystemAudioInputEnabled(false)
        XCTAssertFalse(vm.audioInputSelection.hasEnabledInput)
        XCTAssertFalse(vm.canStartTranscription)
    }

    func testAudioInputSelectionMigratesLegacyAudioCaptureSourceStorage() {
        XCTAssertEqual(
            AudioInputSelection.fromStorageValue(nil, legacyAudioCaptureSourceStorage: nil),
            .defaultSelection
        )
        XCTAssertEqual(
            AudioInputSelection.fromStorageValue(nil, legacyAudioCaptureSourceStorage: AudioCaptureSource.microphone.storageValue),
            AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: false)
        )
        XCTAssertEqual(
            AudioInputSelection.fromStorageValue(nil, legacyAudioCaptureSourceStorage: AudioCaptureSource.systemAudio.storageValue),
            AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: true)
        )
        let legacyApplicationAudio = AudioCaptureSource.application(
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        XCTAssertEqual(
            AudioInputSelection.fromStorageValue(nil, legacyAudioCaptureSourceStorage: legacyApplicationAudio.storageValue),
            AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: true)
        )
    }

    @MainActor
    func testSavedApplicationAudioSourceMigratesToCombinedInputSelection() {
        let legacySource = AudioCaptureSource.application(
            bundleIdentifier: "com.apple.WindowManager",
            name: "Window Manager"
        )
        UserDefaults.standard.set(legacySource.storageValue, forKey: "audioCaptureSource")

        let vm = TranscriptionViewModel()

        XCTAssertEqual(vm.audioInputSelection, AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: true))
        XCTAssertEqual(vm.audioCaptureSourceStatus, "已切换为麦克风 + 电脑音频，避免应用捕获授权冲突")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "audioInputSelection"),
            AudioInputSelection(microphoneEnabled: true, systemAudioEnabled: true).storageValue
        )
    }

    @MainActor
    func testAudioInputTogglesResetOnlyTheirOwnReadiness() {
        let vm = TranscriptionViewModel()
        vm.microphoneReady = true
        vm.systemAudioReady = true

        vm.setMicrophoneInputEnabled(false)
        XCTAssertFalse(vm.microphoneReady)
        XCTAssertTrue(vm.systemAudioReady)

        vm.setSystemAudioInputEnabled(false)
        XCTAssertFalse(vm.systemAudioReady)
    }

    @MainActor
    func testSelfCheckSummaryIncludesOnlyEnabledInputs() {
        let vm = TranscriptionViewModel()
        vm.setMicrophoneInputEnabled(false)
        vm.setSystemAudioInputEnabled(true)

        vm.publishSelfCheckSummary(
            microphone: false,
            audioSourceReady: true,
            sherpa: true,
            whisper: true,
            providerResults: []
        )

        XCTAssertEqual(vm.historyItems.map(\.english), [
            "[自检] 电脑音频: 通过",
            "[自检] Sherpa: 通过",
            "[自检] WhisperKit 本地灾备: 通过"
        ])
    }

    @MainActor
    func testSelfCheckSummaryReportsAppleSystemTranslationReadiness() {
        let vm = TranscriptionViewModel()

        vm.publishSelfCheckSummary(
            microphone: true,
            sherpa: true,
            whisper: true,
            appleTranslation: true,
            providerResults: []
        )

        XCTAssertTrue(
            vm.historyItems.map(\.english)
                .contains("[自检] Apple 系统翻译: 通过")
        )
    }

    @MainActor
    func testAudioInputChangeRequiresOnlyAudioCheckAndPreservesModelReadiness() {
        let vm = TranscriptionViewModel()
        let providerResult = LLMProviderCheckResult(
            provider: LLMProviderCatalog.groqCoreProvider!,
            status: .passed
        )
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.systemAudioReady = false
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.speakerKitReady = true
        vm.apiReady = true
        vm.translationEnabled = true
        vm.liveSummaryReady = true
        vm.providerCheckResults = [providerResult]
        vm.fullSelfCheckRequired = false
        vm.audioInputCheckRequired = false

        vm.setSystemAudioInputEnabled(true)

        XCTAssertTrue(vm.audioInputCheckRequired)
        XCTAssertFalse(vm.fullSelfCheckRequired)
        XCTAssertTrue(vm.microphoneReady)
        XCTAssertFalse(vm.systemAudioReady)
        XCTAssertTrue(vm.sherpaReady)
        XCTAssertTrue(vm.whisperReady)
        XCTAssertTrue(vm.speakerKitReady)
        XCTAssertTrue(vm.apiReady)
        XCTAssertTrue(vm.translationEnabled)
        XCTAssertTrue(vm.liveSummaryReady)
        XCTAssertEqual(vm.providerCheckResults, [providerResult])
        XCTAssertEqual(vm.nextSelfCheckScope, .audioInput)
    }

    @MainActor
    func testProviderModelChangeForcesFullSelfCheck() {
        let vm = TranscriptionViewModel()
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.fullSelfCheckRequired = false
        vm.audioInputCheckRequired = false

        vm.noteProviderModelSelectionChanged()

        XCTAssertTrue(vm.fullSelfCheckRequired)
        XCTAssertFalse(vm.audioInputCheckRequired)
        XCTAssertEqual(vm.nextSelfCheckScope, .full)
    }

    @MainActor
    func testClosingFailedSystemAudioInputRestoresStartGateWhenMicrophoneIsReady() {
        let vm = TranscriptionViewModel()
        vm.applyMeetingLibraryReadinessForTesting(true, message: "")
        vm.engineStatus = .ready("ready")
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.microphoneReady = true
        vm.fullSelfCheckRequired = false
        vm.audioInputCheckRequired = false

        vm.setSystemAudioInputEnabled(true)
        XCTAssertFalse(vm.canStartTranscription)
        XCTAssertTrue(vm.audioInputCheckRequired)

        vm.setSystemAudioInputEnabled(false)
        XCTAssertTrue(vm.canStartTranscription)
        XCTAssertFalse(vm.audioInputCheckRequired)
    }

    func testSystemAudioEngineDoesNotExposeApplicationAudioSources() async {
        let sources = await SystemAudioCaptureEngine.availableApplicationSources()

        XCTAssertTrue(sources.isEmpty)
    }

    func testSystemAudioPermissionMessageDoesNotMentionMicrophonePermission() {
        let error = NSError(
            domain: "SystemAudioCaptureEngine",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "TCC denied"]
        )

        let message = SystemAudioCaptureEngine.permissionMessage(for: .systemAudio, error: error)

        XCTAssertTrue(message.contains("屏幕与系统音频录制"))
        XCTAssertTrue(message.contains("仅系统录音"))
        XCTAssertTrue(message.contains("电脑音频未授权"))
        XCTAssertFalse(message.contains("麦克风权限未授权"))
    }

    func testGeneratedInfoPlistsDeclareMicrophoneAndSystemAudioUsage() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptPaths = [
            packageRoot.appendingPathComponent("script/build_and_run.sh"),
            packageRoot.appendingPathComponent("script/package_dmg.sh")
        ]

        for scriptPath in scriptPaths {
            let script = try String(contentsOf: scriptPath, encoding: .utf8)
            XCTAssertTrue(script.contains("NSMicrophoneUsageDescription"))
            XCTAssertTrue(script.contains("NSScreenCaptureUsageDescription"))
            XCTAssertTrue(script.contains("NSAudioCaptureUsageDescription"))
            XCTAssertTrue(script.contains("record your local speech"))
            XCTAssertTrue(script.contains("screen and system audio recording access"))
        }
    }

    func testDynamicPanelRendersApplePreviewSeparatelyFromFormalTranslation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent(
                    "Sources/HySimulatranslate/Views/TranscriptionView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("vm.draftAppleTranslation"))
        XCTAssertTrue(source.contains("vm.appleRealtimeTranslations[item.id]"))
        XCTAssertTrue(source.contains("apple.logo"))
    }

    @MainActor
    func testFormattedResultEntersOrganizingBeforeTranslation() {
        let vm = TranscriptionViewModel()
        let uid = UUID()
        vm.dynamicItems = [
            TranscriptionItem(
                id: uid,
                english: "Raw text",
                status: .llmFormatting,
                zone: .dynamic
            )
        ]

        vm.postProcessResult(uid: uid, finalText: "AI changed the computer industry.")

        XCTAssertEqual(vm.dynamicItems.first?.english, "AI changed the computer industry.")
        XCTAssertEqual(vm.dynamicItems.first?.status, .organizing)
    }

    @MainActor
    func testOrganizerMergeKeepsVisibleOrderAndConsumesDuplicateFragment() async {
        let vm = TranscriptionViewModel()
        let first = UUID()
        let second = UUID()
        vm.translationEnabled = false
        vm.dynamicItems = [
            TranscriptionItem(id: first, english: "First", status: .llmFormatting, zone: .dynamic),
            TranscriptionItem(id: second, english: "Second", status: .llmFormatting, zone: .dynamic)
        ]

        vm.postProcessResult(uid: first, finalText: "It creates wonderful things for you, generates a bunch of images.")
        vm.postProcessResult(uid: second, finalText: "generates a bunch of images and then comes back with a brochure.")
        await vm.flushOrganizerQueueForTesting()

        let visibleItems = (vm.historyItems + vm.dynamicItems).filter(\.isVisible)
        XCTAssertEqual(visibleItems.map(\.id), [first])
        XCTAssertEqual(
            visibleItems.first?.english,
            "It creates wonderful things for you, generates a bunch of images and then comes back with a brochure."
        )
        XCTAssertEqual(visibleItems.first?.status, .done)
    }

    @MainActor
    func testSelfCheckSummaryIsPrintedToHistoryWall() {
        let vm = TranscriptionViewModel()

        vm.publishSelfCheckSummary(
            microphone: true,
            sherpa: true,
            whisper: true,
            providerResults: [
                LLMProviderCheckResult(
                    provider: LLMProviderCatalog.groqCoreProvider!,
                    status: .passed
                ),
                LLMProviderCheckResult(
                    provider: LLMProviderCatalog.freeLLMSummaryProvider()!,
                    status: .notConfigured
                )
            ]
        )

        XCTAssertEqual(vm.historyItems.count, 5)
        XCTAssertTrue(vm.historyItems.allSatisfy(\.isSystemMessage))
        XCTAssertEqual(vm.historyItems.map(\.english), [
            "[自检] 麦克风: 通过",
            "[自检] Sherpa: 通过",
            "[自检] WhisperKit 本地灾备: 通过",
            "[自检] Groq / llama-3.3-70b-versatile: 通过",
            "[自检] FreeLLMAPI / auto: 未配置"
        ])
    }

    @MainActor
    func testIdleFlushMovesDoneDynamicItemToHistoryAndClearsDraft() {
        let vm = TranscriptionViewModel()
        let now: TimeInterval = 100
        let item = TranscriptionItem(
            english: "The coating thickness is controlled by deposition time.",
            status: .done,
            zone: .dynamic,
            doneTime: now - 3
        )

        vm.dynamicItems = [item]
        vm.draftText = "The coating thickness"

        vm.flushDynamicItemsForIdleInput(now: now)

        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.historyItems.map(\.english), [item.english])
        XCTAssertEqual(vm.draftText, "")
    }

    @MainActor
    func testIdleFlushMovesTranslatingDynamicItemToHistoryBeforeTranslationReturns() {
        let vm = TranscriptionViewModel()
        let now: TimeInterval = 100
        let item = TranscriptionItem(
            english: "The translation is still pending but the sentence can already appear on the history wall.",
            status: .translating,
            zone: .dynamic,
            doneTime: now - 3
        )

        vm.dynamicItems = [item]

        vm.flushDynamicItemsForIdleInput(now: now)
        vm.renderUI(force: true)

        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.historyItems.map(\.english), [item.english])
        XCTAssertEqual(vm.historyItems.first?.status, .done)
        XCTAssertNil(vm.historyItems.first?.chinese)
    }

    @MainActor
    func testLateTranslationResultUpdatesHistoryItemMovedBeforeTranslationReturns() {
        let vm = TranscriptionViewModel()
        let uid = UUID()
        vm.historyItems = [
            TranscriptionItem(
                id: uid,
                english: "The sentence already moved to the history wall.",
                status: .done,
                zone: .history
            )
        ]

        vm.applyTranslation(uid: uid, zhText: "这句话已经先进入历史墙。")

        XCTAssertEqual(vm.historyItems.first?.chinese, "这句话已经先进入历史墙。")
        XCTAssertEqual(vm.historyItems.first?.status, .done)
    }

    @MainActor
    func testRenderKeepsWallOrderWhenShortSentencePrecedesLongSentence() {
        let vm = TranscriptionViewModel()
        let short = TranscriptionItem(
            english: "I'm just kidding.",
            status: .done,
            zone: .dynamic,
            doneTime: 100
        )
        let long = TranscriptionItem(
            english: "Sometimes we become numb to the scale of the numbers and the transformation we are experiencing in the market today.",
            status: .done,
            zone: .dynamic,
            doneTime: 101
        )

        vm.dynamicItems = [short, long]
        vm.renderUI(force: true)

        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.historyItems.map(\.english), [short.english, long.english])
    }

    @MainActor
    func testRenderDoesNotLetLongSentenceBypassUnfinishedEarlierSentence() {
        let vm = TranscriptionViewModel()
        let pending = TranscriptionItem(
            english: "Earlier sentence is still being formatted.",
            status: .llmFormatting,
            zone: .dynamic
        )
        let long = TranscriptionItem(
            english: "A later long sentence has enough words to trigger hard wall movement but must not bypass the earlier item.",
            status: .done,
            zone: .dynamic,
            doneTime: 100
        )

        vm.dynamicItems = [pending, long]
        vm.renderUI(force: true)

        XCTAssertTrue(vm.historyItems.isEmpty)
        XCTAssertEqual(vm.dynamicItems.map(\.english), [pending.english, long.english])
    }

    @MainActor
    func testClearDisplayHistoryRemovesWallDynamicAndDraft() {
        let vm = TranscriptionViewModel()
        vm.historyItems = [TranscriptionItem(english: "History item.", status: .done, zone: .history)]
        vm.dynamicItems = [TranscriptionItem(english: "Dynamic item.", status: .done, zone: .dynamic)]
        vm.draftText = "Current draft"
        vm.canRestart = true

        vm.clearDisplayHistory()

        XCTAssertTrue(vm.historyItems.isEmpty)
        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.draftText, "")
        XCTAssertFalse(vm.canRestart)
    }

    func testNoteRecordScannerReturnsSupportedNoteFilesInModificationOrder() throws {
        let directory = try makeTemporaryDirectory()
        let older = directory.appendingPathComponent("older.txt")
        let newer = directory.appendingPathComponent("newer.TXT")
        let newest = directory.appendingPathComponent("newest.md")
        let markdown = directory.appendingPathComponent("reference.markdown")
        let ignored = directory.appendingPathComponent("ignored.json")
        let nested = directory.appendingPathComponent("Nested", isDirectory: true)

        try Data("Older note body".utf8).write(to: older)
        try Data("Newer note body".utf8).write(to: newer)
        try Data("# Newest note\n---\nMarkdown body".utf8).write(to: newest)
        try Data("# Reference note".utf8).write(to: markdown)
        try Data("Not a note".utf8).write(to: ignored)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("Nested note".utf8).write(to: nested.appendingPathComponent("nested.txt"))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)],
            ofItemAtPath: newest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 150)],
            ofItemAtPath: markdown.path
        )

        let records = TranscriptionViewModel.scanNoteRecords(in: directory)

        XCTAssertEqual(records.map(\.fileName), ["newest.md", "newer.TXT", "reference.markdown", "older.txt"])
        XCTAssertEqual(records.map(\.format), [.markdown, .text, .markdown, .text])
        XCTAssertEqual(records.first?.previewSummary, "Newest note Markdown body")
    }

    @MainActor
    func testRefreshNoteRecordsUsesConfiguredNoteDirectory() throws {
        let directory = try makeTemporaryDirectory()
        try Data("Session note".utf8).write(to: directory.appendingPathComponent("session.txt"))
        try Data("# Markdown note".utf8).write(to: directory.appendingPathComponent("session.md"))
        try Data("Ignore".utf8).write(to: directory.appendingPathComponent("session.json"))

        let vm = TranscriptionViewModel()
        vm.noteDirectoryPath = directory.path
        vm.refreshNoteRecords()

        XCTAssertEqual(Set(vm.noteRecords.map(\.fileName)), Set(["session.txt", "session.md"]))
    }

    @MainActor
    func testNoteFileFormatDefaultsToMarkdownAndBuildsExpectedExtensions() {
        UserDefaults.standard.removeObject(forKey: "noteFileFormat")
        let vm = TranscriptionViewModel()
        let course = CourseSubject(name: "默认", abbrev: "Default", keywords: "", meetingFocus: "")

        XCTAssertEqual(vm.noteFileFormat, .markdown)
        XCTAssertEqual(
            TranscriptionViewModel.noteFileName(course: course, dateString: "2026-06-15_02-45", format: .markdown),
            "Default_Session_2026-06-15_02-45.md"
        )
        XCTAssertEqual(
            TranscriptionViewModel.noteFileName(course: course, dateString: "2026-06-15_02-45", format: .text),
            "Default_Session_2026-06-15_02-45.txt"
        )
    }

    @MainActor
    func testStartNewRecordClearsDisplayButKeepsReadinessAndProviderResults() {
        let vm = TranscriptionViewModel()
        vm.applyMeetingLibraryReadinessForTesting(true, message: "")
        let result = LLMProviderCheckResult(
            provider: LLMProviderCatalog.groqCoreProvider!,
            status: .passed
        )
        vm.selectAudioCaptureSource(.microphone)
        vm.engineStatus = .ready("ready")
        vm.microphoneReady = true
        vm.sherpaReady = true
        vm.whisperReady = true
        vm.apiReady = true
        vm.translationEnabled = true
        vm.liveSummaryReady = true
        vm.providerCheckResults = [result]
        vm.historyItems = [TranscriptionItem(english: "History item.", status: .done, zone: .history)]
        vm.dynamicItems = [TranscriptionItem(english: "Dynamic item.", status: .done, zone: .dynamic)]
        vm.draftText = "Current draft"
        vm.liveSummaryText = "Summary"
        vm.canRestart = true

        vm.startNewRecordWithoutSelfCheck()

        XCTAssertTrue(vm.historyItems.isEmpty)
        XCTAssertTrue(vm.dynamicItems.isEmpty)
        XCTAssertEqual(vm.draftText, "")
        XCTAssertEqual(vm.liveSummaryText, "")
        XCTAssertTrue(vm.microphoneReady)
        XCTAssertTrue(vm.sherpaReady)
        XCTAssertTrue(vm.whisperReady)
        XCTAssertTrue(vm.apiReady)
        XCTAssertTrue(vm.liveSummaryReady)
        XCTAssertEqual(vm.providerCheckResults, [result])
        XCTAssertTrue(vm.canStartTranscription)
    }

    @MainActor
    func testSelectCourseUpdatesCurrentCourseButDoesNotChangeWhileRecording() {
        let vm = TranscriptionViewModel()
        let first = CourseSubject(name: "First", abbrev: "F", keywords: "", meetingFocus: "")
        let second = CourseSubject(name: "Second", abbrev: "S", keywords: "", meetingFocus: "")

        vm.selectCourse(first)
        XCTAssertEqual(vm.currentCourse, first)

        vm.isRecording = true
        vm.selectCourse(second)
        XCTAssertEqual(vm.currentCourse, first)
    }

    @MainActor
    func testProviderCheckStripHidesAfterTranscriptionStartsOrHistoryArrives() {
        let results = [
            LLMProviderCheckResult(provider: LLMProviderCatalog.groqCoreProvider!, status: .passed),
            LLMProviderCheckResult(provider: LLMProviderCatalog.freeLLMSummaryProvider()!, status: .passed)
        ]
        let systemHistory = [
            TranscriptionItem(english: "[自检] Sherpa: 通过", status: .done, zone: .history, isSystemMessage: true)
        ]
        let formalHistory = [
            TranscriptionItem(english: "Hello.", status: .done, zone: .history, isSystemMessage: false)
        ]

        XCTAssertTrue(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: false,
            canRestart: false,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: true,
            isFinalizingSession: false,
            canRestart: false,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: true,
            canRestart: false,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: false,
            canRestart: true,
            historyItems: systemHistory,
            providerCheckResults: results
        ))
        XCTAssertFalse(TranscriptionView.shouldShowProviderCheckStrip(
            isRecording: false,
            isFinalizingSession: false,
            canRestart: false,
            historyItems: formalHistory,
            providerCheckResults: results
        ))
    }

    @MainActor
    func testUpdateProviderAPIKeysUpdatesViewModelProviderKeys() {
        let vm = TranscriptionViewModel()
        vm.updateProviderAPIKeys([
            .groq: "gsk_test_key",
            .freeLLM: "router-test-key",
            .agnes: "sk-test-key"
        ])

        XCTAssertEqual(vm.providerAPIKeys[.groq], "gsk_test_key")
        XCTAssertEqual(vm.providerAPIKeys[.freeLLM], "router-test-key")
        XCTAssertEqual(vm.providerAPIKeys[.agnes], "sk-test-key")
        XCTAssertEqual(vm.providerCheckResults.count, 3)
    }

    @MainActor
    func testStopTranscriptionKeepsRestartDisabledUntilFinalNoteAttemptFinishes() async {
        let vm = TranscriptionViewModel()
        vm.currentCourse = CourseSubject(
            name: "默认",
            abbrev: "Default",
            keywords: "",
            meetingFocus: ""
        )
        vm.isRecording = true
        vm.canRestart = true
        vm.liveSummaryReady = false
        vm.historyItems = [
            TranscriptionItem(
                english: "Alice asked whether the budget can move.",
                chinese: "Alice 询问预算能否调整。",
                status: .done,
                zone: .history
            )
        ]

        vm.stopTranscription()

        XCTAssertTrue(vm.isFinalizingSession)
        XCTAssertFalse(vm.canRestart)

        for _ in 0..<20 where vm.isFinalizingSession {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(vm.isFinalizingSession)
        XCTAssertTrue(vm.canRestart)
        XCTAssertEqual(vm.liveSummaryStatus, "笔记写入失败，可重试")
    }

    func testVADResourcePrefersApplicationSupportFile() throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("Support")
        let payload = root
            .appendingPathComponent("Bundle")
            .appendingPathComponent(AppResourceLocator.payloadDirectoryName)
        let supportVAD = support.appendingPathComponent(AppResourceLocator.vadModelRelativePath)

        try FileManager.default.createDirectory(at: supportVAD.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("vad".utf8).write(to: supportVAD)

        XCTAssertEqual(
            AppResourceLocator.vadModelFile(
                supportDirectory: support,
                bundledPayloadDirectory: payload
            )?.standardizedFileURL.path,
            supportVAD.standardizedFileURL.path
        )
    }

    func testProjectNoLongerShipsOrReferencesLocalDenoiser() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let removedService = packageRoot
            .appendingPathComponent("Sources/HySimulatranslate/Services/SpeechDenoiserService.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedService.path))

        let auditedFiles = [
            "Sources/HySimulatranslate/Services/AppResourceLocator.swift",
            "Sources/HySimulatranslate/Services/ResourceDownloadService.swift",
            "Sources/HySimulatranslate/ViewModels/TranscriptionViewModel.swift",
            "Sources/HySimulatranslate/Models/Types.swift",
            "script/download_dependencies.sh",
            "script/package_dmg.sh",
            "README.md"
        ]
        let forbiddenTokens = [
            "speechdenoiser",
            "gtcrn",
            "denoisedpcm",
            "models/denoise",
            "denoiser_model"
        ]

        for relativePath in auditedFiles {
            let contents = try String(
                contentsOf: packageRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            ).lowercased()
            for token in forbiddenTokens {
                XCTAssertFalse(
                    contents.contains(token),
                    "\(relativePath) still contains removed local denoiser token '\(token)'"
                )
            }
        }
    }

    func testLLMPromptUsesWhisperAsPrimaryAndSherpaAsReference() {
        let promptSource = LLMService.sourceTextForPrompt(
            rawText: "Whisper transcript.",
            whisperText: "WhisperKit recovered the technical phrase.",
            sherpaText: "Sherpa draft recovered the technical phrase."
        )

        XCTAssertTrue(promptSource.contains("WhisperKit primary transcript"))
        XCTAssertTrue(promptSource.contains("Sherpa draft reference"))
        XCTAssertTrue(promptSource.contains("WhisperKit recovered the technical phrase."))
        XCTAssertTrue(promptSource.contains("Sherpa draft recovered the technical phrase."))
    }

    @MainActor
    func testLLMFormatCandidatesBatchBeforeQueuedReview() async {
        let vm = TranscriptionViewModel()
        vm.apiReady = true
        let first = UUID()
        let second = UUID()
        let third = UUID()

        await vm.enqueueLLMFormatCandidateForTesting(
            uid: first,
            text: "Whisper first.",
            sherpaText: "Sherpa first."
        )
        await vm.enqueueLLMFormatCandidateForTesting(
            uid: second,
            text: "Whisper second.",
            sherpaText: "Sherpa second."
        )

        let initiallyQueued = await vm.queuedLLMItemsForTesting()
        XCTAssertEqual(initiallyQueued.count, 0)
        XCTAssertEqual(vm.llmQueueSize, 2)

        await vm.enqueueLLMFormatCandidateForTesting(
            uid: third,
            text: "Whisper third.",
            sherpaText: "Sherpa third."
        )

        let queued = await vm.queuedLLMItemsForTesting()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.sourceIDs, [first, second, third])
        XCTAssertTrue(queued.first?.whisperText.contains("1. Whisper first.") == true)
        XCTAssertTrue(queued.first?.sherpaText.contains("3. Sherpa third.") == true)
        XCTAssertEqual(vm.llmQueueSize, 1)
    }

    func testChatRateLimiterPolicyUsesConservativeBatchingNearLimit() {
        XCTAssertFalse(
            ChatRateLimiter.shouldUseConservativeBatching(
                currentRPM: 10,
                queueDepth: 1,
                recentlyRateLimited: false
            )
        )
        XCTAssertTrue(
            ChatRateLimiter.shouldUseConservativeBatching(
                currentRPM: ChatRateLimiter.targetRPM,
                queueDepth: 1,
                recentlyRateLimited: false
            )
        )
        XCTAssertEqual(ChatRateLimiter.targetBatchSize(conservative: false), 3)
        XCTAssertEqual(ChatRateLimiter.targetBatchSize(conservative: true), 5)
    }

    func testNoteDirectoryDefaultsToDesktopAndExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL

        XCTAssertEqual(
            TranscriptionViewModel.noteDirectory(from: "").standardizedFileURL.path,
            desktop.path
        )
        XCTAssertEqual(
            TranscriptionViewModel.noteDirectory(from: "~/HySimulatranslateNotes").standardizedFileURL.path,
            home.appendingPathComponent("HySimulatranslateNotes", isDirectory: true).standardizedFileURL.path
        )
    }
}
