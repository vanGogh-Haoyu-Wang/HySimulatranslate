import Foundation

struct StreamingAudioResampler: Sendable {
    let sourceRate: Int
    let targetRate: Int
    private var bufferedSamples: [Float] = []
    private var bufferStartInputIndex = 0
    private(set) var inputSampleCount = 0
    private(set) var outputSampleCount = 0

    init(sourceRate: Int, targetRate: Int) {
        precondition(sourceRate > 0 && targetRate > 0)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
    }

    mutating func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        bufferedSamples.append(contentsOf: samples)
        inputSampleCount += samples.count
        let targetOutputCount = Int64(inputSampleCount) * Int64(targetRate) / Int64(sourceRate)
        let count = max(0, Int(targetOutputCount) - outputSampleCount)
        guard count > 0 else { return [] }

        var result: [Float] = []
        result.reserveCapacity(count)
        for outputIndex in outputSampleCount..<(outputSampleCount + count) {
            let inputPosition = Double(outputIndex) * Double(sourceRate) / Double(targetRate)
            let lowerGlobal = Int(inputPosition.rounded(.down))
            let upperGlobal = min(lowerGlobal + 1, inputSampleCount - 1)
            let lower = max(0, min(bufferedSamples.count - 1, lowerGlobal - bufferStartInputIndex))
            let upper = max(0, min(bufferedSamples.count - 1, upperGlobal - bufferStartInputIndex))
            let fraction = Float(inputPosition - Double(lowerGlobal))
            result.append(bufferedSamples[lower] * (1 - fraction) + bufferedSamples[upper] * fraction)
        }
        outputSampleCount += count

        let nextInputPosition = Double(outputSampleCount) * Double(sourceRate) / Double(targetRate)
        let retainFromGlobal = max(bufferStartInputIndex, Int(nextInputPosition.rounded(.down)) - 1)
        let discardCount = min(bufferedSamples.count, retainFromGlobal - bufferStartInputIndex)
        if discardCount > 0 {
            bufferedSamples.removeFirst(discardCount)
            bufferStartInputIndex += discardCount
        }
        return result
    }
}
