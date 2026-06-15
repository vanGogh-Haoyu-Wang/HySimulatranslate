import SwiftUI

// MARK: - 学术专属启动弹窗（对应 Python APIKeyStartupDialog）

struct StartupView: View {
    @ObservedObject var courseDB: CourseDatabase
    @Binding var providerAPIKeys: [LLMProviderID: String]
    @Binding var selectedCourseIndex: Int
    var onLaunch: () -> Void

    @State private var showingAddSubject = false
    @State private var coursePendingDeletion: CourseSubject?
    @State private var isConfirmingCourseDeletion = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                headerView

                VStack(spacing: 16) {
                    apiSection
                    Divider()
                    courseSection
                }
                .padding(18)
                .glassPanel(cornerRadius: 18, material: .regularMaterial)
                .frame(width: 410)

                Button(action: {
                    KeychainManager.shared.saveProviderKeys(providerAPIKeys)
                    onLaunch()
                }) {
                    Label("启动引擎", systemImage: "play.fill")
                        .font(.headline)
                        .frame(width: 230, height: 38)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canLaunch)
            }
            .padding(32)
        }
        .frame(minWidth: 520, minHeight: 620)
        .sheet(isPresented: $showingAddSubject) {
            AddSubjectView(courseDB: courseDB)
        }
        .confirmationDialog(
            "删除强化专项？",
            isPresented: $isConfirmingCourseDeletion,
            titleVisibility: .visible
        ) {
            if let course = coursePendingDeletion {
                Button("删除 \(course.name)", role: .destructive) {
                    deleteCourse(course)
                    coursePendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) {
                coursePendingDeletion = nil
            }
        } message: {
            Text("此操作会从强化专项列表移除该项。默认专项可用 Restore 恢复。")
        }
    }

    private var headerView: some View {
        VStack(spacing: 7) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("HySimulatranslate")
                .font(.system(size: 28, weight: .bold))
            Text("Powered by Haoyu Wang")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("API Key", systemImage: "key.fill")
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: 8) {
                if let groq = LLMProviderCatalog.groqCoreProvider {
                    providerRow(groq, title: "Groq 核心")
                }
                if let nvidia = LLMProviderCatalog.nvidiaSummaryProvider {
                    providerRow(nvidia, title: "NVIDIA 总结")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerRow(_ provider: LLMProvider, title: String) -> some View {
        let key = providerAPIKeys[provider.id, default: ""]
        let hasKey = provider.acceptsKey(key)
        let hasInvalidKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasKey

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: hasKey ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(hasKey ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Link("获取", destination: provider.getAPIKeyURL)
                            .font(.caption.weight(.semibold))
                    }
                    Text("模型可在同传页设置中调整")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            SecureField(provider.keyPlaceholder, text: apiKeyBinding(for: provider.id))
                .textFieldStyle(.roundedBorder)

            if hasInvalidKey {
                Label("Key 应以 '\(provider.requiredKeyPrefix ?? "")' 开头", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func apiKeyBinding(for providerID: LLMProviderID) -> Binding<String> {
        Binding(
            get: { providerAPIKeys[providerID, default: ""] },
            set: { providerAPIKeys[providerID] = $0 }
        )
    }

    private var courseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("强化专项", systemImage: "book.closed.fill")
                    .font(.headline)
                Spacer()
                Button(action: { showingAddSubject = true }) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                if courseDB.hasHiddenDefaultSubjects {
                    Button(action: restoreDefaultCourses) {
                        Label("Restore", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    if courseDB.allSubjects.isEmpty {
                        Text("暂无强化专项。请添加专项或恢复默认项。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                            .padding(.horizontal, 10)
                    }

                    ForEach(Array(courseDB.allSubjects.enumerated()), id: \.element.id) { index, course in
                        courseRow(index: index, course: course)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func courseRow(index: Int, course: CourseSubject) -> some View {
        Button(action: { selectedCourseIndex = index }) {
            HStack(spacing: 8) {
                Text("\(index + 1). \(course.name)")
                    .fontWeight(selectedCourseIndex == index ? .semibold : .regular)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selectedCourseIndex == index {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedCourseIndex == index ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if courseDB.canRemoveSubject(course) {
                Button(role: .destructive) {
                    confirmCourseDeletion(course)
                } label: {
                    Label("删除强化专项", systemImage: "trash")
                }
            }
        }
    }

    private var canLaunch: Bool {
        !courseDB.allSubjects.isEmpty
    }

    private func confirmCourseDeletion(_ course: CourseSubject) {
        coursePendingDeletion = course
        isConfirmingCourseDeletion = true
    }

    private func restoreDefaultCourses() {
        courseDB.restoreDefaultSubjects()
        selectedCourseIndex = min(selectedCourseIndex, max(0, courseDB.allSubjects.count - 1))
    }

    private func deleteCourse(_ course: CourseSubject) {
        let subjects = courseDB.allSubjects
        guard let deletedIndex = subjects.firstIndex(where: { $0.id == course.id }) else { return }
        courseDB.removeSubject(course)

        let remainingCount = courseDB.allSubjects.count
        if selectedCourseIndex > deletedIndex {
            selectedCourseIndex -= 1
        }
        selectedCourseIndex = min(selectedCourseIndex, max(0, remainingCount - 1))
    }
}
