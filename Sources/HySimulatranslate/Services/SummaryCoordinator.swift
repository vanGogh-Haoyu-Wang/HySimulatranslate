import Foundation

enum SummaryTemplateError: Error { case invalidStructure }

enum SummaryPromptRenderer {
    static func make(template: SummaryTemplateRecord, previousSummary: String, content: String, isFinal: Bool) throws -> String {
        guard let data = template.structureJSON.data(using: .utf8),
              let sections = try JSONSerialization.jsonObject(with: data) as? [String] else { throw SummaryTemplateError.invalidStructure }
        return """
        \(template.systemInstruction)
        输出语言：\(template.language)
        这是\(isFinal ? "最终总结" : "实时更新")。只使用提供的内容，不得补充外部知识或臆造身份。
        按以下章节组织；无内容章节可以省略：\(sections.joined(separator: "、"))

        已有总结：
        \(previousSummary.isEmpty ? "无" : previousSummary)

        内容：
        \(content)
        """
    }
}

enum SummaryInputRenderer {
    static func render(items: [TranscriptionItem], speakerAliases: [String: String]) -> String {
        items.filter { $0.zone == .history && $0.isVisible && $0.status == .done && !$0.isSystemMessage }.map { item in
            let label = item.speakerID.flatMap { speakerAliases[$0] } ?? item.speakerID.map { SpeakerDisplayName.displayName(for: $0) }
            return [label.map { "\($0): \(item.english)" } ?? item.english, item.chinese].compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

final class SummaryCoordinator {
    private let transcripts: TranscriptRepository
    init(transcripts: TranscriptRepository) { self.transcripts = transcripts }

    func generate(
        meetingID: UUID, transcriptRevisionID: UUID, translationRevisionID: UUID?,
        template: SummaryTemplateRecord, provider: String, model: String,
        previousSummary: String = "", sourceContent: String = "", isFinal: Bool = true,
        generator: (String) async throws -> String?
    ) async throws -> SummaryRevisionRecord {
        let prompt = try SummaryPromptRenderer.make(template: template, previousSummary: previousSummary, content: sourceContent, isFinal: isFinal)
        let body: String?
        let errorMessage: String?
        do {
            body = try await generator(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = (body ?? "").isEmpty ? "摘要服务未返回有效内容" : nil
        } catch {
            body = nil
            errorMessage = error.localizedDescription
        }
        let succeeded = !(body ?? "").isEmpty
        let revision = SummaryRevisionRecord(meetingID: meetingID, transcriptRevisionID: transcriptRevisionID, translationRevisionID: translationRevisionID, templateID: template.id, provider: provider, model: model, body: body ?? "", status: succeeded ? .succeeded : .failed, errorMessage: errorMessage)
        try transcripts.insert(revision)
        if succeeded { try transcripts.setCurrentSummaryRevision(revision.id, for: meetingID) }
        return revision
    }
}
