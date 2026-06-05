import Foundation

struct TranscriptOrganizerFragment: Equatable {
    let id: UUID
    let text: String

    init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

struct TranscriptOrganizerOutput: Equatable {
    let primaryID: UUID
    let consumedIDs: [UUID]
    let text: String
}

struct TranscriptOrganizerResult: Equatable {
    var outputs: [TranscriptOrganizerOutput]
    var droppedIDs: [UUID]
}

enum TranscriptOrganizer {
    private static let maxOverlapTokens = 8
    private static let minOverlapTokens = 2
    private static let speakerLabelMaxWords = 3
    private static let allowedAcronyms: Set<String> = [
        "AE", "AI", "API", "ASR", "CPU", "GPU", "HTTP", "HTTPS", "IPO", "LLM",
        "ML", "MSc", "NVIDIA", "RTX", "TCP", "UDP", "UI", "URL"
    ]

    static func organizeRuleBased(
        fragments: [TranscriptOrganizerFragment],
        recentHistory: [String]
    ) -> TranscriptOrganizerResult {
        var seenKeys = recentHistory.map(normalizedDuplicateKey).filter { !$0.isEmpty }
        var outputs: [TranscriptOrganizerOutput] = []
        var droppedIDs: [UUID] = []

        for fragment in fragments {
            let cleaned = cleanedText(fragment.text)
            guard !cleaned.isEmpty else {
                droppedIDs.append(fragment.id)
                continue
            }

            guard !shouldDrop(cleaned) else {
                droppedIDs.append(fragment.id)
                continue
            }

            let duplicateKey = normalizedDuplicateKey(cleaned)
            if isDuplicateKey(duplicateKey, in: seenKeys, dropLongerCandidateContainingPrior: false) {
                droppedIDs.append(fragment.id)
                continue
            }

            if let last = outputs.last,
               let merged = mergeIfOverlapping(last.text, cleaned) {
                outputs[outputs.count - 1] = TranscriptOrganizerOutput(
                    primaryID: last.primaryID,
                    consumedIDs: last.consumedIDs + [fragment.id],
                    text: merged
                )
                seenKeys.append(normalizedDuplicateKey(merged))
                continue
            }

            outputs.append(
                TranscriptOrganizerOutput(
                    primaryID: fragment.id,
                    consumedIDs: [fragment.id],
                    text: cleaned
                )
            )
            if !duplicateKey.isEmpty {
                seenKeys.append(duplicateKey)
            }
        }

        return TranscriptOrganizerResult(outputs: outputs, droppedIDs: droppedIDs)
    }

    static func shouldUseAIFallback(for fragments: [String]) -> Bool {
        let cleaned = fragments.map(cleanedText).filter { !$0.isEmpty && !shouldDrop($0) }
        guard (2...4).contains(cleaned.count) else { return false }
        let shortEnough = cleaned.allSatisfy { tokenWords(in: $0).count <= 18 }
        let hasOverlap = zip(cleaned, cleaned.dropFirst()).contains { overlapTokenCount($0, $1) >= minOverlapTokens }
        let hasDanglingBoundary = cleaned.contains { text in
            let words = tokenWords(in: text)
            guard let first = words.first, let last = words.last else { return false }
            return danglingStartWords.contains(first) || danglingEndWords.contains(last) || !hasSentenceTerminator(text)
        }
        return shortEnough && (hasOverlap || hasDanglingBoundary)
    }

    static func validatedAILines(_ output: String, originalFragments: [String]) -> [String]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let forbiddenPrefixes = [
            "here is", "here's", "cleaned transcript", "the cleaned transcript",
            "summary", "以下", "基于"
        ]
        if forbiddenPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return nil
        }

        let lines = trimmed
            .components(separatedBy: .newlines)
            .map(cleanedText)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= max(1, originalFragments.count) else { return nil }
        guard lines.allSatisfy({ !shouldDrop($0) }) else { return nil }

        let originalTokens = Set(originalFragments.flatMap(tokenWords))
        let originalTokenCount = max(1, originalFragments.flatMap(tokenWords).count)
        let outputTokens = lines.flatMap(tokenWords)
        guard outputTokens.count <= max(12, Int(Double(originalTokenCount) * 1.6) + 4) else { return nil }

        let retainedTokenCount = outputTokens.filter { originalTokens.contains($0) }.count
        guard retainedTokenCount >= min(outputTokens.count, max(2, outputTokens.count / 2)) else { return nil }

        return lines
    }

    static func organizeFromAILines(
        _ lines: [String],
        fragments: [TranscriptOrganizerFragment],
        recentHistory: [String]
    ) -> TranscriptOrganizerResult {
        let base = organizeRuleBased(fragments: fragments, recentHistory: recentHistory)
        let consumedIDs = base.outputs.flatMap(\.consumedIDs)
        guard !lines.isEmpty, !consumedIDs.isEmpty else { return base }

        if lines.count == 1 {
            return TranscriptOrganizerResult(
                outputs: [
                    TranscriptOrganizerOutput(
                        primaryID: consumedIDs[0],
                        consumedIDs: consumedIDs,
                        text: lines[0]
                    )
                ],
                droppedIDs: base.droppedIDs
            )
        }

        guard lines.count == base.outputs.count else { return base }
        let outputs = zip(base.outputs, lines).map { output, line in
            TranscriptOrganizerOutput(
                primaryID: output.primaryID,
                consumedIDs: output.consumedIDs,
                text: line
            )
        }
        return TranscriptOrganizerResult(outputs: outputs, droppedIDs: base.droppedIDs)
    }

    static func cleanedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\.{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isLikelyDuplicate(
        _ candidate: String,
        of prior: String,
        dropLongerCandidateContainingPrior: Bool = true
    ) -> Bool {
        let candidateKey = normalizedDuplicateKey(candidate)
        let priorKey = normalizedDuplicateKey(prior)
        guard !candidateKey.isEmpty, !priorKey.isEmpty else { return false }
        return isDuplicateKey(
            candidateKey,
            previousKey: priorKey,
            dropLongerCandidateContainingPrior: dropLongerCandidateContainingPrior
        )
    }

    private static func shouldDrop(_ text: String) -> Bool {
        let trimmed = cleanedText(text)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("context:") || lower.hasPrefix("raw asr:") || lower.hasPrefix("fragments:") {
            return true
        }
        return looksLikeSpeakerLabel(trimmed)
    }

    private static func looksLikeSpeakerLabel(_ text: String) -> Bool {
        guard !text.contains(".") && !text.contains("?") && !text.contains("!") else { return false }
        let words = text.split(separator: " ").map { String($0.trimmingCharacters(in: .punctuationCharacters)) }
            .filter { !$0.isEmpty }
        guard (1...speakerLabelMaxWords).contains(words.count) else { return false }
        guard words.contains(where: { !allowedAcronyms.contains($0) }) else { return false }

        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let uppercase = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let lowercase = letters.filter { CharacterSet.lowercaseLetters.contains($0) }.count
        return uppercase * 100 >= letters.count * 85 && lowercase == 0
    }

    private static func mergeIfOverlapping(_ lhs: String, _ rhs: String) -> String? {
        let overlap = overlapTokenCount(lhs, rhs)
        guard overlap >= minOverlapTokens else { return nil }
        let rhsWords = rhs.split(separator: " ").map(String.init)
        let remainder = rhsWords.dropFirst(overlap).joined(separator: " ")
        guard !remainder.isEmpty else { return lhs }
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftForMerge: String
        if let last = left.last,
           last == "." || last == "!" || last == "?",
           let firstRemainderWord = tokenWords(in: remainder).first,
           danglingStartWords.contains(firstRemainderWord) {
            leftForMerge = String(left.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            leftForMerge = left
        }
        return "\(leftForMerge) \(remainder)"
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func overlapTokenCount(_ lhs: String, _ rhs: String) -> Int {
        let left = tokenWords(in: lhs)
        let right = tokenWords(in: rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let maxCount = min(maxOverlapTokens, left.count, right.count)
        guard maxCount >= minOverlapTokens else { return 0 }
        for count in stride(from: maxCount, through: minOverlapTokens, by: -1) {
            if Array(left.suffix(count)) == Array(right.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func normalizedDuplicateKey(_ text: String) -> String {
        tokenWords(in: text).joined(separator: " ")
    }

    private static func isDuplicateKey(
        _ candidateKey: String,
        in previousKeys: [String],
        dropLongerCandidateContainingPrior: Bool
    ) -> Bool {
        guard !candidateKey.isEmpty else { return false }
        return previousKeys.contains {
            isDuplicateKey(
                candidateKey,
                previousKey: $0,
                dropLongerCandidateContainingPrior: dropLongerCandidateContainingPrior
            )
        }
    }

    private static func isDuplicateKey(
        _ candidateKey: String,
        previousKey: String,
        dropLongerCandidateContainingPrior: Bool
    ) -> Bool {
        guard !candidateKey.isEmpty, !previousKey.isEmpty else { return false }
        if candidateKey == previousKey { return true }

        let candidateTokens = candidateKey.split(separator: " ").map(String.init)
        let previousTokens = previousKey.split(separator: " ").map(String.init)
        guard candidateTokens.count >= 3, previousTokens.count >= 3 else { return false }

        if candidateTokens.count <= previousTokens.count {
            if containsTokenPhrase(haystack: previousTokens, needle: candidateTokens) {
                return true
            }
        } else if dropLongerCandidateContainingPrior,
                  containsTokenPhrase(haystack: candidateTokens, needle: previousTokens) {
            return true
        }

        let candidateSet = Set(candidateTokens)
        let previousSet = Set(previousTokens)
        let intersection = candidateSet.intersection(previousSet).count
        let shorter = min(candidateSet.count, previousSet.count)
        let longer = max(candidateSet.count, previousSet.count)
        guard shorter >= 5 else { return false }
        let containment = Double(intersection) / Double(shorter)
        let sizeRatio = Double(shorter) / Double(max(1, longer))
        return containment >= 0.86 && sizeRatio >= 0.62
    }

    private static func containsTokenPhrase(haystack: [String], needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        if needle.count == haystack.count { return haystack == needle }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    private static func tokenWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func hasSentenceTerminator(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    private static let danglingStartWords: Set<String> = [
        "and", "but", "or", "so", "because", "with", "to", "in", "on", "at", "of", "that", "is"
    ]

    private static let danglingEndWords: Set<String> = [
        "and", "but", "or", "because", "with", "to", "in", "on", "at", "of", "the", "a", "an",
        "is", "are", "was", "were", "that"
    ]
}
