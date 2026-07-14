import Foundation
import WhisperKit

@main
struct DependencyDownloader {
    static func main() async throws {
        let whisperModel = "large-v3-v20240930_626MB"
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.count == 2, arguments.first == "--whisper-download-base" else {
            fputs("usage: DependencyDownloader --whisper-download-base /path/to/Models/WhisperKit\n", stderr)
            throw ExitCode.failure
        }

        let downloadBase = URL(fileURLWithPath: String(arguments.last!), isDirectory: true)
            .standardizedFileURL
        let downloaded = try await WhisperKit.download(
            variant: whisperModel,
            downloadBase: downloadBase,
            progressCallback: { progress in
                let percent = Int(progress.fractionCompleted * 100)
                print("Downloading WhisperKit \(whisperModel) \(percent)%")
            }
        )

        print("WhisperKit model ready at \(downloaded.path)")
    }
}

enum ExitCode: Error {
    case failure
}
