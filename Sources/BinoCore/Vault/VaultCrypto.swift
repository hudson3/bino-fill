import CryptoKit
import Foundation
import LocalAuthentication

public enum VaultError: Error, CustomStringConvertible {
    case noVault
    case secureEnclaveUnavailable
    case softwareKeyNotAllowed
    case cancelled
    case notUnlocked(String)
    case corrupt(String)

    public var description: String {
        switch self {
        case .noVault: return "There is no vault yet. Run `bino vault edit` to create one."
        case .secureEnclaveUnavailable: return "This Mac's Secure Enclave is not available, so the vault cannot be protected."
        case .softwareKeyNotAllowed: return "A test vault key was found in the real vault location. Refusing to use it."
        case .cancelled: return "Unlock was cancelled."
        case .notUnlocked(let why): return "The vault was not unlocked: Touch ID did not complete (\(why))."
        case .corrupt(let why): return "The vault file could not be read: \(why)"
        }
    }
}

/// The key that protects the vault.
///
/// Real vaults use a private key that lives inside the Secure Enclave. It cannot be copied
/// off this Mac, and the chip refuses to use it until you pass Touch ID (or your login
/// password if Touch ID is unavailable).
///
/// Test vaults use an ordinary key in a file. That is only permitted when `BINO_HOME`
/// points away from the real vault folder.
enum VaultKey {
    case secureEnclave(Data)
    case software(Data)

    private struct Stored: Codable {
        var kind: String
        var blob: Data
    }

    static func load() throws -> VaultKey {
        guard let data = try? Data(contentsOf: BinoPaths.vaultKeyFile) else { throw VaultError.noVault }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw VaultError.corrupt("vault.key is not valid")
        }
        switch stored.kind {
        case "secure-enclave": return .secureEnclave(stored.blob)
        case "software-test":
            guard BinoPaths.isRedirected else { throw VaultError.softwareKeyNotAllowed }
            return .software(stored.blob)
        default: throw VaultError.corrupt("unknown key kind \(stored.kind)")
        }
    }

    static func create(testKey: Bool) throws -> VaultKey {
        let key: VaultKey
        if testKey {
            guard BinoPaths.isRedirected else { throw VaultError.softwareKeyNotAllowed }
            key = .software(P256.KeyAgreement.PrivateKey().rawRepresentation)
        } else {
            guard SecureEnclave.isAvailable else { throw VaultError.secureEnclaveUnavailable }
            var cfError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .userPresence], &cfError)
            else { throw VaultError.corrupt("could not set up Touch ID protection") }
            let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            key = .secureEnclave(seKey.dataRepresentation)
        }
        try key.save()
        return key
    }

    private func save() throws {
        let stored: Stored
        switch self {
        case .secureEnclave(let blob): stored = Stored(kind: "secure-enclave", blob: blob)
        case .software(let blob): stored = Stored(kind: "software-test", blob: blob)
        }
        try BinoPaths.writePrivate(try JSONEncoder().encode(stored), to: BinoPaths.vaultKeyFile)
    }

    var isTestKey: Bool {
        if case .software = self { return true }
        return false
    }

    /// Reading the public half never needs Touch ID, so saving changes doesn't prompt twice.
    func publicKey() throws -> P256.KeyAgreement.PublicKey {
        switch self {
        case .secureEnclave(let blob):
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob).publicKey
        case .software(let raw):
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw).publicKey
        }
    }

    /// The step that triggers Touch ID for a real vault.
    func sharedSecret(with peer: P256.KeyAgreement.PublicKey, reason: String) throws -> SharedSecret {
        switch self {
        case .secureEnclave(let blob):
            let context = LAContext()
            context.localizedReason = reason
            do {
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: blob, authenticationContext: context)
                return try key.sharedSecretFromKeyAgreement(with: peer)
            } catch let error as LAError where error.code == .userCancel || error.code == .appCancel
                || error.code == .systemCancel {
                throw VaultError.cancelled
            } catch {
                throw VaultError.notUnlocked((error as NSError).localizedDescription)
            }
        case .software(let raw):
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
                .sharedSecretFromKeyAgreement(with: peer)
        }
    }
}

/// On-disk form of the encrypted vault.
struct SealedVault: Codable {
    var format = 1
    /// One-time public key used for this save.
    var ephemeralPublicKey: Data
    var salt: Data
    /// ChaCha20-Poly1305 nonce + ciphertext + tag.
    var sealed: Data

    private static let info = Data("bino-vault-v1".utf8)

    private static func symmetricKey(_ secret: SharedSecret, salt: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }

    static func seal(_ plaintext: Data, to recipient: P256.KeyAgreement.PublicKey) throws -> SealedVault {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VaultError.corrupt("no random bytes") }
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let box = try ChaChaPoly.seal(plaintext, using: symmetricKey(secret, salt: salt))
        return SealedVault(ephemeralPublicKey: ephemeral.publicKey.x963Representation, salt: salt, sealed: box.combined)
    }

    func open(with key: VaultKey, reason: String) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
        let secret = try key.sharedSecret(with: peer, reason: reason)
        do {
            return try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: sealed),
                                       using: Self.symmetricKey(secret, salt: salt))
        } catch {
            throw VaultError.corrupt("decryption failed")
        }
    }
}
