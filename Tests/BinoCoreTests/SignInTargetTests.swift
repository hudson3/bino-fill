import XCTest
@testable import BinoCore

/// Where `bino login <site>` goes, and which hosts count as the site while signing in.
final class SignInTargetTests: XCTestCase {
    private var apple: Login {
        var login = Login()
        login.site = "apple.com"
        login.username = "alex@example.com"
        login.password = "x"
        return login
    }

    func testTheHostAskedForIsOpenedNotTheParentDomain() {
        XCTAssertEqual(SignInTarget.url(requested: "appstoreconnect.apple.com", login: apple)?.absoluteString, "https://appstoreconnect.apple.com/")
        XCTAssertEqual(SignInTarget.url(requested: "apple.com", login: apple)?.absoluteString, "https://apple.com/")
        XCTAssertEqual(SignInTarget.url(requested: "apple.com", login: apple, address: URL(string: "https://appstoreconnect.apple.com/login")!)?.absoluteString,
                       "https://appstoreconnect.apple.com/login")
        XCTAssertNil(SignInTarget.url(requested: "co.uk", login: apple))
    }

    func testTheSavedSignInPageIsUsedWhenItFits() {
        var login = apple
        login.url = "https://appstoreconnect.apple.com/login"
        XCTAssertEqual(SignInTarget.url(requested: "appstoreconnect.apple.com", login: login)?.absoluteString, "https://appstoreconnect.apple.com/login")
        XCTAssertEqual(SignInTarget.url(requested: "developer.apple.com", login: login)?.absoluteString, "https://developer.apple.com/",
                       "a saved page on another host of the site is not what was asked for")
        login.url = "https://evil.example/login"
        XCTAssertEqual(SignInTarget.url(requested: "apple.com", login: login)?.absoluteString, "https://apple.com/", "never off the site")
    }

    func testAlreadyThereMeansTheHostOrItsSignInHost() {
        let login = apple
        XCTAssertTrue(SignInTarget.isAlreadyThere(current: "https://appstoreconnect.apple.com/login", requested: "appstoreconnect.apple.com", login: login))
        XCTAssertTrue(SignInTarget.isAlreadyThere(current: "https://idmsa.apple.com/appleauth/auth/signin", requested: "appstoreconnect.apple.com", login: login),
                      "Apple's sign-in host counts")
        XCTAssertFalse(SignInTarget.isAlreadyThere(current: "https://www.apple.com/", requested: "appstoreconnect.apple.com", login: login),
                       "the parent's front page is not the host asked for")
        XCTAssertFalse(SignInTarget.isAlreadyThere(current: nil, requested: "apple.com", login: login))
        XCTAssertTrue(SignInTarget.isAlreadyThere(current: "https://www.apple.com/shop", requested: "apple.com", login: login))
        let page = URL(string: "https://appstoreconnect.apple.com/login")!
        XCTAssertTrue(SignInTarget.isAlreadyThere(current: "https://appstoreconnect.apple.com/login?x=1", requested: "apple.com", login: login, address: page))
        XCTAssertFalse(SignInTarget.isAlreadyThere(current: "https://appstoreconnect.apple.com/apps", requested: "apple.com", login: login, address: page))
    }

    func testSignInHostsAreKnownForTheSiteFamily() {
        XCTAssertEqual(SitePolicy.signInHosts(for: "appstoreconnect.apple.com").first, "idmsa.apple.com")
        XCTAssertTrue(SitePolicy.page("https://idmsa.apple.com/x", matchesSiteOrSignInHost: "appstoreconnect.apple.com"))
        XCTAssertTrue(SitePolicy.page("https://accounts.google.com/signin", matchesSiteOrSignInHost: "mail.google.com"))
        XCTAssertTrue(SitePolicy.page("https://login.microsoftonline.com/", matchesSiteOrSignInHost: "outlook.com"))
        XCTAssertFalse(SitePolicy.page("https://idmsa.apple.com.evil.example/", matchesSiteOrSignInHost: "apple.com"))
        XCTAssertFalse(SitePolicy.page("https://accounts.google.com/", matchesSiteOrSignInHost: "apple.com"))
        XCTAssertTrue(SitePolicy.signInHosts(for: "practiceair.com").isEmpty)
    }

    func testSignInPagesAreToldByTheirAddress() {
        for url in ["https://appstoreconnect.apple.com/login", "https://github.com/login", "https://idmsa.apple.com/appleauth/auth/signin",
                    "https://accounts.google.com/", "https://www.example.com/users/sign_in", "https://example.com/auth/callback",
                    "https://example.com/account", "https://auth.example.com/"] {
            XCTAssertTrue(SitePolicy.looksLikeSignInPage(url), url)
        }
        for url in ["https://appstoreconnect.apple.com/apps", "https://www.apple.com/", "https://github.com/someone/project", "https://example.com/blog/signing-off"] {
            XCTAssertFalse(SitePolicy.looksLikeSignInPage(url), url)
        }
    }
}
