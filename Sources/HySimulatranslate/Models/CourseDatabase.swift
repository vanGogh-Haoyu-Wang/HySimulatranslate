import Foundation

// MARK: - 强化专项知识库
class CourseDatabase: ObservableObject {
    static let shared = CourseDatabase()

    @Published var customSubjects: [CourseSubject] = []
    @Published private var hiddenDefaultAbbrevs: Set<String> = []
    private let saveKey = "CustomSubjects"
    private let hiddenDefaultsKey = "HiddenDefaultSubjects"
    private let protectedDefaultAbbrevs: Set<String> = ["Default"]

    let defaultSubjects: [CourseSubject] = [
        CourseSubject(
            name: "默认",
            abbrev: "Default",
            keywords: "general speech, faithful translation, accurate transcript, terminology, context, punctuation",
            meetingFocus: """
            You are a rigorous translator and transcript editor. Preserve the speaker's original meaning exactly. Correct only punctuation, casing, grammar, and obvious ASR or phonetic errors. Keep terminology stable. Do not invent facts, examples, explanations, opinions, or extra context. Output only the refined transcript.
            """
        )
    ]

    var allSubjects: [CourseSubject] {
        defaultSubjects.filter { !hiddenDefaultAbbrevs.contains($0.abbrev) } + customSubjects
    }

    var hasHiddenDefaultSubjects: Bool {
        !hiddenDefaultAbbrevs.isEmpty
    }

    init() {
        loadCustomSubjects()
        loadHiddenDefaultSubjects()
    }

    func addSubject(_ subject: CourseSubject) {
        customSubjects.append(subject)
        saveCustomSubjects()
    }

    func isCustomSubject(_ subject: CourseSubject) -> Bool {
        customSubjects.contains { $0.id == subject.id }
    }

    func canRemoveSubject(_ subject: CourseSubject) -> Bool {
        isCustomSubject(subject) || !protectedDefaultAbbrevs.contains(subject.abbrev)
    }

    func removeSubject(_ subject: CourseSubject) {
        guard canRemoveSubject(subject) else { return }

        if isCustomSubject(subject) {
            customSubjects.removeAll { $0.id == subject.id }
            saveCustomSubjects()
        } else {
            hiddenDefaultAbbrevs.insert(subject.abbrev)
            saveHiddenDefaultSubjects()
        }
    }

    func restoreDefaultSubjects() {
        hiddenDefaultAbbrevs.removeAll()
        saveHiddenDefaultSubjects()
    }

    private func saveCustomSubjects() {
        if let data = try? JSONEncoder().encode(customSubjects) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func loadCustomSubjects() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([CourseSubject].self, from: data)
        else { return }
        customSubjects = decoded
    }

    private func saveHiddenDefaultSubjects() {
        let hidden = Array(hiddenDefaultAbbrevs).sorted()
        UserDefaults.standard.set(hidden, forKey: hiddenDefaultsKey)
    }

    private func loadHiddenDefaultSubjects() {
        guard let hidden = UserDefaults.standard.stringArray(forKey: hiddenDefaultsKey) else { return }
        hiddenDefaultAbbrevs = Set(hidden)
    }
}
