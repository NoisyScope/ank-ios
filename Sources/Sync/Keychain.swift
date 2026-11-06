import Foundation
import Security

/// Stores the sync token, which grants access to the user's AnkiWeb account.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "anki.sync",
        kSecAttrAccount as String: "hkey",
    ]

    static func get() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Returns false if the token could not be stored, so callers can tell the user.
    static func set(_ value: String) -> Bool {
        delete()
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { log("keychain save failed: \(status)") }
        return status == errSecSuccess
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}
