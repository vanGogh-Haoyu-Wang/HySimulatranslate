import SwiftUI
import UniformTypeIdentifiers

enum AudioImportLanguageOption: String, CaseIterable, Identifiable {
    case english
    case chinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: "英语"
        case .chinese: "中文"
        }
    }

    var code: String {
        switch self {
        case .english: "en"
        case .chinese: "zh"
        }
    }
}

struct AudioImportFormState: Equatable {
    var selectedSubjectID: UUID?
    var sourceLanguage: AudioImportLanguageOption = .english
    var targetLanguage: AudioImportLanguageOption = .chinese
    var shouldTranslate = true
    var shouldDiarize = true

    func makeOptions() -> ImportOptions {
        ImportOptions(
            subjectID: selectedSubjectID,
            sourceLanguage: sourceLanguage.code,
            translate: shouldTranslate,
            targetLanguage: targetLanguage.code,
            whisperModel: WhisperKitService.defaultModel,
            diarize: shouldDiarize
        )
    }

    static func firstSupportedURL(in urls: [URL]) -> URL? {
        urls.first {
            AudioImportDecoder.supportedExtensions.contains($0.pathExtension.lowercased())
        }
    }

    static func canStart(selectedURL: URL?, isImporting: Bool) -> Bool {
        selectedURL != nil && !isImporting
    }
}

struct AudioImportWorkspaceView: View {
    let subjects: [CourseSubject]
    var progress: Double = 0
    var status: String = ""
    let onImport: (URL, ImportOptions) async -> Bool
    let onComplete: () -> Void
    @State private var form = AudioImportFormState()
    @State private var selectedURL: URL?
    @State private var presentsImporter = false
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var localError = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("音频转写")
                            .font(.title2.weight(.semibold))
                        Text("上传录音并生成带时间轴的转写、翻译与说话人结果")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    uploadCard

                    GroupBox("语言与专项") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("强化专项", selection: $form.selectedSubjectID) {
                                Text("默认").tag(UUID?.none)
                                ForEach(subjects) { Text($0.name).tag(Optional($0.id)) }
                            }
                            HStack(spacing: 12) {
                                Picker("原语言", selection: $form.sourceLanguage) {
                                    ForEach(AudioImportLanguageOption.allCases) { language in
                                        Text(language.title).tag(language)
                                    }
                                }
                                .onChange(of: form.sourceLanguage) { _, source in
                                    if form.targetLanguage == source {
                                        form.targetLanguage = source == .english ? .chinese : .english
                                    }
                                }
                                Picker("目标语言", selection: $form.targetLanguage) {
                                    ForEach(AudioImportLanguageOption.allCases) { language in
                                        Text(language.title).tag(language)
                                    }
                                }
                                    .disabled(!form.shouldTranslate)
                            }
                        }
                        .padding(.top, 6)
                    }

                    GroupBox("处理选项") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("生成翻译", isOn: $form.shouldTranslate)
                            Toggle("说话人分离", isOn: $form.shouldDiarize)
                            Text("转写模型：WhisperKit Large V3（本地）")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.vertical, 8)
            }
            .disabled(isImporting)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if isImporting {
                    ProgressView(value: progress)
                }
                let displayStatus = localError.isEmpty ? status : localError
                if !displayStatus.isEmpty {
                    Text(displayStatus)
                        .font(.caption)
                        .foregroundStyle(localError.isEmpty ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                HStack {
                    Button("清空") {
                        selectedURL = nil
                        localError = ""
                    }
                    .disabled(isImporting || selectedURL == nil)
                    Spacer()
                    if isImporting {
                        Button("取消任务", role: .cancel) { importTask?.cancel() }
                    }
                    Button(isImporting ? "处理中…" : "开始转写") { startImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !AudioImportFormState.canStart(selectedURL: selectedURL, isImporting: isImporting)
                            || (form.shouldTranslate && form.sourceLanguage == form.targetLanguage)
                        )
                }
            }
            .padding(.top, 12)
        }
        .fileImporter(isPresented: $presentsImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): accept(urls: [url])
            case .failure(let error): localError = "无法选择音频：\(error.localizedDescription)"
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls: urls)
        }
    }

    private var uploadCard: some View {
        Button { presentsImporter = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 28, weight: .medium))
                Text(selectedURL?.lastPathComponent ?? "拖放音频到这里")
                    .font(.headline)
                    .lineLimit(2)
                Text(selectedURL == nil ? "WAV · M4A · MP3 · AAC · CAF" : selectedURL?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(selectedURL == nil ? "选择文件…" : "重新选择…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
    }

    @discardableResult
    private func accept(urls: [URL]) -> Bool {
        guard let url = AudioImportFormState.firstSupportedURL(in: urls) else {
            localError = "不支持该文件，请选择 WAV、M4A、MP3、AAC 或 CAF 音频。"
            return false
        }
        selectedURL = url
        localError = ""
        return true
    }

    private func startImport() {
        guard let selectedURL, !isImporting else { return }
        isImporting = true
        localError = ""
        let options = form.makeOptions()
        importTask = Task {
            let succeeded = await onImport(selectedURL, options)
            guard !Task.isCancelled else {
                isImporting = false
                importTask = nil
                localError = "任务已取消"
                return
            }
            isImporting = false
            importTask = nil
            if succeeded {
                onComplete()
            }
        }
    }
}

struct MeetingRevisionSelector: View {
    let revisions: [TranscriptRevisionRecord]
    @Binding var selection: UUID?
    var body: some View {
        Picker("转写版本", selection: $selection) {
            Text("未选择").tag(UUID?.none)
            ForEach(revisions, id: \.id) { revision in
                Text("v\(revision.number) · \(revision.model) · \(revision.source.rawValue) · \(revision.status.rawValue) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .tag(Optional(revision.id))
            }
        }
    }
}

struct MeetingTranslationRevisionSelector: View {
    let revisions: [TranslationRevisionRecord]; @Binding var selection: UUID?
    var body: some View {
        Picker("翻译版本", selection: $selection) {
            Text("未选择").tag(UUID?.none)
            ForEach(revisions.filter { $0.status == .succeeded }, id: \.id) { revision in
                Text("\(revision.targetLanguage) · \(revision.model) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))").tag(Optional(revision.id))
            }
        }
    }
}
