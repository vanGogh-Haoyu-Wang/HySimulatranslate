import Foundation

enum SpeakerDisplayName {
    static func displayName(for speakerID: String?) -> String {
        let normalized = speakerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return "发言者 ?"
        }
        return "发言者 \(normalized)"
    }
}

struct TranslationOnlyHistoryBlock: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let speakerID: String?
    var text: String
    var sourceIDs: [String]

    var speakerDisplayName: String {
        SpeakerDisplayName.displayName(for: speakerID)
    }
}

enum TranslationOnlyHistoryBuilder {
    static func systemMessages(from items: [TranscriptionItem]) -> [TranscriptionItem] {
        items.filter { $0.isVisible && $0.isSystemMessage && $0.status == .done }
    }

    static func blocks(from items: [TranscriptionItem]) -> [TranslationOnlyHistoryBlock] {
        var blocks: [TranslationOnlyHistoryBlock] = []

        for item in items {
            guard item.isVisible,
                  !item.isSystemMessage,
                  item.status == .done,
                  let chinese = item.chinese?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !chinese.isEmpty
            else { continue }

            let sourceID = item.id.uuidString
            if let lastIndex = blocks.indices.last,
               blocks[lastIndex].speakerID == item.speakerID {
                blocks[lastIndex].text = joinChinese(blocks[lastIndex].text, chinese)
                blocks[lastIndex].sourceIDs.append(sourceID)
                blocks[lastIndex] = TranslationOnlyHistoryBlock(
                    id: blocks[lastIndex].sourceIDs.joined(separator: "+"),
                    speakerID: blocks[lastIndex].speakerID,
                    text: blocks[lastIndex].text,
                    sourceIDs: blocks[lastIndex].sourceIDs
                )
            } else {
                blocks.append(
                    TranslationOnlyHistoryBlock(
                        id: sourceID,
                        speakerID: item.speakerID,
                        text: chinese,
                        sourceIDs: [sourceID]
                    )
                )
            }
        }

        return blocks
    }

    private static func joinChinese(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        return left + right
    }
}
