// Secrets live in the Keychain, never UserDefaults: the Anthropic key (naming) and the share
// upload token.
//
// Both are written as *synchronizable* items, so iCloud Keychain carries them to the user's other
// Macs and a second machine needs nothing typed into it. That costs an entitlement:
// synchronizable items live in the data protection keychain, which a macOS app reaches only with
// keychain-access-groups, authorised by an embedded provisioning profile. Release builds have
// both (see signing/ and scripts/bundle.sh); a locally-built copy is signed Apple Development and
// has neither, so it falls back to an item that stays on this Mac. Same API either way.
//
// One consequence worth knowing when developing: an unentitled build cannot see the synced item
// at all, so a local build of Kapture will report no share token even on a Mac where the release
// build has one. Give the local build its own copy (`--set-share-token`); it is stored separately
// and neither copy disturbs the other. `--secrets-status` says which kind each secret is.
import Foundation
import Security

public enum Keychain {
    private static let service = "sh.kapture.app"

    private static func query(_ account: String, synchronizable: Any) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
    }

    public static func set(_ value: String?, for account: String) {
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            SecItemDelete(query(account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)
            return
        }

        // Deliberately not "delete, then add". Deleting first means any failure to add — a locked
        // keybag, a revoked entitlement — leaves the user with no secret at all, and the only copy
        // of a share token is the one in here. Nothing is removed until a replacement exists.
        var synced = true
        var status = write(data, for: account, synchronizable: true)
        // errSecMissingEntitlement is what an unentitled build normally gets — a local build, or
        // a release whose provisioning profile went missing — but a build signed ad-hoc can be
        // told errSecNotAvailable instead. Both mean the same thing: this process has no data
        // protection keychain. Neither is a reason to lose what the user just typed. A locked
        // keybag is *not* in this set: that is transient, and the existing secret still stands.
        if status == errSecMissingEntitlement || status == errSecNotAvailable {
            synced = false
            status = write(data, for: account, synchronizable: false)
            if status == errSecSuccess { Log.shell.info("keychain: \(account) kept on this Mac") }
        }
        guard status == errSecSuccess else {
            Log.shell.error("keychain write failed for \(account): \(status)")
            return
        }
        // Only now is it safe to drop the leftover, so it cannot shadow what was just written —
        // and only in this direction. An unentitled build must leave the synchronizable item
        // alone: it cannot see it to begin with, and a delete that did land would ride iCloud to
        // the user's other Macs and take the token off them too. Running a local build is not
        // consent to log the rest of your machines out.
        if synced { SecItemDelete(query(account, synchronizable: false) as CFDictionary) }
    }

    private static func write(_ data: Data, for account: String, synchronizable: Bool) -> OSStatus {
        var add = query(account, synchronizable: synchronizable)
        add[kSecValueData as String] = data
        // AfterFirstUnlock, not WhenUnlocked: Kapture uploads in the background, so a token it
        // cannot read while the screen is locked is a token that fails exactly when it is needed.
        // The device-only classes are refused outright for a synchronizable item, which by
        // definition does leave this Mac.
        add[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return status }

        SecItemDelete(query(account, synchronizable: synchronizable) as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(_ account: String) -> String? {
        // Synced first rather than SynchronizableAny: a Mac that holds both forms — one synced
        // down, one left by a local build — must answer with the same one every time.
        for synchronizable in [true, false] {
            var item: CFTypeRef?
            var q = query(account, synchronizable: synchronizable)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let value = String(data: data, encoding: .utf8)
            else { continue }
            if !synchronizable { promote(data, for: account) }
            return value
        }
        return nil
    }

    /// Carry a secret written before this app could sync into iCloud Keychain.
    ///
    /// Deliberately here, on a read that was going to happen anyway, rather than in a migration
    /// pass at launch. Asking for an item's *data* is what makes macOS check its ACL, and the ACL
    /// trusts whichever binary created the item — so a launch-time sweep would greet the user with
    /// an authorisation dialog before the app had done anything, every launch until they answered.
    /// Riding an existing read costs no prompt that the read did not already cost.
    private static func promote(_ data: Data, for account: String) {
        var add = query(account, synchronizable: true)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // Failure here is ordinary — an unentitled build cannot sync — and the local item stays.
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return }
        SecItemDelete(query(account, synchronizable: false) as CFDictionary)
        Log.shell.info("keychain: \(account) now follows iCloud Keychain")
    }

    /// Whether a secret is stored, without reading it.
    ///
    /// This matters: returning the *data* is what makes macOS check the item's ACL and put up
    /// "Kapture wants to access key sh.kapture.app" — and the ACL trusts the exact binary that
    /// created the item, so every rebuild during development asks again. Asking only for
    /// attributes answers "is one set?" with no dialog, which is all the UI ever needed.
    public static func has(_ account: String) -> Bool {
        var q = query(account, synchronizable: kSecAttrSynchronizableAny)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    /// Where a secret is kept — the one thing that differs between a release build and a local
    /// one, and the only way to tell from outside whether syncing is actually in effect.
    public enum Storage: String {
        case synced = "iCloud Keychain"
        case thisDevice = "this Mac only"
        case absent = "not set"
    }

    /// Attribute-only, like `has`, so asking never provokes the ACL dialog.
    public static func storage(_ account: String) -> Storage {
        for (synchronizable, answer) in [(true, Storage.synced), (false, .thisDevice)] {
            var q = query(account, synchronizable: synchronizable)
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess { return answer }
        }
        return .absent
    }

    public static var shareTokenStorage: Storage { storage(shareAccount) }
    public static var anthropicKeyStorage: Storage { storage(anthropicAccount) }

    private static let anthropicAccount = "anthropic-api-key"
    private static let shareAccount = "share-token"

    public static var hasAnthropicKey: Bool { has(anthropicAccount) }
    public static var hasShareToken: Bool { has(shareAccount) }

    public static var anthropicKey: String? {
        get { get(anthropicAccount) }
        set { set(newValue, for: anthropicAccount) }
    }

    /// Bearer token for kapture.sh. The server stores only its sha256, so this string is the
    /// single copy that can authorize a share — hence Keychain, not UserDefaults.
    public static var shareToken: String? {
        get { get(shareAccount) }
        set { set(newValue, for: shareAccount) }
    }
}
