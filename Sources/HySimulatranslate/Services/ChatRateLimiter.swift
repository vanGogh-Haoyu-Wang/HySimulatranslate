import Foundation

actor ChatRateLimiter {
    static let shared = ChatRateLimiter()

    nonisolated static let targetRPM = 22
    nonisolated static let hardRPM = 25
    nonisolated static let minimumRequestInterval: TimeInterval = 2.8
    nonisolated static let rateLimitBackoff: TimeInterval = 15.0

    private var requestTimesByScope: [String: [Date]] = [:]
    private var backoffUntilByScope: [String: Date] = [:]

    func waitTurn(for credential: LLMProviderCredential?) async {
        guard let credential, credential.provider.id == .groq else { return }
        await waitTurn(scope: scope(for: credential))
    }

    func waitTurn(scope: String, now: @autoclosure () -> Date = Date()) async {
        while true {
            let current = now()
            prune(scope: scope, now: current)

            if let backoffUntil = backoffUntilByScope[scope], backoffUntil > current {
                await sleep(seconds: backoffUntil.timeIntervalSince(current))
                continue
            }

            let requestTimes = requestTimesByScope[scope] ?? []
            let lastRequest = requestTimes.last
            let intervalWait = lastRequest.map {
                max(0, Self.minimumRequestInterval - current.timeIntervalSince($0))
            } ?? 0
            let rpmWait: TimeInterval
            if requestTimes.count >= Self.hardRPM, let oldest = requestTimes.first {
                rpmWait = max(0, 60.0 - current.timeIntervalSince(oldest))
            } else {
                rpmWait = 0
            }

            let wait = max(intervalWait, rpmWait)
            if wait > 0 {
                await sleep(seconds: wait)
                continue
            }

            requestTimesByScope[scope, default: []].append(current)
            return
        }
    }

    func noteHTTPStatus(_ statusCode: Int, for credential: LLMProviderCredential?) {
        guard let credential, credential.provider.id == .groq else { return }
        guard statusCode == 429 else { return }
        let scope = scope(for: credential)
        backoffUntilByScope[scope] = Date().addingTimeInterval(Self.rateLimitBackoff)
    }

    func currentRPM(scope: String, now: Date = Date()) -> Int {
        prune(scope: scope, now: now)
        return requestTimesByScope[scope, default: []].count
    }

    nonisolated static func shouldUseConservativeBatching(
        currentRPM: Int,
        queueDepth: Int,
        recentlyRateLimited: Bool
    ) -> Bool {
        recentlyRateLimited || currentRPM >= targetRPM || queueDepth >= 6
    }

    nonisolated static func targetBatchSize(conservative: Bool) -> Int {
        conservative ? 5 : 3
    }

    private func scope(for credential: LLMProviderCredential) -> String {
        "\(credential.provider.id.rawValue):\(credential.provider.modelName)"
    }

    private func prune(scope: String, now: Date) {
        requestTimesByScope[scope, default: []].removeAll {
            now.timeIntervalSince($0) >= 60.0
        }
        if let backoffUntil = backoffUntilByScope[scope], backoffUntil <= now {
            backoffUntilByScope.removeValue(forKey: scope)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0.05, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
