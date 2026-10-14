import Foundation

/// Finds, in your note, the line that answers a form field the vault's own fields do
/// not: "Known Traveler Number: 98765", "Gate code - 4412", "EIN = 12-3456789". A line
/// counts only when every word of its label is in the field's wording and at least one
/// of them says something specific. Lines that look like passwords are never used.
public enum NoteLookup {
    public struct Hit: Equatable {
        public var value: String
        public var label: String
    }

    private static let secret = try! NSRegularExpression(
        pattern: #"pass(word|code|wd|phrase)?s?\b|\bpw\b|\bpin\b|\bcvv\b|\bcvc\b|security code|secret|\bssn\b|social security|token|api key|recovery|backup code"#,
        options: [.caseInsensitive])

    /// Words that say what kind of thing a line is, not which thing.
    static let generic: Set<String> = [
        "number", "no", "num", "name", "id", "code", "date", "email", "phone", "address", "account", "your", "my", "the",
        "of", "enter", "please", "a", "an", "and", "or", "to", "in", "for", "type", "field", "required", "optional",
        "info", "information", "details", "value", "new", "old", "current", "with", "on", "at", "is", "it", "this",
    ]

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty })
    }

    /// The "label: value" lines of a note, one per line, in order.
    public static func lines(_ notes: String) -> [(label: String, value: String)] {
        var out: [(String, String)] = []
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var split: (String, String)?
            for separator in [":", "\t", " - ", " – ", " = ", "="] {
                if let range = line.range(of: separator) {
                    let label = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty, !value.isEmpty, label.count <= 60 {
                        if split == nil || label.count < split!.0.count { split = (label, value) }
                    }
                }
            }
            if let split, split.1.count <= 200 { out.append(split) }
        }
        return out
    }

    public static func value(for field: PageField, in notes: String) -> Hit? {
        guard !notes.isEmpty else { return nil }
        let want = words(field.label + " " + field.placeholder + " " + FieldRules.nameKey(field) + " " + field.section)
        guard !want.isEmpty else { return nil }
        var best: (hit: Hit, score: Int)?
        for (label, value) in lines(notes) {
            guard secret.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) == nil else { continue }
            let have = words(label)
            guard !have.isEmpty, have.isSubset(of: want) else { continue }
            let specific = have.subtracting(generic).filter { $0.count >= 3 }
            guard !specific.isEmpty else { continue }
            let score = have.count * 10 + specific.count
            if best == nil || score > best!.score { best = (Hit(value: value, label: label), score) }
        }
        return best?.hit
    }
}
