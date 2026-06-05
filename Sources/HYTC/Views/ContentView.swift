import SwiftUI
import AppKit

// MARK: - 🏠 根视图

struct ContentView: View {
    @StateObject private var courseDB = CourseDatabase()
    @StateObject private var vm = TranscriptionViewModel()

    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    @State private var providerAPIKeys: [LLMProviderID: String] = [:]
    @State private var selectedCourseIndex: Int = 0
    @State private var isAppReady = false

    var body: some View {
        Group {
            if !isAppReady {
                StartupView(
                    courseDB: courseDB,
                    providerAPIKeys: $providerAPIKeys,
                    selectedCourseIndex: $selectedCourseIndex,
                    onLaunch: launchEngine
                )
            } else {
                TranscriptionView(
                    vm: vm,
                    courseDB: courseDB,
                    courseIndex: selectedCourseIndex,
                    onBack: exitEngine
                )
            }
        }
        .background(GlassWindowConfigurator())
        .onAppear {
            providerAPIKeys = KeychainManager.shared.loadProviderKeys()
            applyAppearance(appearanceMode)
        }
        .onChange(of: appearanceMode) { _, newValue in
            applyAppearance(newValue)
        }
    }

    private func launchEngine() {
        guard selectedCourseIndex < courseDB.allSubjects.count else { return }

        KeychainManager.shared.saveProviderKeys(providerAPIKeys)
        vm.providerAPIKeys = providerAPIKeys
        vm.currentCourse = courseDB.allSubjects[selectedCourseIndex]
        vm.translationEnabled = false
        isAppReady = true
    }

    private func exitEngine() {
        vm.stopTranscription()
        vm.clearDisplayHistory()
        isAppReady = false
    }

    private func applyAppearance(_ mode: String) {
        let selectedMode = AppearanceMode(rawValue: mode) ?? .system
        if let appearanceName = selectedMode.appearanceName {
            NSApp.appearance = NSAppearance(named: appearanceName)
        } else {
            NSApp.appearance = nil
        }
    }
}
