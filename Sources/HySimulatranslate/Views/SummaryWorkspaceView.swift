import SwiftUI

struct SummaryWorkspaceView: View {
    @ObservedObject var workspace: SummaryWorkspaceController
    let liveSummary: String
    let liveStatus: String
    let isUpdating: Bool
    let modelName: String

    @State private var editor: TemplateEditor?
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("笔记总结区").font(.headline).foregroundStyle(.secondary)
                Text("NVIDIA · \(modelName)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isUpdating { ProgressView().scaleEffect(0.65).frame(width: 16, height: 16) }
            }

            HStack {
                Picker("模板", selection: Binding(
                    get: { workspace.selectedTemplateID },
                    set: { workspace.selectTemplate($0) }
                )) {
                    ForEach(workspace.templates, id: \.id) { template in
                        Text(template.name + (template.isBuiltIn ? " · 内置" : "")).tag(Optional(template.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 210)

                Button("新建") { editor = .new }
                Button("复制") { perform { _ = try workspace.copySelectedTemplate() } }
                Button("编辑") {
                    if let template = workspace.selectedTemplate, !template.isBuiltIn { editor = .edit(template) }
                }
                .disabled(workspace.selectedTemplate?.isBuiltIn != false)
                Button("删除", role: .destructive) { perform { try workspace.deleteSelectedTemplate() } }
                    .disabled(workspace.selectedTemplate?.isBuiltIn != false)
            }

            if !workspace.selectableSummaryRevisions.isEmpty {
                Picker("摘要版本", selection: Binding(
                    get: { workspace.selectedSummaryRevisionID },
                    set: { id in if let id { perform { try workspace.selectSummaryRevision(id) } } }
                )) {
                    ForEach(workspace.selectableSummaryRevisions, id: \.id) { revision in
                        Text("\(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(revision.model) · 成功")
                            .tag(Optional(revision.id))
                    }
                }
                .labelsHidden()
            }
            if !workspace.failedSummaryRevisions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("失败历史（不可选择）").font(.caption2).foregroundStyle(.secondary)
                    ForEach(workspace.failedSummaryRevisions, id: \.id) { revision in
                        Text("\(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(revision.model) · \(revision.errorMessage ?? "生成失败")")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            HStack(spacing: 5) {
                Circle().frame(width: 6, height: 6).foregroundStyle(isUpdating ? .orange : .green)
                Text(errorMessage.isEmpty ? liveStatus : errorMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            ScrollView {
                let text = workspace.displayedSummary.isEmpty ? liveSummary : workspace.displayedSummary
                Text(text.isEmpty ? liveStatus : text)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
        .sheet(item: $editor) { value in
            SummaryTemplateEditor(editor: value) { name, language, instruction, sections in
                perform {
                    switch value {
                    case .new:
                        _ = try workspace.createTemplate(name: name, language: language, systemInstruction: instruction, sections: sections)
                    case .edit:
                        try workspace.updateSelectedTemplate(name: name, language: language, systemInstruction: instruction, sections: sections)
                    }
                }
                editor = nil
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); errorMessage = "" } catch { errorMessage = error.localizedDescription }
    }
}

private enum TemplateEditor: Identifiable {
    case new
    case edit(SummaryTemplateRecord)
    var id: String { switch self { case .new: "new"; case .edit(let value): value.id.uuidString } }
}

private struct SummaryTemplateEditor: View {
    let editor: TemplateEditor
    let onSave: (String, String, String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var language: String
    @State private var instruction: String
    @State private var sections: String

    init(editor: TemplateEditor, onSave: @escaping (String, String, String, [String]) -> Void) {
        self.editor = editor; self.onSave = onSave
        let template: SummaryTemplateRecord? = { if case .edit(let value) = editor { return value }; return nil }()
        _name = State(initialValue: template?.name ?? "自定义摘要")
        _language = State(initialValue: template?.language ?? "zh-CN")
        _instruction = State(initialValue: template?.systemInstruction ?? "只根据给定内容生成严谨摘要。")
        let values = template.flatMap { try? JSONSerialization.jsonObject(with: Data($0.structureJSON.utf8)) as? [String] } ?? ["总结", "重点", "行动项"]
        _sections = State(initialValue: values.joined(separator: "、"))
    }

    var body: some View {
        Form {
            TextField("名称", text: $name)
            TextField("输出语言", text: $language)
            TextField("系统指令", text: $instruction, axis: .vertical)
            TextField("章节（用逗号或顿号分隔）", text: $sections)
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存") {
                    onSave(name, language, instruction, sections.components(separatedBy: CharacterSet(charactersIn: ",，、")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding().frame(width: 480)
    }
}
