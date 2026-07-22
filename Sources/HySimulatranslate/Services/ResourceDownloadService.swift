import CryptoKit
import Foundation

enum ResourceDownloadError: LocalizedError {
    case invalidArchive(String)
    case integrityMismatch(String)
    case extractionFailed(String)
    case missingDownloadedModel(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail):
            return "下载的模型压缩包无效：\(detail)"
        case .integrityMismatch(let detail):
            return "下载文件完整性校验失败：\(detail)"
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
    static let vadModelURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(AppResourceLocator.vadModelFileName)"
    )!
    static let sherpaModelArchiveSHA256 = "639e25b578e9e997131402199419c13a941f8e4e198e2da1ce57dbf5cf401282"
    static let sherpaModelArchiveBytes: Int64 = 310_414_022
    static let vadModelSHA256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
    static let vadModelBytes: Int64 = 643_854

    static func ensureSherpaModel(
        supportDirectory: URL = AppResourceLocator.defaultSupportDirectory(),
        bundledPayloadDirectory: URL? = AppResourceLocator.bundledPayloadDirectory(),
        archiveURL: URL = sherpaModelArchiveURL,
        expectedSHA256: String? = sherpaModelArchiveSHA256,
        expectedBytes: Int64? = sherpaModelArchiveBytes,
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
        try validate(downloadedArchive, expectedSHA256: expectedSHA256, expectedBytes: expectedBytes)
        try replaceItem(at: archive, with: downloadedArchive)

        onProgress?(0.75, "正在解压 Sherpa 模型...")
        try validateArchiveEntries(archive)
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

    static func ensureVADModel(
        supportDirectory: URL = AppResourceLocator.defaultSupportDirectory(),
        bundledPayloadDirectory: URL? = AppResourceLocator.bundledPayloadDirectory(),
        fileURL: URL = vadModelURL,
        expectedSHA256: String? = vadModelSHA256,
        expectedBytes: Int64? = vadModelBytes,
        onProgress: ProgressHandler? = nil
    ) async throws -> URL {
        if let existing = AppResourceLocator.vadModelFile(
            supportDirectory: supportDirectory,
            bundledPayloadDirectory: bundledPayloadDirectory
        ) {
            onProgress?(1.0, "VAD 模型已就绪")
            return existing
        }

        return try await ensureSingleFileModel(
            relativePath: AppResourceLocator.vadModelRelativePath,
            sourceURL: fileURL,
            expectedSHA256: expectedSHA256,
            expectedBytes: expectedBytes,
            supportDirectory: supportDirectory,
            statusName: "VAD",
            onProgress: onProgress
        )
    }

    private static func ensureSingleFileModel(
        relativePath: String,
        sourceURL: URL,
        expectedSHA256: String?,
        expectedBytes: Int64?,
        supportDirectory: URL,
        statusName: String,
        onProgress: ProgressHandler?
    ) async throws -> URL {
        let destination = supportDirectory.appendingRelativePathForResourceDownload(relativePath)
        let downloads = supportDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let temporaryDestination = downloads.appendingPathComponent(destination.lastPathComponent)

        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        onProgress?(0.1, "正在下载 \(statusName) 模型...")
        let downloaded = try await downloadFile(from: sourceURL)
        try validate(downloaded, expectedSHA256: expectedSHA256, expectedBytes: expectedBytes)
        try replaceItem(at: temporaryDestination, with: downloaded)
        try replaceItem(at: destination, with: temporaryDestination)
        onProgress?(1.0, "\(statusName) 模型已下载")
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

    static func validate(_ url: URL, expectedSHA256: String?, expectedBytes: Int64?) throws {
        if let expectedBytes {
            let actual = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard actual == expectedBytes else {
                throw ResourceDownloadError.integrityMismatch("大小为 \(actual)，预期 \(expectedBytes) bytes")
            }
        }
        if let expectedSHA256 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw ResourceDownloadError.integrityMismatch("SHA-256 为 \(actual)，与资源清单不符")
            }
        }
    }

    static func validateArchiveEntries(_ archive: URL) throws {
        let output = try runTar(arguments: ["-tjf", archive.path])
        for path in output.split(separator: "\n").map(String.init) {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !components.contains("..") else {
                throw ResourceDownloadError.invalidArchive("包含不安全路径：\(path)")
            }
        }
        let verbose = try runTar(arguments: ["-tvjf", archive.path])
        guard !verbose.contains(" -> "), !verbose.contains(" link to ") else {
            throw ResourceDownloadError.invalidArchive("压缩包包含链接")
        }
    }

    private static func extractTarBzip2(archive: URL, to destination: URL) throws {
        _ = try runTar(arguments: ["-xjf", archive.path, "-C", destination.path])
    }

    private static func runTar(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? "tar exited with \(process.terminationStatus)"
            throw ResourceDownloadError.extractionFailed(output)
        }
        return String(data: data, encoding: .utf8) ?? ""
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
