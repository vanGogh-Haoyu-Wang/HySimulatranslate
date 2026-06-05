import SwiftUI

// MARK: - 添加新强化专项

struct AddSubjectView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var courseDB: CourseDatabase

    @State private var name = ""
    @State private var abbrev = ""
    @State private var keywords = ""
    @State private var meetingFocus = ""

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("添加新强化专项")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 4) {
                    Text("专项名称").font(.subheadline).foregroundColor(.secondary)
                    TextField("例如：Advanced Thermodynamics", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("缩写").font(.subheadline).foregroundColor(.secondary)
                    TextField("例如：Thermo-A", text: $abbrev)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("关键词（用逗号分隔）").font(.subheadline).foregroundColor(.secondary)
                    TextField("biomaterials, stress, strain...", text: $keywords)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("强化方向").font(.subheadline).foregroundColor(.secondary)
                    TextEditor(text: $meetingFocus)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .glassPanel(cornerRadius: 8, material: .thinMaterial)
                }

                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    Button("保存专项") {
                        let subject = CourseSubject(
                            name: name,
                            abbrev: abbrev,
                            keywords: keywords,
                            meetingFocus: meetingFocus.isEmpty
                                ? "Capture the key points about \(name). Preserve technical terms and reasoning."
                                : meetingFocus
                        )
                        courseDB.addSubject(subject)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || abbrev.isEmpty)
                }
            }
            .padding(30)
        }
        .frame(width: 450, height: 400)
    }
}
