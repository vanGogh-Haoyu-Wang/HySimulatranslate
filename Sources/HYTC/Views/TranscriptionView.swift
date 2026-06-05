import SwiftUI

// MARK: - 🎨 同传主界面（对应 Python history_text_area + dynamic_text_area + control_frame）

struct TranscriptionView: View {
    @ObservedObject var vm: TranscriptionViewModel
    @ObservedObject var courseDB: CourseDatabase
    var courseIndex: Int
    var onBack: () -> Void

    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @State private var showingSettings = false

    private let unBlue = Color(red: 0.255, green: 0.561, blue: 0.871)
    private let draftBlue = Color(red: 0.0, green: 0.478, blue: 1.0)
    private let dynamicPanelHeight: CGFloat = 260

    private var courseName: String {
        courseIndex < courseDB.allSubjects.count
            ? courseDB.allSubjects[courseIndex].name
            : "Unknown"
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                headerView

                mainPanels
            }
            .padding(16)
        }
        .frame(minWidth: 1080, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label("强化专项", systemImage: "chevron.left")
                }
                .help("返回强化专项选择")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置")
                .popover(isPresented: $showingSettings, arrowEdge: .top) {
                    settingsPopover
                }
            }
        }
        .onAppear {
            if case .idle = vm.engineStatus {
                vm.runSystemCheck()
            }
        }
    }

    // MARK: - 顶部与设置

    private var mainPanels: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 12
            let availableWidth = max(0, proxy.size.width - spacing)
            HStack(spacing: spacing) {
                leftColumn
                    .frame(width: availableWidth * 0.5)
                rightColumn
                    .frame(width: availableWidth * 0.5)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rightColumn: some View {
        VStack(spacing: 12) {
            dynamicPanel
                .frame(maxWidth: .infinity)
                .frame(height: dynamicPanelHeight)
            liveSummaryPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftColumn: some View {
        VStack(spacing: 12) {
            historyPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.historyItems.filter { $0.isVisible && $0.status == .done }) { item in
                        historyItemView(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .onChange(of: vm.historyItems.count) { _, _ in
                if let last = vm.historyItems.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .glassPanel(cornerRadius: 16, material: .regularMaterial)
    }

    private var liveSummaryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("实时总结", systemImage: "text.justify.left")
                    .font(.headline)
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
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            ScrollView {
                Text(vm.liveSummaryText.isEmpty ? vm.liveSummaryStatus : vm.liveSummaryText)
                    .font(.system(size: 14))
                    .foregroundStyle(vm.liveSummaryText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 16, material: .regularMaterial)
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(courseName)
                    .font(.headline)
                    .lineLimit(1)
                statusBadge
            }

            Spacer()

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
            .font(.caption)
            .foregroundStyle(.secondary)

            controlStrip
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 16, material: .thinMaterial)
    }

    @ViewBuilder
    private var controlStrip: some View {
        HStack(spacing: 12) {
            if vm.isFinalizingSession {
                Button(action: {}) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.75)
                        Text("整理笔记中...")
                    }
                    .frame(minWidth: 160, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(true)
            } else if vm.canRestart {
                Button(action: { vm.prepareRestart() }) {
                    Label("再次开始", systemImage: "arrow.clockwise")
                        .frame(minWidth: 160, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(unBlue)
                .controlSize(.regular)
            } else if vm.isRecording {
                Button(action: { vm.stopTranscription() }) {
                    Label("结束录制", systemImage: "stop.fill")
                        .frame(minWidth: 160, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            } else if case .ready = vm.engineStatus, vm.canStartTranscription {
                Button(action: { vm.startTranscription() }) {
                    Label(vm.startTranscriptionButtonTitle, systemImage: "play.fill")
                        .frame(minWidth: 180, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.translationEnabled ? unBlue : .orange)
                .controlSize(.regular)
            } else if case .checking = vm.engineStatus {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("自检中...")
                            .foregroundColor(.orange)
                    }
                    if vm.downloadProgress > 0.0 && vm.downloadProgress < 1.0 {
                        VStack(spacing: 4) {
                            ProgressView(value: vm.downloadProgress)
                                .frame(width: 300)
                            Text(vm.downloadStatus)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38)
            } else if case .error = vm.engineStatus {
                Button(action: { vm.runSystemCheck() }) {
                    Label("重新自检", systemImage: "arrow.clockwise")
                        .frame(minWidth: 160, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 2)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("停顿时间", systemImage: "timer")
                    Spacer()
                    Text(String(format: "%.1fs", vm.pauseVal))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $vm.pauseVal, in: 0.2...1.5, step: 0.1)
                    .onChange(of: vm.pauseVal) { _, newValue in
                        vm.updatePauseValue(newValue)
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("外观", systemImage: "circle.lefthalf.filled")
                Picker("外观", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(.regularMaterial)
    }

    // MARK: - 蹦字区

    private var dynamicPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.dynamicItems.filter { $0.isVisible }) { item in
                        dynamicItemView(item)
                    }

                    if !vm.draftText.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("🇬🇧")
                            Text(vm.draftText)
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(draftBlue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("[Listening...]")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if vm.dynamicItems.filter({ $0.isVisible }).isEmpty && vm.draftText.isEmpty {
                        Text("Waiting for speech...")
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 24)
                    }

                    Color.clear.frame(height: 1).id("dynamic-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: vm.dynamicItems.count) { _, _ in
                withAnimation { proxy.scrollTo("dynamic-bottom", anchor: .bottom) }
            }
            .onChange(of: vm.draftText) { _, _ in
                withAnimation { proxy.scrollTo("dynamic-bottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: dynamicPanelHeight, maxHeight: dynamicPanelHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
        .clipped()
    }

    // MARK: - 状态指示

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle().frame(width: 6, height: 6).foregroundColor(statusColor)
            Text(statusLabel).font(.caption.bold())
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

    // MARK: - 条目视图

    @ViewBuilder
    private func historyItemView(_ item: TranscriptionItem) -> some View {
        if item.isSystemMessage {
            HStack(spacing: 8) {
                Image(systemName: item.english.contains("未") ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(item.english.contains("未") ? .orange : .green)
                Text(item.english.replacingOccurrences(of: "[自检] ", with: ""))
                    .font(.callout.weight(.medium))
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
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("🇨🇳 \(block.chineseLines[idx])")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(block.englishLines.indices, id: \.self) { idx in
                        Text("🇬🇧 \(block.englishLines[idx])")
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if vm.translationEnabled, !block.chineseLines.isEmpty {
                        Text("🇨🇳 \(block.chineseLines.joined(separator: " "))")
                            .font(.system(size: 14))
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
                Text("🇬🇧").font(.caption)
                Text(item.english.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                statusView(for: item.status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if vm.translationEnabled, let zh = item.chinese, item.status == .done {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("🇨🇳").font(.caption)
                    Text(zh.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 14))
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
                .font(.caption2)
                .foregroundColor(.orange)
        case .llmFormatting:
            Text("[Refining...]")
                .font(.caption2)
                .foregroundColor(.orange)
        case .llmAggregating:
            Text("[Aggregating...]")
                .font(.caption2)
                .foregroundColor(.orange)
        case .organizing:
            Text("[Organizing...]")
                .font(.caption2)
                .foregroundColor(.orange)
        case .translating:
            ProgressView()
                .scaleEffect(0.4)
                .frame(width: 12, height: 12)
        case .done, .dropped:
            EmptyView()
        }
    }
}
