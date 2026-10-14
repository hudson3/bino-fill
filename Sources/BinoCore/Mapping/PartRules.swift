import Foundation

/// Works out which slice of a value a field wants when a date or phone number is
/// split across several boxes.
enum PartRules {
    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august",
                             "september", "october", "november", "december"]

    static func part(for concept: Concept, field: PageField) -> Part? {
        switch concept {
        case .dob, .passportExpiry, .passportIssue, .cardExpiry:
            return datePart(field)
        case .phone:
            return phonePart(field)
        case .middleName:
            let text = FieldRules.labelText(field) + " " + FieldRules.nameKey(field)
            if field.maxLength == 1 || text.contains("initial") || matches(text, #"\bmi\b"#) { return .initial }
            return .whole
        default:
            return nil
        }
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Numbers offered by a dropdown, ignoring a leading "Month"/"--" placeholder.
    static func numericOptions(_ field: PageField) -> [Int] {
        field.options.compactMap { option in
            let text = option.t.trimmingCharacters(in: .whitespaces)
            if let n = Int(text) { return n }
            return Int(option.v.trimmingCharacters(in: .whitespaces))
        }
    }

    static func datePart(_ field: PageField) -> Part {
        if field.type == "date" || field.type == "month" { return .whole }

        if field.type == "select" {
            let named = field.options.filter { option in
                let t = option.t.lowercased()
                return monthNames.contains { t.contains($0.prefix(3)) }
            }.count
            if named >= 6 { return .month }
            let numbers = numericOptions(field)
            if let top = numbers.max(), numbers.count >= 5 {
                if top >= 1900 { return .year }
                if top <= 12, numbers.count >= 12 { return .month }
                if top <= 31, numbers.count >= 28 { return .day }
                // Two-digit years on a card: a run of consecutive numbers starting near now.
                if top <= 99, numbers.count <= 25 { return .year }
            }
        }

        // The field's own name is the most reliable hint ("bday_mm", "expYear").
        let key = FieldRules.lastSegment(field.name) + " " + FieldRules.words(field.domId)
        if let part = partFromWords(key) { return part }

        var label = FieldRules.labelText(field)
        for phrase in ["birthday", "birth date", "date of birth", "birthdate"] {
            label = label.replacingOccurrences(of: phrase, with: " ")
        }
        if let part = partFromWords(label) { return part }

        if field.maxLength == 4, !matches(label, "/") { return .year }
        return .whole
    }

    /// Returns a part only when the words name exactly one of day, month, year.
    private static func partFromWords(_ text: String) -> Part? {
        let month = matches(text, #"\b(month|mon|mm|mo)\b|month"#)
        let day = matches(text, #"\b(day|dd)\b"#)
        let year = matches(text, #"\b(year|yr|yyyy|yy)\b|year"#)
        switch (month, day, year) {
        case (true, false, false): return .month
        case (false, true, false): return .day
        case (false, false, true): return .year
        default: return nil
        }
    }

    static func phonePart(_ field: PageField) -> Part {
        let text = FieldRules.labelText(field) + " " + FieldRules.nameKey(field)
        if matches(text, #"country ?code|dial(ing)? ?code|calling code|intl.*prefix"#) { return .countryCode }
        if field.type == "select", field.options.contains(where: { $0.t.contains("+") }) { return .countryCode }
        if matches(text, #"area ?code|\bnpa\b"#) { return .areaCode }
        if matches(text, #"\bprefix\b|exchange|\bnxx\b|first (three|3)"#) { return .prefix3 }
        if matches(text, #"\bsuffix\b|line ?number|last (four|4)"#) { return .suffix4 }
        return .whole
    }

    /// Fills in parts for a run of neighbouring fields that share one value, using what is
    /// already known and the boxes' sizes. Returns a note when it had to assume an order.
    static func settleDateRun(_ parts: [Part]) -> (parts: [Part], assumed: Bool) {
        var parts = parts
        let wanted: [Part] = parts.count == 2 ? [.month, .year] : [.month, .day, .year]
        guard parts.count == wanted.count else { return (parts, false) }
        let known = Set(parts.filter { $0 != .whole })
        let unknownSlots = parts.indices.filter { parts[$0] == .whole }
        let missing = wanted.filter { !known.contains($0) }
        guard !unknownSlots.isEmpty, unknownSlots.count == missing.count else { return (parts, false) }
        for (slot, part) in zip(unknownSlots, missing) { parts[slot] = part }
        // One gap is settled by elimination; more than one means the order was a guess.
        return (parts, unknownSlots.count > 1)
    }

    /// Boxes too small for a whole number take the next slice, judged by their size.
    static func settlePhoneRun(_ fields: [PageField], _ parts: [Part]) -> [Part] {
        var parts = parts
        let open = parts.indices.filter { parts[$0] == .whole }
        let sizes = open.map { fields[$0].maxLength }
        let haveArea = parts.contains(.areaCode)
        if !haveArea, sizes == [3, 3, 4] {
            parts[open[0]] = .areaCode; parts[open[1]] = .prefix3; parts[open[2]] = .suffix4
        } else if !haveArea, open.count == 2, sizes[0] == 3, sizes[1] == 7 || sizes[1] == 8 {
            parts[open[0]] = .areaCode; parts[open[1]] = .local
        } else if haveArea {
            for (slot, size) in zip(open, sizes) {
                switch size {
                case 3: parts[slot] = .prefix3
                case 4: parts[slot] = .suffix4
                case 7, 8: parts[slot] = .local
                default: break
                }
            }
        }
        return parts
    }
}
