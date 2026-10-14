import Foundation

/// Everything Bino knows about you. Stored only inside the encrypted vault file.
public struct Vault: Codable, Equatable {
    public var version: Int = 1
    public var profile = Profile()
    public var cards: [Card] = []
    public var logins: [Login] = []
    /// Your note, kept whole: Bino looks in it for anything the fields above do not hold.
    public var notes = ""

    public init() {}

    /// A vault saved before `notes` existed has no key for it.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profile = try values.decodeIfPresent(Profile.self, forKey: .profile) ?? Profile()
        cards = try values.decodeIfPresent([Card].self, forKey: .cards) ?? []
        logins = try values.decodeIfPresent([Login].self, forKey: .logins) ?? []
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public var defaultCard: Card? {
        cards.first(where: { $0.isDefault }) ?? cards.first
    }

    /// Every login saved for the page's site: the most specific saved site when several
    /// match (login.united.com over united.com), and all the accounts saved under it.
    public func logins(forPage pageURL: String) -> [Login] {
        let matching = logins.filter { SitePolicy.page(pageURL, matchesSite: $0.site) }
        guard let best = matching.max(by: { SitePolicy.normalizeSite($0.site).count < SitePolicy.normalizeSite($1.site).count }) else { return [] }
        let site = SitePolicy.normalizeSite(best.site)
        return matching.filter { SitePolicy.normalizeSite($0.site) == site }
    }

    /// The first login saved for the page's site, for places that take any account.
    public func login(forPage pageURL: String) -> Login? {
        logins(forPage: pageURL).first
    }

    /// The accounts saved for a site, each with the name `--account` picks it by: what you
    /// called it in the vault, or "account 1", "account 2", … for one you left unnamed.
    public func accounts(forPage pageURL: String) -> [(name: String, login: Login)] {
        Self.named(logins(forPage: pageURL))
    }

    public func accounts(forSite site: String) -> [(name: String, login: Login)] {
        let wanted = SitePolicy.normalizeSite(site)
        return Self.named(logins.filter { SitePolicy.normalizeSite($0.site) == wanted })
    }

    static func named(_ logins: [Login]) -> [(name: String, login: Login)] {
        logins.enumerated().map { index, login in
            let name = login.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty ? "account \(index + 1)" : name, login)
        }
    }

    /// The login to sign in with, or why there is not one.
    public enum LoginChoice: Equatable {
        case one(Login)
        case none
        /// Several accounts and none asked for: their names.
        case several([String])
        /// The account asked for is not saved: the names that are.
        case noSuchAccount(asked: String, saved: [String])
        /// The account asked for fits more than one saved name: those names.
        case ambiguous(asked: String, matching: [String])
    }

    public func login(forPage pageURL: String, account: String?) -> LoginChoice {
        let saved = accounts(forPage: pageURL)
        guard !saved.isEmpty else { return .none }
        if let account {
            switch AccountMatch.pick(account, from: saved.map(\.name)) {
            case .one(let index): return .one(saved[index].login)
            case .several(let names): return .ambiguous(asked: account, matching: names)
            case .none: return .noSuchAccount(asked: account, saved: saved.map(\.name))
            }
        }
        return saved.count == 1 ? .one(saved[0].login) : .several(saved.map(\.name))
    }
}

/// Which saved account a typed `--account` means. Names can be long ("Apple developer
/// account · Enrollment id: B4R94FXNK9"), so a part of one is enough when only one fits.
public enum AccountMatch: Equatable {
    case one(Int)
    /// More than one name fits: the ones that do.
    case several([String])
    case none

    /// Letters and digits only, lowercased, accents dropped: "Personal" fits "per-sonal".
    static func squash(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { String($0) }.joined()
    }

    /// `asked` picks a name in this order: the exact name (ignoring case and spacing), a
    /// 1-based number ("2" or "account 2"), a name that starts with it, a name that
    /// contains it. The first rule that fits anything decides.
    public static func pick(_ asked: String, from names: [String]) -> AccountMatch {
        let wanted = squash(asked)
        guard !wanted.isEmpty, !names.isEmpty else { return .none }
        let squashed = names.map(squash)
        if let exact = squashed.firstIndex(of: wanted) { return .one(exact) }
        let digits = asked.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "account", with: "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        if let number = Int(digits), (1...names.count).contains(number) { return .one(number - 1) }
        for rule in [{ (name: String) in name.hasPrefix(wanted) }, { (name: String) in name.contains(wanted) }] {
            let fits = squashed.indices.filter { rule(squashed[$0]) }
            if fits.count == 1 { return .one(fits[0]) }
            if fits.count > 1 { return .several(fits.map { names[$0] }) }
        }
        return .none
    }
}

public struct Profile: Codable, Equatable {
    public var title = ""
    public var firstName = ""
    public var middleName = ""
    public var lastName = ""
    public var suffix = ""
    /// YYYY-MM-DD
    public var dateOfBirth = ""
    public var gender = ""
    public var nationality = ""
    public var email = ""
    public var phone = ""
    public var company = ""
    public var address = Address()
    public var passport = Passport()
    public var knownTravelerNumber = ""
    public var redressNumber = ""
    public var loyalty: [Loyalty] = []
    /// Social Security number. Kept for you to look up; no form-filling code reads it.
    public var ssn = ""

    public init() {}

    /// A vault saved before a field existed has no key for it, so every field falls back to empty.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try values.decodeIfPresent(String.self, forKey: key) ?? "" }
        title = try text(.title)
        firstName = try text(.firstName)
        middleName = try text(.middleName)
        lastName = try text(.lastName)
        suffix = try text(.suffix)
        dateOfBirth = try text(.dateOfBirth)
        gender = try text(.gender)
        nationality = try text(.nationality)
        email = try text(.email)
        phone = try text(.phone)
        company = try text(.company)
        address = try values.decodeIfPresent(Address.self, forKey: .address) ?? Address()
        passport = try values.decodeIfPresent(Passport.self, forKey: .passport) ?? Passport()
        knownTravelerNumber = try text(.knownTravelerNumber)
        redressNumber = try text(.redressNumber)
        loyalty = try values.decodeIfPresent([Loyalty].self, forKey: .loyalty) ?? []
        ssn = try text(.ssn)
    }

    public var fullName: String {
        [firstName, middleName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct Address: Codable, Equatable {
    public var line1 = ""
    public var line2 = ""
    public var city = ""
    public var state = ""
    public var postalCode = ""
    public var country = ""

    public init() {}

    public var isEmpty: Bool {
        [line1, line2, city, state, postalCode, country].allSatisfy { $0.isEmpty }
    }
}

public struct Passport: Codable, Equatable {
    public var number = ""
    public var issuingCountry = ""
    /// YYYY-MM-DD
    public var issueDate = ""
    /// YYYY-MM-DD
    public var expiryDate = ""

    public init() {}
}

public struct Loyalty: Codable, Equatable, Identifiable {
    public var id = UUID()
    /// Airline or programme name, e.g. "United MileagePlus".
    public var program = ""
    public var number = ""
    /// Site this number belongs to, e.g. "united.com". Optional.
    public var site = ""

    public init() {}
}

public struct Card: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var label = ""
    public var cardholderName = ""
    public var number = ""
    public var expMonth = ""
    public var expYear = ""
    public var cvv = ""
    public var billingAddress = Address()
    public var isDefault = false

    public init() {}

    public var digits: String { number.filter(\.isNumber) }
    public var last4: String { String(digits.suffix(4)) }

    /// Card network from the number prefix.
    public var network: String {
        let d = digits
        guard let first2 = Int(d.prefix(2)) else { return "" }
        let first4 = Int(d.prefix(4)) ?? 0
        if d.hasPrefix("4") { return "Visa" }
        if first2 == 34 || first2 == 37 { return "American Express" }
        if (51...55).contains(first2) || (2221...2720).contains(first4) { return "Mastercard" }
        if first4 == 6011 || first2 == 65 { return "Discover" }
        if first2 == 35 { return "JCB" }
        if first2 == 36 || first2 == 38 || (300...305).contains(Int(d.prefix(3)) ?? 0) { return "Diners Club" }
        return ""
    }
}

public struct Login: Codable, Equatable, Identifiable {
    public var id = UUID()
    /// Site the login belongs to, e.g. "united.com". The password is only ever typed there.
    public var site = ""
    public var username = ""
    public var password = ""
    /// What you call this login ("work", "personal"): the name `--account` picks it by.
    public var note = ""
    /// The sign-in page to open, when the site's front page is not it. Optional; must be on the site.
    public var url = ""

    public init() {}

    /// A login saved before `url` existed has no key for it.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        site = try values.decodeIfPresent(String.self, forKey: .site) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? ""
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    /// Whether every word of a search appears in the label, site or username. The password is never searched.
    public func matches(search: String) -> Bool {
        search.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            [note, site, username].contains { $0.localizedStandardContains(word) }
        }
    }
}
