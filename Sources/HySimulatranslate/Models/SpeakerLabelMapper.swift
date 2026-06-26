import Foundation

struct SpeakerAudioSpan: Equatable, Sendable {
    let itemID: UUID
    let startSample: Int
    let endSample: Int
}

struct SpeakerDiarizationSegment: Equatable, Sendable {
    let rawSpeakerID: String
    let startSample: Int
    let endSample: Int
}

struct SpeakerLabelMapper: Sendable {
    private var itemLabels: [UUID: String] = [:]
    private var rawSpeakerLabels: [String: String] = [:]
    private var nextLabelIndex = 0

    mutating func assignLabels(
        for spans: [SpeakerAudioSpan],
        diarizationSegments: [SpeakerDiarizationSegment]
    ) -> [UUID: String] {
        let bestRawSpeakerByItem = bestRawSpeakerAssignments(spans: spans, segments: diarizationSegments)
        var itemIDsByRawSpeaker: [String: [UUID]] = [:]
        for (itemID, rawSpeakerID) in bestRawSpeakerByItem {
            itemIDsByRawSpeaker[rawSpeakerID, default: []].append(itemID)
        }

        for rawSpeakerID in itemIDsByRawSpeaker.keys.sorted() where rawSpeakerLabels[rawSpeakerID] == nil {
            let existingLabels = itemIDsByRawSpeaker[rawSpeakerID, default: []]
                .compactMap { itemLabels[$0] }
            if let stableLabel = mostCommonLabel(in: existingLabels) {
                rawSpeakerLabels[rawSpeakerID] = stableLabel
            } else {
                rawSpeakerLabels[rawSpeakerID] = makeNextLabel()
            }
        }

        for (itemID, rawSpeakerID) in bestRawSpeakerByItem {
            if let label = rawSpeakerLabels[rawSpeakerID] {
                itemLabels[itemID] = label
            }
        }

        return itemLabels
    }

    private func bestRawSpeakerAssignments(
        spans: [SpeakerAudioSpan],
        segments: [SpeakerDiarizationSegment]
    ) -> [UUID: String] {
        var assignments: [UUID: String] = [:]

        for span in spans {
            guard span.endSample > span.startSample else { continue }
            let bestSegment = segments.max { lhs, rhs in
                overlap(span, lhs) < overlap(span, rhs)
            }
            guard let bestSegment, overlap(span, bestSegment) > 0 else { continue }
            assignments[span.itemID] = bestSegment.rawSpeakerID
        }

        return assignments
    }

    private func overlap(_ span: SpeakerAudioSpan, _ segment: SpeakerDiarizationSegment) -> Int {
        max(0, min(span.endSample, segment.endSample) - max(span.startSample, segment.startSample))
    }

    private func mostCommonLabel(in labels: [String]) -> String? {
        let counts = labels.reduce(into: [String: Int]()) { partial, label in
            partial[label, default: 0] += 1
        }
        return counts.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }.first?.key
    }

    private mutating func makeNextLabel() -> String {
        defer { nextLabelIndex += 1 }
        return Self.label(for: nextLabelIndex)
    }

    private static func label(for index: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard index >= alphabet.count else { return String(alphabet[index]) }

        var value = index
        var scalars: [Character] = []
        repeat {
            scalars.insert(alphabet[value % alphabet.count], at: 0)
            value = value / alphabet.count - 1
        } while value >= 0
        return String(scalars)
    }
}
