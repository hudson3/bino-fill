import XCTest
@testable import BinoCore

/// The Claude pane driver, run against a fake accessibility tree shaped like Apple's
/// two-step sign-in: the Apple ID first, then the password, then a verification code.
@MainActor
final class AccessibilityDriverTests: XCTestCase {
    final class Node: AXNode {
        var role: String
        var subrole = ""
        var roleDescription = ""
        var title: String
        var detail = ""
        var placeholder = ""
        var value = ""
        var url = ""
        var domID = ""
        var enabled = true
        var required = false
        var loaded = true
        var y = 0
        var children: [AXNode]
        var isAlive = true
        var isFocused = false
        var acceptsValue = true
        var onPress: () -> Void = {}
        var onFocus: () -> Void = {}

        init(_ role: String, title: String = "", url: String = "", children: [AXNode] = []) {
            self.role = role; self.title = title; self.url = url; self.children = children
        }

        func setValue(_ text: String) -> Bool { if acceptsValue { value = text }; return acceptsValue }
        func press() -> Bool { onPress(); return true }
        func focus() -> Bool { isFocused = true; onFocus(); return true }
    }

    final class Source: AXSource {
        let name = "a fake pane"
        var roots: [AXNode]
        var typed = ""
        init(_ roots: [AXNode]) { self.roots = roots }
        func windows() throws -> [AXNode] { roots }
        func activate() {}
        func typeKeys(_ text: String) { typed += text }
        func selectAll() {}
        var opener: ((URL) -> Void)?
        func open(_ url: URL) -> Bool { guard let opener else { return false }; opener(url); return true }
    }

    private func shell() -> [Node] {
        [Node("AXWebArea", title: "shell", url: "file:///Applications/Claude.app/x/index.html"),
         Node("AXWebArea", title: "Bino x4 - Claude Code", url: "https://claude.ai/epitaxy/local_1")]
    }

    func testOnlyPagesCountAsTabs() throws {
        let apple = Node("AXWebArea", title: "App Store Connect", url: "https://appstoreconnect.apple.com/login")
        let github = Node("AXWebArea", title: "GitHub", url: "https://github.com/login")
        let window = Node("AXWindow", title: "Claude", children: [Node("AXGroup", children: shell() + [apple, github])])
        let driver = AccessibilityDriver(source: Source([window]), tab: nil)
        let tabs = try driver.tabs()
        XCTAssertEqual(tabs.map(\.url), ["https://appstoreconnect.apple.com/login", "https://github.com/login"])
        XCTAssertEqual(tabs.map(\.id), ["1.1", "1.2"])
        XCTAssertEqual(try AccessibilityDriver(source: Source([window]), tab: "github.com").settleTab(), "1.2")
        XCTAssertEqual(try driver.settleTab(), "1.1", "with no --tab, the first page showing")
        XCTAssertThrowsError(try AccessibilityDriver(source: Source([window]), tab: "example.org").settleTab()) { error in
            XCTAssertTrue("\(error)".contains("No page in a fake pane matches"), "\(error)")
        }
    }

    func testAppleStyleTwoStepSignIn() async throws {
        let email = Node("AXTextField", title: "Email or Phone Number")
        let next = Node("AXButton", title: "Continue")
        let password = Node("AXTextField", title: "Password")
        password.subrole = "AXSecureTextField"
        let signIn = Node("AXButton", title: "Sign In")
        let code = Node("AXTextField", title: "Enter the verification code")
        let heading = Node("AXHeading", title: "Sign in with your Apple Account")
        let page = Node("AXWebArea", title: "App Store Connect", url: "https://appstoreconnect.apple.com/login",
                        children: [Node("AXGroup", children: [heading, email, next])])
        next.onPress = { page.children = [Node("AXGroup", children: [heading, password, signIn])] }
        signIn.onPress = { page.children = [Node("AXGroup", children: [code, Node("AXButton", title: "Continue")])] }
        let window = Node("AXWindow", title: "Claude", children: shell() + [page])
        let source = Source([window])
        let driver = AccessibilityDriver(source: source, tab: "apple.com")

        var login = Login()
        login.site = "apple.com"
        login.username = "alex@example.com"
        login.password = "correct horse"
        var options = RunOptions()
        options.progress = { _ in }
        let report = await FormRunner(driver: driver, vault: nil, decider: nil, options: options).signIn(with: login)

        XCTAssertEqual(email.value, "alex@example.com")
        XCTAssertEqual(password.value, "correct horse")
        XCTAssertEqual(source.typed, "", "set through accessibility, never typed")
        XCTAssertEqual(report.stop, .twoFactor(field: "Enter the verification code"), report.text())
        XCTAssertTrue(code.isFocused)
        XCTAssertEqual(report.pages.map(\.pressed), ["Continue", "Sign In"])
        XCTAssertFalse(report.text().contains("correct horse"), "the password never appears in a report")
    }

    /// A browser that lists its own tabs (Chrome through Apple Events): every window, hidden
    /// ones included. The screen shows only each window's active tab.
    final class Authority: TabAuthority {
        var all: [SafariTab]
        var shown: [Int] = []
        var opened: [String] = []
        /// Puts a tab's page on screen when it is shown or opened.
        var reveal: (SafariTab) -> Void = { _ in }
        init(_ all: [SafariTab]) { self.all = all }
        func tabs() throws -> [SafariTab] { all }
        func show(_ tab: SafariTab) throws {
            guard let id = tab.tabID, let at = all.firstIndex(where: { $0.tabID == id }) else { throw BrowserError.lostTab(browser: "fake") }
            shown.append(id)
            for i in all.indices where all[i].window == tab.window { all[i].isCurrent = all[i].tabID == id }
            reveal(all[at])
        }
        func open(_ url: URL) throws -> SafariTab {
            opened.append(url.absoluteString)
            let tab = SafariTab(window: 1, index: all.filter { $0.window == 1 }.count + 1, isCurrent: true, inFrontWindow: true,
                                url: url.absoluteString, title: "New", tabID: 9000 + all.count)
            all.append(tab)
            reveal(tab)
            return tab
        }
        func tab(id: Int) throws -> SafariTab? { all.first { $0.tabID == id } }
    }

    func testChromeTabsComeFromChromeNotTheScreen() async throws {
        let shop = Node("AXWebArea", title: "Shop", url: "https://shop.example/cart")
        let window = Node("AXWindow", title: "Chrome", children: [shop])
        let source = Source([window])
        let authority = Authority([
            SafariTab(window: 1, index: 1, url: "https://github.com/login", title: "GitHub", tabID: 11),
            SafariTab(window: 1, index: 2, isCurrent: true, inFrontWindow: true, url: "https://shop.example/cart", title: "Shop", tabID: 12),
            SafariTab(window: 2, index: 1, isCurrent: true, url: "https://appstoreconnect.apple.com/login", title: "App Store Connect", tabID: 21, hidden: true),
        ])
        let appleAX = Node("AXWebArea", title: "App Store Connect", url: "https://appstoreconnect.apple.com/login",
                           children: [Node("AXTextField", title: "Email or Phone Number")])
        authority.reveal = { tab in
            if tab.tabID == 21 { window.children = [appleAX] }
            if tab.tabID == 11 { window.children = [Node("AXWebArea", title: "GitHub", url: "https://github.com/login")] }
            if tab.tabID == 12 { window.children = [shop] }
        }

        let listing = AccessibilityDriver(source: source, tabs: authority, tab: nil)
        let tabs = try listing.tabs()
        XCTAssertEqual(tabs.map(\.tabID), [11, 12, 21], "every tab in every window, the hidden one too")
        XCTAssertEqual(tabs.map(\.id), ["1.1", "1.2", "2.1"])
        XCTAssertEqual(try listing.settleTab(), "1.2", "no --tab: the front tab, which is already on screen")
        XCTAssertEqual(authority.shown, [12])

        // Part of an address finds the tab in the hidden window, and it is brought on screen first.
        let byAddress = AccessibilityDriver(source: source, tabs: authority, tab: "appstoreconnect")
        XCTAssertEqual(try byAddress.settleTab(), "2.1")
        XCTAssertEqual(authority.shown, [12, 21])
        let scan = try await byAddress.scan()
        XCTAssertEqual(scan.fields.map(\.label), ["Email or Phone Number"])

        // Chrome's own tab number works as --tab too.
        let byNumber = AccessibilityDriver(source: source, tabs: authority, tab: "11")
        XCTAssertEqual(try byNumber.settleTab(), "1.1")
        let there = try await byNumber.currentURL()
        XCTAssertEqual(there, "https://github.com/login")

        // A tab that is not there is said to be missing, naming the browser's listing command.
        XCTAssertThrowsError(try AccessibilityDriver(source: source, tabs: authority, tab: "united.com").settleTab()) { error in
            XCTAssertTrue("\(error)".contains("No page in a fake pane matches \"united.com\""), "\(error)")
        }

        // Opening goes through the browser, then waits for the page on screen and works there.
        let opener = AccessibilityDriver(source: source, tabs: authority, tab: nil)
        authority.reveal = { tab in
            window.children = [Node("AXWebArea", title: "Apple", url: "https://www.appstoreconnect.apple.com/login", children: [])]
            _ = tab
        }
        try await opener.open(URL(string: "https://appstoreconnect.apple.com/login")!)
        XCTAssertEqual(authority.opened, ["https://appstoreconnect.apple.com/login"])
        let opened = try await opener.currentURL()
        XCTAssertEqual(opened, "https://www.appstoreconnect.apple.com/login", "a redirect to www. is the same page")
    }

    private func runSignIn(_ driver: BrowserDriver, site: String = "apple.com") async -> RunReport {
        var login = Login()
        login.site = site
        login.username = "alex@example.com"
        login.password = "correct horse"
        var options = RunOptions()
        options.progress = { _ in }
        return await FormRunner(driver: driver, vault: nil, decider: nil, options: options).signIn(with: login)
    }

    /// Apple's real shape: the page is appstoreconnect.apple.com, the form is a frame from
    /// idmsa.apple.com (Chromium puts the frame's boxes in the same tree), and the flow is
    /// staged: email, Continue, password, Sign In, then a code.
    func testSignInFormInsideAFrameFromAppleSignInHost() async throws {
        let email = Node("AXTextField", title: "Email or Phone Number")
        let next = Node("AXButton", title: "Continue")
        let password = Node("AXTextField", title: "Password")
        password.subrole = "AXSecureTextField"
        let signIn = Node("AXButton", title: "Sign In")
        let code = Node("AXTextField", title: "Enter the verification code")
        let frame = Node("AXWebArea", title: "Sign in with Apple", url: "https://idmsa.apple.com/appleauth/auth/signin?frame_id=x",
                         children: [Node("AXHeading", title: "Sign in with your Apple Account"), email, next])
        let page = Node("AXWebArea", title: "App Store Connect", url: "https://appstoreconnect.apple.com/login",
                        children: [Node("AXGroup", children: [Node("AXHeading", title: "App Store Connect"), frame])])
        next.onPress = { frame.children = [password, signIn] }
        signIn.onPress = { frame.children = [Node("AXHeading", title: "Two-Factor Authentication"), code, Node("AXButton", title: "Continue")] }
        let window = Node("AXWindow", title: "Chrome", children: [page])
        let driver = AccessibilityDriver(source: Source([window]), tab: "appstoreconnect")

        let scan = try await driver.scan()
        XCTAssertEqual(scan.fields.map(\.origin), ["idmsa.apple.com"], "a box in a frame carries the frame's host")
        XCTAssertEqual(scan.fields.map(\.frame), [1])
        XCTAssertEqual(scan.headings, ["App Store Connect", "Sign in with your Apple Account"])
        XCTAssertTrue(scan.frames.isEmpty, "a frame whose boxes can be read is not an unreachable frame")

        let report = await runSignIn(driver)
        XCTAssertEqual(email.value, "alex@example.com")
        XCTAssertEqual(password.value, "correct horse")
        XCTAssertEqual(report.stop, .twoFactor(field: "Enter the verification code"), report.text())
        XCTAssertTrue(code.isFocused, "the code box is left with the keyboard")
        XCTAssertEqual(code.value, "", "and nothing is typed into it")
        XCTAssertEqual(report.pages.map(\.pressed), ["Continue", "Sign In"])
        XCTAssertEqual(report.pages.map(\.stage), ["username", "two_factor"])
        XCTAssertEqual(report.pages.flatMap(\.entries).map(\.frame), ["idmsa.apple.com", "idmsa.apple.com"])
        XCTAssertEqual(report.filledCount, 2)

        let agent = AgentJSON.text(AgentReport(report))
        XCTAssertTrue(agent.contains("\"reason\" : \"two_factor\""), agent)
        XCTAssertTrue(agent.contains("\"frame\" : \"idmsa.apple.com\""), agent)
        XCTAssertTrue(agent.contains("\"stage\" : \"two_factor\""), agent)
        XCTAssertFalse(agent.contains("correct horse") || agent.contains("alex@example.com"), agent)
    }

    func testNothingGoesIntoAFrameFromAnotherSite() async throws {
        let email = Node("AXTextField", title: "Email")
        let password = Node("AXTextField", title: "Password")
        password.subrole = "AXSecureTextField"
        let frame = Node("AXWebArea", title: "Sign in", url: "https://idmsa.apple.com.evil.example/signin",
                         children: [email, password, Node("AXButton", title: "Sign In")])
        let page = Node("AXWebArea", title: "App Store Connect", url: "https://appstoreconnect.apple.com/login", children: [frame])
        let driver = AccessibilityDriver(source: Source([Node("AXWindow", title: "Chrome", children: [page])]), tab: nil)
        let report = await runSignIn(driver)
        guard case .passwordWithheld(let why) = report.stop else { return XCTFail(report.text()) }
        XCTAssertTrue(why.contains("frame from idmsa.apple.com.evil.example"), why)
        XCTAssertEqual(email.value, "")
        XCTAssertEqual(password.value, "")
    }

    func testAFrameThatCannotBeReadIsNamed() async throws {
        let frame = Node("AXWebArea", title: "", url: "https://idmsa.apple.com/appleauth/auth/signin")
        frame.loaded = true
        let page = Node("AXWebArea", title: "App Store Connect", url: "https://appstoreconnect.apple.com/login",
                        children: [Node("AXGroup", children: [frame])])
        let driver = AccessibilityDriver(source: Source([Node("AXWindow", title: "Chrome", children: [page])]), tab: nil)
        let scan = try await driver.scan()
        XCTAssertEqual(scan.frames.map(\.host), ["idmsa.apple.com"])
        XCTAssertTrue(scan.fields.isEmpty)
        let report = await runSignIn(driver)
        XCTAssertEqual(report.stop, .formInFrame(origin: "idmsa.apple.com"), report.text())
        XCTAssertTrue(AgentJSON.text(AgentReport(report)).contains("\"origin\" : \"idmsa.apple.com\""))

        // A frame still loading is waited for; its boxes appear and the sign-in goes on.
        frame.loaded = false
        let email = Node("AXTextField", title: "Apple ID")
        let password = Node("AXTextField", title: "Password")
        password.subrole = "AXSecureTextField"
        let later = DispatchTime.now() + .seconds(1)
        DispatchQueue.main.asyncAfter(deadline: later) {
            frame.loaded = true
            frame.children = [email, password, Node("AXButton", title: "Sign In")]
        }
        let state = try await driver.readyState()
        XCTAssertEqual(state, "loading", "a frame still loading keeps the page from being complete")
        let again = await runSignIn(AccessibilityDriver(source: Source([Node("AXWindow", title: "Chrome", children: [page])]), tab: nil))
        XCTAssertEqual(email.value, "alex@example.com", again.text())
        XCTAssertEqual(password.value, "correct horse")
    }

    func testTrustThisBrowserIsLeftToYou() async throws {
        let email = Node("AXTextField", title: "Apple ID")
        let password = Node("AXTextField", title: "Password")
        password.subrole = "AXSecureTextField"
        let signIn = Node("AXButton", title: "Sign In")
        let page = Node("AXWebArea", title: "Apple Account", url: "https://account.apple.com/sign-in", children: [email, password, signIn])
        signIn.onPress = {
            page.children = [Node("AXHeading", title: "Trust this browser?"), Node("AXButton", title: "Trust"), Node("AXButton", title: "Not Now")]
        }
        let driver = AccessibilityDriver(source: Source([Node("AXWindow", title: "Chrome", children: [page])]), tab: nil)
        let report = await runSignIn(driver)
        XCTAssertEqual(report.stop, .trustPrompt, report.text())
        XCTAssertEqual(report.pages.last?.stage, "trust_prompt")
        XCTAssertEqual(password.value, "correct horse")
    }

    func testAPageAlreadySignedInIsLeftAlone() async throws {
        let page = Node("AXWebArea", title: "App Store Connect", url: "https://appstoreconnect.apple.com/apps",
                        children: [Node("AXHeading", title: "My Apps"), Node("AXLink", title: "Sign Out"),
                                   Node("AXTextField", title: "Search")])
        let driver = AccessibilityDriver(source: Source([Node("AXWindow", title: "Chrome", children: [page])]), tab: nil)
        let report = await runSignIn(driver)
        XCTAssertEqual(report.stop, .alreadySignedIn(why: "the page has a sign-out link"), report.text())
        XCTAssertEqual(report.stop.code, "already_signed_in")

        // No sign-out link either, but nothing about signing in on the page or in its address.
        let plain = Node("AXWebArea", title: "My Apps", url: "https://appstoreconnect.apple.com/apps", children: [Node("AXHeading", title: "My Apps")])
        let second = await runSignIn(AccessibilityDriver(source: Source([Node("AXWindow", title: "Chrome", children: [plain])]), tab: nil))
        guard case .alreadySignedIn = second.stop else { return XCTFail(second.text()) }

        // On a sign-in address with no form, it is still "no form", not "signed in".
        let empty = Node("AXWebArea", title: "Sign in", url: "https://appstoreconnect.apple.com/login", children: [Node("AXHeading", title: "Loading")])
        let third = await runSignIn(AccessibilityDriver(source: Source([Node("AXWindow", title: "Chrome", children: [empty])]), tab: nil))
        XCTAssertEqual(third.stop, .noSignInForm, third.text())
    }

    func testFillTypesWhenThePageIgnoresTheValue() async throws {
        let box = Node("AXTextField", title: "Username")
        box.acceptsValue = false
        let page = Node("AXWebArea", title: "x", url: "https://example.com/login", children: [box, Node("AXButton", title: "Log in")])
        let source = Source([Node("AXWindow", title: "Claude", children: [page])])
        let driver = AccessibilityDriver(source: source, tab: nil)
        let scan = try await driver.scan()
        XCTAssertEqual(scan.fields.map(\.label), ["Username"])
        let result = try await driver.fill(fieldID: scan.fields[0].id, value: "alex")
        XCTAssertEqual(source.typed, "alex", "falls back to keystrokes once the box has the keyboard")
        XCTAssertFalse(result.ok, "and says so when the page keeps nothing")
        let pressed = try await driver.click(buttonID: scan.buttons[0].id)
        XCTAssertTrue(pressed.ok)
        let links = try await driver.links(matching: "sign.?in")
        XCTAssertTrue(links.isEmpty)
        do {
            try await driver.open(URL(string: "https://example.com/")!)
            XCTFail("the pane cannot be navigated from outside")
        } catch {
            XCTAssertTrue("\(error)".contains("cannot open pages"), "\(error)")
        }
        // A browser that opens pages: the new tab is waited for and worked in from then on.
        let chrome = Source([Node("AXWindow", title: "Chrome", children: [page])])
        chrome.opener = { url in
            (chrome.roots[0] as! Node).children.append(Node("AXWebArea", title: "New", url: url.absoluteString,
                                                               children: [Node("AXTextField", title: "Username")]))
        }
        let opening = AccessibilityDriver(source: chrome, tab: nil)
        try await opening.open(URL(string: "https://example.org/login")!)
        let there = try await opening.currentURL()
        XCTAssertEqual(there, "https://example.org/login")
        XCTAssertEqual(try opening.settleTab(), "1.2")
        // A box that never takes the keyboard gets nothing typed at all.
        let shy = Node("AXTextField", title: "Shy")
        shy.acceptsValue = false
        shy.onFocus = { shy.isFocused = false }
        page.children = [shy]
        let again = try await driver.scan()
        source.typed = ""
        let refused = try await driver.fill(fieldID: again.fields[0].id, value: "x")
        XCTAssertEqual(source.typed, "", "no keyboard, no keystrokes")
        XCTAssertFalse(refused.ok)
    }
}
