import Foundation

/// Suggests where each line of a pasted note belongs, using the Ollama model already on
/// this Mac. The note only ever goes to 127.0.0.1. Every suggestion is checked against
/// the note and shown for review; nothing is saved without you.
public struct NoteSorter {
    public var model = "llama3.2"
    public var endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    public init() {}

    public struct Suggestion: Codable, Equatable {
        public var title, firstName, middleName, lastName, suffix, dateOfBirth, gender, nationality: String?
        public var email, phone, company: String?
        public var addressLine1, addressLine2, city, state, postalCode, country: String?
        public var passportNumber, passportIssuingCountry, passportIssueDate, passportExpiryDate: String?
        public var knownTravelerNumber, redressNumber: String?
        public var cards: [CardSuggestion]?
        public var logins: [LoginSuggestion]?
        public var loyalty: [LoyaltySuggestion]?

        public init() {}
    }

    public struct CardSuggestion: Codable, Equatable {
        public var label, cardholderName, number, expMonth, expYear, cvv: String?
    }

    public struct LoginSuggestion: Codable, Equatable {
        public var site, username, password: String?
    }

    public struct LoyaltySuggestion: Codable, Equatable {
        public var program, number: String?
    }

    public enum SortError: Error, CustomStringConvertible {
        case unavailable
        case tooSlow
        case badReply

        public var description: String {
            switch self {
            case .unavailable: return "Ollama is not running on this Mac, so auto-sort is unavailable. Fill the fields by hand."
            case .tooSlow: return "The local model took too long on this note. Fill the remaining fields by hand, or try a shorter piece of the note."
            case .badReply: return "The local model did not return something usable. Fill the fields by hand."
            }
        }
    }

    private static let stringField: [String: Any] = ["type": "string"]

    // Every key is required: left optional, the small model simply returns nothing.
    private static func object(_ keys: [String]) -> [String: Any] {
        ["type": "object", "required": keys,
         "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, stringField as Any) })]
    }

    private static var schema: [String: Any] {
        let plain = ["title", "firstName", "middleName", "lastName", "suffix", "dateOfBirth", "gender", "nationality",
                     "email", "phone", "company", "addressLine1", "addressLine2", "city", "state", "postalCode",
                     "country", "passportNumber", "passportIssuingCountry", "passportIssueDate",
                     "passportExpiryDate", "knownTravelerNumber", "redressNumber"]
        var properties = Dictionary(uniqueKeysWithValues: plain.map { ($0, stringField as Any) })
        properties["cards"] = ["type": "array",
                               "items": object(["label", "cardholderName", "number", "expMonth", "expYear", "cvv"])]
        properties["logins"] = ["type": "array", "items": object(["site", "username", "password"])]
        properties["loyalty"] = ["type": "array", "items": object(["program", "number"])]
        return ["type": "object", "properties": properties, "required": plain + ["cards", "logins", "loyalty"]]
    }

    public func sort(note: String) async throws -> Suggestion {
        let system = """
            You copy details out of a personal note into labelled fields. Copy each value exactly as written. \
            Use an empty string when the note does not contain a field. Never invent or guess a value. \
            Dates of birth and passport dates go in YYYY-MM-DD form. For logins, "site" is the website \
            the account is for, such as united.com.
            """
        let body: [String: Any] = [
            "model": model, "stream": false, "format": Self.schema,
            // Room for a long note: Ollama's default window would silently drop the start of it.
            "options": ["temperature": 0, "num_ctx": 8192],
            "messages": [["role": "system", "content": system], ["role": "user", "content": note]],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            let (payload, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SortError.unavailable }
            data = payload
        } catch let error as URLError where error.code == .timedOut {
            throw SortError.tooSlow
        } catch is URLError {
            throw SortError.unavailable
        }
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = reply["message"] as? [String: Any],
              let content = (message["content"] as? String)?.data(using: .utf8),
              let suggestion = try? JSONDecoder().decode(Suggestion.self, from: content)
        else { throw SortError.badReply }
        return Self.verified(suggestion, against: note)
    }

    // MARK: Trust nothing the note does not contain

    private static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Every full date written in the note, as "YYYY-M-D". A day/month pair that could be
    /// read either way is recorded both ways.
    static func dates(in note: String) -> Set<String> {
        var found = Set<String>()
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        func add(_ year: Int, _ month: Int, _ day: Int) {
            let fullYear = year < 100 ? (year < 50 ? 2000 + year : 1900 + year) : year
            if (1...12).contains(month), (1...31).contains(day) { found.insert("\(fullYear)-\(month)-\(day)") }
        }
        func each(_ pattern: String, _ body: ([String]) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let range = NSRange(note.startIndex..., in: note)
            regex.enumerateMatches(in: note, range: range) { match, _, _ in
                guard let match else { return }
                body((1..<match.numberOfRanges).map { Range(match.range(at: $0), in: note).map { String(note[$0]) } ?? "" })
            }
        }
        each(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) { g in add(Int(g[0])!, Int(g[1])!, Int(g[2])!) }
        each(#"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2}|\d{4})\b"#) { g in
            add(Int(g[2])!, Int(g[0])!, Int(g[1])!)
            add(Int(g[2])!, Int(g[1])!, Int(g[0])!)
        }
        each(#"\b([a-z]{3,9})\.? (\d{1,2})(?:st|nd|rd|th)?,? (\d{4})\b"#) { g in
            if let month = months.firstIndex(where: { g[0].lowercased().hasPrefix($0) }) { add(Int(g[2])!, month + 1, Int(g[1])!) }
        }
        each(#"\b(\d{1,2})(?:st|nd|rd|th)? ([a-z]{3,9})\.?,? (\d{4})\b"#) { g in
            if let month = months.firstIndex(where: { g[1].lowercased().hasPrefix($0) }) { add(Int(g[2])!, month + 1, Int(g[0])!) }
        }
        return found
    }

    /// Keeps a value only if its letters and digits appear in the note. Dates may be
    /// rewritten to YYYY-MM-DD, so a date is kept only if the note holds that same date.
    static func keep(_ value: String?, note: String, isDate: Bool = false) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if isDate {
            let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count == 3, numbers[0] > 1900 else { return nil }
            return dates(in: note).contains("\(numbers[0])-\(numbers[1])-\(numbers[2])")
                ? String(format: "%04d-%02d-%02d", numbers[0], numbers[1], numbers[2]) : nil
        }
        return squash(note).contains(squash(value)) ? value : nil
    }

    /// The line holding `value`, plus the one before and after it.
    static func lines(around value: String, in note: String) -> String {
        let all = note.components(separatedBy: .newlines)
        let wanted = squash(value)
        guard let index = all.firstIndex(where: { squash($0).contains(wanted) }) else { return "" }
        return all[max(0, index - 1)...min(all.count - 1, index + 1)].joined(separator: "\n")
    }

    static func verified(_ s: Suggestion, against note: String) -> Suggestion {
        var out = Suggestion()
        out.title = keep(s.title, note: note); out.firstName = keep(s.firstName, note: note)
        out.middleName = keep(s.middleName, note: note); out.lastName = keep(s.lastName, note: note)
        out.suffix = keep(s.suffix, note: note)
        out.dateOfBirth = keep(s.dateOfBirth, note: note, isDate: true)
        out.gender = keep(s.gender, note: note); out.nationality = keep(s.nationality, note: note)
        out.email = keep(s.email, note: note); out.phone = keep(s.phone, note: note)
        out.company = keep(s.company, note: note)
        out.addressLine1 = keep(s.addressLine1, note: note); out.addressLine2 = keep(s.addressLine2, note: note)
        out.city = keep(s.city, note: note); out.state = keep(s.state, note: note)
        out.postalCode = keep(s.postalCode, note: note); out.country = keep(s.country, note: note)
        out.passportNumber = keep(s.passportNumber, note: note)
        out.passportIssuingCountry = keep(s.passportIssuingCountry, note: note)
        out.passportIssueDate = keep(s.passportIssueDate, note: note, isDate: true)
        out.passportExpiryDate = keep(s.passportExpiryDate, note: note, isDate: true)
        out.knownTravelerNumber = keep(s.knownTravelerNumber, note: note)
        out.redressNumber = keep(s.redressNumber, note: note)
        out.cards = (s.cards ?? []).compactMap { card in
            guard let number = keep(card.number, note: note) else { return nil }
            // Expiry and security code must sit beside this card number, not come from elsewhere in the note.
            let nearby = lines(around: number, in: note)
            var year = keep(card.expYear, note: nearby)
            if year == nil, let digits = card.expYear?.filter(\.isNumber), digits.count == 4,
               nearby.split(whereSeparator: { !$0.isNumber }).contains(where: { $0 == digits.suffix(2) }) {
                year = digits
            }
            return CardSuggestion(label: keep(card.label, note: note), cardholderName: keep(card.cardholderName, note: note),
                                  number: number, expMonth: keep(card.expMonth, note: nearby),
                                  expYear: year, cvv: keep(card.cvv, note: nearby))
        }
        out.logins = (s.logins ?? []).compactMap { login in
            guard let password = keep(login.password, note: note) else { return nil }
            let nearby = lines(around: password, in: note)
            return LoginSuggestion(site: keep(login.site, note: nearby), username: keep(login.username, note: nearby),
                                   password: password)
        }
        out.loyalty = (s.loyalty ?? []).compactMap { entry in
            guard let number = keep(entry.number, note: note) else { return nil }
            return LoyaltySuggestion(program: keep(entry.program, note: note), number: number)
        }
        return out
    }

    /// Copies suggestions into empty vault fields only, and says which fields it touched.
    public static func apply(_ s: Suggestion, to vault: inout Vault) -> [String] {
        var touched: [String] = []
        func set(_ target: inout String, _ value: String?, _ name: String) {
            guard target.isEmpty, let value, !value.isEmpty else { return }
            target = value
            touched.append(name)
        }
        set(&vault.profile.title, s.title, "title"); set(&vault.profile.firstName, s.firstName, "first name")
        set(&vault.profile.middleName, s.middleName, "middle name"); set(&vault.profile.lastName, s.lastName, "last name")
        set(&vault.profile.suffix, s.suffix, "suffix"); set(&vault.profile.dateOfBirth, s.dateOfBirth, "date of birth")
        set(&vault.profile.gender, s.gender, "gender"); set(&vault.profile.nationality, s.nationality, "nationality")
        set(&vault.profile.email, s.email, "email"); set(&vault.profile.phone, s.phone, "phone")
        set(&vault.profile.company, s.company, "company")
        set(&vault.profile.address.line1, s.addressLine1, "street address")
        set(&vault.profile.address.line2, s.addressLine2, "apartment")
        set(&vault.profile.address.city, s.city, "city"); set(&vault.profile.address.state, s.state, "state")
        set(&vault.profile.address.postalCode, s.postalCode, "postal code")
        set(&vault.profile.address.country, s.country, "country")
        set(&vault.profile.passport.number, s.passportNumber, "passport number")
        set(&vault.profile.passport.issuingCountry, s.passportIssuingCountry, "passport country")
        set(&vault.profile.passport.issueDate, s.passportIssueDate, "passport issue date")
        set(&vault.profile.passport.expiryDate, s.passportExpiryDate, "passport expiry")
        set(&vault.profile.knownTravelerNumber, s.knownTravelerNumber, "known traveler number")
        set(&vault.profile.redressNumber, s.redressNumber, "redress number")

        for suggestion in s.cards ?? [] {
            let digits = (suggestion.number ?? "").filter(\.isNumber)
            guard digits.count >= 12, !vault.cards.contains(where: { $0.digits == digits }) else { continue }
            var card = Card()
            card.label = suggestion.label ?? ""; card.cardholderName = suggestion.cardholderName ?? ""
            card.number = suggestion.number ?? ""; card.expMonth = suggestion.expMonth ?? ""
            card.expYear = suggestion.expYear ?? ""; card.cvv = suggestion.cvv ?? ""
            card.isDefault = vault.cards.isEmpty
            vault.cards.append(card)
            touched.append("card ending \(card.last4)")
        }
        for suggestion in s.logins ?? [] {
            let site = SitePolicy.normalizeSite(suggestion.site ?? "")
            guard !vault.logins.contains(where: { SitePolicy.normalizeSite($0.site) == site && $0.username == (suggestion.username ?? "") })
            else { continue }
            var login = Login()
            login.site = site; login.username = suggestion.username ?? ""; login.password = suggestion.password ?? ""
            vault.logins.append(login)
            touched.append("login for \(site.isEmpty ? "unknown site" : site)")
        }
        for suggestion in s.loyalty ?? [] {
            guard !vault.profile.loyalty.contains(where: { $0.number == suggestion.number }) else { continue }
            var entry = Loyalty()
            entry.program = suggestion.program ?? ""; entry.number = suggestion.number ?? ""
            vault.profile.loyalty.append(entry)
            touched.append("member number for \(entry.program.isEmpty ? "unknown programme" : entry.program)")
        }
        return touched
    }
}
