import Foundation

/// Rules about which page a secret may be typed into. These are fixed checks,
/// never model decisions.
public enum SitePolicy {
    /// Multi-part public suffixes a login must not be saved against on their own.
    private static let bareSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz",
        "co.jp", "com.br", "com.mx", "co.in", "co.za", "com.sg", "com.hk", "co.kr",
        "com.cn", "com.tr", "com.ar", "co.il", "github.io", "vercel.app", "netlify.app",
        "herokuapp.com", "pages.dev", "web.app", "appspot.com", "blogspot.com",
    ]

    /// Turns whatever was typed ("https://www.United.com/login") into a bare host ("united.com").
    public static func normalizeSite(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A saved site must be specific enough that "ends with this" cannot match unrelated sites.
    public static func isAcceptableSite(_ site: String) -> Bool {
        let s = normalizeSite(site)
        if s == "localhost" { return true }
        let labels = s.split(separator: ".")
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        if bareSuffixes.contains(s) { return false }
        return true
    }

    /// The site a new login made on this page should be saved against: the name the site
    /// is known by ("accounts.shop.example" gives "shop.example"), so the login also works
    /// on its other pages. nil when the address has no usable host.
    public static func accountSite(forPage pageURL: String) -> String? {
        guard let host = host(of: pageURL) else { return nil }
        let labels = normalizeSite(host).split(separator: ".").map(String.init)
        // Numeric addresses have no shorter form.
        guard labels.count > 2, !labels.allSatisfy({ Int($0) != nil }) else {
            return isAcceptableSite(host) ? normalizeSite(host) : nil
        }
        let keep = bareSuffixes.contains(labels.suffix(2).joined(separator: ".")) ? 3 : 2
        let site = labels.suffix(keep).joined(separator: ".")
        return isAcceptableSite(site) ? site : nil
    }

    public static func host(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// True when the page's host is the saved site or a subdomain of it.
    /// "united.com.evil.io" and "notunited.com" do not match "united.com".
    public static func page(_ pageURL: String, matchesSite site: String) -> Bool {
        guard let host = host(of: pageURL) else { return false }
        let s = normalizeSite(site)
        guard isAcceptableSite(s) else { return false }
        return host == s || host.hasSuffix("." + s)
    }

    /// Hosts that sign people in for a site without being under it: Apple's sign-in
    /// frame comes from idmsa.apple.com even on appstoreconnect.apple.com. A saved
    /// login may be typed into a page or frame from one of these, and a tab on one of
    /// them counts as "on the site" while signing in.
    public static func signInHosts(for site: String) -> [String] {
        // A login saved under appstoreconnect.apple.com is still signed in by idmsa.apple.com.
        let family = accountSite(forPage: "https://\(normalizeSite(site))/") ?? normalizeSite(site)
        switch family {
        case "apple.com", "icloud.com": return ["idmsa.apple.com", "appleid.apple.com", "account.apple.com", "iforgot.apple.com"]
        case "google.com", "youtube.com", "gmail.com": return ["accounts.google.com", "accounts.youtube.com"]
        case "microsoft.com", "live.com", "outlook.com", "office.com", "azure.com", "xbox.com":
            return ["login.microsoftonline.com", "login.live.com", "login.microsoft.com"]
        default: return []
        }
    }

    /// True when the page (or frame) is on the saved site, or on one of the hosts that
    /// sign people in for it.
    public static func page(_ pageURL: String, matchesSiteOrSignInHost site: String) -> Bool {
        if page(pageURL, matchesSite: site) { return true }
        guard let host = host(of: pageURL) ?? bareHost(pageURL) else { return false }
        return signInHosts(for: site).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A host given on its own ("idmsa.apple.com") rather than as an address.
    private static func bareHost(_ text: String) -> String? {
        let s = normalizeSite(text)
        return s.isEmpty || s.contains("/") ? nil : s
    }

    /// Whether an address looks like a page that signs people in, judged from its host
    /// and path only: a known sign-in host, or words like "login" or "signin" in the address.
    public static func looksLikeSignInPage(_ pageURL: String) -> Bool {
        guard let host = host(of: pageURL) else { return false }
        let knownHosts = ["idmsa.apple.com", "appleid.apple.com", "account.apple.com", "accounts.google.com",
                          "login.microsoftonline.com", "login.live.com", "login.microsoft.com"]
        if knownHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = (URL(string: pageURL)?.path ?? "").lowercased()
        let text = host + path
        let pattern = #"\b(log|sign)[-_]?(in|on)\b|\bauth\b|/auth[/.]|oauth|/sso\b|idmsa|/session\b|/accounts?(/|$)"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Secrets only go to encrypted pages. Pages served from this Mac count as safe.
    public static func isSecureContext(_ pageURL: String) -> Bool {
        guard let url = URL(string: pageURL), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        if scheme == "http", let host = url.host?.lowercased() {
            return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
                || host.hasSuffix(".localhost")
        }
        return false
    }
}
