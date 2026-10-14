import Foundation
import Security

enum Keychain {
    private static let service = "TasksBar"
    private static let account = "google-oauth"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ data: Data) {
        // Update in place: no window without a token if saving fails.
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            if status != errSecSuccess { NSLog("Keychain update failed: \(status)") }
            return
        }
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(q as CFDictionary, nil)
        if add != errSecSuccess { NSLog("Keychain add failed: \(add)") }
    }

    static func load() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

/// Token storage abstraction (the real Keychain in the app, memory in tests).
protocol TokenStorage {
    func load() -> Data?
    func save(_ data: Data)
    func delete()
}

struct KeychainStorage: TokenStorage {
    func load() -> Data? { Keychain.load() }
    func save(_ data: Data) { Keychain.save(data) }
    func delete() { Keychain.delete() }
}
