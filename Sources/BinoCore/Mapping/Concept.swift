import Foundation

/// The kinds of information a form field can ask for. The `label` is the wording the
/// model sees; it must match sidecar/concepts.json (a test checks this).
public enum Concept: String, CaseIterable, Codable {
    case title
    case firstName = "first_name"
    case middleName = "middle_name"
    case lastName = "last_name"
    case suffix
    case fullName = "full_name"
    case dob
    case gender
    case nationality
    case email
    case phone
    case phoneExtension = "phone_extension"
    case company
    case addressLine1 = "address_line1"
    case addressLine2 = "address_line2"
    case city
    case state
    case postalCode = "postal_code"
    case country
    case cardName = "card_name"
    case cardNumber = "card_number"
    case cardExpiry = "card_expiry"
    case cardCVV = "card_cvv"
    case cardType = "card_type"
    case passportNumber = "passport_number"
    case passportCountry = "passport_country"
    case passportExpiry = "passport_expiry"
    case passportIssue = "passport_issue"
    case knownTravelerNumber = "known_traveler_number"
    case redressNumber = "redress_number"
    case loyaltyNumber = "loyalty_number"
    case username
    case password
    case none

    public var label: String {
        switch self {
        case .title: return "title or honorific (Mr, Ms, Dr)"
        case .firstName: return "first name"
        case .middleName: return "middle name or initial"
        case .lastName: return "last name"
        case .suffix: return "name suffix (Jr, Sr, III)"
        case .fullName: return "full name"
        case .dob: return "date of birth"
        case .gender: return "gender"
        case .nationality: return "nationality or citizenship"
        case .email: return "email address"
        case .phone: return "phone number"
        case .phoneExtension: return "phone extension"
        case .company: return "company name"
        case .addressLine1: return "street address"
        case .addressLine2: return "apartment, suite or unit"
        case .city: return "city"
        case .state: return "state or province"
        case .postalCode: return "zip or postal code"
        case .country: return "country"
        case .cardName: return "name on card"
        case .cardNumber: return "credit card number"
        case .cardExpiry: return "card expiration date"
        case .cardCVV: return "card security code (CVV)"
        case .cardType: return "card type (Visa, Mastercard)"
        case .passportNumber: return "passport number"
        case .passportCountry: return "passport issuing country"
        case .passportExpiry: return "passport expiration date"
        case .passportIssue: return "passport issue date"
        case .knownTravelerNumber: return "known traveler number (TSA PreCheck)"
        case .redressNumber: return "redress number"
        case .loyaltyNumber: return "frequent flyer or rewards member number"
        case .username: return "username or user ID"
        case .password: return "password"
        case .none: return "something else"
        }
    }

    /// Plain name for reports.
    public var displayName: String {
        switch self {
        case .cardCVV: return "card security code"
        case .none: return "nothing from the vault"
        default:
            if let paren = label.firstIndex(of: "(") {
                return label[..<paren].trimmingCharacters(in: .whitespaces)
            }
            return label
        }
    }

    public static func from(label: String) -> Concept? {
        allCases.first { $0.label == label }
    }

    /// How much of the value a report may show.
    public enum Sensitivity { case normal, partial, secret }

    public var sensitivity: Sensitivity {
        switch self {
        case .password, .cardCVV: return .secret
        // Dates stay readable: their layout is the thing most worth checking in a report.
        case .cardNumber, .passportNumber, .knownTravelerNumber, .redressNumber, .loyaltyNumber:
            return .partial
        default: return .normal
        }
    }

    /// Values that may only be typed on an encrypted page.
    public var needsSecurePage: Bool {
        switch self {
        case .password, .cardNumber, .cardCVV, .cardExpiry, .passportNumber, .knownTravelerNumber, .redressNumber:
            return true
        default: return false
        }
    }

    public var isCard: Bool {
        switch self {
        case .cardName, .cardNumber, .cardExpiry, .cardCVV, .cardType: return true
        default: return false
        }
    }

    public var isDate: Bool {
        switch self {
        case .dob, .passportExpiry, .passportIssue, .cardExpiry: return true
        default: return false
        }
    }

    /// Details that identify a person; a second set on one page usually means another traveller.
    public var isPersonal: Bool {
        switch self {
        case .title, .firstName, .middleName, .lastName, .suffix, .fullName, .dob, .gender, .nationality,
             .passportNumber, .passportCountry, .passportExpiry, .passportIssue, .knownTravelerNumber,
             .redressNumber:
            return true
        default: return false
        }
    }
}

/// Which slice of a value a field wants, when a value is split across several fields.
public enum Part: String, Codable {
    case whole
    case day, month, year
    /// Phone slices: "national" is the full number without country code, "local" the last seven digits.
    case countryCode, national, areaCode, prefix3, suffix4, local
    case initial
}
