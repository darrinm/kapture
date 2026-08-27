// Secrets live in the Keychain, never UserDefaults: the Anthropic key (naming) and, later, the
// share upload token. ThisDeviceOnly so a key never rides a backup to another Mac.
import Foundation
import Security

public enum Keychain {
    private static let service = "sh.kapture.app"

    public static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.shell.error("keychain write failed: \(status)") }
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    public static var anthropicKey: String? {
        get { get("anthropic-api-key") }
        set { set(newValue, for: "anthropic-api-key") }
    }

    /// Bearer token for kapture.sh. The server stores only its sha256, so this string is the
    /// single copy that can authorize a share — hence Keychain, not UserDefaults.
    public static var shareToken: String? {
        get { get("share-token") }
        set { set(newValue, for: "share-token") }
    }
}
