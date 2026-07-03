import Foundation
import Security

/// 极简 Keychain 封装（generic password）：敏感凭据（如 LLM API Key）存钥匙串，
/// 不落 UserDefaults（`com.vowky.app.plist` 任何本地进程可读）。
/// 同一签名身份的 app 读写自己创建的条目不会触发系统弹窗。
enum KeychainStore {
    private static let service = "com.vowky.app"

    static func string(forKey key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写入（存在则更新）。空字符串等价于删除，避免留下空条目。
    static func set(_ value: String, forKey key: String) {
        guard !value.isEmpty else {
            remove(forKey: key)
            return
        }
        guard let data = value.data(using: .utf8) else { return }
        var query = baseQuery(key: key)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func remove(forKey key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
