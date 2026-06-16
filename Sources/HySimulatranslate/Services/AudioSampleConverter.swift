import AVFoundation
import CoreMedia
import Foundation

final class AudioSampleConverter {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceSignature: SourceSignature?

    init?(sampleRate: Double = 16_000) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        targetFormat = format
    }

    var targetSampleRate: Int32 {
        Int32(targetFormat.sampleRate)
    }

    func convert(buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if buffer.format.commonFormat == .pcmFormatFloat32,
           buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           let floatData = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
        }

        let signature = SourceSignature(format: buffer.format)
        if converter == nil || sourceSignature != signature {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            sourceSignature = signature
        }
        guard let converter else { return [] }

        let ratio = targetFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(max(1, Int(Double(buffer.frameLength) * ratio) + 64))
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return []
        }

        var error: NSError?
        var inputProvided = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, let floatData = outBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
    }

    func convert(sampleBuffer: CMSampleBuffer) -> [Float] {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return [] }

        var audioStreamDescription = streamDescription.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &audioStreamDescription) else {
            return []
        }

        var neededSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, neededSize > 0 else { return [] }

        let rawAudioBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: neededSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawAudioBufferList.deallocate() }

        let audioBufferList = rawAudioBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: audioBufferList,
            bufferListSize: neededSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return [] }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            bufferListNoCopy: UnsafePointer(audioBufferList),
            deallocator: nil
        ) else { return [] }
        pcmBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        return convert(buffer: pcmBuffer)
    }

    private struct SourceSignature: Equatable {
        let commonFormat: AVAudioCommonFormat
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let interleaved: Bool

        init(format: AVAudioFormat) {
            commonFormat = format.commonFormat
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            interleaved = format.isInterleaved
        }
    }
}
