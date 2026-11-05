import Foundation
import Security

enum KeyStore {
    private static let service = "local.translategap.deepseek"
    private static let account = "primary"
    // A rebuilt ad-hoc signature must not open a legacy Keychain ACL dialog
    // while the app starts or grades in the background.
    private static let noninteractive = SecKeychainSetUserInteractionAllowed(false)
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read() -> String? {
        guard noninteractive == errSecSuccess else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count >= 20, !key.contains("\n") else {
            throw AppFailure.message("请输入完整的 DeepSeek API Key。")
        }
        guard noninteractive == errSecSuccess else { throw AppFailure.message("钥匙串暂不可用，请解锁后重试。") }
        // On an explicit save, recreate only this app's entry so its ACL trusts
        // the current binary instead of retaining the previous local signature.
        let removed = SecItemDelete(query as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw AppFailure.message("钥匙串暂不可用，请解锁后重试。") }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "译隙 · DeepSeek API"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppFailure.message("钥匙串保存失败（\(status)）。") }
    }
}
