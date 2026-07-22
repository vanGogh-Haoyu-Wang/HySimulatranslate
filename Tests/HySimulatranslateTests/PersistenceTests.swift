import XCTest
@testable import HySimulatranslate

final class PersistenceTests: XCTestCase {
    func testInMemoryDatabaseMigratesAndSeedsReadOnlyBuiltInTemplates() throws {
        let database = try AppDatabase.inMemory()
        let repository = SummaryTemplateRepository(database: database)

        let templates = try repository.fetchAll()

        XCTAssertEqual(Set(templates.map(\.name)), ["Standard Meeting", "Class Notes", "Interview", "Action Items"])
        XCTAssertTrue(templates.allSatisfy(\.isBuiltIn))
        XCTAssertThrowsError(try repository.update(templates[0]))
    }

    func testDefaultDatabaseURLUsesApplicationSupportDatabaseDirectory() throws {
        let support = URL(fileURLWithPath: "/tmp/HySimulatranslate-Support", isDirectory: true)

        let url = AppDatabase.defaultDatabaseURL(applicationSupportDirectory: support)

        XCTAssertEqual(url, support.appendingPathComponent("HySimulatranslate/Database/hysimulatranslate.sqlite"))
    }

    func testLegacyIndexingIsIdempotentAndDoesNotInventSegments() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = directory.appendingPathComponent("Lecture.md")
        try "# Lecture\nA useful preview".write(to: markdown, atomically: true, encoding: .utf8)
        try "plain notes".write(to: directory.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
        try "ignored".write(to: directory.appendingPathComponent("Other.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try meetings.indexLegacyNotes(in: directory), 2)
        XCTAssertEqual(try meetings.indexLegacyNotes(in: directory), 0)
        let records = try meetings.fetchActive()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.source == .legacyImported && $0.legacyNotePath != nil })
        XCTAssertTrue(try transcripts.fetchRevisions(meetingID: records[0].id).isEmpty)
    }

    func testExportedNotePathIsAttachedAndExcludedFromLegacyIndexing() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("Meeting.md")
        try "# Meeting".write(to: note, atomically: true, encoding: .utf8)

        try meetings.attachExportedNote(path: note.path, to: meeting.id)

        XCTAssertEqual(try meetings.fetch(id: meeting.id)?.exportedNotePath, note.standardizedFileURL.path)
        XCTAssertEqual(try meetings.indexLegacyNotes(in: directory), 0)
        XCTAssertEqual(try meetings.fetchActive().map(\.id), [meeting.id])
    }

    func testReconcileLegacyExportsMergesOnlyUniqueMinuteMatchWithoutDeletingFile() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uniqueNote = directory.appendingPathComponent("Default_Session_2026-07-16_11-09.md")
        let ambiguousNote = directory.appendingPathComponent("Default_Session_2026-07-16_12-00.md")
        try "unique".write(to: uniqueNote, atomically: true, encoding: .utf8)
        try "ambiguous".write(to: ambiguousNote, atomically: true, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm:ss"
        let uniqueLive = MeetingRecord(title: "Default", source: .live, createdAt: formatter.date(from: "2026-07-16_11-09:30")!, updatedAt: Date())
        let firstAmbiguous = MeetingRecord(title: "A", source: .live, createdAt: formatter.date(from: "2026-07-16_12-00:10")!, updatedAt: Date())
        let secondAmbiguous = MeetingRecord(title: "B", source: .live, createdAt: formatter.date(from: "2026-07-16_12-00:40")!, updatedAt: Date())
        let uniqueLegacy = MeetingRecord(title: uniqueNote.deletingPathExtension().lastPathComponent, source: .legacyImported, legacyNotePath: uniqueNote.path)
        let ambiguousLegacy = MeetingRecord(title: ambiguousNote.deletingPathExtension().lastPathComponent, source: .legacyImported, legacyNotePath: ambiguousNote.path)
        try database.writer.write { db in
            try uniqueLive.insert(db); try firstAmbiguous.insert(db); try secondAmbiguous.insert(db)
            try uniqueLegacy.insert(db); try ambiguousLegacy.insert(db)
        }

        XCTAssertEqual(try meetings.reconcileLegacyExports(), 1)
        XCTAssertEqual(try meetings.fetch(id: uniqueLive.id)?.exportedNotePath, uniqueNote.standardizedFileURL.path)
        XCTAssertNil(try meetings.fetch(id: uniqueLegacy.id))
        XCTAssertNotNil(try meetings.fetch(id: ambiguousLegacy.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: uniqueNote.path))
        _ = firstAmbiguous; _ = secondAmbiguous
    }

    func testOnlySuccessfulTranscriptRevisionCanBecomeCurrent() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let meeting = try meetings.create(title: "Revision Test", source: .live)
        let failed = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "model", language: "en", status: .failed)
        XCTAssertThrowsError(try transcripts.setCurrentTranscriptRevision(failed.id, for: meeting.id))
        XCTAssertNil(try meetings.fetch(id: meeting.id)?.currentTranscriptRevisionID)

        let successful = try transcripts.createRevision(meetingID: meeting.id, number: 2, source: .live, model: "model", language: "en", status: .succeeded)
        try transcripts.setCurrentTranscriptRevision(successful.id, for: meeting.id)
        XCTAssertEqual(try meetings.fetch(id: meeting.id)?.currentTranscriptRevisionID, successful.id)
    }

    func testSoftDeleteAndPurgeUseThirtyDayCutoff() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let old = try meetings.create(title: "Old", source: .live)
        let recent = try meetings.create(title: "Recent", source: .live)
        let now = Date(timeIntervalSince1970: 4_000_000)
        try meetings.softDelete(id: old.id, at: now.addingTimeInterval(-31 * 86_400))
        try meetings.softDelete(id: recent.id, at: now.addingTimeInterval(-29 * 86_400))

        let purged = try meetings.purgeDeleted(olderThan: now.addingTimeInterval(-30 * 86_400))

        XCTAssertEqual(purged, [old.id])
        XCTAssertNil(try meetings.fetch(id: old.id))
        XCTAssertNotNil(try meetings.fetch(id: recent.id))
        XCTAssertEqual(try meetings.fetchDeleted().map(\.id), [recent.id])
    }

    func testSegmentsTranslationsAliasesSummariesAndAudioAssetsRoundTrip() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let speakers = SpeakerRepository(database: database)
        let meeting = try meetings.create(title: "Round Trip", source: .imported)
        let revision = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .imported, model: "whisper", language: "en", status: .succeeded)
        let segment = TranscriptSegmentRecord(revisionID: revision.id, sequence: 0, startTime: 1.25, endTime: 2.5, draftText: "draft", refinedText: "hello", speakerID: "speaker_0", confidence: 0.9, status: .succeeded)
        try transcripts.insert(segment)
        XCTAssertEqual(try transcripts.fetchSegments(revisionID: revision.id), [segment])

        let translation = try transcripts.createTranslationRevision(meetingID: meeting.id, transcriptRevisionID: revision.id, targetLanguage: "zh", provider: "provider", model: "model", status: .succeeded)
        try transcripts.insert(SegmentTranslationRecord(translationRevisionID: translation.id, segmentID: segment.id, text: "你好"))
        try transcripts.setCurrentTranslationRevision(translation.id, for: meeting.id)
        XCTAssertEqual(try transcripts.fetchTranslations(revisionID: translation.id).first?.text, "你好")

        try speakers.setAlias(meetingID: meeting.id, speakerID: "speaker_0", displayName: "Alice")
        XCTAssertEqual(try speakers.aliases(meetingID: meeting.id)["speaker_0"], "Alice")

        let audio = AudioAssetRecord(meetingID: meeting.id, track: .mixed, path: "/tmp/mixed.wav", format: "wav", sampleRate: 16_000, channelCount: 1, duration: 20, status: .ready)
        try meetings.saveAudioAsset(audio)
        XCTAssertEqual(try meetings.fetchAudioAssets(meetingID: meeting.id), [audio])

        let template = try SummaryTemplateRepository(database: database).fetchAll().first!
        let summary = SummaryRevisionRecord(meetingID: meeting.id, transcriptRevisionID: revision.id, translationRevisionID: translation.id, templateID: template.id, provider: "provider", model: "model", body: "summary", status: .succeeded)
        try transcripts.insert(summary)
        try transcripts.setCurrentSummaryRevision(summary.id, for: meeting.id)
        let storedSummaries = try transcripts.fetchSummaryRevisions(meetingID: meeting.id)
        XCTAssertEqual(storedSummaries.map(\.id), [summary.id])
        XCTAssertEqual(storedSummaries.first?.body, "summary")
    }

    func testTranslationRevisionRejectsTranscriptOwnedByAnotherMeeting() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let first = try meetings.create(title: "First", source: .live)
        let second = try meetings.create(title: "Second", source: .live)
        let revision = try transcripts.createRevision(meetingID: first.id, number: 1, source: .live, model: "m", language: "en", status: .succeeded)

        XCTAssertThrowsError(try transcripts.createTranslationRevision(meetingID: second.id, transcriptRevisionID: revision.id, targetLanguage: "zh", provider: "p", model: "m", status: .succeeded))
    }

    func testSegmentTranslationRejectsSegmentOutsideSourceTranscript() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let source = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "m", language: "en", status: .succeeded)
        let other = try transcripts.createRevision(meetingID: meeting.id, number: 2, source: .live, model: "m", language: "en", status: .succeeded)
        let segment = TranscriptSegmentRecord(revisionID: other.id, sequence: 0, startTime: 0, endTime: 1, draftText: nil, refinedText: "other", speakerID: nil, confidence: nil, status: .succeeded)
        try transcripts.insert(segment)
        let translation = try transcripts.createTranslationRevision(meetingID: meeting.id, transcriptRevisionID: source.id, targetLanguage: "zh", provider: "p", model: "m", status: .succeeded)

        XCTAssertThrowsError(try transcripts.insert(SegmentTranslationRecord(translationRevisionID: translation.id, segmentID: segment.id, text: "错误")))
    }

    func testSummaryRejectsMismatchedMeetingTranscriptAndTranslationRelationships() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let first = try meetings.create(title: "First", source: .live)
        let second = try meetings.create(title: "Second", source: .live)
        let firstTranscript = try transcripts.createRevision(meetingID: first.id, number: 1, source: .live, model: "m", language: "en", status: .succeeded)
        let secondTranscript = try transcripts.createRevision(meetingID: second.id, number: 1, source: .live, model: "m", language: "en", status: .succeeded)
        let secondTranslation = try transcripts.createTranslationRevision(meetingID: second.id, transcriptRevisionID: secondTranscript.id, targetLanguage: "zh", provider: "p", model: "m", status: .succeeded)
        let template = try SummaryTemplateRepository(database: database).fetchAll()[0]

        XCTAssertThrowsError(try transcripts.insert(SummaryRevisionRecord(meetingID: first.id, transcriptRevisionID: secondTranscript.id, translationRevisionID: nil, templateID: template.id, provider: "p", model: "m", body: "bad", status: .succeeded)))
        XCTAssertThrowsError(try transcripts.insert(SummaryRevisionRecord(meetingID: first.id, transcriptRevisionID: firstTranscript.id, translationRevisionID: secondTranslation.id, templateID: template.id, provider: "p", model: "m", body: "bad", status: .succeeded)))
    }

    func testNonSuccessfulTranslationAndSummaryCannotBecomeCurrent() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let source = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "m", language: "en", status: .succeeded)
        let failedTranslation = try transcripts.createTranslationRevision(meetingID: meeting.id, transcriptRevisionID: source.id, targetLanguage: "zh", provider: "p", model: "m", status: .failed)
        let template = try SummaryTemplateRepository(database: database).fetchAll()[0]
        let failedSummary = SummaryRevisionRecord(meetingID: meeting.id, transcriptRevisionID: source.id, translationRevisionID: nil, templateID: template.id, provider: "p", model: "m", body: "bad", status: .failed)
        try transcripts.insert(failedSummary)

        XCTAssertThrowsError(try transcripts.setCurrentTranslationRevision(failedTranslation.id, for: meeting.id))
        XCTAssertThrowsError(try transcripts.setCurrentSummaryRevision(failedSummary.id, for: meeting.id))
        XCTAssertNil(try meetings.fetch(id: meeting.id)?.currentTranslationRevisionID)
        XCTAssertNil(try meetings.fetch(id: meeting.id)?.currentSummaryRevisionID)
    }

    func testLegacyIndexIgnoresDirectoriesAndIsIdempotentAcrossConcurrentCalls() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Fake.md"), withIntermediateDirectories: true)
        try "notes".write(to: directory.appendingPathComponent("Real.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do { _ = try meetings.indexLegacyNotes(in: directory) }
            catch { lock.lock(); errors.append(error); lock.unlock() }
        }

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try meetings.fetchActive().map(\.title), ["Real"])
        XCTAssertEqual(try meetings.indexLegacyNotes(in: directory), 0)
    }

    func testUniqueAndCascadeConstraintsProtectRevisionGraph() throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let meeting = try meetings.create(title: "Meeting", source: .live)
        let revision = try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "m", language: "en", status: .succeeded)
        XCTAssertThrowsError(try transcripts.createRevision(meetingID: meeting.id, number: 1, source: .live, model: "m", language: "en", status: .succeeded))
        try meetings.purge(id: meeting.id)
        XCTAssertTrue(try transcripts.fetchRevisions(meetingID: meeting.id).isEmpty)
        XCTAssertNil(try meetings.fetch(id: meeting.id))
        _ = revision
    }
}
