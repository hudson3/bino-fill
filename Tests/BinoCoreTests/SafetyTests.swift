import XCTest
@testable import BinoCore

final class SafetyTests: XCTestCase {
    func testSiteNormalizing() {
        XCTAssertEqual(SitePolicy.normalizeSite("https://www.United.com/login?x=1"), "united.com")
        XCTAssertEqual(SitePolicy.normalizeSite(" united.com. "), "united.com")
        XCTAssertTrue(SitePolicy.isAcceptableSite("united.com"))
        XCTAssertFalse(SitePolicy.isAcceptableSite("com"))
        XCTAssertFalse(SitePolicy.isAcceptableSite("co.uk"))
        XCTAssertFalse(SitePolicy.isAcceptableSite(""))
    }

    func testPasswordsOnlyMatchTheirOwnSite() {
        XCTAssertTrue(SitePolicy.page("https://united.com/account", matchesSite: "united.com"))
        XCTAssertTrue(SitePolicy.page("https://www.united.com/account", matchesSite: "united.com"))
        XCTAssertTrue(SitePolicy.page("https://login.united.com/", matchesSite: "united.com"))
        XCTAssertFalse(SitePolicy.page("https://united.com.evil.io/account", matchesSite: "united.com"))
        XCTAssertFalse(SitePolicy.page("https://notunited.com/", matchesSite: "united.com"))
        XCTAssertFalse(SitePolicy.page("https://evil.io/united.com", matchesSite: "united.com"))
        XCTAssertFalse(SitePolicy.page("https://united.com@evil.io/", matchesSite: "united.com"))
        XCTAssertFalse(SitePolicy.page("https://anything.co.uk/", matchesSite: "co.uk"))
    }

    func testSecurePages() {
        XCTAssertTrue(SitePolicy.isSecureContext("https://shop.example/pay"))
        XCTAssertTrue(SitePolicy.isSecureContext("http://localhost:8765/step4.html"))
        XCTAssertFalse(SitePolicy.isSecureContext("http://shop.example/pay"))
        XCTAssertFalse(SitePolicy.isSecureContext("http://localhost.evil.io/pay"))
    }

    func testPasswordIsBlockedOnOtherSites() {
        var vault = Vault.sample
        vault.logins[0].site = "practiceair.com"
        let box = PageField(id: "1", type: "password", label: "Password")
        let good = ValueResolver(vault: vault, pageURL: "https://www.practiceair.com/login")
        XCTAssertEqual(good.resolve(.password, part: .whole, field: box).resolution, .text("practice-only-password"))
        for bad in ["https://practiceair.com.evil.example/login", "https://practiceair.co/login",
                    "https://evil.example/practiceair.com"] {
            let resolver = ValueResolver(vault: vault, pageURL: bad)
            guard case .blocked = resolver.resolve(.password, part: .whole, field: box).resolution else {
                return XCTFail("password was offered to \(bad)")
            }
            guard case .missing = resolver.resolve(.username, part: .whole, field: box).resolution else {
                return XCTFail("username was offered to \(bad)")
            }
        }
    }

    func testSecretsNeedAnEncryptedPage() {
        let resolver = ValueResolver(vault: .sample, pageURL: "http://shop.example/checkout")
        let box = PageField(id: "1", label: "Card number")
        for concept in [Concept.cardNumber, .cardCVV, .cardExpiry, .passportNumber, .password, .knownTravelerNumber] {
            guard case .blocked = resolver.resolve(concept, part: .whole, field: box).resolution else {
                return XCTFail("\(concept) was offered to a page without https")
            }
        }
        // Ordinary details are fine.
        XCTAssertEqual(resolver.resolve(.firstName, part: .whole, field: box).resolution, .text("Alex"))
    }

    func testReportsHideSecrets() {
        XCTAssertEqual(RunReport.mask("practice-only-password", concept: .password), "•••• (hidden)")
        XCTAssertEqual(RunReport.mask("123", concept: .cardCVV), "•••• (hidden)")
        XCTAssertEqual(RunReport.mask("4242424242424242", concept: .cardNumber), "••••4242")
        XCTAssertEqual(RunReport.mask("X12345678", concept: .passportNumber), "••••78")
        XCTAssertEqual(RunReport.mask("Alex", concept: .firstName), "Alex")
        XCTAssertEqual(RunReport.tidy("https://a.example/book/step2?token=abc123#x"), "a.example/book/step2")
    }
}
