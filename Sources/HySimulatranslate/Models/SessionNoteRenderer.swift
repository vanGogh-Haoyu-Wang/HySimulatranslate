import Foundation

enum SessionNoteRenderer {
    static func render(
        course: CourseSubject,
        translationEnabled: Bool,
        items: [TranscriptionItem],
        finalSummary: String,
        format: NoteFileFormat = .text,
        date: Date = Date()
    ) -> String {
        switch format {
        case .markdown:
            renderMarkdown(
                course: course,
                translationEnabled: translationEnabled,
                items: items,
                finalSummary: finalSummary,
                date: date
            )
        case .text:
            renderText(
                course: course,
                translationEnabled: translationEnabled,
                items: items,
                finalSummary: finalSummary,
                date: date
            )
        }
    }

    private static func renderText(
        course: CourseSubject,
        translationEnabled: Bool,
        items: [TranscriptionItem],
        finalSummary: String,
        date: Date
    ) -> String {
        var content = """
        =========================================
        📚 HySimulatranslate Notes
        🎯 强化专项: \(course.name)
        📅 Date:   \(DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .long))
        =========================================

        逐句同传记录
        -----------------------------------------

        """

        var emittedEnglishLines: [String] = []
        for item in items.filter({ $0.zone == .history && $0.isVisible && $0.status == .done && !$0.isSystemMessage }) {
            let block = TranscriptDisplayBlock(item: item)
            if block.canInterleaveLineByLine {
                for idx in block.englishLines.indices {
                    guard shouldEmit(block.englishLines[idx], emittedEnglishLines: emittedEnglishLines) else { continue }
                    content += "\(block.englishLines[idx])\n"
                    emittedEnglishLines.append(block.englishLines[idx])
                    if translationEnabled {
                        content += "\(block.chineseLines[idx])\n"
                    }
                    content += "\n"
                }
            } else {
                let linesToEmit = block.englishLines.filter {
                    shouldEmit($0, emittedEnglishLines: emittedEnglishLines)
                }
                guard !linesToEmit.isEmpty else { continue }
                for englishLine in linesToEmit {
                    content += "\(englishLine)\n"
                    emittedEnglishLines.append(englishLine)
                }
                if translationEnabled, !block.chineseLines.isEmpty {
                    content += "\(block.chineseLines.joined(separator: " "))\n"
                }
                content += "\n"
            }
        }

        let summary = finalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        content += """
        最终中文总结
        -----------------------------------------
        \(summary.isEmpty ? "暂无总结" : summary)
        """
        return content
    }

    private static func renderMarkdown(
        course: CourseSubject,
        translationEnabled: Bool,
        items: [TranscriptionItem],
        finalSummary: String,
        date: Date
    ) -> String {
        var content = """
        # HySimulatranslate Notes

        **强化专项:** \(course.name)

        **Date:** \(DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .long))

        ---

        ## 逐句同传记录

        """

        var emittedEnglishLines: [String] = []
        for item in items.filter({ $0.zone == .history && $0.isVisible && $0.status == .done && !$0.isSystemMessage }) {
            let block = TranscriptDisplayBlock(item: item)
            if block.canInterleaveLineByLine {
                for idx in block.englishLines.indices {
                    guard shouldEmit(block.englishLines[idx], emittedEnglishLines: emittedEnglishLines) else { continue }
                    content += "\(block.englishLines[idx])\n"
                    emittedEnglishLines.append(block.englishLines[idx])
                    if translationEnabled {
                        content += "\(block.chineseLines[idx])\n"
                    }
                    content += "\n"
                }
            } else {
                let linesToEmit = block.englishLines.filter {
                    shouldEmit($0, emittedEnglishLines: emittedEnglishLines)
                }
                guard !linesToEmit.isEmpty else { continue }
                for englishLine in linesToEmit {
                    content += "\(englishLine)\n"
                    emittedEnglishLines.append(englishLine)
                }
                if translationEnabled, !block.chineseLines.isEmpty {
                    content += "\(block.chineseLines.joined(separator: " "))\n"
                }
                content += "\n"
            }
        }

        let summary = finalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        content += """
        ---

        ## 最终中文总结

        \(summary.isEmpty ? "暂无总结" : summary)
        """
        return content
    }

    private static func shouldEmit(_ englishLine: String, emittedEnglishLines: [String]) -> Bool {
        !emittedEnglishLines.contains {
            TranscriptOrganizer.isLikelyDuplicate(
                englishLine,
                of: $0,
                dropLongerCandidateContainingPrior: false
            )
        }
    }
}
