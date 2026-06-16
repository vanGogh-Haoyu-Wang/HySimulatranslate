import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct CheckResult: Equatable {
        let passed: Bool
        let sourceName: String
        let message: String
    }

    private let sampleQueue = DispatchQueue(label: "com.hysimulatranslate.system-audio.samples")
    private let converter = AudioSampleConverter()
    private var stream: SCStream?
    private var onSamples: (@Sendable ([Float], Int32) -> Void)?
    private var isRunning = false

    static func availableApplicationSources() async -> [AudioCaptureSource] {
        []
    }

    func checkConnectivity(source: AudioCaptureSource) async -> CheckResult {
        let effectiveSource = Self.normalizedSource(source)
        do {
            try await start(source: effectiveSource) { _, _ in }
            try? await Task.sleep(nanoseconds: 250_000_000)
            await stop()
            return CheckResult(
                passed: true,
                sourceName: effectiveSource.statusTitle,
                message: "\(effectiveSource.statusTitle) 可用"
            )
        } catch {
            await stop()
            return CheckResult(
                passed: false,
                sourceName: effectiveSource.statusTitle,
                message: Self.permissionMessage(for: effectiveSource, error: error)
            )
        }
    }

    func start(source: AudioCaptureSource, onSamples: @escaping @Sendable ([Float], Int32) -> Void) async throws {
        if isRunning {
            await stop()
        }
        guard let converter else {
            throw NSError(
                domain: "SystemAudioCaptureEngine",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "无法创建系统音频转换器"]
            )
        }

        let effectiveSource = Self.normalizedSource(source)
        self.onSamples = onSamples
        let content = try await Self.systemAudioContent()
        guard let display = content.displays.first else {
            throw NSError(
                domain: "SystemAudioCaptureEngine",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "未找到可采集的显示器"]
            )
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = Int(converter.targetSampleRate)
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()
        stream = newStream
        isRunning = true
        print("[SystemAudioCaptureEngine] started: \(effectiveSource.statusTitle)")
    }

    func stop() async {
        guard let stream else {
            isRunning = false
            onSamples = nil
            return
        }
        do {
            try await stream.stopCapture()
        } catch {
            print("[SystemAudioCaptureEngine] stop failed: \(error.localizedDescription)")
        }
        self.stream = nil
        isRunning = false
        onSamples = nil
        print("[SystemAudioCaptureEngine] stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning, let converter else { return }
        let samples = converter.convert(sampleBuffer: sampleBuffer)
        guard !samples.isEmpty else { return }
        onSamples?(samples, converter.targetSampleRate)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[SystemAudioCaptureEngine] stream stopped with error: \(error.localizedDescription)")
        isRunning = false
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func systemAudioContent() async throws -> SCShareableContent {
        if #available(macOS 14.4, *) {
            let currentProcessContent = try await SCShareableContent.currentProcess
            if !currentProcessContent.displays.isEmpty {
                return currentProcessContent
            }
        }
        return try await shareableContent()
    }

    private static func normalizedSource(_ source: AudioCaptureSource) -> AudioCaptureSource {
        source.kind == .applicationAudio ? .systemAudio : source
    }

    static func permissionMessage(for source: AudioCaptureSource, error: Error) -> String {
        let detail = error.localizedDescription
        let base = "电脑音频未授权，请在系统设置 > 隐私与安全性 > 屏幕与系统音频录制 / 仅系统录音中允许。"
        let localBuildHint = "本地未签名构建可能需要重新授权本 app。"
        return "\(source.statusTitle): \(base)\(localBuildHint)\(detail.isEmpty ? "" : "（\(detail)）")"
    }
}
