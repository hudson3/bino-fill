import Foundation

/// Where `bino login <site>` goes: the host that was asked for, not the parent domain
/// the login happens to be saved under (asking for appstoreconnect.apple.com with a
/// login saved for apple.com opens appstoreconnect.apple.com).
public enum SignInTarget {
    /// The page to open. `requested` is the site as typed; `address` a `--url` to use
    /// instead; the login's own sign-in page is used when it is on the requested host.
    public static func url(requested: String, login: Login, address: URL? = nil) -> URL? {
        if let address { return address }
        let host = SitePolicy.normalizeSite(requested)
        guard SitePolicy.isAcceptableSite(host) else { return nil }
        let saved = login.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty, let url = URL(string: saved), SitePolicy.page(saved, matchesSite: host), SitePolicy.page(saved, matchesSite: login.site) {
            return url
        }
        return URL(string: "https://\(host)/")
    }

    /// Whether the page already open is the one to sign in on, so nothing need be opened:
    /// with `--url`, that very address; otherwise any page on the requested host, or on a
    /// host that signs people in for the login's site (idmsa.apple.com for apple.com).
    public static func isAlreadyThere(current: String?, requested: String, login: Login, address: URL? = nil) -> Bool {
        guard let current, !current.isEmpty else { return false }
        if let address { return RunReport.tidy(current) == RunReport.tidy(address.absoluteString) }
        let host = SitePolicy.normalizeSite(requested)
        if SitePolicy.page(current, matchesSite: host) { return true }
        guard let here = SitePolicy.host(of: current) else { return false }
        return SitePolicy.signInHosts(for: login.site).contains { here == $0 || here.hasSuffix("." + $0) }
    }
}
