import Foundation

/// Names a country or US state can go by, so a saved "United States" can be matched to a
/// dropdown that says "USA" or has the value "US".
enum Geography {
    private static let english = Locale(identifier: "en_US")

    private static let iso3: [String: String] = [
        "US": "USA", "CA": "CAN", "MX": "MEX", "GB": "GBR", "IE": "IRL", "FR": "FRA", "DE": "DEU", "ES": "ESP",
        "IT": "ITA", "PT": "PRT", "NL": "NLD", "BE": "BEL", "CH": "CHE", "AT": "AUT", "SE": "SWE", "NO": "NOR",
        "DK": "DNK", "FI": "FIN", "IS": "ISL", "PL": "POL", "CZ": "CZE", "GR": "GRC", "TR": "TUR", "IL": "ISR",
        "AE": "ARE", "SA": "SAU", "IN": "IND", "CN": "CHN", "JP": "JPN", "KR": "KOR", "SG": "SGP", "HK": "HKG",
        "TW": "TWN", "TH": "THA", "VN": "VNM", "PH": "PHL", "ID": "IDN", "MY": "MYS", "AU": "AUS", "NZ": "NZL",
        "BR": "BRA", "AR": "ARG", "CL": "CHL", "CO": "COL", "PE": "PER", "ZA": "ZAF", "EG": "EGY", "NG": "NGA",
        "KE": "KEN", "MA": "MAR", "RU": "RUS", "UA": "UKR", "HU": "HUN", "RO": "ROU", "HR": "HRV", "CR": "CRI",
        "PA": "PAN", "DO": "DOM", "JM": "JAM", "BS": "BHS", "PR": "PRI",
    ]

    private static let aliases: [String: [String]] = [
        "US": ["United States", "United States of America", "USA", "U.S.", "U.S.A.", "America", "American"],
        "GB": ["United Kingdom", "UK", "U.K.", "Great Britain", "Britain", "England", "British"],
        "CA": ["Canadian"], "AU": ["Australian"], "MX": ["Mexican"], "IE": ["Irish"], "DE": ["German"],
        "FR": ["French"], "ES": ["Spanish"], "IT": ["Italian"], "IN": ["Indian"], "CN": ["Chinese"],
        "JP": ["Japanese"], "KR": ["South Korea", "Korea", "Republic of Korea", "Korean"],
        "NL": ["Netherlands", "Holland", "Dutch"], "BR": ["Brazilian"], "NZ": ["New Zealander"],
        "AE": ["UAE", "United Arab Emirates"], "RU": ["Russia", "Russian Federation"],
        "CZ": ["Czech Republic", "Czechia"], "TR": ["Turkey", "Türkiye"],
    ]

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static let codeByName: [String: String] = {
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2 else { continue }
            if let name = english.localizedString(forRegionCode: code) { map[normalize(name)] = code }
            map[normalize(code)] = code
        }
        for (code, three) in iso3 { map[normalize(three)] = code }
        for (code, names) in aliases { for name in names { map[normalize(name)] = code } }
        return map
    }()

    /// ISO two-letter code for whatever was typed in the vault.
    static func countryCode(for text: String) -> String? {
        codeByName[normalize(text)]
    }

    /// Every way the country might appear in a dropdown, most specific first.
    static func countryNames(for text: String) -> [String] {
        guard let code = countryCode(for: text) else { return [text] }
        var names: [String] = []
        if let name = english.localizedString(forRegionCode: code) { names.append(name) }
        names.append(contentsOf: aliases[code] ?? [])
        names.append(code)
        if let three = iso3[code] { names.append(three) }
        names.append(text)
        return names
    }

    static let states: [(abbr: String, name: String)] = [
        ("AL", "Alabama"), ("AK", "Alaska"), ("AZ", "Arizona"), ("AR", "Arkansas"), ("CA", "California"),
        ("CO", "Colorado"), ("CT", "Connecticut"), ("DE", "Delaware"), ("DC", "District of Columbia"),
        ("FL", "Florida"), ("GA", "Georgia"), ("HI", "Hawaii"), ("ID", "Idaho"), ("IL", "Illinois"),
        ("IN", "Indiana"), ("IA", "Iowa"), ("KS", "Kansas"), ("KY", "Kentucky"), ("LA", "Louisiana"),
        ("ME", "Maine"), ("MD", "Maryland"), ("MA", "Massachusetts"), ("MI", "Michigan"), ("MN", "Minnesota"),
        ("MS", "Mississippi"), ("MO", "Missouri"), ("MT", "Montana"), ("NE", "Nebraska"), ("NV", "Nevada"),
        ("NH", "New Hampshire"), ("NJ", "New Jersey"), ("NM", "New Mexico"), ("NY", "New York"),
        ("NC", "North Carolina"), ("ND", "North Dakota"), ("OH", "Ohio"), ("OK", "Oklahoma"), ("OR", "Oregon"),
        ("PA", "Pennsylvania"), ("RI", "Rhode Island"), ("SC", "South Carolina"), ("SD", "South Dakota"),
        ("TN", "Tennessee"), ("TX", "Texas"), ("UT", "Utah"), ("VT", "Vermont"), ("VA", "Virginia"),
        ("WA", "Washington"), ("WV", "West Virginia"), ("WI", "Wisconsin"), ("WY", "Wyoming"),
        ("PR", "Puerto Rico"),
    ]

    /// Abbreviation and full name for a US state, whichever was saved. Other regions pass through.
    static func stateNames(for text: String) -> [String] {
        let wanted = normalize(text)
        if let match = states.first(where: { normalize($0.abbr) == wanted || normalize($0.name) == wanted }) {
            return [match.abbr, match.name]
        }
        return [text]
    }
}
