import Foundation
import Security

/// Thin wrapper around the macOS Security framework's Keychain for a single
/// generic-password slot (service + account). Used by `LLMConfigStore` to
/// move the OpenAI-compatible API key out of UserDefaults (where it was
/// stored in plaintext in v0.3.x) and into the user's login keychain.
///
/// All public methods are safe to call from any thread — `SecItem*` APIs
/// are thread-safe.
enum KeychainStore {

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedData
        case status(OSStatus)

        var description: String {
            switch self {
            case .unexpectedData:
                return "Keychain returned an item in an unexpected format"
            case .status(let code):
                let msg = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
                return "Keychain error \(code): \(msg)"
            }
        }
    }

    /// Bundle-scoped service name. All VoiceTyping keychain items share this.
    static let service = "com.voicetyping.app"

    /// Account name for the OpenAI-compatible API key (the only secret we
    /// currently store). Future secrets should use distinct account names,
    /// not overload this one.
    static let apiKeyAccount = "openai-api-key"

    // MARK: - API key convenience wrappers

    static func readAPIKey() -> String? {
        do {
            return try read(account: apiKeyAccount)
        } catch {
            Log.llm.error("Keychain read failed for API key: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func writeAPIKey(_ key: String) throws {
        try write(key, account: apiKeyAccount)
    }

    static func deleteAPIKey() throws {
        try delete(account: apiKeyAccount)
    }

    // MARK: - Generic generic-password helpers

    /// Returns the stored value, or `nil` if no item exists.
    /// Throws on any error other than "item not found".
    static func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Upserts. If an item already exists for this account, updates it;
    /// otherwise adds a new one.
    static func write(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        let query = baseQuery(account: account)
        let updates: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // Not yet present — add it. Accessibility is `WhenUnlocked`:
            // API key is only needed while the user is actively dictating,
            // which implies the device is unlocked.
            var addAttrs = query
            addAttrs[kSecValueData as String] = data
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.status(addStatus)
            }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    /// No-op if the item doesn't exist.
    static func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
