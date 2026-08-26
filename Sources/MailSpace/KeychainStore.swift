import Foundation
import Security

/// MailSpace's own Keychain items for Google passwords.
///
/// One `kSecClassGenericPassword` item per account, service `MailSpace`,
/// account name = the Google email address. Passwords never touch
/// `accounts.json`, stdout or the notification payloads — the Keychain is the
/// only place they live.
///
/// `service` is injectable so tests can work in a throwaway namespace instead
/// of the user's real MailSpace items; the app always goes through `shared`.
struct KeychainStore {
    static let defaultService = "MailSpace"
    static let shared = KeychainStore()

    let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func baseQuery(for email: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email
        ]
    }

    func password(for email: String) -> String? {
        guard !email.isEmpty else { return nil }
        var query = baseQuery(for: email)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else { return nil }
        return password
    }

    func hasPassword(for email: String) -> Bool {
        password(for: email) != nil
    }

    @discardableResult
    func setPassword(_ password: String, for email: String) -> Bool {
        guard !email.isEmpty, !password.isEmpty else { return false }
        let data = Data(password.utf8)
        let query = baseQuery(for: email)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            report("could not update Keychain item", status: updateStatus)
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = "MailSpace — \(email)"
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            report("could not add Keychain item", status: addStatus)
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    func deletePassword(for email: String) -> Bool {
        guard !email.isEmpty else { return false }
        let status = SecItemDelete(baseQuery(for: email) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Never logs the password itself — only the failure and its OSStatus.
    private func report(_ message: String, status: OSStatus) {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        Log.error("\(message) (\(detail))")
    }
}
