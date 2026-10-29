import Foundation
import Security

/// Plugin secrets in the login keychain, one item per (plugin, key). The self-signed
/// signing certificate keeps the ACL stable across rebuilds.
enum Keychain {
    static let service = "cc.dotdot.cubi"

    static func get(plugin: String, key: String) -> String? {
        var query = base(plugin: plugin, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(plugin: String, key: String, value: String) -> Bool {
        let data = Data(value.utf8)
        var query = base(plugin: plugin, key: key)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(plugin: String, key: String) -> Bool {
        let status = SecItemDelete(base(plugin: plugin, key: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func base(plugin: String, key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(plugin).\(key)"]
    }
}
