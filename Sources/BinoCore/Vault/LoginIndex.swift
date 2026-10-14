import CryptoKit
import Foundation

/// Answers "is a login saved for this site?" without unlocking the vault.
///
/// The file holds a salted hash of each saved site, and the names of the accounts under
/// it ("work", "personal"): no site names, usernames or passwords. Someone who can
/// read the file cannot list your sites from it, though they could test a guess ("is
/// united.com in here?"). It is rewritten whenever the vault is saved or unlocked.
public enum LoginIndex {
    private struct Stored: Codable {
        var salt: Data
        var sites: [String]
        /// Account names by site hash. Missing in an index written before accounts had names.
        var accounts: [String: [String]]?
    }

    private static func digest(_ site: String, salt: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(site.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func load() -> Stored? {
        guard let data = try? Data(contentsOf: BinoPaths.loginIndexFile) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func write(for vault: Vault) {
        let existing = load()
        let salt = existing?.salt ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let sites = Set(vault.logins.map { SitePolicy.normalizeSite($0.site) }.filter(SitePolicy.isAcceptableSite))
        var accounts: [String: [String]] = [:]
        for site in sites { accounts[digest(site, salt: salt)] = vault.accounts(forSite: site).map(\.name) }
        let stored = Stored(salt: salt, sites: sites.map { digest($0, salt: salt) }.sorted(), accounts: accounts)
        if let existing, existing.sites == stored.sites, existing.accounts == stored.accounts { return }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? BinoPaths.writePrivate(data, to: BinoPaths.loginIndexFile)
    }

    /// Whether a saved login would be used on this site, by the same rule the vault uses
    /// (the saved site itself or any subdomain of it). nil when there is no index yet.
    public static func hasLogin(forSite site: String) -> Bool? {
        guard let stored = load() else { return nil }
        var labels = SitePolicy.normalizeSite(site).split(separator: ".").map(String.init)
        while !labels.isEmpty {
            if stored.sites.contains(digest(labels.joined(separator: "."), salt: stored.salt)) { return true }
            labels.removeFirst()
        }
        return false
    }

    /// The names of the accounts that would be used on this site, without unlocking the
    /// vault. nil when the index is missing or predates account names; empty when nothing
    /// is saved for the site.
    public static func accounts(forSite site: String) -> [String]? {
        guard let stored = load(), let accounts = stored.accounts else { return nil }
        var labels = SitePolicy.normalizeSite(site).split(separator: ".").map(String.init)
        while !labels.isEmpty {
            if let names = accounts[digest(labels.joined(separator: "."), salt: stored.salt)] { return names }
            labels.removeFirst()
        }
        return []
    }
}
