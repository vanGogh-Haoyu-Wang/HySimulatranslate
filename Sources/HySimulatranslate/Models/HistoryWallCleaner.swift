import Foundation

enum HistoryWallCleaner {
    static let minimumBoundaryOverlapWords = 3

    static func clean(_ items: [TranscriptionItem]) -> [TranscriptionItem] {
        var cleaned = items
        removeExactDuplicates(in: &cleaned)
        trimAdjacentBoundaryOverlaps(in: &cleaned)
        return cleaned
    }

    private static func removeExactDuplicates(in items: inout [TranscriptionItem]) {
        var emitted: [String] = []
        for idx in items.indices {
            guard shouldClean(items[idx]) else { continue }
            let normalized = normalizedForDuplicate(items[idx].english)
            guard !normalized.isEmpty else { continue }
            if emitted.contains(normalized) || emitted.contains(where: {
                TranscriptOrganizer.isLikelyDuplicate(
                    items[idx].english,
                    of: $0,
                    dropLongerCandidateContainingPrior: false
                )
            }) {
                items[idx].isVisible = false
                items[idx].status = .dropped
            } else {
                emitted.append(normalized)
            }
        }
    }

    private static func trimAdjacentBoundaryOverlaps(in items: inout [TranscriptionItem]) {
        var previousVisibleIndex: Int?
        for idx in items.indices {
            guard shouldClean(items[idx]) else { continue }
            defer { previousVisibleIndex = idx }
            guard let previous = previousVisibleIndex, shouldClean(items[previous]) else { continue }

            let overlap = boundaryOverlapWordCount(
                previousText: items[previous].english,
                nextText: items[idx].english
            )
            guard overlap >= minimumBoundaryOverlapWords else { continue }

            let trimmed = droppingLastWords(overlap, from: items[previous].english)
            if trimmed.isEmpty {
                items[previous].isVisible = false
                items[previous].status = .dropped
            } else {
                items[previous].english = trimmed
            }
        }
    }

    static func boundaryOverlapWordCount(previousText: String, nextText: String) -> Int {
        let previousTokens = wordTokens(previousText)
        let nextTokens = wordTokens(nextText)
        guard previousTokens.count >= minimumBoundaryOverlapWords,
              nextTokens.count >= minimumBoundaryOverlapWords
        else { return 0 }

        let maxOverlap = min(previousTokens.count, nextTokens.count)
        for count in stride(from: maxOverlap, through: minimumBoundaryOverlapWords, by: -1) {
            if Array(previousTokens.suffix(count)) == Array(nextTokens.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func shouldClean(_ item: TranscriptionItem) -> Bool {
        item.zone == .history &&
            item.isVisible &&
            !item.isSystemMessage &&
            item.status != .dropped &&
            !item.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func droppingLastWords(_ count: Int, from text: String) -> String {
        let words = text.split { $0.isWhitespace }.map(String.init)
        guard words.count > count else { return "" }
        return words.dropLast(count)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordTokens(_ text: String) -> [String] {
        text.split { $0.isWhitespace }
            .map {
                $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
    }

    private static func normalizedForDuplicate(_ text: String) -> String {
        wordTokens(text).joined(separator: " ")
    }
}
