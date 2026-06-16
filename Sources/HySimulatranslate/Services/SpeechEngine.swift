import Foundation
import AVFoundation
import CoreAudio

// MARK: - 🎙️ 音频采集层（AVAudioEngine 抓 mic → 转 int16 → 喂 Sherpa）
// 完全替代原 SFSpeechRecognizer 方案

final class SpeechEngine: NSObject, @unchecked Sendable {
    struct MicrophoneCheckResult: Equatable {
        let passed: Bool
        let deviceName: String
        let message: String
    }

    var currentVolume: Float {
        volumeLock.lock()
        defer { volumeLock.unlock() }
        return storedCurrentVolume
    }
    private(set) var micDeviceName: String = ""

    private let engine = AVAudioEngine()
    private let volumeLock = NSLock()
    private var storedCurrentVolume: Float = 0.0
    private var isRunning = false
    private var volumePollTask: Task<Void, Never>?

    // 回调
    typealias VolumeHandler = @Sendable (Float) -> Void
    private var onSamples: (@Sendable ([Float], Int32) -> Void)?

    func configure(onSamples: @escaping @Sendable ([Float], Int32) -> Void) {
        self.onSamples = onSamples
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default:
            return false
        }
    }

    func checkMicrophoneConnectivity() async -> MicrophoneCheckResult {
        guard await Self.requestMicrophoneAccess() else {
            micDeviceName = ""
            return MicrophoneCheckResult(
                passed: false,
                deviceName: "",
                message: "麦克风权限未授权，请在系统设置 > 隐私与安全性 > 麦克风中允许。"
            )
        }

        guard let defaultID = defaultInputDeviceID() else {
            micDeviceName = ""
            return MicrophoneCheckResult(passed: false, deviceName: "", message: "未找到默认输入设备")
        }

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            micDeviceName = ""
            return MicrophoneCheckResult(passed: false, deviceName: "", message: "麦克风输入格式不可用")
        }

        let name = deviceNameForID(defaultID) ?? "默认麦克风"
        micDeviceName = name
        return MicrophoneCheckResult(passed: true, deviceName: name, message: name)
    }

    // MARK: - 启动

    func start() throws {
        guard !isRunning else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(
                domain: "SpeechEngine",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "麦克风权限未授权"]
            )
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[SpeechEngine] native format: \(nativeFormat)")

        if let defaultID = defaultInputDeviceID() {
            micDeviceName = deviceNameForID(defaultID) ?? "Built-in Microphone"
        } else {
            micDeviceName = "Built-in Microphone"
        }
        print("[SpeechEngine] mic device: \(micDeviceName)")

        // 16kHz float32 转换
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else { throw NSError(domain: "SpeechEngine", code: 1) }

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw NSError(domain: "SpeechEngine", code: 2)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // RMS 音量
            if let floatData = buffer.floatChannelData {
                let ptr = floatData[0]
                let c = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<c { sum += ptr[i] * ptr[i] }
                self.setCurrentVolume(sqrt(sum / Float(max(1, c))))
            }

            // 转换为 16kHz float32
            let outCap = Int(buffer.frameLength)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outCap))
            else { return }
            var err: NSError?
            var inputProvided = false
            converter.convert(to: outBuf, error: &err) { _, outStatus in
                if inputProvided { outStatus.pointee = .noDataNow; return nil }
                inputProvided = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let floatPtr = outBuf.floatChannelData {
                let frameCnt = Int(outBuf.frameLength)
                let samples = Array(UnsafeBufferPointer(start: floatPtr[0], count: frameCnt))
                self.onSamples?(samples, 16000)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            isRunning = false
            throw error
        }
        print("[SpeechEngine] engine started, isRunning=\(engine.isRunning)")
    }

    // MARK: - 停止

    func stop() {
        isRunning = false
        volumePollTask?.cancel()
        volumePollTask = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        print("[SpeechEngine] stopped")
    }

    private func setCurrentVolume(_ volume: Float) {
        volumeLock.lock()
        storedCurrentVolume = volume
        volumeLock.unlock()
    }

    // MARK: - 设备查询

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID()
        var s = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &id) == noErr,
              id != AudioDeviceID(kAudioObjectUnknown)
        else { return nil }
        return id
    }

    private func deviceNameForID(_ id: AudioDeviceID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var s = UInt32(MemoryLayout<CFString?>.size)
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString?>.size,
            alignment: MemoryLayout<CFString?>.alignment
        )
        defer { pointer.deallocate() }

        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, pointer) == noErr,
              let name = pointer.load(as: CFString?.self)
        else { return nil }
        return name as String
    }
}
