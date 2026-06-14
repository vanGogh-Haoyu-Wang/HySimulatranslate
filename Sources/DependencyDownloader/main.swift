import Foundation
import WhisperKit

@main
struct DependencyDownloader {
    static func main() async throws {
        let whisperModel = "large-v3-v20240930_626MB"
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.count == 2, arguments.first == "--whisper" else {
            fputs("usage: DependencyDownloader --whisper /path/to/openai_whisper-large-v3\n", stderr)
            throw ExitCode.failure
        }

        let destination = URL(fileURLWithPath: String(arguments.last!), isDirectory: true)
            .standardizedFileURL
        let downloaded = try await WhisperKit.download(
            variant: whisperModel,
            progressCallback: { progress in
                let percent = Int(progress.fractionCompleted * 100)
                print("Downloading WhisperKit \(whisperModel) \(percent)%")
            }
        )

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: downloaded, to: destination)
        print("WhisperKit model ready at \(destination.path)")
    }
}

enum ExitCode: Error {
    case failure
}
