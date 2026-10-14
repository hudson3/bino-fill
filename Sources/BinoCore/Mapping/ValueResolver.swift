import Foundation

/// What to put in one field, or why nothing can be put there.
public enum Resolution: Equatable {
    case text(String)
    case option(FieldOption)
    /// The vault has nothing for this.
    case missing(String)
    /// A safety rule forbids it.
    case blocked(String)
    /// The value exists but does not fit this field.
    case unsupported(String)
}

public struct Resolved: Equatable {
    public var resolution: Resolution
    /// Assumptions worth a second look, e.g. a guessed date layout.
    public var notes: [String] = []
}

struct DateValue {
    var year: Int, month: Int, day: Int

    /// Parses "YYYY-MM-DD" (also accepts "MM/DD/YYYY").
    init?(_ text: String) {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        if numbers[0] > 31 {
            (year, month, day) = (numbers[0], numbers[1], numbers[2])
        } else {
            (month, day, year) = (numbers[0], numbers[1], numbers[2])
        }
        guard (1...12).contains(month), (1...31).contains(day), year > 1900 else { return nil }
    }
}

public struct ValueResolver {
    public let vault: Vault
    public let pageURL: String
    /// Which of several accounts saved for the site to use, by its name.
    public let account: String?

    public init(vault: Vault, pageURL: String, account: String? = nil) {
        self.vault = vault
        self.pageURL = pageURL
        self.account = account
    }

    private enum Chosen {
        case login(Login)
        case nothing(String)
    }

    /// The saved login for this page, or why nothing from one can be typed.
    private func chosenLogin() -> Chosen {
        switch vault.login(forPage: pageURL, account: account) {
        case .one(let login): return .login(login)
        case .none: return .nothing("no login saved for this site")
        case .several(let names):
            return .nothing("several accounts are saved for this site (\(names.joined(separator: ", "))): say which with --account")
        case .noSuchAccount(let asked, let saved):
            return .nothing("no account named \"\(asked)\" is saved for this site (saved: \(saved.joined(separator: ", ")))")
        case .ambiguous(let asked, let matching):
            return .nothing("\"\(asked)\" fits more than one account saved for this site (\(matching.joined(separator: ", "))): say more of the name")
        }
    }

    // MARK: Entry point

    public func resolve(_ concept: Concept, part: Part, field: PageField, billing: Bool = false) -> Resolved {
        if concept.needsSecurePage, !SitePolicy.isSecureContext(pageURL) {
            return Resolved(resolution: .blocked("this page is not encrypted (no https), so \(concept.displayName) was not typed"))
        }
        let profile = vault.profile
        let card = vault.defaultCard
        let address: Address = {
            if billing, let card, !card.billingAddress.isEmpty { return card.billingAddress }
            return profile.address
        }()

        switch concept {
        case .none:
            return Resolved(resolution: .missing("not something the vault holds"))
        case .title:
            return choiceOrText(profile.title, names: titleNames(profile.title), field, what: "title")
        case .firstName: return plain(profile.firstName, field, "first name")
        case .middleName:
            let value = part == .initial ? String(profile.middleName.prefix(1)) : profile.middleName
            return plain(value, field, "middle name")
        case .lastName: return plain(profile.lastName, field, "last name")
        case .suffix: return choiceOrText(profile.suffix, names: [profile.suffix], field, what: "name suffix")
        case .fullName: return plain(profile.fullName, field, "name")
        case .dob: return date(profile.dateOfBirth, part: part, field, what: "date of birth", card: false)
        case .gender: return choiceOrText(profile.gender, names: genderNames(profile.gender), field, what: "gender")
        case .nationality:
            return choiceOrText(profile.nationality, names: Geography.countryNames(for: profile.nationality), field,
                                what: "nationality")
        case .email: return plain(profile.email, field, "email")
        case .phone: return phone(profile.phone, part: part, field)
        case .phoneExtension: return Resolved(resolution: .missing("no phone extension saved"))
        case .company: return plain(profile.company, field, "company")
        case .addressLine1: return plain(address.line1, field, "street address")
        case .addressLine2: return plain(address.line2, field, "apartment or unit")
        case .city: return plain(address.city, field, "city")
        case .state:
            let names = Geography.stateNames(for: address.state)
            if field.isChoice { return choice(names, field, what: "state") }
            // A two-character box wants the abbreviation.
            let text = (field.maxLength > 0 && field.maxLength <= 3) ? names[0] : address.state
            return plain(text, field, "state")
        case .postalCode: return plain(address.postalCode, field, "postal code")
        case .country:
            return choiceOrText(address.country, names: Geography.countryNames(for: address.country), field,
                                what: "country")
        case .cardName:
            guard let card else { return noCard }
            return plain(card.cardholderName.isEmpty ? profile.fullName : card.cardholderName, field, "name on card")
        case .cardNumber:
            guard let card else { return noCard }
            if field.maxLength > 0, field.maxLength < card.digits.count {
                return Resolved(resolution: .unsupported("the card number box is too short for the whole number"))
            }
            return plain(card.digits, field, "card number")
        case .cardExpiry:
            guard let card else { return noCard }
            guard let month = Int(card.expMonth), let year = Int(card.expYear), (1...12).contains(month) else {
                return Resolved(resolution: .missing("no card expiry saved"))
            }
            let fullYear = year < 100 ? 2000 + year : year
            return date("\(fullYear)-\(month)-1", part: part, field, what: "card expiry", card: true)
        case .cardCVV:
            guard let card else { return noCard }
            return plain(card.cvv, field, "card security code")
        case .cardType:
            guard let card else { return noCard }
            return choiceOrText(card.network, names: networkNames(card.network), field, what: "card type")
        case .passportNumber: return plain(profile.passport.number, field, "passport number")
        case .passportCountry:
            return choiceOrText(profile.passport.issuingCountry,
                                names: Geography.countryNames(for: profile.passport.issuingCountry), field,
                                what: "passport country")
        case .passportExpiry:
            return date(profile.passport.expiryDate, part: part, field, what: "passport expiry", card: false)
        case .passportIssue:
            return date(profile.passport.issueDate, part: part, field, what: "passport issue date", card: false)
        case .knownTravelerNumber: return plain(profile.knownTravelerNumber, field, "known traveler number")
        case .redressNumber: return plain(profile.redressNumber, field, "redress number")
        case .loyaltyNumber:
            let text = (field.label + " " + field.section).lowercased()
            let match = profile.loyalty.first { entry in
                guard !entry.number.isEmpty else { return false }
                if !entry.site.isEmpty, SitePolicy.page(pageURL, matchesSite: entry.site) { return true }
                let words = entry.program.lowercased().split(separator: " ").filter { $0.count > 3 }
                return !words.isEmpty && words.contains { text.contains($0) }
            }
            guard let match else {
                return Resolved(resolution: .missing("no frequent flyer or member number saved for this site"))
            }
            return plain(match.number, field, "member number")
        case .username:
            switch chosenLogin() {
            case .login(let login): return plain(login.username, field, "username")
            case .nothing(let why): return Resolved(resolution: .missing(why))
            }
        case .password:
            // The one place a password can leave the vault: a saved login whose site matches this page.
            switch chosenLogin() {
            case .login(let login): return plain(login.password, field, "password")
            case .nothing(let why): return Resolved(resolution: .blocked("\(why), so no password was typed"))
            }
        }
    }

    private var noCard: Resolved { Resolved(resolution: .missing("no payment card saved")) }

    // MARK: Text and choices

    private func plain(_ value: String, _ field: PageField, _ what: String) -> Resolved {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return Resolved(resolution: .missing("no \(what) saved")) }
        if field.isChoice { return choice([value], field, what: what) }
        return Resolved(resolution: .text(value))
    }

    private func choiceOrText(_ value: String, names: [String], _ field: PageField, what: String) -> Resolved {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Resolved(resolution: .missing("no \(what) saved"))
        }
        if field.isChoice { return choice(names, field, what: what) }
        return Resolved(resolution: .text(value))
    }

    private func choice(_ names: [String], _ field: PageField, what: String) -> Resolved {
        guard names.contains(where: { !$0.isEmpty }) else { return Resolved(resolution: .missing("no \(what) saved")) }
        if let option = OptionMatcher.match(field.options, candidates: names) {
            return Resolved(resolution: .option(option))
        }
        return Resolved(resolution: .unsupported("none of the choices matches your saved \(what)"))
    }

    private func titleNames(_ title: String) -> [String] {
        let key = Geography.normalize(title)
        let groups = [["Mr", "Mr.", "Mister"], ["Mrs", "Mrs."], ["Ms", "Ms."], ["Miss"], ["Dr", "Dr.", "Doctor"],
                      ["Mx", "Mx."], ["Prof", "Prof.", "Professor"]]
        return groups.first { $0.contains { Geography.normalize($0) == key } } ?? [title]
    }

    private func genderNames(_ gender: String) -> [String] {
        let key = Geography.normalize(gender)
        let groups = [["Male", "M", "Man"], ["Female", "F", "Woman"],
                      ["X", "Unspecified", "Non-binary", "Nonbinary", "Another gender", "Other", "U", "Undisclosed"]]
        return groups.first { $0.contains { Geography.normalize($0) == key } } ?? [gender]
    }

    private func networkNames(_ network: String) -> [String] {
        switch network {
        case "Visa": return ["Visa", "VI", "VISA"]
        case "Mastercard": return ["Mastercard", "Master Card", "MC", "CA"]
        case "American Express": return ["American Express", "Amex", "AX", "AmEx"]
        case "Discover": return ["Discover", "DS", "DI", "Discover Card"]
        default: return [network]
        }
    }

    // MARK: Dates

    private func date(_ saved: String, part: Part, _ field: PageField, what: String, card: Bool) -> Resolved {
        guard let value = DateValue(saved) else { return Resolved(resolution: .missing("no \(what) saved")) }
        let two = { (n: Int) in String(format: "%02d", n) }
        let shortYear = two(value.year % 100)

        switch part {
        case .month:
            if field.isChoice {
                let name = PartRules.monthNames[value.month - 1].capitalized
                return numberChoice(value.month, extra: [name, String(name.prefix(3))], field, what: "month")
            }
            return Resolved(resolution: .text(two(value.month)))
        case .day:
            if field.isChoice { return numberChoice(value.day, extra: [], field, what: "day") }
            return Resolved(resolution: .text(field.maxLength == 1 ? String(value.day) : two(value.day)))
        case .year:
            if field.isChoice { return numberChoice(value.year, extra: [shortYear], field, what: "year") }
            return Resolved(resolution: .text(field.maxLength == 2 ? shortYear : String(value.year)))
        default:
            break
        }

        if field.isChoice {
            return Resolved(resolution: .unsupported("this date is a single dropdown, which Bino does not fill"))
        }
        if field.type == "date" {
            return Resolved(resolution: .text("\(value.year)-\(two(value.month))-\(two(value.day))"))
        }
        if field.type == "month" {
            return Resolved(resolution: .text("\(value.year)-\(two(value.month))"))
        }

        let hint = (field.placeholder + " " + field.label).lowercased()
        if card {
            // MM/YY unless the field says otherwise.
            let spaced = hint.contains("mm / yy")
            let separator = spaced ? " / " : "/"
            if hint.contains("yyyy") || (field.maxLength == 7 && !spaced) {
                return Resolved(resolution: .text(two(value.month) + separator + String(value.year)))
            }
            if field.maxLength == 4 { return Resolved(resolution: .text(two(value.month) + shortYear)) }
            return Resolved(resolution: .text(two(value.month) + separator + shortYear))
        }

        if let layout = dateLayout(in: hint) {
            let text = layout
                .replacingOccurrences(of: "yyyy", with: String(value.year))
                .replacingOccurrences(of: "yy", with: shortYear)
                .replacingOccurrences(of: "mm", with: two(value.month))
                .replacingOccurrences(of: "dd", with: two(value.day))
            return Resolved(resolution: .text(text))
        }
        if field.maxLength == 8 {
            return Resolved(resolution: .text(two(value.month) + two(value.day) + String(value.year)),
                            notes: ["date typed as MMDDYYYY; the page gave no format"])
        }
        return Resolved(resolution: .text("\(two(value.month))/\(two(value.day))/\(value.year)"),
                        notes: ["date typed as MM/DD/YYYY; the page gave no format"])
    }

    /// Finds a layout such as "mm/dd/yyyy" or "dd.mm.yyyy" in a placeholder or label.
    func dateLayout(in text: String) -> String? {
        let pattern = #"(mm|dd|yyyy)\s?([/\-. ])\s?(mm|dd)\s?[/\-. ]\s?(yyyy|yy|dd|mm)"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let found = text[range].replacingOccurrences(of: " ", with: "")
        let tokens = ["mm", "dd", "yy"].filter { found.contains($0) }
        return tokens.count == 3 ? found : nil
    }

    private func numberChoice(_ number: Int, extra: [String], _ field: PageField, what: String) -> Resolved {
        let candidates = [String(number), String(format: "%02d", number)] + extra
        if let option = OptionMatcher.match(field.options, candidates: candidates, allowPrefix: !extra.isEmpty) {
            return Resolved(resolution: .option(option))
        }
        return Resolved(resolution: .unsupported("the \(what) dropdown has no matching choice"))
    }

    // MARK: Phone

    private func phone(_ saved: String, part: Part, _ field: PageField) -> Resolved {
        let digits = saved.filter(\.isNumber)
        guard digits.count >= 7 else { return Resolved(resolution: .missing("no phone number saved")) }
        // North American numbers split cleanly; others are only ever typed whole.
        let explicitPlus = saved.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        let nanp = (digits.count == 10 && !explicitPlus) || (digits.count == 11 && digits.hasPrefix("1"))
        let national = nanp ? String(digits.suffix(10)) : digits
        let countryCode = nanp ? "1" : (explicitPlus ? String(digits.prefix(max(1, digits.count - 10))) : "")

        switch part {
        case .countryCode:
            guard !countryCode.isEmpty else { return Resolved(resolution: .missing("no phone country code saved")) }
            if field.isChoice {
                let matching = field.options.first { option in
                    let t = option.t.replacingOccurrences(of: " ", with: "")
                    return t.contains("+\(countryCode))") || t.hasSuffix("+\(countryCode)") || t.contains("(+\(countryCode))")
                        || option.v == countryCode || option.v == "+\(countryCode)"
                        || (countryCode == "1" && (option.v.uppercased() == "US" || option.t.lowercased().hasPrefix("united states")))
                }
                if let matching { return Resolved(resolution: .option(matching)) }
                return Resolved(resolution: .unsupported("the country code dropdown has no matching choice"))
            }
            return Resolved(resolution: .text(field.placeholder.contains("+") ? "+" + countryCode : countryCode))
        case .areaCode, .prefix3, .suffix4, .local:
            guard nanp else {
                return Resolved(resolution: .unsupported("this phone number cannot be split into the page's boxes"))
            }
            let area = String(national.prefix(3)), prefix = String(national.dropFirst(3).prefix(3))
            let suffix = String(national.suffix(4))
            switch part {
            case .areaCode: return Resolved(resolution: .text(area))
            case .prefix3: return Resolved(resolution: .text(prefix))
            case .suffix4: return Resolved(resolution: .text(suffix))
            default: return Resolved(resolution: .text(prefix + suffix))
            }
        default:
            if field.isChoice {
                return Resolved(resolution: .unsupported("a phone number cannot go in a dropdown"))
            }
            if !nanp {
                return Resolved(resolution: .text(explicitPlus ? "+" + digits : digits))
            }
            // Copy the page's own layout when its example shows one, e.g. "(555) 555-5555".
            let example = field.placeholder
            if example.filter(\.isNumber).count == 10, example.contains(where: { "()- .".contains($0) }) {
                var remaining = Substring(national)
                let shaped = String(example.map { ch -> Character in
                    if ch.isNumber, let next = remaining.first { remaining = remaining.dropFirst(); return next }
                    return ch
                })
                return Resolved(resolution: .text(shaped))
            }
            return Resolved(resolution: .text(national))
        }
    }
}

/// Picks the dropdown or radio choice that means the same as a saved value.
enum OptionMatcher {
    static func match(_ options: [FieldOption], candidates: [String], allowPrefix: Bool = true) -> FieldOption? {
        let wanted = candidates.map(Geography.normalize).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return nil }
        // Exact on the visible text first, then on the submitted value.
        for candidate in wanted {
            if let hit = options.first(where: { Geography.normalize($0.t) == candidate }) { return hit }
        }
        for candidate in wanted {
            if let hit = options.first(where: { !$0.v.isEmpty && Geography.normalize($0.v) == candidate }) { return hit }
        }
        guard allowPrefix else { return nil }
        // "TX - Texas", "01 - January", "United States (+1)".
        for candidate in wanted where candidate.count >= 3 {
            let hits = options.filter { option in
                let text = Geography.normalize(option.t)
                return text.hasPrefix(candidate) || text.hasSuffix(candidate)
            }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }
}
