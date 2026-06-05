import Foundation

struct TranscriptDisplayBlock: Equatable {
    let englishLines: [String]
    let chineseLines: [String]

    init(item: TranscriptionItem) {
        englishLines = Self.cleanedLines(from: item.english)
        chineseLines = Self.cleanedLines(from: item.chinese ?? "")
    }

    var canInterleaveLineByLine: Bool {
        !chineseLines.isEmpty && chineseLines.count == englishLines.count
    }

    private static func cleanedLines(from text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
