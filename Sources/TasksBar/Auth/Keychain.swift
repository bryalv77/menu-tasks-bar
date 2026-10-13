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
        // Update in place: no hay ventana sin token si falla el guardado.
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            if status != errSecSuccess { NSLog("Keychain update falló: \(status)") }
            return
        }
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(q as CFDictionary, nil)
        if add != errSecSuccess { NSLog("Keychain add falló: \(add)") }
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

/// Abstracción del almacenamiento de tokens (el Keychain real en la app, memoria en tests).
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
