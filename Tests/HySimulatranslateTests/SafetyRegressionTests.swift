import CryptoKit
import XCTest
@testable import HySimulatranslate

private final class SummaryURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class SafetyRegressionTests: XCTestCase {
    func testOmniRouteSummaryUsesBearerAutoAndOpenAIResponseShape() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryURLProtocolStub.self]
        SummaryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://router.example/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"choices":[{"message":{"content":"有效摘要"}}]}"#.utf8))
        }
        let provider = try XCTUnwrap(LLMProviderCatalog.omniRouteSummaryProvider(baseURL: "https://router.example/v1"))
        let credential = LLMProviderCredential(provider: provider, apiKey: "secret")
        let request = OmniRouteSummaryService.makeRequest(credential: credential, prompt: "content", maxTokens: 20, timeout: 1)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "auto")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let service = OmniRouteSummaryService(session: URLSession(configuration: configuration))
        let summary = try await service.summarize(
            prompt: "content",
            credential: credential,
            isFinal: false
        )
        XCTAssertEqual(summary, "有效摘要")
    }

    func testOmniRouteErrorMessageParsesAuthenticationFailure() {
        let data = Data(#"{"error":{"message":"Invalid API key","type":"authentication_error"}}"#.utf8)
        XCTAssertEqual(OmniRouteSummaryService.errorMessage(from: data), "Invalid API key")
    }

    func testSameLanguageTranslationDoesNotCallACloudProvider() async {
        let result = await TranslationService().robustTranslate(
            "原文",
            sourceLanguage: "zh",
            targetLanguage: "zh",
            groqCredential: nil
        )
        XCTAssertEqual(result, "原文")
    }

    func testNoteWriterNeverLetsOlderSnapshotReplaceNewerSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = NoteWriteCoordinator()
        _ = await writer.write(content: "new", to: url, revision: 2)
        let staleResult = await writer.write(content: "old", to: url, revision: 1)
        XCTAssertEqual(staleResult, .skipped)
        XCTAssertEqual(try String(contentsOf: url), "new")
    }

    func testAudioPipelineBufferRemainsBoundedAcrossLongInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try SessionAudioPipeline(
            sessionID: UUID(), rootDirectory: root,
            enabledSources: [.microphone, .systemAudio], maximumAlignmentLatency: 0.5
        )
        let chunk = Array(repeating: Float(0.1), count: 1_600)
        for index in 0..<120 {
            _ = try pipeline.accept(.init(
                source: .microphone, samples: chunk, sampleRate: 16_000,
                sessionStartTime: Double(index) * 0.1
            ))
            XCTAssertLessThanOrEqual(pipeline.bufferedSampleCount, 9_600)
        }
    }

    func testResourceIntegrityValidationAcceptsExpectedHashAndRejectsMismatch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("integrity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("verified".utf8)
        try data.write(to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try ResourceDownloadService.validate(url, expectedSHA256: hash, expectedBytes: Int64(data.count)))
        XCTAssertThrowsError(try ResourceDownloadService.validate(url, expectedSHA256: String(repeating: "0", count: 64), expectedBytes: nil))
    }
}
