import Foundation
import Security

class KeychainManager {
    static let shared = KeychainManager()
    static let providerKeysAggregateAccount = "provider_api_keys_v1"

    private let service = "com.hysimulatranslate.app"
    private let legacyAccount = "groq_api_key"

    func save(key: String) -> Bool {
        save(key: key, account: legacyAccount)
    }

    func save(key: String, account: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func load() -> String? {
        load(account: legacyAccount)
    }

    func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess, let data = dataTypeRef as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        delete(account: legacyAccount)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func saveProviderKeys(_ keys: [LLMProviderID: String]) {
        let encoded = Self.encodeProviderKeys(keys)
        _ = save(key: encoded, account: Self.providerKeysAggregateAccount)
    }

    func loadProviderKeys() -> [LLMProviderID: String] {
        Self.resolveProviderKeys(aggregate: load(account: Self.providerKeysAggregateAccount))
    }

    static func encodeProviderKeys(_ keys: [LLMProviderID: String]) -> String {
        let payload = providerKeysPayload(keys)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return encoded
    }

    static func decodeProviderKeys(_ encoded: String) -> [LLMProviderID: String]? {
        guard let data = encoded.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        var keys: [LLMProviderID: String] = [:]
        for (rawID, key) in payload {
            guard let providerID = LLMProviderID(rawValue: rawID) else { continue }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                keys[providerID] = trimmed
            }
        }
        return keys
    }

    static func providerKeysPayload(_ keys: [LLMProviderID: String]) -> [String: String] {
        var payload: [String: String] = [:]
        for provider in LLMProviderCatalog.allProviders {
            let key = keys[provider.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                payload[provider.id.rawValue] = key
            }
        }
        return payload
    }

    static func migrateLegacyProviderKeys(load: (String) -> String?) -> [LLMProviderID: String] {
        var keys: [LLMProviderID: String] = [:]
        for provider in LLMProviderCatalog.allProviders {
            if let key = load(provider.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                keys[provider.id] = key
            }
        }
        if keys[.groq] == nil,
           let legacyGroqKey = load("groq_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyGroqKey.isEmpty {
            keys[.groq] = legacyGroqKey
        }
        return keys
    }

    static func resolveProviderKeys(aggregate: String?) -> [LLMProviderID: String] {
        if let aggregate,
           let keys = decodeProviderKeys(aggregate) {
            return keys
        }

        return [:]
    }
}
