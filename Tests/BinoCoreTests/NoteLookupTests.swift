import XCTest
@testable import BinoCore

/// Your note answers the boxes the vault's fields cannot.
final class NoteLookupTests: XCTestCase {
    func testLinesAreReadWithTheirSeparators() {
        let lines = NoteLookup.lines("Known Traveler Number: 98765\nGate code - 4412\nEIN = 12-3456789\nWifi\tbluebird\njust a sentence\n: nothing\n")
        XCTAssertEqual(lines.map(\.label), ["Known Traveler Number", "Gate code", "EIN", "Wifi"])
        XCTAssertEqual(lines.map(\.value), ["98765", "4412", "12-3456789", "bluebird"])
        XCTAssertEqual(NoteLookup.lines("Time: 10:30 - meeting").first?.value, "10:30 - meeting", "the shortest label wins")
    }

    func testTheBestLineIsPickedAndSecretsNever() {
        let notes = "KTN: 1\nKnown Traveler Number: 2\nNumber: 5\nApple password: hunter2\nPIN: 1234\nGate code: 4412"
        XCTAssertEqual(NoteLookup.value(for: PageField(id: "k", label: "Known Traveler Number / PASS ID"), in: notes)?.value, "2")
        XCTAssertEqual(NoteLookup.value(for: PageField(id: "k", label: "KTN"), in: notes)?.value, "1")
        XCTAssertNil(NoteLookup.value(for: PageField(id: "c", label: "Card number"), in: notes), "a label of only generic words says nothing")
        XCTAssertNil(NoteLookup.value(for: PageField(id: "p", label: "Apple password"), in: notes), "passwords never come from the note")
        XCTAssertNil(NoteLookup.value(for: PageField(id: "p", label: "PIN"), in: notes))
        XCTAssertEqual(NoteLookup.value(for: PageField(id: "g", placeholder: "Enter your gate code"), in: notes)?.label, "Gate code")
        XCTAssertNil(NoteLookup.value(for: PageField(id: "g", label: "Gate"), in: notes), "every word of the line's label has to be in the field")
        XCTAssertNil(NoteLookup.value(for: PageField(id: "g", label: "Gate code"), in: ""))
    }

    func testTheMapperFillsFromTheNoteAndFlagsIt() async {
        var vault = Vault()
        vault.profile.firstName = "Alex"
        vault.notes = "Known Traveler Number: 98765\nGate code: 4412\nSite password: nope"
        let scan = PageScan(url: "https://example.com/", fields: [
            PageField(id: "f1", label: "Known Traveler Number"),
            PageField(id: "f2", label: "Gate code"),
            PageField(id: "f3", label: "First name"),
            PageField(id: "f4", type: "password", label: "Site password"),
        ])
        let plans = await FieldMapper(decider: nil).plan(scan: scan, resolver: ValueResolver(vault: vault, pageURL: scan.url)).plans
        let by = Dictionary(uniqueKeysWithValues: plans.map { ($0.field.id, $0) })
        XCTAssertEqual(by["f1"]?.decision, .type("98765"))
        XCTAssertEqual(by["f1"]?.source, .notes)
        XCTAssertTrue(by["f1"]?.notes.first?.contains("in your note") == true)
        XCTAssertEqual(by["f2"]?.decision, .type("4412"), "a box Bino has no kind for still gets its line")
        XCTAssertEqual(by["f3"]?.decision, .type("Alex"), "the vault's own fields come first")
        XCTAssertEqual(by["f3"]?.source, .rules)
        if case .type = by["f4"]?.decision { XCTFail("a password must never come from the note") }
    }
}
