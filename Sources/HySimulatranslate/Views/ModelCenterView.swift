import SwiftUI

struct ModelCenterView: View {
    @ObservedObject var viewModel: ModelCenterViewModel
    var modelSelectionDisabled = false
    @AppStorage("modelCenterListScope") private var listScopeStorage = ModelListScope.recommended.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("本地模型") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.localResources, id: \.definition.id) { item in
                        localResourceRow(item)
                        if item.definition.id != viewModel.localResources.last?.definition.id { Divider() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            GroupBox("云端 Provider") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("模型范围", selection: $listScopeStorage) {
                        Text("推荐").tag(ModelListScope.recommended.rawValue)
                        Text("全部").tag(ModelListScope.all.rawValue)
                    }
                    .pickerStyle(.segmented)

                    ForEach(viewModel.cloudProviders) { provider in
                        cloudProviderRow(provider)
                        if provider.id != viewModel.cloudProviders.last?.id { Divider() }
                    }
                    Button("刷新模型与连通性") { Task { await viewModel.refreshCloud() } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            if let error = viewModel.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog("确认删除模型？", isPresented: Binding(
            get: { viewModel.pendingDeletion != nil },
            set: { if !$0 { viewModel.pendingDeletion = nil } }
        )) {
            Button("删除", role: .destructive) { viewModel.confirmDelete() }
        } message: {
            if let request = viewModel.pendingDeletion {
                Text("将释放 \(ByteCountFormatter.string(fromByteCount: request.size, countStyle: .file))，并影响：\(request.affectedCapability)")
            }
        }
        .task { viewModel.rescan(); await viewModel.refreshCloud() }
    }

    private func localResourceRow(_ item: ModelResourceSnapshot) -> some View {
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(item.definition.displayName).fontWeight(.semibold)
                Spacer()
                Text(stateLabel(item.state)).foregroundStyle(.secondary)
                if item.shouldDisplayInUse { Text("使用中").foregroundStyle(.orange) }
                if item.state != .ready { Button("下载") { Task { await viewModel.download(resourceID: item.definition.id) } } }
                if item.state != .missing { Button("删除") { viewModel.requestDelete(resourceID: item.definition.id) } }
            }
            Text("\(item.definition.version ?? "未知版本") · \(item.definition.location.path) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let status = viewModel.statusByResource[item.definition.id], !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let progress = viewModel.progressByResource[item.definition.id], progress > 0, progress < 1 {
                ProgressView(value: progress)
            }
        }
    }

    private func cloudProviderRow(_ provider: CloudModelProviderState) -> some View {
        let models = viewModel.visibleModels(
            for: provider.id,
            scope: ModelListScope(storageValue: listScopeStorage)
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(providerTitle(provider.id)).fontWeight(.semibold)
                Spacer()
                Text(provider.connectivity.displayText).foregroundStyle(connectivityColor(provider.connectivity))
            }
            if models.isEmpty {
                Text(provider.configured ? "没有可用模型，请刷新" : "请先配置 API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("模型", selection: Binding(
                    get: { viewModel.selectedModelID(for: provider.id) },
                    set: { viewModel.selectModel($0, for: provider.id) }
                )) {
                    ForEach(models) { model in Text(model.displayText).tag(model.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(modelSelectionDisabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func providerTitle(_ id: LLMProviderID) -> String {
        switch id { case .groq: "Groq 核心"; case .freeLLM: "FreeLLMAPI 总结"; case .agnes: "Agnes 整理" }
    }
    private func stateLabel(_ state: ModelResourceState) -> String {
        switch state { case .missing: "未安装"; case .corrupt: "已损坏"; case .ready: "已就绪" }
    }
    private func connectivityColor(_ status: LLMProviderCheckStatus) -> Color {
        switch status { case .passed: .green; case .notConfigured: .secondary; case .failed: .red }
    }
}
