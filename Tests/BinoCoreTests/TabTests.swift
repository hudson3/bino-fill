import XCTest
@testable import BinoCore

/// `--tab`: which Safari tab a few typed words mean.
final class TabTests: XCTestCase {
    private let tabs = [
        SafariTab(window: 10, index: 1, url: "https://docs.google.com/spreadsheets/d/abc/edit", title: "Accounts - Google Sheets"),
        SafariTab(window: 10, index: 2, isCurrent: true, inFrontWindow: true, url: "https://www.booking.com/hotel/x.html", title: "Booking.com"),
        SafariTab(window: 10, index: 3, url: "https://apply.pdt.example/form/step2?token=abc", title: "Application | PDT"),
        SafariTab(window: 22, index: 1, isCurrent: true, url: "https://www.pdt.example/about", title: "About PDT"),
    ]

    func testTheFrontTabIsTheDefault() throws {
        XCTAssertEqual(try SafariTab.choose("front", from: tabs).id, "10.2")
        XCTAssertEqual(try SafariTab.choose("", from: tabs).id, "10.2")
    }

    func testPartOfAnAddressPicksTheTab() throws {
        XCTAssertEqual(try SafariTab.choose("apply.pdt.example", from: tabs).id, "10.3")
        XCTAssertEqual(try SafariTab.choose("https://www.booking.com", from: tabs).id, "10.2")
        XCTAssertEqual(try SafariTab.choose("pdt.example/form", from: tabs).id, "10.3")
        XCTAssertEqual(try SafariTab.choose("Google Sheets", from: tabs).id, "10.1", "the title is tried when no address fits")
    }

    func testAnIdFromTheListIsExact() throws {
        XCTAssertEqual(try SafariTab.choose("22.1", from: tabs).url, "https://www.pdt.example/about")
        XCTAssertThrowsError(try SafariTab.choose("22.9", from: tabs))
    }

    func testAChromeTabNumberIsExact() throws {
        let chrome = [
            SafariTab(window: 1, index: 1, url: "https://www.apple.com/", title: "Apple", tabID: 896638801),
            SafariTab(window: 1, index: 2, isCurrent: true, inFrontWindow: true, url: "https://appstoreconnect.apple.com/login", title: "App Store Connect", tabID: 896638802),
            SafariTab(window: 2, index: 1, isCurrent: true, url: "https://appstoreconnect.apple.com/apps", title: "App Store Connect", tabID: 896638900, hidden: true),
        ]
        XCTAssertEqual(try SafariTab.choose("896638900", from: chrome).id, "2.1", "a hidden window's tab is found all the same")
        XCTAssertEqual(try SafariTab.choose("1.1", from: chrome).tabID, 896638801)
        XCTAssertThrowsError(try SafariTab.choose("12345", from: chrome))
        XCTAssertThrowsError(try SafariTab.choose("appstoreconnect", from: chrome), "two tabs on the site: not guessed")
        XCTAssertEqual(try SafariTab.choose("appstoreconnect.apple.com/apps", from: chrome).tabID, 896638900)
        // Without Chrome numbers, a bare number is just text to look for.
        XCTAssertThrowsError(try SafariTab.choose("22", from: tabs))
    }

    func testBinoDoesNotGuessBetweenTabs() {
        XCTAssertThrowsError(try SafariTab.choose("pdt.example", from: tabs)) { error in
            guard case BrowserError.ambiguousTab(_, let which, _) = error else { return XCTFail("\(error)") }
            // The choices are offered without anything from the address's query string.
            XCTAssertEqual(which, ["10.3  apply.pdt.example/form/step2", "22.1  www.pdt.example/about"])
        }
        XCTAssertThrowsError(try SafariTab.choose("united.com", from: tabs)) { error in
            guard case BrowserError.noSuchTab = error else { return XCTFail("\(error)") }
        }
    }

    func testTheSamePageOpenTwiceMeansTheOneShowing() throws {
        let twice = [
            SafariTab(window: 10, index: 1, url: "https://apply.pdt.example/form"),
            SafariTab(window: 10, index: 2, isCurrent: true, inFrontWindow: true, url: "https://apply.pdt.example/form"),
        ]
        XCTAssertEqual(try SafariTab.choose("apply.pdt.example", from: twice).id, "10.2")
    }
}
