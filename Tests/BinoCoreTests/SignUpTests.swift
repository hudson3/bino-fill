import WebKit
import XCTest
@testable import BinoCore

/// `bino signup`: fill the sign-up form, make a password, save it, type it, press nothing.
@MainActor
final class SignUpTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bino-test-\(UUID().uuidString)")
        setenv("BINO_HOME", home.path, 1)
        var vault = Vault.sample
        vault.logins = []
        try VaultStore.save(vault, createTestVault: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
        unsetenv("BINO_HOME")
    }

    private func page(_ body: String, title: String = "Practice Shop") -> String {
        "<!doctype html><html><head><title>\(title)</title></head><body>\(body)</body></html>"
    }

    private let pressing = #"onclick="window.pressed=(window.pressed||0)+1;return false""#

    /// The usual sign-up form: name, email, a password and its confirmation.
    private func form(extra: String = "", button: String = "Create account") -> String {
        """
        <form><h1>Join Practice Shop</h1>
        <label for=f>First name</label><input id=f name=firstName>
        <label for=e>Email</label><input id=e type=email name=email>\(extra)
        <label for=p>Create a password</label><input id=p type=password name=pw1>
        <label for=q>Confirm password</label><input id=q type=password name=pw2>
        <label><input type=checkbox id=t name=terms> I agree to the terms</label>
        <button type=submit \(pressing)>\(button)</button></form>
        """
    }

    private func open(_ html: String, at address: String = "https://www.shop.example/register") async throws -> WebViewDriver {
        let driver = WebViewDriver()
        try await driver.load(html: html, baseURL: URL(string: address)!)
        return driver
    }

    private func signUp(_ driver: WebViewDriver, username: String? = nil, dryRun: Bool = false,
                        change: (inout Vault) -> Void = { _ in }) async throws -> RunReport {
        var vault = try VaultStore.unlock(reason: "test")
        change(&vault)
        try VaultStore.save(vault)
        let keeper = NewLoginKeeper(vault: vault)
        var request = SignUpRequest(site: "shop.example", save: { try keeper.save($0) }, forget: { keeper.forget($0) })
        request.username = username
        var options = RunOptions()
        options.dryRun = dryRun
        return await FormRunner(driver: driver, vault: dryRun ? nil : vault, decider: nil, options: options).signUp(request)
    }

    private func js(_ driver: WebViewDriver, _ expression: String) async throws -> String {
        try await driver.evaluate("String(\(expression))")
    }

    private func value(_ driver: WebViewDriver, _ id: String) async throws -> String {
        try await js(driver, "document.getElementById('\(id)').value")
    }

    private func saved() throws -> [Login] {
        try VaultStore.unlock(reason: "test").logins
    }

    // MARK: The usual case

    func testFillsTheFormSavesThePasswordAndPressesNothing() async throws {
        let driver = try await open(page(form()))
        let report = try await signUp(driver)
        XCTAssertEqual(report.stop, .signUpReady(button: "Create account", needs: []), report.text())

        let typed = try await value(driver, "p"), again = try await value(driver, "q")
        XCTAssertEqual(typed.count, PasswordMaker.defaultLength)
        XCTAssertEqual(typed, again)
        let rest = try await js(driver, "document.getElementById('f').value+'/'+document.getElementById('e').value+'/'+document.getElementById('t').checked+'/'+(window.pressed||0)")
        XCTAssertEqual(rest, "Alex/alex.rivera@example.com/false/0", "the terms box and the button are yours")

        // What is in the vault is exactly what is on the page.
        let logins = try saved()
        XCTAssertEqual(logins.count, 1)
        XCTAssertEqual(logins.first?.site, "shop.example")
        XCTAssertEqual(logins.first?.username, "alex.rivera@example.com")
        XCTAssertEqual(logins.first?.password, typed)
        XCTAssertEqual(LoginIndex.hasLogin(forSite: "www.shop.example"), true)
        XCTAssertEqual(report.newLogin, NewLoginReport(site: "shop.example", username: "alex.rivera@example.com", saved: true))

        // The password appears in no report; the agent's form has no value at all.
        let agent = AgentJSON.text(AgentReport(report))
        XCTAssertFalse(report.text().contains(typed))
        XCTAssertFalse(agent.contains(typed) || agent.contains("alex.rivera") || agent.contains("Alex\""), agent)
        XCTAssertTrue(agent.contains("\"reason\" : \"sign_up_ready\""), agent)
        XCTAssertTrue(agent.contains("\"saved\" : true"), agent)

        // And the saved login signs in on that site afterwards.
        let vault = try VaultStore.unlock(reason: "test")
        XCTAssertEqual(vault.login(forPage: "https://www.shop.example/login")?.password, typed)
    }

    func testOnePasswordBoxOnAPageThatSaysSignUp() async throws {
        let driver = try await open(page("""
            <form><label for=e>Email</label><input id=e type=email name=email>
            <label for=p>Password</label><input id=p type=password name=password>
            <button type=submit \(pressing)>Sign up</button></form>
            """))
        let report = try await signUp(driver)
        XCTAssertEqual(report.stop, .signUpReady(button: "Sign up", needs: []), report.text())
        let typed = try await value(driver, "p")
        XCTAssertEqual(try saved().first?.password, typed)
        XCTAssertFalse(typed.isEmpty)
    }

    func testContinueIsNotPressedOnceThePasswordIsIn() async throws {
        let driver = try await open(page("""
            <form><label for=e>Email</label><input id=e type=email name=email>
            <label for=p>Choose a password</label><input id=p type=password name=password autocomplete=new-password>
            <button type=submit \(pressing)>Continue</button></form>
            """))
        let report = try await signUp(driver)
        XCTAssertEqual(report.stop, .signUpReady(button: "Continue", needs: []), report.text())
        let pressed = try await js(driver, "window.pressed||0")
        XCTAssertEqual(pressed, "0")
    }

    func testEmailFirstThenPassword() async throws {
        let driver = try await open(page("""
            <div id=main><form><h1>Create your account</h1><label for=e>Email</label><input id=e type=email name=email>
            <button type=submit onclick="window.e=document.getElementById('e').value;document.getElementById('main').innerHTML=document.getElementById('t').innerHTML;return false">Continue</button></form></div>
            <template id=t><form><h1>One more step</h1><label for=p>Password</label><input id=p type=password name=password>
            <button type=submit \(pressing)>Continue</button></form></template>
            """))
        let report = try await signUp(driver)
        XCTAssertEqual(report.stop, .signUpReady(button: "Continue", needs: []), report.text())
        XCTAssertEqual(report.pages.map(\.pressed), ["Continue", nil])
        let state = try await js(driver, "window.e+'/'+(window.pressed||0)")
        XCTAssertEqual(state, "alex.rivera@example.com/0")
        let typed = try await value(driver, "p")
        XCTAssertEqual(try saved().first?.password, typed)
        XCTAssertEqual(try saved().first?.username, "alex.rivera@example.com")
    }

    func testFollowsASignUpLinkFromTheFrontPage() async throws {
        let driver = try await open(page("""
            <nav><a href="#">Deals</a><a href="#">Sign in</a>
            <a href="#" onclick="document.getElementById('main').innerHTML=document.getElementById('t').innerHTML;return false">Create account</a></nav>
            <div id=main><h1>Shop the sale</h1></div>
            <footer><label for=n>Email me offers</label><input id=n type=email name=newsletter><button type=button>Subscribe</button></footer>
            <template id=t>\(form())</template>
            """))
        let report = try await signUp(driver)
        XCTAssertEqual(report.stop, .signUpReady(button: "Create account", needs: []), report.text())
        XCTAssertEqual(report.pages.first?.pressed, "Create account")
        XCTAssertEqual(try saved().count, 1)
    }

    func testWhatOnlyYouCanAnswerIsListedNotGuessed() async throws {
        let driver = try await open(page(form().replacingOccurrences(of: "id=t name=terms", with: "id=t name=terms required")))
        let report = try await signUp(driver)
        XCTAssertEqual(report.stop, .signUpReady(button: "Create account", needs: ["I agree to the terms"]), report.text())
        let ticked = try await js(driver, "document.getElementById('t').checked")
        XCTAssertEqual(ticked, "false")
        XCTAssertEqual(try saved().count, 1)
    }

    // MARK: Usernames

    func testAUsernameIsMadeFromTheEmailAndFlagged() async throws {
        let driver = try await open(page(form(extra: "<label for=u>Username</label><input id=u name=username>")))
        let report = try await signUp(driver)
        XCTAssertEqual(report.stop, .signUpReady(button: "Create account", needs: []), report.text())
        let typed = try await value(driver, "u")
        XCTAssertEqual(typed, "alex.rivera")
        XCTAssertEqual(try saved().first?.username, "alex.rivera")
        XCTAssertTrue(report.attention.contains { $0.entry.field == "Username" }, "a made-up username is worth a look")
    }

    func testAGivenUsernameIsUsed() async throws {
        let driver = try await open(page(form(extra: "<label for=u>Username</label><input id=u name=username>")))
        _ = try await signUp(driver, username: "arivera90")
        let typed = try await value(driver, "u")
        XCTAssertEqual(typed, "arivera90")
        XCTAssertEqual(try saved().first?.username, "arivera90")
    }

    // MARK: Where nothing must happen

    func testASignInPageIsLeftAlone() async throws {
        let driver = try await open(page("""
            <form><label for=u>Email</label><input id=u type=email name=email>
            <label for=p>Password</label><input id=p type=password name=password>
            <button type=submit \(pressing)>Sign in</button></form>
            <p>New here? <a href="/register">Sign up</a></p>
            """, title: "Sign in or sign up"))
        let report = try await signUp(driver)
        guard case .noSignUpForm = report.stop else { return XCTFail(report.text()) }
        let state = try await js(driver, "document.getElementById('u').value+'/'+document.getElementById('p').value+'/'+(window.pressed||0)")
        XCTAssertEqual(state, "//0")
        XCTAssertEqual(try saved().count, 0)
        XCTAssertEqual(report.newLogin?.saved, false)
    }

    func testNoPasswordIsMadeOnALookalikeSite() async throws {
        let driver = try await open(page(form()), at: "https://shop.example.account-check.test/register")
        let report = try await signUp(driver)
        guard case .passwordWithheld = report.stop else { return XCTFail(report.text()) }
        let typed = try await value(driver, "p")
        XCTAssertEqual(typed, "")
        XCTAssertEqual(try saved().count, 0)
    }

    func testNoPasswordIsMadeWithoutHttps() async throws {
        let driver = try await open(page(form()), at: "http://www.shop.example/register")
        let report = try await signUp(driver)
        guard case .passwordWithheld = report.stop else { return XCTFail(report.text()) }
        XCTAssertEqual(try saved().count, 0)
    }

    func testALoginAlreadySavedForTheSiteIsNotTyped() async throws {
        let driver = try await open(page(form(extra: "<label for=u>Username</label><input id=u name=username>")))
        _ = try await signUp(driver, username: "second.account") { vault in
            var old = Login()
            old.site = "shop.example"
            old.username = "first.account"
            old.password = "practice-only-password"
            vault.logins = [old]
        }
        let user = try await value(driver, "u"), typed = try await value(driver, "p")
        XCTAssertEqual(user, "second.account")
        XCTAssertNotEqual(typed, "practice-only-password")
        // The first account's login is untouched, and the new one sits beside it.
        let logins = try saved()
        XCTAssertEqual(logins.map(\.username), ["first.account", "second.account"])
        XCTAssertEqual(logins.first?.password, "practice-only-password")
    }

    func testADryRunMakesAndSavesNothing() async throws {
        let driver = try await open(page(form()))
        let report = try await signUp(driver, dryRun: true)
        XCTAssertEqual(report.stop, .dryRun, report.text())
        let typed = try await value(driver, "p")
        XCTAssertEqual(typed, "")
        XCTAssertEqual(try saved().count, 0)
        XCTAssertTrue(report.pages[0].entries.contains { $0.field == "Create a password" && $0.status == .wouldFill })
    }

    func testAPasswordThePageThrowsAwayIsNotKept() async throws {
        let driver = try await open(page("""
            <form><h1>Register</h1><label for=e>Email</label><input id=e type=email name=email>
            <label for=p>Create a password</label><input id=p type=password name=pw1 oninput="this.value=''">
            <button type=submit \(pressing)>Register</button></form>
            """))
        let report = try await signUp(driver)
        guard case .pageErrors = report.stop else { return XCTFail(report.text()) }
        XCTAssertEqual(try saved().count, 0, "a password that is not on the page must not stay in the vault")
        XCTAssertEqual(report.newLogin?.saved, false)
    }

    func testABoxTooShortForAStrongPasswordIsLeftToYou() async throws {
        let driver = try await open(page("""
            <form><h1>Register</h1><label for=e>Email</label><input id=e type=email name=email>
            <label for=p>Create a PIN</label><input id=p type=password name=pw1 maxlength=6>
            <button type=submit \(pressing)>Register</button></form>
            """))
        let report = try await signUp(driver)
        let typed = try await value(driver, "p")
        XCTAssertEqual(typed, "", report.text())
        XCTAssertEqual(try saved().count, 0)
    }

    func testThePasswordFitsTheBox() async throws {
        let driver = try await open(page("""
            <form><h1>Register</h1><label for=e>Email</label><input id=e type=email name=email>
            <label for=p>Create a password</label><input id=p type=password name=pw1 maxlength=16>
            <button type=submit \(pressing)>Register</button></form>
            """))
        _ = try await signUp(driver)
        let typed = try await value(driver, "p")
        XCTAssertEqual(typed.count, 16)
        XCTAssertEqual(try saved().first?.password, typed)
    }

    // MARK: The pieces

    func testPasswordsAreStrongAndDifferent() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let password = PasswordMaker.make()
            XCTAssertEqual(password.count, 20)
            XCTAssertTrue(password.contains { $0.isLowercase } && password.contains { $0.isUppercase })
            XCTAssertTrue(password.contains { $0.isNumber } && password.contains { PasswordMaker.symbols.contains($0) })
            XCTAssertFalse(zip(password, password.dropFirst()).contains { $0 == $1 }, password)
            XCTAssertTrue(password.first!.isLetter)
            seen.insert(password)
        }
        XCTAssertEqual(seen.count, 200)
        let plain = PasswordMaker.make(length: 14, symbols: false)
        XCTAssertEqual(plain.count, 14)
        XCTAssertTrue(plain.allSatisfy { $0.isLetter || $0.isNumber })
        XCTAssertEqual(PasswordMaker.make(length: 3).count, PasswordMaker.shortestAllowed)
    }

    func testTheSiteANewLoginIsSavedFor() {
        XCTAssertEqual(SitePolicy.accountSite(forPage: "https://www.shop.example/register?x=1"), "shop.example")
        XCTAssertEqual(SitePolicy.accountSite(forPage: "https://accounts.shop.example/new"), "shop.example")
        XCTAssertEqual(SitePolicy.accountSite(forPage: "https://signup.shop.co.uk/"), "shop.co.uk")
        XCTAssertEqual(SitePolicy.accountSite(forPage: "https://myapp.vercel.app/join"), "myapp.vercel.app")
        XCTAssertEqual(SitePolicy.accountSite(forPage: "http://localhost:8765/signup.html"), "localhost")
        XCTAssertNil(SitePolicy.accountSite(forPage: "about:blank"))
    }
}
