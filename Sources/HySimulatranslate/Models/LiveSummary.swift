import Foundation

struct LiveSummaryCursor {
    static let defaultTriggerInterval = 8

    private(set) var summarizedCount = 0
    private var failedAtCount: Int?
    let triggerInterval: Int

    init(triggerInterval: Int = Self.defaultTriggerInterval) {
        self.triggerInterval = triggerInterval
    }

    mutating func pendingRange(totalCount: Int) -> Range<Int>? {
        if totalCount < summarizedCount {
            summarizedCount = 0
            failedAtCount = nil
        }
        if let failedAtCount, totalCount - failedAtCount < triggerInterval {
            return nil
        }
        guard totalCount - summarizedCount >= triggerInterval else { return nil }
        return summarizedCount..<totalCount
    }

    mutating func markSummarized(upTo count: Int) {
        summarizedCount = max(0, count)
        failedAtCount = nil
    }

    mutating func markFailed(at count: Int) {
        failedAtCount = max(0, count)
    }

    mutating func reset() {
        summarizedCount = 0
        failedAtCount = nil
    }
}

enum LiveSummaryPrompt {
    static func make(previousSummary: String, newContent: String) -> String {
        """
        任务：根据“已有中文总结”和“新增历史墙内容”，更新截至目前为止的中文会议/口播总结。

        严格规则：
        1. 只输出中文。
        2. 只使用提供的内容，不得补充外部知识。
        3. 不要预测接下来会讲什么。
        4. 不要把内容机械翻译成零散列点，要整理成能看懂上下文的中文纪要。
        5. 如果内容中能判断人物或角色，请写清谁提出了什么观点、问题、要求或担忧，谁回答了什么，以及双方是否有不同观点；如果无法判断身份，使用“发言者A/发言者B”“提问者/回答者”等中性称呼，不要臆造身份。
        6. 保留任务、结论、原因、数字、术语、人物要求、承诺、反对意见和下一步安排。
        7. 如果已有总结为空，就直接根据新增内容生成总结。
        8. 输出 4 到 8 条中文信息单元，可以是短段落或要点；不要写标题，不要写英文原文。
        9. 不要写“以下是”“基于提供的内容”等引导语。

        已有中文总结：
        \(previousSummary.isEmpty ? "无" : previousSummary)

        新增历史墙内容：
        \(newContent)
        """
    }

    static func makeFinalDetailed(previousSummary: String, fullContent: String) -> String {
        """
        任务：根据整场“逐句同传记录”和已有实时总结，生成最终详细中文总结。

        严格规则：
        1. 只输出中文，只使用提供的逐句记录和已有总结，不得补充外部知识。
        2. 这是最终详细中文总结，可以比实时摘要更完整，但不要臆造身份、姓名、因果或结论。
        3. 如果能从内容判断双人口播、采访或多人会议关系，请区分人物/角色与观点：谁提出问题、观点、要求或担忧，谁回答、接受、补充或提出不同观点。
        4. 如果无法判断具体身份，用“发言者A/发言者B”“提问者/回答者”“主持人/受访者”等中性称呼，并说明仅基于上下文判断。
        5. 保留重要事实、数字、术语、决定、待办事项、争议点、原因和约束条件。
        6. 忽略明显重复、误识别、空白、寒暄噪声和与主题无关的系统状态。
        7. 可使用以下小标题；没有内容的小标题可以省略：核心脉络、人物/角色与观点、问题与回答、分歧或补充观点、重要事实与数字、要求与后续事项。
        8. 不要写英文原文，不要写“以下是”“基于提供的内容”等引导语。

        已有实时总结：
        \(previousSummary.isEmpty ? "无" : previousSummary)

        逐句同传记录：
        \(fullContent)
        """
    }
}
