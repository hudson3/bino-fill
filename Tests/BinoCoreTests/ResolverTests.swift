import XCTest
@testable import BinoCore

final class ResolverTests: XCTestCase {
    private let resolver = ValueResolver(vault: .sample, pageURL: "https://practiceair.example/book")

    private func select(_ options: [(String, String)]) -> PageField {
        PageField(id: "1", tag: "select", type: "select",
                  options: options.enumerated().map { FieldOption(t: $1.0, v: $1.1, id: String($0)) })
    }

    private func text(_ resolved: Resolved) -> String? {
        if case .text(let value) = resolved.resolution { return value }
        return nil
    }

    private func option(_ resolved: Resolved) -> String? {
        if case .option(let option) = resolved.resolution { return option.t }
        return nil
    }

    func testDateLayoutsFollowThePage() {
        let ddmm = PageField(id: "1", placeholder: "DD/MM/YYYY")
        XCTAssertEqual(text(resolver.resolve(.passportExpiry, part: .whole, field: ddmm)), "31/05/2031")
        let iso = PageField(id: "1", placeholder: "yyyy-mm-dd")
        XCTAssertEqual(text(resolver.resolve(.dob, part: .whole, field: iso)), "1990-03-14")
        let native = PageField(id: "1", type: "date")
        XCTAssertEqual(text(resolver.resolve(.dob, part: .whole, field: native)), "1990-03-14")
        let labelled = PageField(id: "1", label: "Date of birth (MM/DD/YYYY)")
        XCTAssertEqual(text(resolver.resolve(.dob, part: .whole, field: labelled)), "03/14/1990")
    }

    func testAGuessedDateLayoutIsFlagged() {
        let bare = resolver.resolve(.dob, part: .whole, field: PageField(id: "1", label: "Date of birth"))
        XCTAssertEqual(text(bare), "03/14/1990")
        XCTAssertFalse(bare.notes.isEmpty)
    }

    func testDateDropdowns() {
        let months = select([("Month", ""), ("January", "1"), ("February", "2"), ("March", "3"), ("April", "4")])
        XCTAssertEqual(option(resolver.resolve(.dob, part: .month, field: months)), "March")
        let numbered = select([("--", ""), ("01", "01"), ("02", "02"), ("03", "03")])
        XCTAssertEqual(option(resolver.resolve(.dob, part: .month, field: numbered)), "03")
        let years = select([("Year", "")] + (1985...1995).map { (String($0), String($0)) })
        XCTAssertEqual(option(resolver.resolve(.dob, part: .year, field: years)), "1990")
        let shortYears = select((26...35).map { (String($0), String($0)) })
        XCTAssertEqual(option(resolver.resolve(.cardExpiry, part: .year, field: shortYears)), "29")
    }

    func testCardExpiryLayouts() {
        XCTAssertEqual(text(resolver.resolve(.cardExpiry, part: .whole, field: PageField(id: "1", placeholder: "MM/YY"))), "08/29")
        XCTAssertEqual(text(resolver.resolve(.cardExpiry, part: .whole,
                                             field: PageField(id: "1", placeholder: "MM / YY", maxLength: 7))), "08 / 29")
        XCTAssertEqual(text(resolver.resolve(.cardExpiry, part: .whole, field: PageField(id: "1", placeholder: "MM/YYYY"))), "08/2029")
        XCTAssertEqual(text(resolver.resolve(.cardExpiry, part: .whole, field: PageField(id: "1", maxLength: 4))), "0829")
        XCTAssertEqual(text(resolver.resolve(.cardExpiry, part: .month, field: PageField(id: "1"))), "08")
        XCTAssertEqual(text(resolver.resolve(.cardExpiry, part: .year, field: PageField(id: "1", maxLength: 2))), "29")
        XCTAssertEqual(text(resolver.resolve(.cardNumber, part: .whole, field: PageField(id: "1"))), "4242424242424242")
    }

    func testPhoneShapes() {
        XCTAssertEqual(text(resolver.resolve(.phone, part: .whole, field: PageField(id: "1"))), "5125550142")
        XCTAssertEqual(text(resolver.resolve(.phone, part: .whole, field: PageField(id: "1", placeholder: "(555) 555-5555"))),
                       "(512) 555-0142")
        XCTAssertEqual(text(resolver.resolve(.phone, part: .areaCode, field: PageField(id: "1"))), "512")
        XCTAssertEqual(text(resolver.resolve(.phone, part: .prefix3, field: PageField(id: "1"))), "555")
        XCTAssertEqual(text(resolver.resolve(.phone, part: .suffix4, field: PageField(id: "1"))), "0142")
        XCTAssertEqual(text(resolver.resolve(.phone, part: .countryCode, field: PageField(id: "1"))), "1")
        let codes = select([("United Kingdom (+44)", "GB"), ("United States (+1)", "US")])
        XCTAssertEqual(option(resolver.resolve(.phone, part: .countryCode, field: codes)), "United States (+1)")
    }

    func testPlacesMatchHoweverThePageSpellsThem() {
        XCTAssertEqual(option(resolver.resolve(.state, part: .whole, field: select([("CA - California", "CA"), ("TX - Texas", "TX")]))), "TX - Texas")
        XCTAssertEqual(option(resolver.resolve(.state, part: .whole, field: select([("California", "1"), ("Texas", "2")]))), "Texas")
        XCTAssertEqual(text(resolver.resolve(.state, part: .whole, field: PageField(id: "1", maxLength: 2))), "TX")
        XCTAssertEqual(option(resolver.resolve(.country, part: .whole, field: select([("Canada", "CAN"), ("United States", "USA")]))), "United States")
        XCTAssertEqual(option(resolver.resolve(.country, part: .whole, field: select([("Canada", "CA"), ("United States of America", "US")]))), "United States of America")
        XCTAssertEqual(option(resolver.resolve(.country, part: .whole, field: select([("CA", "CA"), ("US", "US")]))), "US")
        XCTAssertEqual(option(resolver.resolve(.gender, part: .whole, field: select([("M", "M"), ("F", "F")]))), "M")
        XCTAssertEqual(option(resolver.resolve(.title, part: .whole, field: select([("Mr.", "1"), ("Ms.", "2")]))), "Mr.")
        XCTAssertEqual(option(resolver.resolve(.cardType, part: .whole, field: select([("MasterCard", "MC"), ("Visa", "VI")]))), "Visa")
    }

    func testNoMatchingChoiceIsNotGuessed() {
        let others = select([("Canada", "CA"), ("Mexico", "MX")])
        guard case .unsupported = resolver.resolve(.country, part: .whole, field: others).resolution else {
            return XCTFail("picked a country that is not the saved one")
        }
    }

    func testMissingValuesAreReportedNotInvented() {
        guard case .missing = resolver.resolve(.redressNumber, part: .whole, field: PageField(id: "1")).resolution else {
            return XCTFail()
        }
        guard case .missing = resolver.resolve(.loyaltyNumber, part: .whole,
                                               field: PageField(id: "1", label: "Other Airline number")).resolution else {
            return XCTFail("a member number was offered to an unrelated programme")
        }
        XCTAssertEqual(text(resolver.resolve(.loyaltyNumber, part: .whole, field: PageField(id: "1", label: "SkyPoints number"))),
                       "PA998877")
    }

    func testNoteSorterOnlyKeepsWhatTheNoteSays() {
        let note = "Passport X12345678 exp May 31 2031\nunited.com  alex / hunter2!"
        XCTAssertEqual(NoteSorter.keep("X12345678", note: note), "X12345678")
        XCTAssertNil(NoteSorter.keep("Y99999999", note: note))
        XCTAssertEqual(NoteSorter.keep("2031-05-31", note: note, isDate: true), "2031-05-31")
        XCTAssertNil(NoteSorter.keep("2031-06-30", note: note, isDate: true))
        // Numbers that all appear in the note, but never together as this date.
        let mixed = "issued 6/1/2021 expires 5/31/2031"
        XCTAssertNil(NoteSorter.keep("2021-05-31", note: mixed, isDate: true))
        XCTAssertEqual(NoteSorter.keep("2031-05-31", note: mixed, isDate: true), "2031-05-31")
        XCTAssertEqual(NoteSorter.keep("2021-06-01", note: mixed, isDate: true), "2021-06-01")
        XCTAssertEqual(NoteSorter.keep("1990-3-14", note: "born March 14 1990", isDate: true), "1990-03-14")
        XCTAssertEqual(NoteSorter.keep("hunter2!", note: note), "hunter2!")
    }
}
