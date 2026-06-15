import SwiftUI

// MARK: - Codex 式三栏工作台

struct TranscriptionView: View {
    @ObservedObject var vm: TranscriptionViewModel
    @ObservedObject var courseDB: CourseDatabase
    @Binding var providerAPIKeys: [LLMProviderID: String]
    @Binding var selectedCourseIndex: Int

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    @State private var workspaceMode: WorkspaceMode = .transcription
    @State private var showingAddSubject = false
    @State private var isConfirmingCourseDeletion = false
    @State private var coursePendingDeletion: CourseSubject?
    @State private var isLeftSidebarCollapsed = false
    @State private var isSummaryPaneCollapsed = false
    @State private var activeNotePreview: NoteRecord?

    private let layoutSpacing: CGFloat = 12
    private let leftRatio: CGFloat = 3
    private let centerRatio: CGFloat = 7
    private let rightRatio: CGFloat = 4
    private let titlebarLeadingPadding: CGFloat = 16
    // SwiftUI points, not screenshot pixels; keeps title text clear of macOS titlebar controls.
    private let collapsedTitlebarLeadingPadding: CGFloat = 162
    private let titlebarControlsLeadingPadding: CGFloat = 92
    private let titlebarControlsTopPadding: CGFloat = 10
    private let titlebarControlSize: CGFloat = 22
    private let centerWallTextSize: CGFloat = 13
    private let unBlue = Color(red: 0.255, green: 0.561, blue: 0.871)
    private let draftBlue = Color(red: 0.0, green: 0.478, blue: 1.0)

    private var isDarkSurface: Bool {
        colorScheme == .dark
    }

    private var workSurfaceColor: Color {
        isDarkSurface ? .black : .white
    }

    private var workSurfaceBorderColor: Color {
        isDarkSurface ? .white.opacity(0.14) : .black.opacity(0.12)
    }

    private var workSurfaceShadowColor: Color {
        .black.opacity(isDarkSurface ? 0.26 : 0.14)
    }

    private var dynamicInputBorderColor: Color {
        isDarkSurface ? .white.opacity(0.13) : .black.opacity(0.10)
    }

    private var dynamicInputGlassTintColor: Color {
        isDarkSurface ? .white.opacity(0.06) : .white.opacity(0.34)
    }

    private var deepGlassOverlay: Color {
        isDarkSurface
            ? .black.opacity(0.34)
            : Color(red: 0.43, green: 0.69, blue: 0.90).opacity(0.38)
    }

    private var sidebarRowBackgroundColor: Color {
        isDarkSurface ? .white.opacity(0.07) : .black.opacity(0.08)
    }

    private var sidebarSelectedRowBackgroundColor: Color {
        Color.accentColor.opacity(isDarkSurface ? 0.24 : 0.20)
    }

    private var titlebarStatusLeadingPadding: CGFloat {
        isLeftSidebarCollapsed
            ? collapsedTitlebarLeadingPadding
            : titlebarLeadingPadding
    }

    private func centerWallFont(weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: centerWallTextSize, weight: weight, design: design)
    }

    private var courseName: String {
        vm.currentCourse?.name
            ?? (selectedCourseIndex < courseDB.allSubjects.count ? courseDB.allSubjects[selectedCourseIndex].name : "请选择强化专项")
    }

    private var noteDirectoryBinding: Binding<String> {
        Binding(
            get: {
                vm.noteDirectoryPath.isEmpty
                    ? vm.defaultNoteDirectoryPath
                    : vm.noteDirectoryPath
            },
            set: { newValue in
                vm.noteDirectoryPath = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                vm.refreshNoteRecords()
            }
        )
    }

    private var providerModelControlsDisabled: Bool {
        vm.isRecording || vm.isFinalizingSession || isChecking || vm.isRefreshingProviderModels
    }

    private var isChecking: Bool {
        if case .checking = vm.engineStatus { return true }
        return false
    }

    private var shouldShowProviderCheckStrip: Bool {
        Self.shouldShowProviderCheckStrip(
            isRecording: vm.isRecording,
            isFinalizingSession: vm.isFinalizingSession,
            canRestart: vm.canRestart,
            historyItems: vm.historyItems,
            providerCheckResults: vm.providerCheckResults
        )
    }

    private var canReturnToTranscription: Bool {
        (workspaceMode == .settings || workspaceMode == .courseSelection)
            && !courseDB.allSubjects.isEmpty
    }

    static func shouldShowProviderCheckStrip(
        isRecording: Bool,
        isFinalizingSession: Bool,
        canRestart: Bool,
        historyItems: [TranscriptionItem],
        providerCheckResults: [LLMProviderCheckResult]
    ) -> Bool {
        guard !providerCheckResults.isEmpty else { return false }
        guard !isRecording, !isFinalizingSession, !canRestart else { return false }
        return !historyItems.contains { !$0.isSystemMessage }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Rectangle()
                .fill(deepGlassOverlay)
                .ignoresSafeArea()

            GeometryReader { proxy in
                let visibleSpacing = isLeftSidebarCollapsed ? CGFloat(0) : layoutSpacing
                let leftInset = isLeftSidebarCollapsed ? CGFloat(0) : CGFloat(6)
                let contentWidth = max(0, proxy.size.width - leftInset - visibleSpacing)
                let computedSidebarWidth = contentWidth * leftRatio / (leftRatio + centerRatio + rightRatio)
                let leftWidth = max(240, min(340, computedSidebarWidth))

                HStack(spacing: visibleSpacing) {
                    if !isLeftSidebarCollapsed {
                        noteHistorySidebar()
                            .frame(width: leftWidth)
                            .padding(.leading, leftInset)
                            .padding(.top, 38)
                            .padding(.bottom, 6)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    mainWorkArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea(.container, edges: [.top, .trailing])

            titlebarNavigationControls
                .padding(.leading, titlebarControlsLeadingPadding)
                .padding(.top, titlebarControlsTopPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 1320, minHeight: 720)
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
        .onAppear {
            vm.refreshNoteRecords()
            if courseDB.allSubjects.isEmpty {
                workspaceMode = .courseSelection
            }
        }
        .onChange(of: vm.noteDirectoryPath) { _, _ in
            vm.refreshNoteRecords()
        }
        .onChange(of: courseDB.allSubjects.count) { _, _ in
            normalizeCourseSelection()
        }
    }

    // MARK: - 左侧笔记历史

    private var titlebarNavigationControls: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    isLeftSidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: isLeftSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: titlebarControlSize, height: titlebarControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary.opacity(0.85))
            .help(isLeftSidebarCollapsed ? "展开历史记录区" : "收起历史记录区")

            Button {
                workspaceMode = .transcription
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: titlebarControlSize, height: titlebarControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary.opacity(0.85))
            .help(canReturnToTranscription ? "返回当前同传" : "当前已在同传主界面")
        }
    }

    private func noteHistorySidebar() -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                sidebarActionButton(
                    title: "新记录",
                    systemImage: "square.and.pencil",
                    isDisabled: vm.isRecording || vm.isFinalizingSession,
                    action: createNewRecord
                )

                sidebarActionButton(
                    title: "强化专项",
                    systemImage: "book.closed",
                    action: { workspaceMode = .courseSelection }
                )
            }

            HStack {
                Text("记录")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.72))
                Spacer()
                Button("刷新") {
                    vm.refreshNoteRecords()
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("刷新当前笔记文件夹的笔记文件")
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if vm.noteRecords.isEmpty {
                        Text("暂无笔记")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 18)
                    }

                    ForEach(vm.noteRecords) { record in
                        noteRecordRow(record)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer(minLength: 0)

            Button {
                workspaceMode = .settings
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                    Text("设置")
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func sidebarActionButton(
        title: String,
        systemImage: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .foregroundStyle(isDisabled ? .secondary : .primary)
    }

    private func noteRecordRow(_ record: NoteRecord) -> some View {
        Button {
            Task {
                await vm.loadNotePreview(record)
                activeNotePreview = record
                isSummaryPaneCollapsed = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(record.fileName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("\(formatDate(record.modifiedAt)) · \(formatFileSize(record.fileSize))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let preview = record.previewSummary {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(vm.selectedNoteRecord?.id == record.id ? sidebarSelectedRowBackgroundColor : sidebarRowBackgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 中右合并主框

    private var mainWorkArea: some View {
        VStack(spacing: 0) {
            titlebarStatusRail

            VStack(spacing: 8) {
                mainContentRow
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                dynamicInputPanel
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(workSurfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(workSurfaceBorderColor, lineWidth: 1)
        )
        .shadow(color: workSurfaceShadowColor, radius: 16, y: 6)
        .ignoresSafeArea(.container, edges: [.top, .trailing])
    }

    private var titlebarStatusRail: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: titlebarStatusLeadingPadding)

            HStack(spacing: 12) {
                Text(courseName)
                    .font(centerWallFont(weight: .semibold))
                    .lineLimit(1)

                statusBadge
                Spacer(minLength: 16)

                HStack(spacing: 6) {
                    Image(systemName: "mic")
                        .foregroundStyle(.secondary)
                    Text(vm.micDeviceName.isEmpty ? "未连接麦克风" : vm.micDeviceName)
                        .lineLimit(1)
                    Divider()
                        .frame(height: 14)
                    Text("W\(vm.whisperQueueSize) / L\(vm.llmQueueSize)")
                        .monospacedDigit()
                }
                .font(centerWallFont())
                .foregroundStyle(.secondary)

                Button {
                    withAnimation(.snappy) {
                        isSummaryPaneCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isSummaryPaneCollapsed ? "sidebar.right" : "sidebar.trailing")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: titlebarControlSize, height: titlebarControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary.opacity(0.85))
                .help(isSummaryPaneCollapsed ? "展开笔记总结区" : "收起笔记总结区")

                if activeNotePreview != nil {
                    Button {
                        withAnimation(.snappy) {
                            activeNotePreview = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13, weight: .regular))
                            .frame(width: titlebarControlSize, height: titlebarControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary.opacity(0.85))
                    .help("关闭历史笔记预览")
                }
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(workSurfaceBorderColor)
                .frame(height: 1)
        }
    }

    private var mainContentRow: some View {
        GeometryReader { proxy in
            let spacing = isSummaryPaneCollapsed ? CGFloat(0) : layoutSpacing
            let rightWidth = max(280, (proxy.size.width - spacing) * rightRatio / (centerRatio + rightRatio))

            HStack(alignment: .top, spacing: spacing) {
                centerContentPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isSummaryPaneCollapsed {
                    rightContentPanel
                        .frame(width: rightWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private var centerContentPanel: some View {
        switch workspaceMode {
        case .courseSelection:
            courseSelectionPanel
        case .settings:
            settingsPanel
        case .transcription, .notePreview:
            sessionHistoryPanel
        }
    }

    private var sessionHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前同传")
                    .font(centerWallFont(weight: .semibold))
                providerModelBadge(prefix: "Groq", modelName: vm.groqCoreModelName)
                Spacer()
                Text(statusLabel)
                    .font(centerWallFont(weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            Text(vm.statusMessage)
                .font(centerWallFont())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .checking = vm.engineStatus,
               vm.downloadProgress > 0.0,
               vm.downloadProgress < 1.0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: vm.downloadProgress)
                    let downloadDetail = vm.downloadStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !downloadDetail.isEmpty, downloadDetail != vm.statusMessage {
                        Text(downloadDetail)
                            .font(centerWallFont())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if shouldShowProviderCheckStrip {
                Divider()
                providerCheckStrip
                Divider()
            }

            currentHistoryScroll
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var providerCheckStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleProviderCheckResults, id: \.provider.id) { result in
                HStack(spacing: 8) {
                    Circle()
                        .frame(width: 7, height: 7)
                        .foregroundStyle(providerStatusColor(for: result.provider.id))
                    Text("\(result.provider.displayName) · \(result.provider.modelName)")
                        .lineLimit(1)
                    Spacer()
                    Text(result.status.displayText)
                        .foregroundStyle(providerStatusColor(for: result.provider.id))
                }
                .font(centerWallFont())
            }
        }
    }

    private var visibleProviderCheckResults: [LLMProviderCheckResult] {
        vm.providerCheckResults.filter { result in
            if result.provider.id == .agnes, result.status == .notConfigured {
                return false
            }
            return true
        }
    }

    private var courseSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("强化专项")
                    .font(centerWallFont(weight: .semibold))

                Spacer()

                Button {
                    showingAddSubject = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(centerWallFont(weight: .semibold))
                }
                .buttonStyle(.bordered)

                if courseDB.hasHiddenDefaultSubjects {
                    Button {
                        restoreDefaultCourses()
                    } label: {
                        Label("Restore", systemImage: "arrow.counterclockwise")
                            .font(centerWallFont(weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    if courseDB.allSubjects.isEmpty {
                        Text("暂无强化专项")
                            .font(centerWallFont())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 24)
                    }

                    ForEach(Array(courseDB.allSubjects.enumerated()), id: \.element.id) { index, course in
                        courseRow(index: index, course: course)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func courseRow(index: Int, course: CourseSubject) -> some View {
        Button {
            selectCourse(index: index, course: course)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(course.name)
                        .font(centerWallFont(weight: selectedCourseIndex == index ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    if selectedCourseIndex == index {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(course.meetingFocus)
                    .font(centerWallFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedCourseIndex == index ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.isRecording || vm.isFinalizingSession)
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

    // MARK: - 右侧内容区

    @ViewBuilder
    private var rightContentPanel: some View {
        if activeNotePreview != nil {
            notePreviewOverlayPanel
        } else {
            summaryEnvironmentPanel
        }
    }

    private var currentHistoryScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let visibleItems = vm.historyItems.filter { $0.isVisible && $0.status == .done }

                    if visibleItems.isEmpty {
                        Text("暂无历史内容")
                            .font(centerWallFont())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 18)
                    }

                    ForEach(visibleItems) { item in
                        historyItemView(item)
                    }

                    Color.clear.frame(height: 1).id("history-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: vm.historyItems.count) { _, _ in
                withAnimation { proxy.scrollTo("history-bottom", anchor: .bottom) }
            }
        }
    }

    private var summaryEnvironmentPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("笔记总结区")
                    .font(centerWallFont(weight: .semibold))
                    .foregroundStyle(.secondary)
                providerModelBadge(prefix: "NVIDIA", modelName: vm.nvidiaSummaryModelName)
                Spacer()
                if vm.isLiveSummaryUpdating {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                }
            }

            HStack(spacing: 5) {
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(vm.liveSummaryReady ? .green : .secondary)
                Text(vm.liveSummaryStatus)
                    .font(centerWallFont(weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            ScrollView {
                Text(vm.liveSummaryText.isEmpty ? vm.liveSummaryStatus : vm.liveSummaryText)
                    .font(centerWallFont())
                    .foregroundStyle(vm.liveSummaryText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
    }

    private var notePreviewOverlayPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("历史笔记")
                    .font(centerWallFont(weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(activeNotePreview?.fileName ?? vm.selectedNoteRecord?.fileName ?? "笔记")
                    .font(centerWallFont(weight: .semibold))
                    .lineLimit(2)
                Text(vm.notePreviewStatus)
                    .font(centerWallFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            ScrollView {
                notePreviewContent
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var notePreviewContent: some View {
        let text = vm.notePreviewText.isEmpty ? vm.notePreviewStatus : vm.notePreviewText
        let isEmpty = vm.notePreviewText.isEmpty
        let format = activeNotePreview?.format ?? vm.selectedNoteRecord?.format

        if format == .markdown, !isEmpty {
            MarkdownNotePreview(text: text)
                .foregroundStyle(.primary)
        } else {
            Text(text)
                .font(centerWallFont(design: .monospaced))
                .foregroundStyle(isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - 蹦字输入框

    private var dynamicInputPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(vm.dynamicItems.filter { $0.isVisible }) { item in
                            dynamicItemView(item)
                        }

                        if !vm.draftText.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("🇬🇧")
                                Text(vm.draftText)
                                    .font(centerWallFont(weight: .heavy))
                                    .foregroundStyle(draftBlue)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("[Listening...]")
                                    .font(centerWallFont())
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if vm.dynamicItems.filter({ $0.isVisible }).isEmpty && vm.draftText.isEmpty {
                            Text("Waiting for speech...")
                                .font(centerWallFont())
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }

                        Color.clear.frame(height: 1).id("dynamic-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: vm.dynamicItems.count) { _, _ in
                    withAnimation { proxy.scrollTo("dynamic-bottom", anchor: .bottom) }
                }
                .onChange(of: vm.draftText) { _, _ in
                    withAnimation { proxy.scrollTo("dynamic-bottom", anchor: .bottom) }
                }
            }

            HStack(spacing: 10) {
                Text("HySimulatranslate powered by Haoyu Wang")
                    .font(centerWallFont(weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.72))
                    .lineLimit(1)
                Spacer()
                controlStrip
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 154)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(dynamicInputGlassTintColor)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(dynamicInputBorderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(isDarkSurface ? 0.22 : 0.10), radius: 12, y: 5)
        .clipped()
    }

    @ViewBuilder
    private var controlStrip: some View {
        HStack(spacing: 8) {
            if vm.isFinalizingSession {
                Button(action: {}) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.75)
                        Text("整理笔记中...")
                    }
                    .font(centerWallFont(weight: .semibold))
                    .frame(minWidth: 138, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            } else if vm.canRestart {
                dynamicControlButton(
                    systemImage: "arrow.clockwise",
                    tint: unBlue,
                    help: "再次开始"
                ) {
                    vm.prepareRestart()
                    vm.refreshNoteRecords()
                }
            } else if vm.isRecording {
                dynamicControlButton(
                    systemImage: "stop.fill",
                    tint: .red,
                    help: "结束录制"
                ) {
                    vm.stopTranscription()
                }
            } else if case .ready = vm.engineStatus, vm.canStartTranscription {
                dynamicControlButton(
                    systemImage: "play.fill",
                    tint: vm.translationEnabled ? unBlue : .orange,
                    help: vm.startTranscriptionButtonTitle
                ) {
                    vm.startTranscription()
                }
            } else if case .checking = vm.engineStatus {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("自检中")
                        .foregroundColor(.orange)
                }
                .font(centerWallFont(weight: .semibold))
                .frame(minWidth: 108, minHeight: 30)
            } else if case .error = vm.engineStatus {
                dynamicControlButton(
                    systemImage: "arrow.clockwise",
                    tint: .orange,
                    help: "重新自检"
                ) {
                    vm.runSystemCheck()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func dynamicControlButton(
        systemImage: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // MARK: - 设置

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("设置")
                    .font(centerWallFont(weight: .semibold))

                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    apiKeySection
                    Divider()
                    noteDirectorySection
                    Divider()
                    modelSection
                    Divider()
                    whisperSection
                    Divider()
                    pauseSection
                    Divider()
                    appearanceSection
                }
                .frame(maxWidth: 840, alignment: .leading)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API Key", systemImage: "key.fill")
                .font(centerWallFont(weight: .semibold))
            if let groq = LLMProviderCatalog.groqCoreProvider {
                providerKeyRow(groq, title: "Groq 核心")
            }
            if let nvidia = LLMProviderCatalog.nvidiaSummaryProvider {
                providerKeyRow(nvidia, title: "NVIDIA 总结")
            }
            if let agnes = LLMProviderCatalog.agnesOrganizerProvider {
                providerKeyRow(agnes, title: "Agnes 整理", showsStatus: true)
            }
        }
    }

    private func providerKeyRow(_ provider: LLMProvider, title: String, showsStatus: Bool = false) -> some View {
        let key = providerAPIKeys[provider.id, default: ""]
        let hasKey = provider.acceptsKey(key)
        let hasInvalidKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasKey

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: hasKey ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(hasKey ? .green : .secondary)
                Text(title)
                    .font(centerWallFont(weight: .semibold))
                Spacer()
                Link("获取", destination: provider.getAPIKeyURL)
                    .font(centerWallFont(weight: .semibold))
            }

            SecureField(provider.keyPlaceholder, text: apiKeyBinding(for: provider.id))
                .font(centerWallFont())
                .textFieldStyle(.roundedBorder)

            if hasInvalidKey {
                Label("Key 应以 '\(provider.requiredKeyPrefix ?? "")' 开头", systemImage: "exclamationmark.triangle.fill")
                    .font(centerWallFont())
                    .foregroundStyle(.red)
            }

            if showsStatus {
                Text(providerStatusText(for: provider.id))
                    .font(centerWallFont())
                    .foregroundStyle(providerStatusColor(for: provider.id))
                    .lineLimit(1)
            }
        }
    }

    private func apiKeyBinding(for providerID: LLMProviderID) -> Binding<String> {
        Binding(
            get: { providerAPIKeys[providerID, default: ""] },
            set: { newValue in
                var updated = providerAPIKeys
                updated[providerID] = newValue
                providerAPIKeys = updated
                KeychainManager.shared.saveProviderKeys(updated)
                vm.updateProviderAPIKeys(updated)
            }
        )
    }

    private var noteDirectorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("笔记位置", systemImage: "folder")
                .font(centerWallFont(weight: .semibold))
            HStack(spacing: 8) {
                TextField("笔记保存路径", text: noteDirectoryBinding)
                    .font(centerWallFont())
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                Button {
                    vm.chooseNoteDirectory()
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("选择笔记文件夹")
                Button {
                    vm.resetNoteDirectoryToDesktop()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("恢复桌面")
            }
            .disabled(vm.isRecording || vm.isFinalizingSession)

            Picker("笔记格式", selection: $vm.noteFileFormatRaw) {
                ForEach(NoteFileFormat.allCases) { format in
                    Text(format.title).tag(format.rawValue)
                }
            }
            .font(centerWallFont())
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 360, alignment: .leading)
            .padding(.top, 1)
            .disabled(vm.isRecording || vm.isFinalizingSession)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("模型", systemImage: "cpu")
                    .font(centerWallFont(weight: .semibold))
                Spacer()
                if vm.isRefreshingProviderModels {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                }
            }

            HStack(spacing: 8) {
                Button {
                    vm.refreshProviderModelLists()
                } label: {
                    Label("刷新列表", systemImage: "arrow.triangle.2.circlepath")
                        .font(centerWallFont(weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(providerModelControlsDisabled)

                Button {
                    vm.runSystemCheck()
                } label: {
                    Label("重新自检", systemImage: "arrow.clockwise")
                        .font(centerWallFont(weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(providerModelControlsDisabled)
            }

            providerModelPicker(
                title: "Groq 核心",
                providerID: .groq,
                selection: $vm.groqCoreModelName,
                models: vm.providerModelOptions(for: .groq)
            )
            providerModelPicker(
                title: "NVIDIA 总结",
                providerID: .nvidia,
                selection: $vm.nvidiaSummaryModelName,
                models: vm.providerModelOptions(for: .nvidia)
            )

            if !vm.providerModelRefreshStatus.isEmpty {
                Text(vm.providerModelRefreshStatus)
                    .font(centerWallFont())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whisperSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Whisper 精校", systemImage: "waveform.and.magnifyingglass")
                .font(centerWallFont(weight: .semibold))
            Picker("Whisper 精校", selection: $vm.whisperRefinementModeRaw) {
                ForEach(WhisperRefinementMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .font(centerWallFont())
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(vm.isRecording)
        }
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("停顿时间", systemImage: "timer")
                    .font(centerWallFont(weight: .semibold))
                Spacer()
                Text(String(format: "%.1fs", vm.pauseVal))
                    .font(centerWallFont(design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $vm.pauseVal, in: 0.2...1.5, step: 0.1)
                .onChange(of: vm.pauseVal) { _, newValue in
                    vm.updatePauseValue(newValue)
                }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("外观", systemImage: "circle.lefthalf.filled")
                .font(centerWallFont(weight: .semibold))
            Picker("外观", selection: $appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .font(centerWallFont())
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private func providerModelPicker(
        title: String,
        providerID: LLMProviderID,
        selection: Binding<String>,
        models: [LLMProviderModel]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(centerWallFont(weight: .semibold))
            Picker(title, selection: selection) {
                ForEach(models) { model in
                    Text(vm.providerModelDisplayText(model)).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(providerModelControlsDisabled)
            .onChange(of: selection.wrappedValue) { _, _ in
                vm.noteProviderModelSelectionChanged()
            }

            Text(providerStatusText(for: providerID))
                .font(centerWallFont())
                .foregroundStyle(providerStatusColor(for: providerID))
                .lineLimit(1)
        }
    }

    private func providerStatusText(for providerID: LLMProviderID) -> String {
        guard let result = vm.providerCheckResults.first(where: { $0.provider.id == providerID }) else {
            return "上次自检：尚未运行"
        }
        return "上次自检：\(result.provider.modelName) · \(result.status.displayText)"
    }

    private func providerStatusColor(for providerID: LLMProviderID) -> Color {
        guard let status = vm.providerCheckResults.first(where: { $0.provider.id == providerID })?.status else {
            return .secondary
        }
        switch status {
        case .passed:
            return .green
        case .notConfigured:
            return .secondary
        case .failed:
            return .orange
        }
    }

    // MARK: - 状态与条目

    private func providerModelBadge(prefix: String, modelName: String) -> some View {
        Text("\(prefix) · \(modelName)")
            .font(centerWallFont(weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(-1)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle().frame(width: 6, height: 6).foregroundColor(statusColor)
            Text(statusLabel)
                .font(centerWallFont(weight: .semibold))
        }
    }

    private var statusColor: Color {
        switch vm.engineStatus {
        case .idle: .gray
        case .checking: .orange
        case .ready: .green
        case .running: .green
        case .error: .red
        }
    }

    private var statusLabel: String {
        switch vm.engineStatus {
        case .idle: return "空闲"
        case .checking: return "自检中"
        case .ready: return "已就绪"
        case .running: return "运转中"
        case .error: return "错误"
        }
    }

    @ViewBuilder
    private func historyItemView(_ item: TranscriptionItem) -> some View {
        if item.isSystemMessage {
            HStack(spacing: 8) {
                Image(systemName: item.english.contains("未") ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(item.english.contains("未") ? .orange : .green)
                Text(item.english.replacingOccurrences(of: "[自检] ", with: ""))
                    .font(centerWallFont(weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(item.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                let block = TranscriptDisplayBlock(item: item)

                if block.canInterleaveLineByLine {
                    ForEach(block.englishLines.indices, id: \.self) { idx in
                        Text("🇬🇧 \(block.englishLines[idx])")
                            .font(centerWallFont())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("🇨🇳 \(block.chineseLines[idx])")
                            .font(centerWallFont())
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(block.englishLines.indices, id: \.self) { idx in
                        Text("🇬🇧 \(block.englishLines[idx])")
                            .font(centerWallFont())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if vm.translationEnabled, !block.chineseLines.isEmpty {
                        Text("🇨🇳 \(block.chineseLines.joined(separator: " "))")
                            .font(centerWallFont())
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                }
            }
            .id(item.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func dynamicItemView(_ item: TranscriptionItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("🇬🇧").font(centerWallFont())
                Text(item.english.replacingOccurrences(of: "\n", with: " "))
                    .font(centerWallFont())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                statusView(for: item.status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if vm.translationEnabled, let zh = item.chinese, item.status == .done {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("🇨🇳").font(centerWallFont())
                    Text(zh.replacingOccurrences(of: "\n", with: " "))
                        .font(centerWallFont())
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func statusView(for status: ItemStatus) -> some View {
        switch status {
        case .whispering:
            Text("[Processing...]")
                .font(centerWallFont())
                .foregroundColor(.orange)
        case .llmFormatting:
            Text("[Refining...]")
                .font(centerWallFont())
                .foregroundColor(.orange)
        case .llmAggregating:
            Text("[Aggregating...]")
                .font(centerWallFont())
                .foregroundColor(.orange)
        case .organizing:
            Text("[Organizing...]")
                .font(centerWallFont())
                .foregroundColor(.orange)
        case .translating:
            ProgressView()
                .scaleEffect(0.4)
                .frame(width: 12, height: 12)
        case .done, .dropped:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func createNewRecord() {
        if courseDB.allSubjects.isEmpty {
            workspaceMode = .courseSelection
            return
        }
        normalizeCourseSelection()
        vm.startNewRecordWithoutSelfCheck()
        vm.runSystemCheck()
        activeNotePreview = nil
        workspaceMode = .transcription
    }

    private func selectCourse(index: Int, course: CourseSubject) {
        guard !vm.isRecording, !vm.isFinalizingSession else { return }
        selectedCourseIndex = index
        vm.selectCourse(course)
    }

    private func normalizeCourseSelection() {
        guard !courseDB.allSubjects.isEmpty else {
            workspaceMode = .courseSelection
            return
        }
        selectedCourseIndex = min(selectedCourseIndex, courseDB.allSubjects.count - 1)
        vm.selectCourse(courseDB.allSubjects[selectedCourseIndex])
    }

    private func confirmCourseDeletion(_ course: CourseSubject) {
        coursePendingDeletion = course
        isConfirmingCourseDeletion = true
    }

    private func restoreDefaultCourses() {
        courseDB.restoreDefaultSubjects()
        selectedCourseIndex = min(selectedCourseIndex, max(0, courseDB.allSubjects.count - 1))
        normalizeCourseSelection()
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
        normalizeCourseSelection()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MarkdownNotePreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                markdownLine(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func markdownLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == "---" {
            Divider()
                .padding(.vertical, 4)
        } else if let heading = heading(from: trimmed) {
            Text(heading.text)
                .font(headingFont(for: heading.level))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, heading.level <= 2 ? 6 : 2)
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 6)
        } else {
            Text(line)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let remainder = String(line.dropFirst(hashes))
        guard remainder.first?.isWhitespace == true else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (hashes, text)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title3
        case 2: .headline
        case 3: .subheadline
        case 4: .callout
        default: .caption
        }
    }
}
