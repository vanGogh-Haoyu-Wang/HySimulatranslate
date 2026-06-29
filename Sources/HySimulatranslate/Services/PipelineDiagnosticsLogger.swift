import Darwin
import Foundation

struct PipelineDiagnosticsSnapshot: Equatable, Sendable {
    let timestamp: TimeInterval
    let whisperQueue: Int
    let llmQueue: Int
    let pendingPCMBytes: Int
    let loadState: RefinementLoadState
    let speakerDiarizationActive: Bool
    let residentMemoryBytes: UInt64

    var logLine: String {
        let residentMB = Double(residentMemoryBytes) / 1_048_576.0
        return String(
            format: "t=%.3f W=%d L=%d pcmBytes=%d load=%@ speaker=%@ residentMB=%.1f",
            timestamp,
            whisperQueue,
            llmQueue,
            pendingPCMBytes,
            loadState.shortTitle,
            speakerDiarizationActive ? "active" : "idle",
            residentMB
        )
    }
}

final class PipelineDiagnosticsLogger: @unchecked Sendable {
    private let logURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    init(
        logURL: URL = PipelineDiagnosticsLogger.defaultLogURL(),
        maxBytes: Int = 1_000_000
    ) {
        self.logURL = logURL
        self.maxBytes = maxBytes
    }

    func record(_ snapshot: PipelineDiagnosticsSnapshot) {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue >= maxBytes {
            try? FileManager.default.removeItem(at: logURL)
        }

        let data = Data((snapshot.logLine + "\n").utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    static func defaultLogURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("HySimulatranslate", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("pipeline.log")
    }
}
