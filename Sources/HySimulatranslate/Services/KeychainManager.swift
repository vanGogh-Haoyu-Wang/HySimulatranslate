import Foundation
import Security

class KeychainManager {
    static let shared = KeychainManager()
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
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
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
        for provider in LLMProviderCatalog.allProviders {
            let key = keys[provider.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                delete(account: provider.keychainAccount)
            } else {
                _ = save(key: key, account: provider.keychainAccount)
            }
        }
    }

    func loadProviderKeys() -> [LLMProviderID: String] {
        var keys: [LLMProviderID: String] = [:]
        for provider in LLMProviderCatalog.allProviders {
            if let key = load(account: provider.keychainAccount), !key.isEmpty {
                keys[provider.id] = key
            }
        }
        return keys
    }
}
