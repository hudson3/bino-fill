import Foundation

/// Makes the password for a new account. Random from the system's secure generator;
/// nothing about you goes into it.
public enum PasswordMaker {
    // Without l, I, O, 0 and 1, so it can be read off a screen and typed on a phone.
    static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    /// The marks nearly every site accepts.
    static let symbols = Array("-_!@#$%*?")

    public static let defaultLength = 20
    /// Shorter than this is not worth calling strong; a box that allows less is left to you.
    public static let shortestAllowed = 12

    /// At least one of each kind of character, and never the same character twice in a
    /// row (some sites refuse that).
    public static func make(length: Int = defaultLength, symbols useSymbols: Bool = true) -> String {
        var random = SystemRandomNumberGenerator()
        let kinds = [lower, upper, digits] + (useSymbols ? [symbols] : [])
        let all = kinds.flatMap { $0 }
        let length = max(length, shortestAllowed)
        while true {
            var characters = kinds.map { $0.randomElement(using: &random)! }
            while characters.count < length { characters.append(all.randomElement(using: &random)!) }
            characters.shuffle(using: &random)
            let repeats = zip(characters, characters.dropFirst()).contains { $0 == $1 }
            // A leading mark trips up some sites' checks.
            if !repeats, characters[0].isLetter { return String(characters) }
        }
    }
}
