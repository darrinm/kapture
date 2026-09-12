// Client-side encryption for the shared library (docs/SHARED-LIBRARY.md §4).
//
// The server holds ciphertext and never a key (D1). Two reviews found the same class of error
// here twice — a key derived from a value that only exists inside the ciphertext it opens — so
// the rule this file exists to enforce is F95: every derivation input must be readable before
// anything is decrypted. `KeyScope` is what makes that checkable rather than hoped for.

import CryptoKit
import Foundation

/// What a key is derived for. The associated values are exactly the inputs F12 allows, and each
/// one is available to a reader before it decrypts: `opID` comes from the plaintext envelope,
/// blob scopes from the object's own key path, `snapshot` from the snapshot's key path.
public enum KeyScope: Sendable, Equatable {
    /// A row payload, scoped by the op that carries it (F126). Never by revision: a row's
    /// revision is inside the payload, and deriving from it would repeat the F95 mistake.
    case row(opID: String)
    /// Bytes, scoped by the capture they are filed under and their revision. `capture` is the
    /// owning blindedID, which differs from the naming row's for a fork (F128).
    case blob(purpose: BlobPurpose, capture: String, revision: Int64)
    /// A row-set snapshot, scoped by the log sequence it represents.
    case snapshot(seq: Int64)

    var purposeLabel: String {
        switch self {
        case .row: return "row"
        case .blob(let purpose, _, _): return purpose.rawValue
        case .snapshot: return "snap"
        }
    }

    var scopeLabel: String {
        switch self {
        case .row(let opID): return opID
        case .blob(_, let capture, let revision): return "\(capture)/\(revision)"
        case .snapshot(let seq): return String(seq)
        }
    }
}

public enum BlobPurpose: String, Sendable, Codable, CaseIterable {
    case blob, thumb, orig
}

public struct LibraryKeyMismatch: LocalizedError {
    public let expected: String
    public let found: String
    public var errorDescription: String? {
        "This library was made with a different key (\(found), expected \(expected))"
    }
}

public struct LibraryDecryptionFailure: LocalizedError {
    public var errorDescription: String? { "The library data could not be decrypted" }
}

/// The library key and everything derived from it. Held only in memory; the key itself lives in
/// the iCloud Keychain (F11) and is never sent anywhere.
public struct LibraryCrypto: Sendable {
    private let key: SymmetricKey

    /// First 8 bytes of SHA-256(key), hex (F14). Identifies which library a byte belongs to
    /// without revealing anything about the key.
    public let keyID: String

    public init(key: SymmetricKey) {
        self.key = key
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        self.keyID = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - Blinded identifiers (F15)

    /// `base32(HMAC-SHA256(libraryKey, captureID))`, truncated to 26 characters.
    ///
    /// A ULID carries its creation time in its first ten characters, so using capture ids as
    /// object keys would hand the server a timeline. HMAC does not invert, which is exactly why
    /// F12 may not derive from `captureID`: a reader holding only the blinded form cannot get
    /// back to it.
    public func blind(_ captureID: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(captureID.utf8), using: key)
        return LibraryCrypto.base32(Data(mac)).prefix(26).description
    }

    // MARK: - Derivation (F12)

    func derive(_ scope: KeyScope, writer: String) -> SymmetricKey {
        let info = "kapture/v1/\(scope.purposeLabel)/\(scope.scopeLabel)/\(writer)"
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data(keyID.utf8),                 // F96: the keyID, never a per-device salt
            info: Data(info.utf8),
            outputByteCount: 32)
    }

    // MARK: - Sealing (F13)

    /// AES-256-GCM with a fresh random nonce per object, the nonce carried in the combined box.
    ///
    /// Two objects may share a derived key — a rename re-encrypts a row whose revision has not
    /// changed — so uniqueness rests on the nonce rather than on the derivation. CryptoKit
    /// generates a random nonce per seal, which is the property this depends on.
    public func seal(_ plaintext: Data, scope: KeyScope, writer: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: derive(scope, writer: writer))
        guard let combined = box.combined else { throw LibraryDecryptionFailure() }
        return combined
    }

    public func open(_ ciphertext: Data, scope: KeyScope, writer: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: derive(scope, writer: writer))
        } catch {
            throw LibraryDecryptionFailure()
        }
    }

    /// Seal a `Codable` payload. Dates are ISO-8601 so a row round-trips identically across
    /// builds, the way sidecars already do.
    public func seal<T: Encodable>(_ value: T, scope: KeyScope, writer: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try seal(encoder.encode(value), scope: scope, writer: writer)
    }

    public func open<T: Decodable>(_ type: T.Type, from ciphertext: Data,
                                   scope: KeyScope, writer: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: open(ciphertext, scope: scope, writer: writer))
    }

    // MARK: - Recovery code (F85)

    /// The key as Crockford base32 with a checksum, in groups of five.
    ///
    /// This is the only way into a library from a Mac that cannot get the key from iCloud
    /// Keychain, and the only backup if iCloud Keychain loses it. F16 means losing both loses
    /// the library outright, for everyone including the operator.
    public func recoveryCode() -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        let checksum = SHA256.hash(data: raw).prefix(2)
        let body = LibraryCrypto.base32(raw + Data(checksum))
        return stride(from: 0, to: body.count, by: 5).map { start -> String in
            let from = body.index(body.startIndex, offsetBy: start)
            let to = body.index(from, offsetBy: min(5, body.count - start))
            return String(body[from..<to])
        }.joined(separator: "-")
    }

    public static func key(fromRecoveryCode code: String) throws -> SymmetricKey {
        let cleaned = code.uppercased().filter { alphabet.contains($0) }
        let decoded = try base32Decode(cleaned)
        guard decoded.count == 34 else { throw RecoveryCodeInvalid() }
        let raw = decoded.prefix(32)
        let checksum = decoded.suffix(2)
        guard Data(SHA256.hash(data: raw).prefix(2)) == Data(checksum) else {
            throw RecoveryCodeInvalid()
        }
        return SymmetricKey(data: raw)
    }

    public struct RecoveryCodeInvalid: LocalizedError {
        public var errorDescription: String? { "That recovery code is not valid" }
    }

    // MARK: - Crockford base32

    /// Crockford's alphabet, as `ULID` already uses: no I, L, O or U, so a handwritten code
    /// survives being read back.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func base32(_ data: Data) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 0x1F])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 0x1F]) }
        return out
    }

    static func base32Decode(_ text: String) throws -> Data {
        var out = Data()
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else {
                throw RecoveryCodeInvalid()
            }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}
