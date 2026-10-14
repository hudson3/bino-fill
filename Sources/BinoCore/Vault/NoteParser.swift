import Foundation

/// Reads the common "label, then username, then password" shapes out of a note with
/// fixed rules. It is instant, and it cannot invent anything: every value is a line
/// copied from the note. Whatever it does not recognise is handed back as leftover.
public enum NoteParser {
    public struct Result {
        public var logins: [Login] = []
        /// Lines that are not logins (personal details, cards and so on).
        public var leftover = ""
        /// Labels whose site was worked out from a well-known name rather than written in the note.
        public var guessedSites: [String] = []
    }

    // A label like this introduces personal details, not a login.
    private static let notALogin = try! NSRegularExpression(
        pattern: #"passport|address|\bname\b|birth|\bdob\b|phone|\bcell\b|mobile|\bcard\b|visa|mastercard|amex|\bktn\b|known travell?er|redress|\btsa\b|\bssn\b|licen[sc]e|frequent fl[yi]er|\bmiles\b"#,
        options: [.caseInsensitive])

    private static let knownSites: [(word: String, site: String)] = [
        ("gmail", "google.com"), ("google", "google.com"), ("youtube", "google.com"),
        ("apple", "apple.com"), ("icloud", "apple.com"), ("supabase", "supabase.com"), ("twilio", "twilio.com"),
        ("github", "github.com"), ("vercel", "vercel.com"), ("expo", "expo.dev"), ("openai", "openai.com"),
        ("stripe", "stripe.com"), ("cloudflare", "cloudflare.com"), ("aws", "amazon.com"), ("amazon", "amazon.com"),
        ("netflix", "netflix.com"), ("spotify", "spotify.com"), ("paypal", "paypal.com"),
        ("facebook", "facebook.com"), ("instagram", "instagram.com"), ("twitter", "x.com"),
        ("linkedin", "linkedin.com"), ("reddit", "reddit.com"), ("discord", "discord.com"), ("slack", "slack.com"),
        ("notion", "notion.so"), ("figma", "figma.com"), ("dropbox", "dropbox.com"), ("siteground", "siteground.com"),
        ("united", "united.com"), ("delta", "delta.com"), ("southwest", "southwest.com"),
        ("american airlines", "aa.com"), ("jetblue", "jetblue.com"), ("alaska air", "alaskaair.com"),
        ("airbnb", "airbnb.com"), ("uber", "uber.com"), ("venmo", "venmo.com"),
    ]

    /// The site a label refers to: one written in the label itself, else a well-known name.
    static func site(for label: String) -> (site: String, guessed: Bool) {
        let lower = label.lowercased()
        if let range = lower.range(of: #"([a-z0-9-]+\.)+[a-z]{2,}"#, options: .regularExpression) {
            let candidate = SitePolicy.normalizeSite(String(lower[range]))
            if SitePolicy.isAcceptableSite(candidate) { return (candidate, false) }
        }
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for entry in knownSites {
            let hit = entry.word.contains(" ") ? lower.contains(entry.word) : words.contains(entry.word)
            if hit { return (entry.site, true) }
        }
        return ("", false)
    }

    /// A username or password: one unbroken run of characters.
    private static func isCredential(_ line: String) -> Bool {
        !line.isEmpty && !line.contains(" ") && !line.hasSuffix(":")
    }

    private static func header(_ line: String) -> String? {
        guard line.hasSuffix(":") else { return nil }
        let label = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    private static func looksPersonal(_ label: String) -> Bool {
        notALogin.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    /// "united.com - alex / secret" and "Example login: alex pw: secret" on one line.
    private static func inline(_ line: String) -> Login? {
        let patterns = [
            #"^(.+?)\s*[-–—:]\s*(\S+)\s*/\s*(\S+)$"#,
            #"^(.+?)\s+(?:login|user(?:name)?|email):\s*(\S+)\s+(?:pw|pass|password):\s*(\S+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges == 4
            else { continue }
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
            guard parts.count == 3, !looksPersonal(parts[0]) else { continue }
            // "born - 3/14/1990" is a date, not a username and password.
            let dateLike = CharacterSet(charactersIn: "0123456789/.-")
            if (parts[1] + parts[2]).unicodeScalars.allSatisfy(dateLike.contains) { continue }
            var login = Login()
            login.note = parts[0].trimmingCharacters(in: .whitespaces)
            login.username = parts[1]
            login.password = parts[2]
            return login
        }
        return nil
    }

    public static func parse(_ note: String) -> Result {
        var result = Result()
        var leftover: [String] = []

        // Blocks are runs of lines separated by blank lines.
        var blocks: [[String]] = [[]]
        for raw in note.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !(blocks.last?.isEmpty ?? true) { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }

        for block in blocks where !block.isEmpty {
            guard let label = header(block[0]) else {
                // No label line: keep any one-line logins, pass the rest on.
                for line in block {
                    if let login = inline(line) { result.logins.append(login) } else { leftover.append(line) }
                }
                leftover.append("")
                continue
            }
            let body = Array(block.dropFirst())
            if body.isEmpty { continue }  // a heading for the blocks that follow
            if looksPersonal(label) {
                leftover.append(contentsOf: block)
                leftover.append("")
                continue
            }

            // "Enrollment id:" followed by its value is an extra detail, kept with the login.
            var values: [String] = []
            var extras: [String] = []
            var index = 0
            while index < body.count {
                if let sub = header(body[index]), index + 1 < body.count, header(body[index + 1]) == nil {
                    extras.append("\(sub): \(body[index + 1])")
                    index += 2
                } else {
                    values.append(body[index])
                    index += 1
                }
            }
            guard !values.isEmpty, values.allSatisfy(isCredential) else {
                leftover.append(contentsOf: block)
                leftover.append("")
                continue
            }

            var login = Login()
            if values.count == 1 {
                login.password = values[0]
            } else {
                login.username = values[0]
                login.password = values[1]
                extras.append(contentsOf: values.dropFirst(2))
            }
            login.note = ([label] + extras).joined(separator: " · ")
            result.logins.append(login)
        }

        for index in result.logins.indices {
            let label = result.logins[index].note.components(separatedBy: " · ").first ?? ""
            let found = site(for: label)
            result.logins[index].site = found.site
            if found.guessed { result.guessedSites.append(label) }
        }
        result.leftover = leftover.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Whether the leftover holds anything worth asking the model about: a line with a
    /// digit, an @, or several words. A stray title such as "Passwords" is not.
    public static func isWorthReading(_ leftover: String) -> Bool {
        leftover.components(separatedBy: .newlines).contains { line in
            line.contains("@") || line.contains(where: \.isNumber) || line.split(separator: " ").count >= 3
        }
    }

    /// Adds parsed logins that are not already in the vault. Returns how many were added.
    public static func apply(_ result: Result, to vault: inout Vault) -> Int {
        var added = 0
        for login in result.logins {
            let exists = vault.logins.contains { $0.username == login.username && $0.password == login.password }
            if !exists {
                vault.logins.append(login)
                added += 1
            }
        }
        return added
    }
}
