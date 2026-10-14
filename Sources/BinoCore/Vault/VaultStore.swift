import CryptoKit
import Foundation

/// Reads and writes the encrypted vault file.
public enum VaultStore {
    public static var exists: Bool {
        FileManager.default.fileExists(atPath: BinoPaths.vaultFile.path)
            && FileManager.default.fileExists(atPath: BinoPaths.vaultKeyFile.path)
    }

    /// True when the vault in the current `BINO_HOME` is a test vault (no Touch ID).
    public static var isTestVault: Bool {
        (try? VaultKey.load().isTestKey) ?? false
    }

    /// Decrypts the vault. For a real vault this shows the Touch ID prompt with `reason`.
    public static func unlock(reason: String) throws -> Vault {
        let key = try VaultKey.load()
        guard let data = try? Data(contentsOf: BinoPaths.vaultFile) else { throw VaultError.noVault }
        guard let sealed = try? JSONDecoder().decode(SealedVault.self, from: data) else {
            throw VaultError.corrupt("vault.bin is not valid")
        }
        let plaintext = try sealed.open(with: key, reason: reason)
        do {
            let vault = try JSONDecoder().decode(Vault.self, from: plaintext)
            LoginIndex.write(for: vault)
            return vault
        } catch {
            throw VaultError.corrupt("contents are not a vault")
        }
    }

    /// Encrypts and saves. Creates the key on first save. Never prompts: only the public
    /// half of the key is needed to encrypt.
    public static func save(_ vault: Vault, createTestVault: Bool = false) throws {
        let key: VaultKey
        do {
            key = try VaultKey.load()
        } catch VaultError.noVault {
            key = try VaultKey.create(testKey: createTestVault)
        }
        let plaintext = try JSONEncoder().encode(vault)
        let sealed = try SealedVault.seal(plaintext, to: try key.publicKey())
        try BinoPaths.writePrivate(try JSONEncoder().encode(sealed), to: BinoPaths.vaultFile)
        LoginIndex.write(for: vault)
    }

    /// Changes whenever the vault file is saved, by anything. Lets an open window notice
    /// that a command (a new account's password, say) saved the vault behind its back.
    public static func stamp() -> Data? {
        (try? Data(contentsOf: BinoPaths.vaultFile)).map { Data(SHA256.hash(data: $0)) }
    }
}

/// Keeps a new account's login in the vault while the sign-up form is being filled.
/// Saving needs no Touch ID (only the public half of the key), so the login can go in
/// before its password is typed anywhere and be corrected afterwards.
public final class NewLoginKeeper {
    private var vault: Vault

    /// `vault`: the vault as just unlocked.
    public init(vault: Vault) {
        self.vault = vault
    }

    /// Adds the login, or replaces the copy saved earlier in this run.
    public func save(_ login: Login) throws {
        var updated = vault
        if let at = updated.logins.firstIndex(where: { $0.id == login.id }) {
            updated.logins[at] = login
        } else {
            updated.logins.append(login)
        }
        try VaultStore.save(updated)
        vault = updated
    }

    /// Takes the login out again: its password was never typed into the page.
    public func forget(_ login: Login) {
        var updated = vault
        updated.logins.removeAll { $0.id == login.id }
        if (try? VaultStore.save(updated)) != nil { vault = updated }
    }
}
