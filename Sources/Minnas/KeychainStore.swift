//
// Secrets (the OpenAI key) in the login keychain, one generic-password item
// per key: service = the bundle id, account = the key name
// (OPENAI_API_KEY).
//
// Deliberately the legacy file-based login keychain, not the data-
// protection keychain: the latter needs a keychain-access-groups
// entitlement, which a self-signed app can't carry. kSecAttrAccessible is
// left at its default for the same keychain (it only applies to the
// data-protection one). The item's ACL trusts the creating app's
// designated requirement, which the stable "Minnas Dev"
// identity keeps constant across rebuilds — so no prompt per rebuild.
//
// Only the bundled .app should call this: a bare `swift run` binary has a
// new signature on every build and would trigger an ACL prompt per read.
// Config/Settings enforce that; this type doesn't know about bundles.
//
// No caching and no shared state — every call is a fresh Security
// framework query, which is itself thread-safe.
//

import Foundation
import Security

struct KeychainError: Error, CustomStringConvertible, LocalizedError {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }

    var errorDescription: String? { description }
}

enum KeychainStore {
    static let service = AppInfo.bundleID

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// The stored value, or nil when there is no item for `key`.
    static func get(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Adds the item, or replaces its value when it already exists.
    static func set(_ key: String, _ value: String) throws {
        let data = Data(value.utf8)
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        // A label makes the item recognisable in Keychain Access.
        add[kSecAttrLabel as String] = "Minnas: \(key)"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw KeychainError(status: status) }
        let update = SecItemUpdate(
            baseQuery(key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard update == errSecSuccess else { throw KeychainError(status: update) }
    }

    /// Removes the item. Deleting an absent item is not an error.
    static func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
