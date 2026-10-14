import WebKit
import XCTest
@testable import BinoCore

/// Answers the way the model would for the practice site's awkwardly worded fields,
/// so these tests are repeatable without loading the model.
private struct StubDecider: DecisionMaker {
    var answers: [(containing: String, concept: Concept, confidence: Double)] = [
        ("send your itinerary", .email, 0.91),
        ("day of travel", .phone, 0.88),
        ("SkyPoints number", .loyaltyNumber, 0.9),
        ("Special assistance", .none, 0.4),
        ("Full name", .fullName, 0.95),
    ]

    func decide(_ requests: [DecisionRequest]) async throws -> [Decision] {
        requests.map { request in
            if let hit = answers.first(where: { request.state.contains($0.containing) }) {
                return Decision(choice: hit.concept.label, confidence: hit.confidence)
            }
            return Decision(choice: Concept.none.label, confidence: 0.3)
        }
    }
}

@MainActor
final class EndToEndTests: XCTestCase {
    private static var server: Process?
    private static var port = 0

    private var site: String { "http://localhost:\(Self.port)" }

    override class func setUp() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("testsite")
        let chosen = Int.random(in: 20000...40000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", String(chosen), "--bind", "127.0.0.1", "--directory", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        server = process
        port = chosen
        // Give the server a moment to start listening.
        for _ in 0..<50 {
            if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(chosen)/site.css")!)) != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    override class func tearDown() {
        server?.terminate()
    }

    private func value(_ driver: WebViewDriver, _ id: String) async throws -> String {
        try await driver.evaluate("(function(){var e=document.getElementById('\(id)');return e?String(e.value):'MISSING'})()")
    }

    private func run(_ driver: WebViewDriver, vault: Vault = .sample, onePage: Bool = false) async -> RunReport {
        var options = RunOptions()
        options.onePage = onePage
        return await FormRunner(driver: driver, vault: vault, decider: StubDecider(), options: options).run()
    }

    // MARK: The practice booking

    func testWholeBookingStopsBeforePaying() async throws {
        let driver = WebViewDriver()
        try await driver.load(url: URL(string: "\(site)/step1.html")!)
        let report = await run(driver)

        XCTAssertEqual(report.stop, .paymentPage)
        XCTAssertEqual(report.pages.count, 4)
        XCTAssertEqual(report.pages.map(\.pressed), ["Sign in", "Continue to contact details", "Continue to payment", nil])
        let address = try await driver.currentURL()
        XCTAssertTrue(address.hasSuffix("/step4.html"), "ended on \(address)")

        // The payment page is filled but nothing on it was pressed.
        let cardName = try await value(driver, "cn")
        let cardNumber = try await value(driver, "cc")
        let expiry = try await value(driver, "exp")
        let code = try await value(driver, "cvc")
        let billingZip = try await value(driver, "bz")
        XCTAssertEqual(cardName, "Alex J Rivera")
        XCTAssertEqual(cardNumber, "4242424242424242")
        XCTAssertEqual(expiry, "08 / 29")
        XCTAssertEqual(code, "123")
        XCTAssertEqual(billingZip, "78701")
        let terms = try await driver.evaluate("String(document.querySelector('input[name=terms]').checked)")
        XCTAssertEqual(terms, "false", "Bino must not accept terms for you")

        // The report owns up to what it left alone.
        let text = report.text()
        XCTAssertTrue(report.pages[3].unreachable.contains { $0.contains("Payment box") }, text)
        let attention = report.attention.map { $0.entry.field }
        XCTAssertTrue(attention.contains { $0.contains("fare rules") }, text)
        XCTAssertTrue(attention.contains("Full name"), "emergency contact should be flagged: \(text)")

        // No secret appears anywhere in the report.
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for secret in ["4242424242424242", "practice-only-password", "X12345678", "TT1234567"] {
            XCTAssertFalse(text.contains(secret) || json.contains(secret), "\(secret) leaked into the report")
        }
    }

    func testTravelerPageValues() async throws {
        let driver = WebViewDriver()
        try await driver.load(url: URL(string: "\(site)/step2.html")!)
        let report = await run(driver, onePage: true)
        XCTAssertEqual(report.stop, .onePageOnly)

        let expected = ["ttl": "Mr", "gn": "Alex", "mn": "Jordan", "sn": "Rivera", "bm": "3", "bd": "14", "by": "1990",
                        "nat": "US", "ktn": "TT1234567", "rdr": "", "ffp": "PA998877", "asst": "",
                        "en": "", "ep": ""]
        for (id, want) in expected {
            let got = try await value(driver, id)
            XCTAssertEqual(got, want, "field \(id)")
        }
        let gender = try await driver.evaluate("(document.querySelector('input[name=\"pax[0].gender\"]:checked')||{}).value||''")
        XCTAssertEqual(gender, "M")
        let offers = try await driver.evaluate("String(document.querySelector('input[name=offers]').checked)")
        XCTAssertEqual(offers, "false")
    }

    func testContactPageValues() async throws {
        let driver = WebViewDriver()
        try await driver.load(url: URL(string: "\(site)/step3.html")!)
        _ = await run(driver, onePage: true)

        let expected = ["itin": "alex.rivera@example.com", "reach": "5125550142", "a1": "200 Example Street",
                        "a2": "Apt 4B", "cty": "Dallas", "st": "TX", "zip": "78701", "ctry": "USA",
                        "doc": "X12345678", "iss": "US", "dex": "31/05/2031", "promo": ""]
        for (id, want) in expected {
            let got = try await value(driver, id)
            XCTAssertEqual(got, want, "field \(id)")
        }
        let phone = try await driver.evaluate("['ph_a','ph_b','ph_c'].map(function(n){return document.querySelector('[name='+n+']').value}).join('-')")
        XCTAssertEqual(phone, "512-555-0142")
        // The page keeps its own copy of this field and throws away values set without the right events.
        try await Task.sleep(nanoseconds: 400_000_000)
        let kept = try await value(driver, "itin")
        XCTAssertEqual(kept, "alex.rivera@example.com")
    }

    // MARK: Things Bino must never do

    private func page(_ body: String) -> String {
        "<!doctype html><html><head><title>Test</title></head><body>\(body)</body></html>"
    }

    func testPasswordIsNotTypedOnALookalikeSite() async throws {
        var vault = Vault.sample
        vault.logins[0].site = "practiceair.com"
        let html = page("""
            <form><label for=u>Username</label><input id=u name=username>
            <label for=p>Password</label><input id=p type=password name=password>
            <button type=submit onclick="window.pressed=1;return false">Sign in</button></form>
            """)

        let fake = WebViewDriver()
        try await fake.load(html: html, baseURL: URL(string: "https://practiceair.com.account-check.example/login")!)
        let report = await run(fake, vault: vault)
        let fakeUser = try await value(fake, "u")
        let fakePassword = try await value(fake, "p")
        XCTAssertEqual(fakePassword, "")
        XCTAssertEqual(fakeUser, "")
        let pressed = try await fake.evaluate("String(window.pressed||0)")
        XCTAssertEqual(pressed, "0", "must not press Sign in without having signed in")
        XCTAssertTrue(report.attention.contains { $0.entry.leaveKind == .safety }, report.text())

        let real = WebViewDriver()
        try await real.load(html: html, baseURL: URL(string: "https://www.practiceair.com/login")!)
        _ = await run(real, vault: vault, onePage: true)
        let realPassword = try await value(real, "p")
        XCTAssertEqual(realPassword, "practice-only-password")
    }

    func testCardIsNotTypedWithoutHttps() async throws {
        let driver = WebViewDriver()
        let html = page("""
            <form><label for=n>First name</label><input id=n name=fname>
            <label for=c>Card number</label><input id=c name=cardnumber>
            <label for=v>CVV</label><input id=v name=cvv>
            <button type=submit>Continue</button></form>
            """)
        try await driver.load(html: html, baseURL: URL(string: "http://shop.example/checkout")!)
        let report = await run(driver)
        let name = try await value(driver, "n")
        let card = try await value(driver, "c")
        let code = try await value(driver, "v")
        XCTAssertEqual(name, "Alex")
        XCTAssertEqual(card, "")
        XCTAssertEqual(code, "")
        XCTAssertEqual(report.stop, .paymentPage)
    }

    func testFinalButtonsAreNeverPressed() async throws {
        for label in ["Place order", "Submit", "Pay now", "Book flight", "Complete purchase", "Confirm"] {
            let driver = WebViewDriver()
            let html = page("""
                <form onsubmit="window.pressed=(window.pressed||0)+1;return false">
                <label for=e>Email</label><input id=e type=email name=email>
                <button type=submit onclick="window.pressed=(window.pressed||0)+1">\(label)</button></form>
                """)
            try await driver.load(html: html, baseURL: URL(string: "https://shop.example/review")!)
            let report = await run(driver)
            let pressed = try await driver.evaluate("String(window.pressed||0)")
            XCTAssertEqual(pressed, "0", "pressed \"\(label)\"")
            XCTAssertEqual(report.stop, .finalStep(button: label))
        }
    }

    func testUnrecognisedButtonsAreNotPressed() async throws {
        let driver = WebViewDriver()
        let html = page("""
            <form><label for=e>Email</label><input id=e type=email name=email>
            <button type=submit onclick="window.pressed=1;return false">Let's go!</button></form>
            """)
        try await driver.load(html: html, baseURL: URL(string: "https://shop.example/start")!)
        let report = await run(driver)
        let pressed = try await driver.evaluate("String(window.pressed||0)")
        XCTAssertEqual(pressed, "0")
        XCTAssertEqual(report.stop, .noWayForward)
    }

    func testUnansweredQuestionStopsTheRun() async throws {
        let driver = WebViewDriver()
        let html = page("""
            <form><label for=e>Email</label><input id=e type=email name=email>
            <fieldset><legend>Add travel insurance?</legend>
            <label><input type=radio name=ins value=y> Yes, protect my trip</label>
            <label><input type=radio name=ins value=n> No thanks</label></fieldset>
            <button type=submit onclick="window.pressed=1;return false">Continue</button></form>
            """)
        try await driver.load(html: html, baseURL: URL(string: "https://shop.example/extras")!)
        let report = await run(driver)
        let pressed = try await driver.evaluate("String(window.pressed||0)")
        let chosen = try await driver.evaluate("String(document.querySelectorAll('input[name=ins]:checked').length)")
        XCTAssertEqual(pressed, "0")
        XCTAssertEqual(chosen, "0", "Bino must not answer the insurance question")
        guard case .needsYou = report.stop else { return XCTFail(report.text()) }
    }

    func testCaptchaStopsTheRun() async throws {
        let driver = WebViewDriver()
        let html = page("""
            <form><label for=e>Email</label><input id=e type=email name=email>
            <iframe title="reCAPTCHA" src="about:blank#recaptcha/anchor" style="width:304px;height:78px"></iframe>
            <button type=submit onclick="window.pressed=1;return false">Continue</button></form>
            """)
        try await driver.load(html: html, baseURL: URL(string: "https://shop.example/signup")!)
        let report = await run(driver)
        let pressed = try await driver.evaluate("String(window.pressed||0)")
        XCTAssertEqual(pressed, "0")
        XCTAssertEqual(report.stop, .captcha)
    }

    func testSecondTravelerIsLeftBlank() async throws {
        let driver = WebViewDriver()
        let html = page("""
            <form>
            <fieldset><legend>Passenger 1</legend><label for=a>First name</label><input id=a name="p1first">
            <label for=b>Last name</label><input id=b name="p1last"></fieldset>
            <fieldset><legend>Passenger 2</legend><label for=c>First name</label><input id=c name="p2first">
            <label for=d>Last name</label><input id=d name="p2last"></fieldset>
            </form>
            """)
        try await driver.load(html: html, baseURL: URL(string: "https://air.example/pax")!)
        _ = await run(driver, onePage: true)
        let first = try await value(driver, "a"), second = try await value(driver, "c")
        let secondLast = try await value(driver, "d")
        XCTAssertEqual(first, "Alex")
        XCTAssertEqual(second, "")
        XCTAssertEqual(secondLast, "")
    }

    func testNewPasswordsAreLeftToYou() async throws {
        var vault = Vault.sample
        vault.logins[0].site = "shop.example"
        let driver = WebViewDriver()
        let html = page("""
            <form><label for=e>Email</label><input id=e type=email name=email>
            <label for=p>Create a password</label><input id=p type=password name=pw1>
            <label for=q>Confirm password</label><input id=q type=password name=pw2></form>
            """)
        try await driver.load(html: html, baseURL: URL(string: "https://shop.example/register")!)
        _ = await run(driver, vault: vault, onePage: true)
        let first = try await value(driver, "p"), second = try await value(driver, "q")
        XCTAssertEqual(first, "")
        XCTAssertEqual(second, "")
    }
}
