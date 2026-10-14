import Foundation

/// What pressing a button would do, judged from its wording by fixed rules.
public enum ButtonKind: String, Codable {
    /// Moves to the next step. The only kind Bino presses on its own (besides sign-in).
    case next
    /// Pays, books, orders or submits. Never pressed.
    case final
    case login
    /// Back, cancel, help and the like.
    case other
}

public enum ButtonRules {
    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // Checked first: anything that spends money or commits you.
    private static let final = rx(
        #"\bpay\b|\bbuy\b|purchase|place (your |my )?order|order now|\bbook\b|\breserve\b|donate|"#
        + #"(complete|submit|make|confirm|process|send|finish|authori[sz]e) (a |my |your |the )?(payment|order|purchase|booking|reservation|application|request|transaction)|"#
        + #"^(submit|confirm|complete|finish|finali[sz]e|send|apply now|enroll|join|agree.*|accept.*|i agree|sign up|register|create (my |an |your )?account)\b"#)

    private static let next = rx(
        #"^(continue|next|proceed|save (and|&) continue|save (and|&) next|go to (the )?(next|payment|checkout|review)|"#
        + #"review( and continue| (your |my )?(order|booking|trip|details|itinerary))?|check ?out|begin checkout|continue checkout|start|get started)\b"#)

    // Look like "continue" but lead away from the form or make a choice for you.
    private static let detour = rx(
        #"shopping|browsing|as (a )?guest|without|start (over|again|new)|new search|write a review|reviews|review (this|item|product)"#)

    private static let login = rx(#"^(sign in|log in|login|log on|sign on)\b"#)

    private static let other = rx(
        #"back|previous|cancel|edit|change|remove|delete|clear|reset|close|help|learn more|add\b|search|find|^apply\b|"#
        + #"forgot|show|hide|skip|no,? thanks|upload|print|share|menu|view|details|select|choose|modify|update|"#
        + #"calculate|redeem|use this|promo|coupon|gift|chat|feedback|language|currency"#)

    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "$" || scalar == "&" || scalar == "," ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func found(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// nil means the wording is not recognised, which Bino treats as "do not press".
    public static func classify(_ rawText: String) -> ButtonKind? {
        let text = normalize(rawText)
        if text.isEmpty { return nil }
        if found(final, text) { return .final }
        if found(detour, text) { return .other }
        if found(login, text) { return .login }
        if found(next, text) { return .next }
        if found(other, text) { return .other }
        return nil
    }
}
