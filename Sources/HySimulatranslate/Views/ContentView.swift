import SwiftUI
import AppKit

// MARK: - 🏠 根视图

struct ContentView: View {
    @StateObject private var courseDB = CourseDatabase()
    @StateObject private var vm = TranscriptionViewModel()

    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    @State private var providerAPIKeys: [LLMProviderID: String] = [:]
    @State private var selectedCourseIndex: Int = 0
    @State private var didInitializeWorkspace = false

    var body: some View {
        TranscriptionView(
            vm: vm,
            courseDB: courseDB,
            providerAPIKeys: $providerAPIKeys,
            selectedCourseIndex: $selectedCourseIndex
        )
        .background(GlassWindowConfigurator())
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            applyAppearance(appearanceMode)
            initializeWorkspaceIfNeeded()
        }
        .onChange(of: appearanceMode) { _, newValue in
            applyAppearance(newValue)
        }
        .onChange(of: courseDB.allSubjects.count) { _, _ in
            normalizeCourseSelection()
        }
    }

    private func applyAppearance(_ mode: String) {
        let selectedMode = AppearanceMode(rawValue: mode) ?? .system
        if let appearanceName = selectedMode.appearanceName {
            NSApp.appearance = NSAppearance(named: appearanceName)
        } else {
            NSApp.appearance = nil
        }
    }

    private func initializeWorkspaceIfNeeded() {
        guard !didInitializeWorkspace else { return }
        didInitializeWorkspace = true

        providerAPIKeys = KeychainManager.shared.loadProviderKeys()
        vm.updateProviderAPIKeys(providerAPIKeys)
        normalizeCourseSelection()
        vm.refreshNoteRecords()

        if vm.currentCourse != nil, case .idle = vm.engineStatus {
            vm.runSystemCheck()
        }
    }

    private func normalizeCourseSelection() {
        guard !courseDB.allSubjects.isEmpty else { return }
        selectedCourseIndex = min(selectedCourseIndex, courseDB.allSubjects.count - 1)
        vm.selectCourse(courseDB.allSubjects[selectedCourseIndex])
    }
}
