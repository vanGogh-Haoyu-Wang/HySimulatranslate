import SwiftUI

@MainActor protocol MeetingSidebarViewModel: ObservableObject {
    var isRecording: Bool { get }; var isFinalizingSession: Bool { get }; var isImportingAudio: Bool { get }
    var importProgress: Double { get }; var meetingLibraryStatus: String { get }; var isMeetingLibraryReady: Bool { get }
    var pendingImportJobs: [ImportJobRecord] { get }; var resumedImportProgress: [UUID: Double] { get }
    var meetings: [MeetingRecord] { get }; var unindexedNoteRecords: [NoteRecord] { get }
    var selectedMeeting: MeetingRecord? { get }; var selectedNoteRecord: NoteRecord? { get }
    func refreshNoteRecords(); func refreshMeetingLibrary(); func startResumeImport(_ job: ImportJobRecord); func cancelImport(jobID: UUID); func deleteMeeting(_ meeting: MeetingRecord)
}

extension TranscriptionViewModel: MeetingSidebarViewModel {}

/// Owns the meeting/note navigation surface while the parent workspace retains
/// navigation state (course selection, settings, and preview presentation).
struct MeetingSidebarView<VM: MeetingSidebarViewModel>: View {
    @ObservedObject var vm: VM
    let onNewRecord: () -> Void
    let onSelectCourses: () -> Void
    let onImportAudio: () -> Void
    let onSelectMeeting: (MeetingRecord) -> Void
    let onSelectNote: (NoteRecord) -> Void
    let onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                actionButton(title: "新记录", systemImage: "square.and.pencil", isDisabled: vm.isRecording || vm.isFinalizingSession, action: onNewRecord)
                actionButton(title: "强化专项", systemImage: "book.closed", action: onSelectCourses)
            }

            HStack {
                Text("记录").font(.caption.weight(.semibold)).foregroundStyle(.secondary.opacity(0.72))
                Spacer()
                Button(action: onImportAudio) { Label("导入音频", systemImage: "square.and.arrow.down") }
                    .font(.caption.weight(.medium)).buttonStyle(.plain)
                    .disabled(vm.isRecording || vm.isFinalizingSession || vm.isImportingAudio)
                Button("刷新") {
                    vm.refreshNoteRecords()
                    vm.refreshMeetingLibrary()
                }
                .font(.caption.weight(.medium)).buttonStyle(.plain).foregroundStyle(.secondary)
                .help("刷新当前笔记文件夹的笔记文件")
            }
            .padding(.horizontal, 4).padding(.top, 4)

            if !vm.meetingLibraryStatus.isEmpty {
                Text(vm.meetingLibraryStatus)
                    .font(.caption2)
                    .foregroundStyle(vm.isMeetingLibraryReady ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
            if vm.isImportingAudio { ProgressView(value: vm.importProgress).padding(.horizontal, 4) }
            ForEach(vm.pendingImportJobs, id: \.id) { job in
                VStack(alignment: .leading) {
                    ProgressView(value: vm.resumedImportProgress[job.id] ?? job.progress)
                    HStack {
                        Button("继续导入：\(URL(fileURLWithPath: job.sourcePath).lastPathComponent)") { vm.startResumeImport(job) }
                        Button("取消") { vm.cancelImport(jobID: job.id) }
                    }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(vm.meetings, id: \.id) { meeting in meetingRow(meeting) }
                    if !vm.meetings.isEmpty && !vm.unindexedNoteRecords.isEmpty { Divider().padding(.vertical, 4) }
                    if vm.meetings.isEmpty && vm.unindexedNoteRecords.isEmpty {
                        Text("暂无笔记").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                    }
                    ForEach(vm.unindexedNoteRecords) { record in noteRow(record) }
                }
            }
            .scrollIndicators(.hidden).frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer(minLength: 0)
            Button(action: onOpenSettings) {
                HStack(spacing: 9) { Image(systemName: "gearshape"); Text("设置"); Spacer() }
                    .font(.system(size: 13, weight: .medium)).padding(.vertical, 8).padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.top, 8).padding(.bottom, 6)
    }

    private var rowBackground: Color { colorScheme == .dark ? .white.opacity(0.07) : .black.opacity(0.055) }
    private var selectedRowBackground: Color { Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.20) }

    private func meetingRow(_ meeting: MeetingRecord) -> some View {
        Button { onSelectMeeting(meeting) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: meeting.source == .legacyImported ? "doc.text" : "waveform")
                    Text(meeting.title).lineLimit(1)
                    Spacer()
                    if meeting.status == .draft { Image(systemName: "record.circle").foregroundStyle(.red) }
                }.font(.callout.weight(.medium))
                Text("\(formatDate(meeting.createdAt)) · \(PlaybackTimeFormatter.string(meeting.duration))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(vm.selectedMeeting?.id == meeting.id ? selectedRowBackground : rowBackground))
        }
        .buttonStyle(.plain).disabled(vm.isRecording || vm.isFinalizingSession)
        .contextMenu { Button(role: .destructive) { vm.deleteMeeting(meeting) } label: { Label("移到最近删除", systemImage: "trash") } }
    }

    private func noteRow(_ record: NoteRecord) -> some View {
        Button { onSelectNote(record) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(record.fileName).font(.callout.weight(.medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("\(formatDate(record.modifiedAt)) · \(formatFileSize(record.fileSize))").font(.caption2).foregroundStyle(.secondary)
                if let preview = record.previewSummary {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(vm.selectedNoteRecord?.id == record.id ? selectedRowBackground : rowBackground))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func actionButton(title: String, systemImage: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) { Image(systemName: systemImage); Text(title); Spacer() }
                .font(.system(size: 13, weight: .medium)).padding(.vertical, 8).padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(isDisabled).foregroundStyle(isDisabled ? .secondary : .primary)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    private func formatFileSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct MeetingPlaybackView: View {
    @ObservedObject var playback: MeetingPlaybackController
    let isDisabled: Bool

    var body: some View {
        HStack {
            Button(playback.isPlaying ? "暂停" : "播放") { playback.isPlaying ? playback.pause() : playback.play() }
            Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }), in: 0...max(0.1, playback.duration))
            Text("\(PlaybackTimeFormatter.string(playback.currentTime)) / \(PlaybackTimeFormatter.string(playback.duration))")
                .font(.caption.monospacedDigit())
        }.disabled(isDisabled)
    }
}

@MainActor protocol TranscriptTimelineViewModel: ObservableObject {
    var selectedMeetingRevisions: [TranscriptRevisionRecord] { get }; var selectedMeetingRevisionID: UUID? { get set }
    var selectedTranslationRevisions: [TranslationRevisionRecord] { get }; var selectedTranslationRevisionID: UUID? { get set }
    var isImportingAudio: Bool { get }; var isRecording: Bool { get }; var isFinalizingSession: Bool { get }
    var selectedMeetingAudioURL: URL? { get }; var meetingPlayback: MeetingPlaybackController { get }
    var selectedMeetingSegments: [TranscriptSegmentRecord] { get }; var selectedMeetingTranslations: [UUID: String] { get }
    var selectedMeetingSpeakerAliases: [String: String] { get }
    var retranslationStatus: String { get }; var retranslationError: String? { get }
    func selectMeetingRevision(_ revisionID: UUID?); func selectTranslationRevision(_ revisionID: UUID?)
    func retranscribeSelectedMeeting(options: ImportOptions) async; func retranslateSelectedMeeting() async
    func selectedMeetingSpeakerName(_ speakerID: String) -> String; func setSelectedMeetingSpeakerAlias(speakerID: String, displayName: String)
    func retryRetranslation()
}
extension TranscriptionViewModel: TranscriptTimelineViewModel {}

struct TranscriptTimelineView<VM: TranscriptTimelineViewModel>: View {
    @ObservedObject var vm: VM
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(meeting.title).font(.headline)
            if !vm.selectedMeetingRevisions.isEmpty {
                MeetingRevisionSelector(revisions: vm.selectedMeetingRevisions, selection: Binding(
                    get: { vm.selectedMeetingRevisionID },
                    set: { vm.selectedMeetingRevisionID = $0; vm.selectMeetingRevision($0) }
                ))
            }
            if !vm.selectedTranslationRevisions.isEmpty {
                MeetingTranslationRevisionSelector(revisions: vm.selectedTranslationRevisions, selection: Binding(
                    get: { vm.selectedTranslationRevisionID },
                    set: { vm.selectedTranslationRevisionID = $0; vm.selectTranslationRevision($0) }
                ))
            }
            HStack {
                Button("重新转写") {
                    Task { await vm.retranscribeSelectedMeeting(options: .init(subjectID: meeting.subjectID, sourceLanguage: "en", translate: false, targetLanguage: "zh", whisperModel: WhisperKitService.defaultModel, diarize: false)) }
                }
                Button("重新翻译") { Task { await vm.retranslateSelectedMeeting() } }
            }.disabled(vm.isImportingAudio || vm.isRecording || vm.isFinalizingSession)
            if !vm.retranslationStatus.isEmpty {
                HStack {
                    Text(vm.retranslationError.map { "\(vm.retranslationStatus)：\($0)" } ?? vm.retranslationStatus)
                        .font(.caption)
                        .foregroundStyle(vm.retranslationError == nil ? Color.secondary : Color.red)
                    if vm.retranslationError != nil { Button("重试") { vm.retryRetranslation() }.font(.caption) }
                }
            }

            speakerEditors
            if vm.selectedMeetingAudioURL != nil {
                MeetingPlaybackView(playback: vm.meetingPlayback, isDisabled: vm.isRecording || vm.isFinalizingSession)
            }
            ForEach(vm.selectedMeetingSegments, id: \.id) { segment in
                Button { vm.meetingPlayback.seek(to: segment.startTime) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(PlaybackTimeFormatter.string(segment.startTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(segment.speakerID.map { "\(vm.selectedMeetingSpeakerName($0)): \(segment.refinedText)" } ?? segment.refinedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let translation = vm.selectedMeetingTranslations[segment.id] {
                            Text(translation).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(vm.meetingPlayback.highlightedSegmentID == segment.id ? Color.accentColor.opacity(0.18) : Color.clear))
                }
                .buttonStyle(.plain).disabled(vm.selectedMeetingAudioURL == nil)
            }
        }
    }

    @ViewBuilder private var speakerEditors: some View {
        let speakerIDs = Array(Set(vm.selectedMeetingSegments.compactMap(\.speakerID))).sorted()
        if !speakerIDs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("说话人").font(.caption).foregroundStyle(.secondary)
                ForEach(speakerIDs, id: \.self) { speakerID in
                    HStack {
                        Text(SpeakerDisplayName.displayName(for: speakerID)).frame(width: 90, alignment: .leading)
                        TextField("显示姓名", text: Binding(
                            get: { vm.selectedMeetingSpeakerAliases[speakerID] ?? "" },
                            set: { vm.setSelectedMeetingSpeakerAlias(speakerID: speakerID, displayName: $0) }
                        ))
                    }
                }
            }
        }
    }
}

/// Stable workspace entry point for both picker and drag-and-drop imports.
struct ImportWorkspaceView: View {
    let subjects: [CourseSubject]
    let progress: Double
    let onImport: (URL, ImportOptions) async -> Void

    var body: some View { AudioImportView(subjects: subjects, progress: progress, onImport: onImport) }
}

private enum PlaybackTimeFormatter {
    static func string(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
