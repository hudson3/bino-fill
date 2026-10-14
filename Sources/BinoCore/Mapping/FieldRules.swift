import Foundation

/// A guess at what a field wants, made from fixed rules with no model involved.
public struct RuleHit: Equatable {
    public enum Strength: Int, Comparable {
        /// A hint only: ask the model.
        case weak = 0
        /// The label or the field's name says so plainly.
        case strong = 1
        /// The label and the name agree, or the page declares it outright.
        case certain = 2

        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    public var concept: Concept
    public var part: Part?
    public var strength: Strength
    /// The page marks this as a password being created, not an existing one.
    public var newPassword = false
}

public enum FieldRules {
    // MARK: Standard autocomplete hints

    private static let autocompleteMap: [String: (Concept, Part?)] = [
        "name": (.fullName, nil), "given-name": (.firstName, nil), "additional-name": (.middleName, nil),
        "family-name": (.lastName, nil), "honorific-prefix": (.title, nil), "honorific-suffix": (.suffix, nil),
        "email": (.email, nil), "username": (.username, nil), "current-password": (.password, nil),
        "new-password": (.password, nil), "organization": (.company, nil),
        "street-address": (.addressLine1, nil), "address-line1": (.addressLine1, nil),
        "address-line2": (.addressLine2, nil), "address-level2": (.city, nil), "address-level1": (.state, nil),
        "postal-code": (.postalCode, nil), "country": (.country, nil), "country-name": (.country, nil),
        "tel": (.phone, .whole), "tel-national": (.phone, .national), "tel-local": (.phone, .local), "tel-country-code": (.phone, .countryCode),
        "tel-area-code": (.phone, .areaCode), "tel-local-prefix": (.phone, .prefix3),
        "tel-local-suffix": (.phone, .suffix4), "tel-extension": (.phoneExtension, nil),
        "cc-name": (.cardName, nil), "cc-number": (.cardNumber, nil), "cc-exp": (.cardExpiry, .whole),
        "cc-exp-month": (.cardExpiry, .month), "cc-exp-year": (.cardExpiry, .year), "cc-csc": (.cardCVV, nil),
        "cc-type": (.cardType, nil), "bday": (.dob, .whole), "bday-day": (.dob, .day),
        "bday-month": (.dob, .month), "bday-year": (.dob, .year), "sex": (.gender, nil),
        "one-time-code": (.none, nil),
    ]

    static func fromAutocomplete(_ attribute: String) -> RuleHit? {
        // e.g. "section-pax1 billing tel-national": the last token names the field.
        guard let token = attribute.split(separator: " ").last.map(String.init),
              let (concept, part) = autocompleteMap[token]
        else { return nil }
        return RuleHit(concept: concept, part: part, strength: .certain, newPassword: token == "new-password")
    }

    // MARK: Keyword rules, most specific first

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals in this file; a bad one is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let rules: [(concept: Concept, regex: NSRegularExpression, weak: Bool)] = [
        (.none, rx(#"\bfax\b|search|keyword|promo|coupon|discount|voucher|gift|captcha|(security|secret) ?(question|answer)|\bhint\b|comment|\bmessage\b|quantity|\bqty\b|newsletter|\bssn\b|social security|one.?time|\botp\b|nick ?name|job ?title|\bage\b|how did you hear|referr|(country|place|city|town|state|province)[a-z ]{0,20} of birth|birth ?(place|country|city)|(frequent ?fl[yi]er|loyalty|rewards?) program(me)?$"#), false),
        (.fullName, rx(#"first (and|&) last|first name last name|full ?name"#), false),
        (.cardCVV, rx(#"\bcvv2?\b|\bcvc2?\b|\bcsc\b|\bcid\b|\bcvn\b|card (verification|security|identification|id) ?(code|number|value|#)?|security code|verification (code|number|value)"#), false),
        (.cardName, rx(#"name on (the |your )?card|card ?holder|\bcc ?name\b|card ?name|name as (it )?appears|appears on (the |your )?card"#), false),
        (.cardType, rx(#"card ?type|\bcc ?type\b|type of card|card brand"#), false),
        (.cardNumber, rx(#"(credit|debit)? ?card ?(number|no\b|num\b|#)|\bcc ?(number|num|no)\b|card ?num|\bccn\b|credit ?card$"#), false),
        (.passportExpiry, rx(#"(passport|document|travel doc).*(expir|\bexp\b|valid until)|expir.*(passport|document)"#), false),
        (.passportIssue, rx(#"(passport|document).*(issue date|date of issue|issued on|date issued)|(issue date|date of issue|date issued).*(passport|document)"#), false),
        (.passportCountry, rx(#"(passport|document).*(country|issu)|(country|region|place) of issu|issuing (country|state|authority)"#), false),
        (.passportNumber, rx(#"(passport|travel document|document) ?(number|no\b|num\b|#|id\b)|^passport$"#), false),
        (.cardExpiry, rx(#"expir|\bexp\b|exp ?(date|month|year|mo\b|yr\b|mm|yy)|valid (thru|until|through)|good thru|\bmm ?/ ?yy"#), false),
        (.knownTravelerNumber, rx(#"known ?travell?er|\bktn\b|pass ?id\b|tsa ?pre|trusted ?travell?er|global ?entry"#), false),
        (.redressNumber, rx(#"redress"#), false),
        (.loyaltyNumber, rx(#"frequent ?fl[yi]er ?(number|no\b|num\b|#|id)|\bff ?(number|no|num|#)\b|mileage ?plan|mileage ?plus|loyalty ?(number|no\b|id|#)|member(ship)? ?(number|no\b|id|#)|rewards? ?(number|no\b|id|#)"#), false),
        (.nationality, rx(#"nationality|citizenship|\bcitizen\b"#), false),
        (.dob, rx(#"birth|\bdob\b|d\.o\.b|\bb ?day\b"#), false),
        (.gender, rx(#"gender|\bsex\b"#), false),
        (.password, rx(#"passw|\bpwd\b|passcode"#), false),
        // "Apple ID", "Microsoft account": the account's name at a site that calls it that.
        (.username, rx(#"user ?(name|id)|login ?(name|id)|\buserid\b|\blogin\b|screen ?name|member ?name|sign.?in ?(name|id)|apple ?(id|account)|microsoft account|google account"#), false),
        (.email, rx(#"e-?mail"#), false),
        (.phoneExtension, rx(#"\bext\b|extension"#), false),
        (.phone, rx(#"phone|mobile|\btel\b|telephone|\bcell\b|contact (number|no\b)|dial(ing)? ?code|calling code"#), false),
        (.title, rx(#"\btitle\b|salutation|honorific|name ?prefix"#), false),
        (.suffix, rx(#"name ?suffix|generational suffix"#), false),
        // On their own these two words are as likely to be parts of a phone number.
        (.title, rx(#"\bprefix\b"#), true),
        (.suffix, rx(#"suffix"#), true),
        (.firstName, rx(#"first ?name|given ?name|fore ?name|\bf ?name\b"#), false),
        (.middleName, rx(#"middle|\bm ?name\b|\bmi\b"#), false),
        (.lastName, rx(#"last ?name|sur ?name|family ?name|\bl ?name\b"#), false),
        (.company, rx(#"company|organi[sz]ation|business ?name|employer"#), false),
        (.addressLine2, rx(#"address ?(line)? ?(2|two)|addr(ess)? ?2|street ?(2|two)|line ?(2|two)|\bapt\b|apartment|\bsuite\b|\bunit\b"#), false),
        (.addressLine1, rx(#"(?<!mail )(?<!mail)(?<!ip )(?<!web )address|street|\baddr"#), false),
        (.city, rx(#"city|\btown\b|suburb|locality"#), false),
        (.state, rx(#"\bstate\b|province|\bregion\b"#), false),
        (.postalCode, rx(#"\bzip|post ?code|postal"#), false),
        (.country, rx(#"country"#), false),
        (.fullName, rx(#"your name"#), false),
        // A bare "name" is the least specific rule there is: only ever a hint.
        (.fullName, rx(#"\bname\b"#), true),
    ]

    /// Lowercases, splits camelCase and turns punctuation into spaces: "billAddr2" -> "bill addr2".
    static func words(_ raw: String) -> String {
        var out = ""
        var previous: Character?
        for ch in raw {
            if ch.isUppercase, let p = previous, p.isLowercase || p.isNumber { out.append(" ") }
            out.append(ch.isLetter || ch.isNumber ? Character(ch.lowercased()) : " ")
            previous = ch
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// First rule, in priority order, that matches natural-language text.
    static func matchText(_ text: String) -> (concept: Concept, weak: Bool)? {
        let range = NSRange(text.startIndex..., in: text)
        for rule in rules where rule.regex.firstMatch(in: text, range: range) != nil {
            return (rule.concept, rule.weak)
        }
        return nil
    }

    /// For machine names such as "mailing address zip" the most specific word comes last,
    /// so the match that ends furthest along wins.
    static func matchKey(_ key: String) -> (concept: Concept, weak: Bool)? {
        let range = NSRange(key.startIndex..., in: key)
        var best: (concept: Concept, weak: Bool, end: Int)?
        for rule in rules {
            var lastEnd = -1
            rule.regex.enumerateMatches(in: key, range: range) { match, _, _ in
                if let match { lastEnd = max(lastEnd, match.range.upperBound) }
            }
            guard lastEnd >= 0 else { continue }
            // A specific word beats a bare "name" wherever it sits ("organizationName").
            let better: Bool
            if let current = best {
                better = current.weak != rule.weak ? current.weak : lastEnd > current.end
            } else {
                better = true
            }
            if better { best = (rule.concept, rule.weak, lastEnd) }
        }
        return best.map { ($0.concept, $0.weak) }
    }

    /// How many different kinds of information a piece of text mentions.
    static func distinctMatches(_ text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<Concept>()
        for rule in rules where !rule.weak && rule.concept != Concept.none
            && rule.regex.firstMatch(in: text, range: range) != nil {
            seen.insert(rule.concept)
        }
        return seen.count
    }

    static func labelText(_ field: PageField) -> String {
        let text = [field.label, field.placeholder].filter { !$0.isEmpty }.joined(separator: " ")
        return text.lowercased().replacingOccurrences(of: "*", with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    static func nameKey(_ field: PageField) -> String {
        [field.name, field.domId].filter { !$0.isEmpty }.map(words).joined(separator: " ")
    }

    /// The last component of a dotted or nested name: "pax[0].givenName" -> "given name".
    static func lastSegment(_ name: String) -> String {
        let segments = name.split(whereSeparator: { "$.:/[]".contains($0) })
        return words(String(segments.last ?? ""))
    }

    // MARK: Classification

    public static func classify(_ field: PageField) -> RuleHit? {
        if let hit = fromAutocomplete(field.autocomplete) {
            return withPart(hit, field)
        }
        switch field.type {
        case "email": return RuleHit(concept: .email, part: nil, strength: .certain)
        case "checkbox", "textarea", "search", "file", "range", "color": return nil
        default: break
        }

        // A very long "label", or one naming several different things, is usually text the
        // page put near the field rather than its label.
        let text = labelText(field)
        let labelIsBlurb = text.count > 60 || distinctMatches(text) >= 3
        var fromLabel = matchText(text)
        var fromName = matchKey(lastSegment(field.name)) ?? matchKey(nameKey(field))

        // "Country code" beside phone wording is the dialling code, not the country.
        let phoneContext = text + " " + nameKey(field)
        if PartRules.matches(phoneContext, #"country ?code|\bprefix\b"#),
           PartRules.matches(phoneContext, #"phone|mobile|\btel\b|telephone|\bcell\b"#) {
            fromLabel = (.phone, false)
            fromName = (.phone, false)
        }

        var hit: RuleHit?
        switch (fromLabel, fromName) {
        case let (label?, name?) where label.concept == name.concept:
            hit = RuleHit(concept: label.concept, part: nil, strength: label.weak && name.weak ? .strong : .certain)
        case let (label?, name?):
            if labelIsBlurb || label.weak {
                // Two unreliable hints that disagree: a job for the model.
                hit = RuleHit(concept: name.concept, part: nil, strength: .weak)
            } else {
                hit = resolveConflict(label: label.concept, name: name.concept, nameIsWeak: name.weak)
            }
        case let (label?, nil):
            hit = RuleHit(concept: label.concept, part: nil, strength: label.weak || labelIsBlurb ? .weak : .strong)
        case let (nil, name?):
            hit = RuleHit(concept: name.concept, part: nil,
                          strength: field.label.isEmpty && !name.weak ? .strong : .weak)
        case (nil, nil):
            hit = nil
        }

        // "Expiry date" under a passport heading is the passport's, not a card's.
        if var dated = hit, dated.concept == .cardExpiry {
            let context = (field.section + " " + text + " " + nameKey(field)).lowercased()
            if context.contains("passport") || context.contains("travel doc") {
                dated.concept = .passportExpiry
                hit = dated
            }
        }

        if field.type == "password" {
            // Some sites mask the card security code like a password.
            if hit?.concept != .cardCVV { hit = RuleHit(concept: .password, part: nil, strength: .certain) }
        } else if field.type == "tel", hit == nil {
            hit = RuleHit(concept: .phone, part: nil, strength: .weak)
        }
        return hit.map { withPart($0, field) }
    }

    /// The label and the field's name point at different things.
    private static func resolveConflict(label: Concept, name: Concept, nameIsWeak: Bool) -> RuleHit {
        // Two boxes often share one label ("Address", "Phone") with the difference only in the name.
        if label == .addressLine1, name == .addressLine2 {
            return RuleHit(concept: .addressLine2, part: nil, strength: .strong)
        }
        if label == .phone, name == .phoneExtension {
            return RuleHit(concept: .phoneExtension, part: nil, strength: .strong)
        }
        // A generic word in the name loses to a specific label.
        if nameIsWeak { return RuleHit(concept: label, part: nil, strength: .strong) }
        // Anything else is a real disagreement: let the model weigh in.
        return RuleHit(concept: label, part: nil, strength: .weak)
    }

    private static func withPart(_ hit: RuleHit, _ field: PageField) -> RuleHit {
        var hit = hit
        if hit.part == nil { hit.part = PartRules.part(for: hit.concept, field: field) }
        return hit
    }
}
