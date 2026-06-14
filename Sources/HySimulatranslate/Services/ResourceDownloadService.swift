import Foundation

enum ResourceDownloadError: LocalizedError {
    case invalidArchive(String)
    case extractionFailed(String)
    case missingDownloadedModel(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail):
            return "下载的模型压缩包无效：\(detail)"
        case .extractionFailed(let detail):
            return "模型解压失败：\(detail)"
        case .missingDownloadedModel(let detail):
            return "下载完成但模型文件不完整：\(detail)"
        }
    }
}

enum ResourceDownloadService {
    typealias ProgressHandler = @Sendable (Double, String) -> Void

    static let sherpaModelArchiveURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(AppResourceLocator.sherpaModelFolderName).tar.bz2"
    )!

    static func ensureSherpaModel(
        supportDirectory: URL = AppResourceLocator.defaultSupportDirectory(),
        bundledPayloadDirectory: URL? = AppResourceLocator.bundledPayloadDirectory(),
        archiveURL: URL = sherpaModelArchiveURL,
        onProgress: ProgressHandler? = nil
    ) async throws -> URL {
        if let existing = AppResourceLocator.sherpaModelDirectory(
            supportDirectory: supportDirectory,
            bundledPayloadDirectory: bundledPayloadDirectory
        ), AppResourceLocator.isUsableSherpaModelDirectory(existing) {
            onProgress?(1.0, "Sherpa 模型已就绪")
            return existing
        }

        let destination = supportDirectory.appendingRelativePathForResourceDownload(
            AppResourceLocator.sherpaModelRelativePath
        )
        let archive = supportDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("\(AppResourceLocator.sherpaModelFolderName).tar.bz2")
        let staging = supportDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Sherpa-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        onProgress?(0.05, "正在下载 Sherpa 模型 (~310MB)...")
        let downloadedArchive = try await downloadFile(from: archiveURL)
        try replaceItem(at: archive, with: downloadedArchive)

        onProgress?(0.75, "正在解压 Sherpa 模型...")
        try extractTarBzip2(archive: archive, to: staging)

        let extracted = staging.appendingPathComponent(AppResourceLocator.sherpaModelFolderName, isDirectory: true)
        guard AppResourceLocator.isUsableSherpaModelDirectory(extracted) else {
            throw ResourceDownloadError.missingDownloadedModel(extracted.path)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: extracted, to: destination)
        onProgress?(1.0, "Sherpa 模型已下载")
        return destination
    }

    private static func downloadFile(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ResourceDownloadError.invalidArchive(response.description)
        }
        return temporaryURL
    }

    private static func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func extractTarBzip2(archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", destination.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "tar exited with \(process.terminationStatus)"
            throw ResourceDownloadError.extractionFailed(output)
        }
    }
}

private extension URL {
    func appendingRelativePathForResourceDownload(_ relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { url, component in
                url.appendingPathComponent(String(component), isDirectory: true)
            }
    }
}
