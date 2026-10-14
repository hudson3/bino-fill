import XCTest
@testable import BinoCore

final class RulesTests: XCTestCase {
    private func field(_ label: String, name: String = "", type: String = "text", autocomplete: String = "",
                       placeholder: String = "", section: String = "", maxLength: Int = 0,
                       options: [String] = []) -> PageField {
        PageField(id: "1", type: type, name: name, autocomplete: autocomplete, placeholder: placeholder,
                  label: label, section: section, maxLength: maxLength,
                  options: options.enumerated().map { FieldOption(t: $1, v: $1, id: String($0)) })
    }

    func testConceptLabelsMatchTheFileTheModelWasMeasuredWith() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("sidecar/concepts.json"))
        struct File: Decodable {
            struct Item: Decodable { var id: String; var label: String }
            var question: String
            var concepts: [Item]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        XCTAssertEqual(file.question, FieldDescriber.question)
        XCTAssertEqual(file.concepts.map(\.id), Concept.allCases.map(\.rawValue))
        XCTAssertEqual(file.concepts.map(\.label), Concept.allCases.map(\.label))
    }

    func testAutocompleteHintsAreTrusted() {
        let hit = FieldRules.classify(field("Whatever", autocomplete: "section-a billing cc-exp-month"))
        XCTAssertEqual(hit?.concept, .cardExpiry)
        XCTAssertEqual(hit?.part, .month)
        XCTAssertEqual(hit?.strength, .certain)
        XCTAssertEqual(FieldRules.classify(field("x", autocomplete: "new-password"))?.newPassword, true)
    }

    func testCommonLabels() {
        let cases: [(String, String, Concept)] = [
            ("Given name (as on passport)", "pax[0].givenName", .firstName),
            ("Surname", "pax[0].sn", .lastName),
            ("Email Address", "email", .email),
            ("Zip/Postal Code", "zip", .postalCode),
            ("State/Province*", "FormUserControl$_mailingAddress$_stateUS", .state),
            ("Name on card", "cardholder", .cardName),
            ("Card number", "cardnumber", .cardNumber),
            ("Security code", "cvc", .cardCVV),
            ("Known Traveler Number (optional)", "pax[0].ktn", .knownTravelerNumber),
            ("Redress number (optional)", "pax[0].redress", .redressNumber),
            ("Document number", "apis.docNum", .passportNumber),
            ("Country of issue", "apis.issuer", .passportCountry),
            ("Nationality", "pax[0].nationality", .nationality),
            ("Gift Card Number", "giftCardNumber", .none),
            ("Promo code", "promo", .none),
            ("Fax:", "fax", .none),
            ("Social Security Number", "ssn", .none),
            ("Job Title:", "jobtitle", .none),
            ("Your name:*", "userName", .fullName),
            ("First and Last Name:", "userName", .fullName),
        ]
        for (label, name, expected) in cases {
            XCTAssertEqual(FieldRules.classify(field(label, name: name))?.concept, expected, "\(label) / \(name)")
        }
    }

    func testTheFieldNameSettlesASharedLabel() {
        XCTAssertEqual(FieldRules.classify(field("Address *", name: "BillStreet2"))?.concept, .addressLine2)
        XCTAssertEqual(FieldRules.classify(field("* Home Phone:", name: "BilltoHpExt"))?.concept, .phoneExtension)
        // A nested name is judged by its last part, not by "address" earlier in it.
        XCTAssertEqual(FieldRules.classify(field("", name: "FormUserControl$_mailingAddress$_city"))?.concept, .city)
    }

    func testLessonsFromTheHoldoutSet() {
        // Unlabelled phone boxes named prefix/suffix are not a title or a name suffix.
        XCTAssertNotEqual(FieldRules.classify(field("", name: "HomePrefix"))?.strength, .strong)
        XCTAssertNotEqual(FieldRules.classify(field("", name: "HomeSuffix"))?.strength, .strong)
        XCTAssertEqual(FieldRules.classify(field("Suffix", name: "accountData.suffix"))?.concept, .suffix)
        XCTAssertEqual(FieldRules.classify(field("Title", name: "pax[0].title"))?.concept, .title)
        // Birthplace is not a date of birth.
        XCTAssertEqual(FieldRules.classify(field("City or Town of Birth:", name: "cityOrTownOfBirth"))?.concept, Concept.none)
        XCTAssertEqual(FieldRules.classify(field("Country of birth", name: "paisNacimiento"))?.concept, Concept.none)
        // A dialling code next to phone wording belongs to the phone number.
        let code = FieldRules.classify(field("International Country Code", name: "intlPhone1Prefix"))
        XCTAssertEqual(code?.concept, .phone)
        XCTAssertEqual(code?.part, .countryCode)
        XCTAssertEqual(FieldRules.classify(field("", name: "enterAddressCountryCode"))?.concept, .country)
        XCTAssertEqual(FieldRules.classify(field("Email address", name: "contact.emailAddress"))?.concept, .email)
        XCTAssertEqual(FieldRules.classify(field("", name: "organizationName"))?.concept, .company)
    }

    func testExpiryUnderPassportIsThePassports() {
        let hit = FieldRules.classify(field("Expiry date", name: "apis.docExpiry", section: "Passport"))
        XCTAssertEqual(hit?.concept, .passportExpiry)
        XCTAssertEqual(FieldRules.classify(field("Expiry", name: "exp", section: "Card details"))?.concept, .cardExpiry)
    }

    func testAParagraphIsNotALabel() {
        let blurb = "First Name Last Name Street Address Apartment, Building, Floor City State Zip Phone"
        XCTAssertNotEqual(FieldRules.classify(field(blurb, name: "expfield"))?.strength, .certain)
        XCTAssertNotEqual(FieldRules.classify(field(blurb, name: "expfield"))?.strength, .strong)
    }

    func testPasswordTypeWinsExceptForCardCodes() {
        XCTAssertEqual(FieldRules.classify(field("", name: "x", type: "password"))?.concept, .password)
        XCTAssertEqual(FieldRules.classify(field("Security code", name: "cvc", type: "password"))?.concept, .cardCVV)
    }

    func testDateParts() {
        let months = ["Month", "January", "February", "March", "April", "May", "June", "July"]
        XCTAssertEqual(PartRules.datePart(field("Date of birth", name: "b.m", type: "select", options: months)), .month)
        let days = ["Day"] + (1...31).map(String.init)
        XCTAssertEqual(PartRules.datePart(field("", name: "b.d", type: "select", options: days)), .day)
        let years = ["Year"] + (1950...2026).map(String.init)
        XCTAssertEqual(PartRules.datePart(field("", name: "b.y", type: "select", options: years)), .year)
        XCTAssertEqual(PartRules.datePart(field("Birthdate:", name: "Widget[CreateAccount]_bday_mm")), .month)
        XCTAssertEqual(PartRules.datePart(field("Date of birth (MM/DD/YYYY)", name: "dob")), .whole)
        XCTAssertEqual(PartRules.settleDateRun([.month, .whole, .year]).parts, [.month, .day, .year])
        XCTAssertFalse(PartRules.settleDateRun([.month, .whole, .year]).assumed)
        XCTAssertTrue(PartRules.settleDateRun([.whole, .whole, .whole]).assumed)
    }

    func testPhoneBoxesBySize() {
        let boxes = [field("Mobile phone area code", maxLength: 3), field("next", maxLength: 3), field("last", maxLength: 4)]
        XCTAssertEqual(PartRules.settlePhoneRun(boxes, [.areaCode, .whole, .whole]), [.areaCode, .prefix3, .suffix4])
        XCTAssertEqual(PartRules.settlePhoneRun(boxes, [.whole, .whole, .whole]), [.areaCode, .prefix3, .suffix4])
    }

    func testButtons() {
        let cases: [(String, ButtonKind?)] = [
            ("Continue", .next), ("Next", .next), ("Continue to payment", .next), ("Save & continue", .next),
            ("Proceed to checkout", .next), ("Review your trip", .next),
            ("Pay $482.30", .final), ("Pay now", .final), ("Place order", .final), ("Complete purchase", .final),
            ("Book now", .final), ("Submit", .final), ("Confirm booking", .final), ("Review and pay", .final),
            ("Proceed to pay", .final), ("Submit payment", .final), ("Donate", .final), ("Buy now", .final),
            ("Sign in", .login), ("Log in", .login),
            ("Back", .other), ("Cancel", .other), ("Apply", .other), ("Apply now", .final), ("Search", .other),
            ("Continue shopping", .other), ("Continue as guest", .other), ("Start over", .other),
            ("Write a review", .other), ("Continue without insurance", .other),
            ("→", nil), ("OK", nil), ("Go", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ButtonRules.classify(text), expected, text)
        }
    }
}
