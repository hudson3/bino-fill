import XCTest
@testable import BinoCore

/// Several accounts on one site: named in the vault, chosen with --account, listed
/// without unlocking.
final class AccountsTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bino-accounts-\(UUID().uuidString)")
        setenv("BINO_HOME", home.path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        unsetenv("BINO_HOME")
    }

    private func login(_ site: String, _ user: String, named name: String = "") -> Login {
        var login = Login()
        login.site = site; login.username = user; login.password = "pw-\(user)"; login.note = name
        return login
    }

    private var vault: Vault {
        var vault = Vault()
        vault.logins = [login("apple.com", "alex@work.example", named: "work"), login("apple.com", "alex@personal.example", named: "personal"),
                        login("united.com", "alex"), login("login.united.com", "alex2")]
        return vault
    }

    func testAccountsAreNamedAndChosen() {
        let page = "https://appstoreconnect.apple.com/login"
        XCTAssertEqual(vault.accounts(forPage: page).map(\.name), ["work", "personal"])
        XCTAssertEqual(vault.login(forPage: page, account: nil), .several(["work", "personal"]))
        guard case .one(let chosen) = vault.login(forPage: page, account: " Personal ") else { return XCTFail() }
        XCTAssertEqual(chosen.username, "alex@personal.example", "names match whatever the case")
        XCTAssertEqual(vault.login(forPage: page, account: "pixar"), .noSuchAccount(asked: "pixar", saved: ["work", "personal"]))
        XCTAssertEqual(vault.login(forPage: "https://nothing.example/", account: nil), .none)

        // The most specific saved site wins, and a lone unnamed login is "account 1".
        XCTAssertEqual(vault.accounts(forPage: "https://login.united.com/x").map(\.name), ["account 1"])
        guard case .one(let united) = vault.login(forPage: "https://login.united.com/x", account: nil) else { return XCTFail() }
        XCTAssertEqual(united.username, "alex2")
        guard case .one(let byNumber) = vault.login(forPage: "https://www.united.com/", account: "account 1") else { return XCTFail() }
        XCTAssertEqual(byNumber.username, "alex")
        XCTAssertEqual(vault.login(forPage: page)?.username, "alex@work.example", "the old lookup still returns the first")
    }

    func testIndexListsAccountNamesWithoutTheVault() throws {
        XCTAssertNil(LoginIndex.accounts(forSite: "apple.com"), "no index yet")
        try VaultStore.save(vault, createTestVault: true)
        XCTAssertEqual(LoginIndex.accounts(forSite: "appstoreconnect.apple.com"), ["work", "personal"])
        XCTAssertEqual(LoginIndex.accounts(forSite: "united.com"), ["account 1"])
        XCTAssertEqual(LoginIndex.accounts(forSite: "nothing.example"), [])
        let raw = String(decoding: try Data(contentsOf: BinoPaths.loginIndexFile), as: UTF8.self)
        XCTAssertTrue(raw.contains("work"))
        for secret in ["apple.com", "personal.example", "alex", "pw-"] { XCTAssertFalse(raw.contains(secret), "\(secret) is in the index") }
    }

    func testResolverNeedsTheAccountWhenThereAreSeveral() {
        let field = PageField(id: "u", label: "Apple ID")
        let page = "https://appstoreconnect.apple.com/login"
        let vague = ValueResolver(vault: vault, pageURL: page).resolve(.username, part: .whole, field: field)
        guard case .missing(let why) = vague.resolution else { return XCTFail("\(vague)") }
        XCTAssertTrue(why.contains("work, personal"), why)
        let password = ValueResolver(vault: vault, pageURL: page).resolve(.password, part: .whole, field: PageField(id: "p", type: "password"))
        guard case .blocked = password.resolution else { return XCTFail("\(password)") }
        let chosen = ValueResolver(vault: vault, pageURL: page, account: "work").resolve(.username, part: .whole, field: field)
        XCTAssertEqual(chosen.resolution, .text("alex@work.example"))
    }

    func testOlderVaultsStillOpen() throws {
        var saved = Vault.sample
        saved.notes = "Gate code: 4412"
        let json = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(Vault.self, from: json), saved)
        var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        object["notes"] = nil
        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Vault.self, from: older)
        XCTAssertEqual(decoded.notes, "")
        XCTAssertEqual(decoded.logins, saved.logins)
    }

    func testAPartOfAnAccountNameIsEnough() {
        let names = ["Apple developer account · Enrollment id: B4R94FXNK9", "work"]
        XCTAssertEqual(AccountMatch.pick("B4R94FXNK9", from: names), .one(0))
        XCTAssertEqual(AccountMatch.pick("enrollment", from: names), .one(0))
        XCTAssertEqual(AccountMatch.pick("apple developer", from: names), .one(0))
        XCTAssertEqual(AccountMatch.pick("Apple developer account · Enrollment id: B4R94FXNK9", from: names), .one(0))
        XCTAssertEqual(AccountMatch.pick("WOR", from: names), .one(1))
        XCTAssertEqual(AccountMatch.pick("2", from: names), .one(1), "a 1-based number")
        XCTAssertEqual(AccountMatch.pick("account 1", from: names), .one(0))
        XCTAssertEqual(AccountMatch.pick("pixar", from: names), .none)
        XCTAssertEqual(AccountMatch.pick("", from: names), .none)
        XCTAssertEqual(AccountMatch.pick("3", from: names), .none)
        // Both names contain "e": ambiguous, and the ones that fit are listed.
        XCTAssertEqual(AccountMatch.pick("o", from: names), .several(names))
        // A name that is exactly another's prefix is still exact.
        XCTAssertEqual(AccountMatch.pick("per", from: ["per", "personal"]), .one(0))
        XCTAssertEqual(AccountMatch.pick("pers", from: ["per", "personal"]), .one(1))

        let page = "https://appstoreconnect.apple.com/login"
        guard case .one(let chosen) = vault.login(forPage: page, account: "pers") else { return XCTFail() }
        XCTAssertEqual(chosen.username, "alex@personal.example")
        XCTAssertEqual(vault.login(forPage: page, account: "o"), .ambiguous(asked: "o", matching: ["work", "personal"]))
        let resolver = ValueResolver(vault: vault, pageURL: page, account: "o").resolve(.username, part: .whole, field: PageField(id: "u", label: "Apple ID"))
        guard case .missing(let why) = resolver.resolution else { return XCTFail("\(resolver)") }
        XCTAssertTrue(why.contains("more than one"), why)
    }

    func testRenamingALoginKeepsItsSecrets() throws {
        var renamed = vault
        let at = renamed.logins.firstIndex { $0.note == "personal" }!
        renamed.logins[at].note = "bc"
        XCTAssertEqual(renamed.accounts(forSite: "apple.com").map(\.name), ["work", "bc"])
        XCTAssertEqual(renamed.logins[at].username, vault.logins[at].username)
        XCTAssertEqual(renamed.logins[at].password, vault.logins[at].password)
        try VaultStore.save(renamed, createTestVault: true)
        XCTAssertEqual(LoginIndex.accounts(forSite: "appstoreconnect.apple.com"), ["work", "bc"], "status lists the new name")
        // A login saved before it had a sign-in page still opens.
        let json = try JSONEncoder().encode(renamed.logins[at])
        var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        object["url"] = nil
        let older = try JSONDecoder().decode(Login.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.url, "")
        XCTAssertEqual(older.password, renamed.logins[at].password)
    }

    func testWhichAccountIsAStopReason() {
        let stop = StopReason.whichAccount(site: "apple.com", accounts: ["work", "personal"], asked: nil)
        XCTAssertEqual(stop.code, "which_account")
        XCTAssertTrue(stop.headline.contains("work, personal"))
        var report = RunReport()
        report.command = "login"
        report.stop = stop
        let agent = AgentReport(report, reportFile: nil)
        XCTAssertEqual(agent.stopped.accounts, ["work", "personal"])
        XCTAssertTrue(StopReason.whichAccount(site: "apple.com", accounts: ["a"], asked: "b").headline.contains("No account named \"b\""))
        XCTAssertTrue(StopReason.whichAccount(site: "apple.com", accounts: ["ab", "ac"], asked: "a", ambiguous: true).headline.contains("fits more than one"))
    }
}
