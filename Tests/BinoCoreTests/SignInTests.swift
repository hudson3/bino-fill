import WebKit
import XCTest
@testable import BinoCore

/// `bino login`: one saved login, typed only on its own site, then the sign-in button.
@MainActor
final class SignInTests: XCTestCase {
    private var login: Login {
        var login = Login()
        login.site = "practiceair.com"
        login.username = "alex.rivera"
        login.password = "practice-only-password"
        return login
    }

    private func page(_ body: String) -> String {
        "<!doctype html><html><head><title>Practice Air</title></head><body>\(body)</body></html>"
    }

    /// A sign-in form whose button records what was in the boxes and then shows `after`.
    private func form(user: String = "<label for=u>Username</label><input id=u name=username>",
                      button: String = "Sign in", after: String = "<h1>Welcome back</h1>") -> String {
        """
        <form id=f>\(user)
        <label for=p>Password</label><input id=p type=password name=password>
        <button type=submit onclick="window.u=document.getElementById('u').value;window.p=document.getElementById('p').value;\
        window.pressed=(window.pressed||0)+1;document.getElementById('f').outerHTML='\(after)';return false">\(button)</button></form>
        """
    }

    private func open(_ html: String, at address: String = "https://www.practiceair.com/login") async throws -> WebViewDriver {
        let driver = WebViewDriver()
        try await driver.load(html: page(html), baseURL: URL(string: address)!)
        return driver
    }

    private func signIn(_ driver: WebViewDriver) async -> RunReport {
        await FormRunner(driver: driver, vault: nil, decider: nil).signIn(with: login)
    }

    private func js(_ driver: WebViewDriver, _ expression: String) async throws -> String {
        try await driver.evaluate("String(\(expression))")
    }

    func testTypesTheLoginAndPressesSignIn() async throws {
        let driver = try await open(form())
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .signInPressed(button: "Sign in", formStillShowing: false), report.text())
        let typed = try await js(driver, "window.u+'/'+window.p+'/'+window.pressed")
        XCTAssertEqual(typed, "alex.rivera/practice-only-password/1")

        // Neither form of the report gives the password away, and the agent's form gives no value at all.
        let agent = AgentJSON.text(AgentReport(report))
        XCTAssertFalse(report.text().contains("practice-only-password"))
        XCTAssertFalse(agent.contains("practice-only-password") || agent.contains("alex.rivera"), agent)
        XCTAssertTrue(agent.contains("\"reason\" : \"sign_in_pressed\""), agent)
    }

    func testAnEmailBoxTakesTheSavedUsername() async throws {
        let driver = try await open(form(user: "<label for=u>Email address</label><input id=u type=email name=email>",
                                         button: "Continue"))
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .signInPressed(button: "Continue", formStillShowing: false), report.text())
        let typed = try await js(driver, "window.u")
        XCTAssertEqual(typed, "alex.rivera")
    }

    func testNothingIsTypedOnALookalikeSite() async throws {
        let driver = try await open(form(), at: "https://practiceair.com.account-check.example/login")
        let report = await signIn(driver)
        guard case .passwordWithheld = report.stop else { return XCTFail(report.text()) }
        let state = try await js(driver, "document.getElementById('u').value+'/'+document.getElementById('p').value+'/'+(window.pressed||0)")
        XCTAssertEqual(state, "//0")
    }

    func testNothingIsTypedWithoutHttps() async throws {
        let driver = try await open(form(), at: "http://www.practiceair.com/login")
        let report = await signIn(driver)
        guard case .passwordWithheld = report.stop else { return XCTFail(report.text()) }
        let state = try await js(driver, "document.getElementById('u').value+'/'+document.getElementById('p').value+'/'+(window.pressed||0)")
        XCTAssertEqual(state, "//0")
    }

    func testFollowsASignInLinkFromTheFrontPage() async throws {
        let driver = try await open("""
            <nav><a href="#">Flights</a>
            <a href="#" onclick="document.getElementById('main').innerHTML=document.getElementById('t').innerHTML;return false">Sign in</a></nav>
            <div id=main><h1>Fly somewhere</h1></div>
            <footer><label for=n>Email me offers</label><input id=n type=email name=newsletter><button type=button>Subscribe</button></footer>
            <template id=t>\(form())</template>
            """)
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .signInPressed(button: "Sign in", formStillShowing: false), report.text())
        XCTAssertEqual(report.pages.first?.pressed, "Sign in")
        let typed = try await js(driver, "window.u+'/'+window.p+'/'+document.getElementById('n').value")
        XCTAssertEqual(typed, "alex.rivera/practice-only-password/", "the newsletter box must stay empty")
    }

    func testUsernameFirstThenPassword() async throws {
        let driver = try await open("""
            <div id=main><form><h1>Sign in</h1><label for=u>Email or phone</label><input id=u type=text name=identifier>
            <button type=submit onclick="window.u=document.getElementById('u').value;document.getElementById('main').innerHTML=document.getElementById('t').innerHTML;return false">Next</button></form></div>
            <template id=t><form><h1>Enter your password</h1><label for=p>Password</label><input id=p type=password name=password>
            <button type=submit onclick="window.p=document.getElementById('p').value;document.getElementById('main').innerHTML='<h1>Welcome</h1>';return false">Log in</button></form></template>
            """)
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .signInPressed(button: "Log in", formStillShowing: false), report.text())
        XCTAssertEqual(report.pages.map(\.pressed), ["Next", "Log in"])
        let typed = try await js(driver, "window.u+'/'+window.p")
        XCTAssertEqual(typed, "alex.rivera/practice-only-password")
    }

    func testARegistrationPageIsLeftAlone() async throws {
        let driver = try await open("""
            <form><label for=e>Email</label><input id=e type=email name=email>
            <label for=p>Create a password</label><input id=p type=password name=pw1>
            <label for=q>Confirm password</label><input id=q type=password name=pw2>
            <button type=submit onclick="window.pressed=1;return false">Create account</button></form>
            """)
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .noSignInForm, report.text())
        let state = try await js(driver, "document.getElementById('e').value+'/'+document.getElementById('p').value+'/'+(window.pressed||0)")
        XCTAssertEqual(state, "//0")
    }

    func testAVerificationCodeIsLeftToYou() async throws {
        let driver = try await open(form(after: "<form><h1>Check your phone</h1><label for=c>Enter the 6-digit code</label><input id=c name=otp autocomplete=one-time-code><button type=submit>Verify</button></form>"))
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .twoFactor(field: "Enter the 6-digit code"), report.text())
        XCTAssertEqual(report.pages.last?.stage, "two_factor")
        let code = try await js(driver, "document.getElementById('c').value+'/'+document.activeElement.id")
        XCTAssertEqual(code, "/c", "nothing typed, and the keyboard left in the code box")
        let agent = AgentJSON.text(AgentReport(report))
        XCTAssertTrue(agent.contains("\"reason\" : \"two_factor\"") && agent.contains("Enter the 6-digit code"), agent)
    }

    func testAFormInsideASameOriginFrameIsFilled() async throws {
        // srcdoc frames share the page's origin, so the page script can see into them.
        let inner = form().replacingOccurrences(of: "\"", with: "&quot;")
        let driver = try await open("<h1>Welcome</h1><iframe id=fr srcdoc=\"\(inner)\" style='width:600px;height:400px'></iframe>")
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .signInPressed(button: "Sign in", formStillShowing: false), report.text())
        let typed = try await js(driver, "(function(){var w=document.getElementById('fr').contentWindow;return w.u+'/'+w.p+'/'+w.pressed})()")
        XCTAssertEqual(typed, "alex.rivera/practice-only-password/1")
        XCTAssertEqual(report.pages.first?.entries.map(\.frame), [nil, nil], "a frame on the same site is not a foreign frame")
    }

    func testAFormInsideShadowDOMIsFilled() async throws {
        // A web component: the form lives in an open shadow root, and so does its "Welcome" afterwards.
        let driver = try await open("""
            <h1>Welcome</h1><div id=host></div>
            <script>
            var root = document.getElementById('host').attachShadow({mode: 'open'});
            root.innerHTML = '<form id=f><label for=u>Username</label><input id=u name=username>'
              + '<label for=p>Password</label><input id=p type=password name=password>'
              + '<button type=submit id=b>Sign in</button></form>';
            root.getElementById('b').addEventListener('click', function (e) {
              e.preventDefault();
              window.u = root.getElementById('u').value; window.p = root.getElementById('p').value;
              window.pressed = (window.pressed || 0) + 1;
              root.innerHTML = '<h1>Welcome back</h1>';
            });
            </script>
            """)
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .signInPressed(button: "Sign in", formStillShowing: false), report.text())
        let typed = try await js(driver, "window.u+'/'+window.p+'/'+window.pressed")
        XCTAssertEqual(typed, "alex.rivera/practice-only-password/1")
    }

    func testAFormInAFrameFromElsewhereIsReportedNotGuessed() async throws {
        let driver = try await open("""
            <h1>Sign in</h1>
            <iframe title="Sign in with Apple" src="https://idmsa.practiceair.example/auth/signin" style='width:600px;height:400px'></iframe>
            """)
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .formInFrame(origin: "idmsa.practiceair.example"), report.text())
        XCTAssertEqual(report.stop.code, "form_in_frame")
    }

    func testAPageWithASignOutLinkIsAlreadySignedIn() async throws {
        let driver = try await open("<nav><a href='#'>My trips</a><a href='#'>Sign out</a></nav><h1>Welcome back, Alex</h1>",
                                    at: "https://www.practiceair.com/account/trips")
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .alreadySignedIn(why: "the page has a sign-out link"), report.text())
    }

    func testStaySignedInIsLeftToYou() async throws {
        let driver = try await open(form(after: "<h1>Stay signed in?</h1><p>Do this to reduce the number of times you are asked to sign in.</p><input type=checkbox id=k><label for=k>Do not show this again</label><button type=button>No</button><button type=button>Yes</button>"))
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .trustPrompt, report.text())
    }

    func testARejectedLoginIsReported() async throws {
        let driver = try await open(form(after: "<form><h2>Try again</h2><div role=alert>That username or password is not right.</div><label for=p2>Password</label><input id=p2 type=password name=password></form>"))
        let report = await signIn(driver)
        XCTAssertEqual(report.stop, .pageErrors(["That username or password is not right."]), report.text())
    }
}
