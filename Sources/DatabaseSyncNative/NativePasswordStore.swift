import Foundation
import Security

enum NativePasswordStore {
    private static let service = "dev.adityadarma.dbsync.connection-password"
    private static let legacyServices = ["dev.adityadarma.tableplus.dbsync.connection-password"]

    /// Reads the current credential first, then migrates credentials saved by
    /// earlier builds that were keyed by the TablePlus plist record ID.
    static func password(for connectionID: String, legacyConnectionIDs: [String] = []) -> String? {
        let accounts = unique([connectionID] + legacyConnectionIDs)
        let services = unique([service] + legacyServices)
        for serviceName in services {
            for account in accounts {
                guard let password = password(service: serviceName, account: account) else { continue }
                if serviceName != service || account != connectionID {
                    try? save(password, for: connectionID)
                }
                return password
            }
        }
        return nil
    }

    private static func password(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for connectionID: String) throws {
        guard !password.isEmpty else { return }
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: connectionID
        ]
        let attributes: [CFString: Any] = [kSecValueData: Data(password.utf8)]
        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw keychainError(updateStatus) }

        var item = key
        item[kSecValueData] = Data(password.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    static func removePassword(for connectionID: String, legacyConnectionIDs: [String] = []) throws {
        let accounts = unique([connectionID] + legacyConnectionIDs)
        let services = unique([service] + legacyServices)
        for serviceName in services {
            for account in accounts {
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: serviceName,
                    kSecAttrAccount: account
                ]
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
            }
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func keychainError(_ status: OSStatus) -> BridgeError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return BridgeError.message(L10n.format("Keychain tidak dapat menyimpan password: %@", message))
    }
}
