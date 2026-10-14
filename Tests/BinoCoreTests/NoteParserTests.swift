import XCTest
@testable import BinoCore

final class NoteParserTests: XCTestCase {
    // Every value here is made up for the test.
    private let note = """
        Passwords

        Personal Gmail:
        sam.tester@example.com
        made-up-Pass-1

        Side project:

        Supabase:
        dev@example.com
        Another-Fake_Secret-22

        Database password:
        only-a-password-(x9)

        Project login:
        S
        Fake89311example

        Apple developer account:
        dev@example.com
        fake&&Apple-pw
        Enrollment id:
        ZZ99FAKE00

        practiceair.com - sam / inline-fake-1
        born - 3/14/1990

        Passport:
        X12345678

        Home address:
        200 Example Street
        """

    func testBlocksBecomeLogins() {
        let result = NoteParser.parse(note)
        let byLabel = Dictionary(uniqueKeysWithValues: result.logins.map { ($0.note, $0) })
        XCTAssertEqual(result.logins.count, 6)

        XCTAssertEqual(byLabel["Personal Gmail"]?.username, "sam.tester@example.com")
        XCTAssertEqual(byLabel["Personal Gmail"]?.password, "made-up-Pass-1")
        XCTAssertEqual(byLabel["Personal Gmail"]?.site, "google.com")
        XCTAssertEqual(byLabel["Supabase"]?.site, "supabase.com")
        XCTAssertEqual(byLabel["Supabase"]?.password, "Another-Fake_Secret-22")

        // A lone value under a label is a password with no username.
        XCTAssertEqual(byLabel["Database password"]?.username, "")
        XCTAssertEqual(byLabel["Database password"]?.password, "only-a-password-(x9)")
        XCTAssertEqual(byLabel["Database password"]?.site, "")

        // A one-letter username is still a username.
        XCTAssertEqual(byLabel["Project login"]?.username, "S")
        XCTAssertEqual(byLabel["Project login"]?.password, "Fake89311example")

        // Extra labelled details ride along in the description.
        let apple = result.logins.first { $0.note.hasPrefix("Apple developer account") }
        XCTAssertEqual(apple?.password, "fake&&Apple-pw")
        XCTAssertEqual(apple?.note, "Apple developer account · Enrollment id: ZZ99FAKE00")
        XCTAssertEqual(apple?.site, "apple.com")

        XCTAssertEqual(byLabel["practiceair.com"]?.username, "sam")
        XCTAssertEqual(byLabel["practiceair.com"]?.password, "inline-fake-1")
        XCTAssertEqual(byLabel["practiceair.com"]?.site, "practiceair.com")
    }

    func testOnlyWellKnownNamesAreGuessed() {
        let result = NoteParser.parse(note)
        XCTAssertEqual(Set(result.guessedSites), ["Personal Gmail", "Supabase", "Apple developer account"])
        XCTAssertEqual(NoteParser.site(for: "My bank").site, "")
        XCTAssertEqual(NoteParser.site(for: "United MileagePlus").site, "united.com")
        // A word inside another word is not a match.
        XCTAssertEqual(NoteParser.site(for: "Reunited club").site, "")
    }

    func testPersonalDetailsAreLeftForTheModel() {
        let result = NoteParser.parse(note)
        XCTAssertTrue(result.leftover.contains("X12345678"))
        XCTAssertTrue(result.leftover.contains("200 Example Street"))
        XCTAssertTrue(result.leftover.contains("born - 3/14/1990"))
        XCTAssertFalse(result.leftover.contains("made-up-Pass-1"))
        XCTAssertFalse(result.logins.contains { $0.password == "X12345678" || $0.password == "1990" })
        XCTAssertTrue(NoteParser.isWorthReading(result.leftover))
    }

    func testANoteOfOnlyLoginsNeedsNoModel() {
        let result = NoteParser.parse("Passwords\n\nTwilio:\ndev@example.com\nfake-twilio-pw\n")
        XCTAssertEqual(result.logins.count, 1)
        XCTAssertFalse(NoteParser.isWorthReading(result.leftover))
    }

    func testEveryValueComesFromTheNote() {
        for login in NoteParser.parse(note).logins {
            for value in [login.username, login.password] where !value.isEmpty {
                XCTAssertTrue(note.contains(value), "\(value) is not in the note")
            }
        }
    }

    func testApplyingTwiceAddsNothingNew() {
        var vault = Vault()
        XCTAssertEqual(NoteParser.apply(NoteParser.parse(note), to: &vault), 6)
        XCTAssertEqual(NoteParser.apply(NoteParser.parse(note), to: &vault), 0)
    }
}
