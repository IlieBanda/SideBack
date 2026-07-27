import Foundation
import Security

/// The on-device backup password. Silo runs on the one phone it backs up —
/// there is only ever one relevant device, the one this code is running on
/// — so a single stored password is enough; it doesn't need to be keyed per
/// destination server or per device the way `KeychainStore`'s server token
/// does.
///
/// Without a backup password, `BackupAgent2` silently omits Keychain items,
/// Health data, call history, and Safari history from the backup even
/// though the run reports success — a "complete" backup made without one
/// is not actually complete. So this is on by default, not an opt-in extra.
enum BackupEncryptionStore {
    private static let service = "com.ilia.silo.backup-encryption-password"
    private static let account = "device-backup-password"
    private static let enabledKey = "silo.backupEncryption.enabled"

    /// Default true: encrypted-by-default, per the reasoning above. The
    /// explicit override lives in the UI as "start without encryption", not as
    /// a silent default.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func savePassword(_ password: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
        // A changed password has to be re-applied to the device — see
        // `isConfirmedSetOnDevice`'s doc comment for why this can't just be
        // silently assumed to already match.
        isConfirmedSetOnDevice = false
    }

    static var password: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        isConfirmedSetOnDevice = false
    }

    /// Whether `mobilebackup2_change_password` has already succeeded once
    /// with the currently-stored password. `ChangePassword` needs the
    /// *current* device password to change it again — calling it with
    /// `old: nil` a second time, after the device already has this password
    /// set, fails. Tracking this locally avoids re-attempting it (and
    /// avoids a spurious on-device confirmation prompt) on every run.
    static var isConfirmedSetOnDevice: Bool {
        get { UserDefaults.standard.bool(forKey: "silo.backupEncryption.confirmedSetOnDevice") }
        set { UserDefaults.standard.set(newValue, forKey: "silo.backupEncryption.confirmedSetOnDevice") }
    }
}
