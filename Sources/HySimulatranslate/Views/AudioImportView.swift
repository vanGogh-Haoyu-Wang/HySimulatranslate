import SwiftUI
import UniformTypeIdentifiers

struct AudioImportView: View {
    let subjects: [CourseSubject]
    var progress: Double = 0
    let onImport: (URL, ImportOptions) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSubjectID: UUID?
    @State private var sourceLanguage = "en"
    @State private var targetLanguage = "zh"
    @State private var shouldTranslate = true
    @State private var shouldDiarize = true
    @State private var model = WhisperKitService.defaultModel
    @State private var selectedURL: URL?
    @State private var presentsImporter = false
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        Form {
            HStack {
                Text(selectedURL?.lastPathComponent ?? "尚未选择音频")
                Spacer()
                Button("选择音频…") { presentsImporter = true }
            }
            if isImporting { ProgressView(value: progress) }
            Picker("强化专项", selection: $selectedSubjectID) {
                Text("默认").tag(UUID?.none)
                ForEach(subjects) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("源语言", text: $sourceLanguage)
            Toggle("生成翻译", isOn: $shouldTranslate)
            if shouldTranslate { TextField("目标语言", text: $targetLanguage) }
            TextField("WhisperKit 模型", text: $model)
            Toggle("说话人分离", isOn: $shouldDiarize)
            HStack {
                Spacer()
                Button(isImporting ? "取消任务" : "取消") {
                    if isImporting { importTask?.cancel() } else { dismiss() }
                }
                Button(isImporting ? "处理中…" : "开始导入") {
                    guard let selectedURL else { return }
                    isImporting = true
                    let options = ImportOptions(subjectID: selectedSubjectID, sourceLanguage: sourceLanguage, translate: shouldTranslate, targetLanguage: targetLanguage, whisperModel: model, diarize: shouldDiarize)
                    importTask = Task { await onImport(selectedURL, options); isImporting = false; importTask = nil; dismiss() }
                }.disabled(selectedURL == nil || isImporting)
            }
        }
        .padding().frame(minWidth: 480)
        .fileImporter(isPresented: $presentsImporter, allowedContentTypes: [.audio]) { result in selectedURL = try? result.get() }
        .dropDestination(for: URL.self) { urls, _ in
            selectedURL = urls.first(where: { AudioImportDecoder.supportedExtensions.contains($0.pathExtension.lowercased()) })
            return selectedURL != nil
        }
        .onDisappear { importTask?.cancel() }
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
