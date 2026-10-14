import AppKit
import ArgumentParser
import BinoCore
import Foundation

/// Where a command's words go.
///
/// With `--json` the only thing on standard output is one JSON object, so another program
/// can read it: progress lines move to standard error and failures become JSON too.
struct Output {
    var json: Bool
    var command: String

    func progress(_ text: String) {
        if json {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        } else {
            say(text)
        }
    }

    func fail(_ text: String) -> Never {
        guard json else { bino.fail(text) }
        say(AgentJSON.text(AgentFailure(command: command, error: text)))
        Foundation.exit(1)
    }

    /// Saves the report and prints it, as JSON without values or as the usual text.
    func finish(_ report: RunReport) throws {
        let saved = try? report.save()
        if json {
            say(AgentJSON.text(AgentReport(report, reportFile: saved?.path)))
        } else {
            say("")
            say(report.text())
            if let saved {
                say("")
                say("Saved to \(saved.path)")
            }
        }
        if case .failed = report.stop { throw ExitCode(1) }
    }
}

/// Which browser a command works in.
enum BrowserChoice: String, ExpressibleByArgument, CaseIterable {
    case safari
    /// Google Chrome, driven through accessibility.
    case chrome
    /// The Claude desktop app's own browser pane, driven through accessibility.
    case claude

    /// A driver on that browser's tab (the front one unless `tab` names another).
    func driver(tab: String?) -> TabbedBrowserDriver {
        switch self {
        case .safari: return SafariDriver(tab: tab)
        // Chrome's tabs come from Chrome itself (every window, every desktop); its pages from the screen.
        case .chrome: return AccessibilityDriver(source: AccessibilityDriver.chrome, tabs: ChromeTabAuthority(), tab: tab)
        case .claude: return AccessibilityDriver(source: AccessibilityDriver.claude, tab: tab)
        }
    }

    var name: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .claude: return "Claude's browser pane"
        }
    }
}

/// A browser tab (the front one unless `tab` names another), or an off-screen test
/// browser showing `testURL`.
func makeDriver(testURL: String?, tab: String? = nil, browser: BrowserChoice = .safari, output: Output) async -> BrowserDriver {
    guard let testURL else { return browser.driver(tab: tab) }
    guard let url = URL(string: testURL) else { output.fail("That test address is not valid.") }
    let driver = await MainActor.run { () -> WebViewDriver in
        _ = NSApplication.shared
        return WebViewDriver()
    }
    do {
        try await driver.load(url: url)
    } catch {
        output.fail("The test page did not load: \(error.localizedDescription)")
    }
    return driver
}

// MARK: status

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Say which site is in the browser's front tab, whether it looks signed in, and whether Bino is ready. No Touch ID, nothing typed.")

    @Option(name: .long, help: "Look at this tab instead of the front one: part of its address (apply.example.com), or an id from `bino tabs`.")
    var tab: String?

    @Option(name: .long, help: "Which browser: safari (default), chrome, or claude for the Claude desktop app's browser pane.")
    var browser: BrowserChoice = .safari

    @Option(name: .long, help: "Say whether a login is saved for this site (appstoreconnect.apple.com), even when no tab is on it.")
    var site: String?

    @Flag(name: .long, help: "Print one JSON object for another program to read.")
    var json = false

    struct Payload: Encodable {
        struct Browser: Encodable {
            /// "safari", "chrome" or "claude".
            var name: String
            var reachable: Bool
            /// The tab looked at, as `bino tabs` names it.
            var tab: String?
            /// Chrome's own number for the tab, which `--tab` also takes.
            var tabId: Int?
            var site: String?
            var address: String?
            var title: String?
            /// Whether the page looks signed in: true (a sign-out link), false (a sign-in form), or unknown.
            var signedIn: String = "unknown"
            /// How `signedIn` was judged.
            var signedInBy: String?
            var problem: String?
        }

        struct VaultInfo: Encodable {
            var exists: Bool
            var touchId: Bool
        }

        struct ModelInfo: Encodable {
            var configured: Bool
            var running: Bool
            var name: String?
        }

        struct Last: Encodable {
            var command: String
            var site: String
            var stopped: String
            var finishedAt: Date
        }

        var ok = true
        var command = "status"
        /// The browser looked at and the tab in it. `safari` is the same object, kept for
        /// programs written when Safari was the only browser.
        var browser: Browser
        var safari: Browser
        /// The site `saved_login` and `accounts` are about: the tab's, or --site.
        var site: String?
        /// "yes", "no", or "unknown" until the vault has been unlocked once with this version.
        var savedLogin: String
        /// The names of the accounts saved for the site (or a parent of it). More than one: say which with --account.
        var accounts: [String]?
        var vault: VaultInfo
        var model: ModelInfo
        var lastReport: Last?
    }

    /// Whether the page looks signed in, from what is on it: a sign-out link means yes, a
    /// password box or a sign-in form means no. Nothing is typed or pressed.
    @MainActor
    private func judgeSignedIn(_ driver: BrowserDriver) async -> (String, String?) {
        guard let scan = try? await driver.scan() else { return ("unknown", nil) }
        if scan.fields.contains(where: { $0.type == "password" }) { return ("false", "the page has a password box") }
        let signOut = (try? await driver.links(matching: FormRunner.signOutWording)) ?? []
        if let link = signOut.first { return ("true", "the page has a \"\(link.text)\" link") }
        if let button = scan.buttons.first(where: { $0.text.range(of: FormRunner.signOutWording, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return ("true", "the page has a \"\(button.text)\" button")
        }
        let signIn = (try? await driver.links(matching: FormRunner.signInWording)) ?? []
        if let link = signIn.first { return ("false", "the page has a \"\(link.text)\" link") }
        if let button = scan.buttons.first(where: { ButtonRules.classify($0.text) == .login }) {
            return ("false", "the page has a \"\(button.text)\" button")
        }
        return ("unknown", "no sign-in or sign-out link on the page")
    }

    func run() async throws {
        var looked = Payload.Browser(name: browser.rawValue, reachable: false)
        let driver = browser.driver(tab: tab)
        do {
            let url = try await driver.currentURL()
            looked.reachable = true
            looked.tab = try await MainActor.run { try driver.settleTab() }
            if let id = looked.tab, let tabs = try? await MainActor.run(body: { try driver.tabs() }) {
                looked.tabId = tabs.first { $0.id == id }?.tabID
            }
            looked.site = SitePolicy.host(of: url)
            looked.address = RunReport.tidy(url)
            looked.title = try await driver.title()
            (looked.signedIn, looked.signedInBy) = await judgeSignedIn(driver)
        } catch {
            looked.problem = "\(error)"
        }

        // Which site to answer "is a login saved?" for: --site, else the tab's, else a host given as --tab.
        let asked = site.map(SitePolicy.normalizeSite)
            ?? looked.site
            ?? tab.map(SitePolicy.normalizeSite).flatMap { SitePolicy.isAcceptableSite($0) ? $0 : nil }
        var savedLogin = "unknown"
        var accounts: [String]?
        if let asked, let known = LoginIndex.hasLogin(forSite: asked) {
            savedLogin = known ? "yes" : "no"
            if known { accounts = LoginIndex.accounts(forSite: asked) }
        }

        let config = BinoConfig.load()
        let last = RunReport.loadLatest()
        let payload = Payload(
            browser: looked, safari: looked, site: asked, savedLogin: savedLogin, accounts: accounts,
            vault: .init(exists: VaultStore.exists, touchId: VaultStore.exists && !VaultStore.isTestVault),
            model: .init(configured: config != nil, running: await SidecarDecider().isRunning(), name: config?.model),
            lastReport: last.map {
                .init(command: $0.command ?? "fill", site: $0.site, stopped: $0.stop.code, finishedAt: $0.finishedAt)
            })

        if json {
            say(AgentJSON.text(payload))
            return
        }
        if let site = looked.site {
            say("\(browser.name): \(site)" + ((looked.title ?? "").isEmpty ? "" : " (\(looked.title ?? ""))"))
            switch looked.signedIn {
            case "true": say("Signed in: looks like it (\(looked.signedInBy ?? ""))")
            case "false": say("Signed in: no (\(looked.signedInBy ?? ""))")
            default: say("Signed in: cannot tell")
            }
        } else {
            say("\(browser.name): \(looked.problem ?? "no page open")")
        }
        if let asked {
            let what = asked == looked.site ? "this site" : asked
            switch savedLogin {
            case "yes": say("Saved login for \(what): yes" + (accounts.map { $0.count > 1 ? " (\($0.joined(separator: ", ")))" : "" } ?? ""))
            case "no": say("Saved login for \(what): no")
            default: say("Saved login for \(what): not known until the vault is next unlocked")
            }
        }
        say("Vault: " + (payload.vault.exists
            ? (payload.vault.touchId ? "protected by Touch ID" : "test vault (no Touch ID)") : "none yet"))
        say("Decision model: " + (config.map { "\($0.model), \(payload.model.running ? "loaded" : "not loaded (loads on the first fill)")" }
            ?? "not set up"))
        if let last { say("Last report: \(last.site). \(last.stop.headline)") }
    }
}

// MARK: login

/// Something that stopped a command before it began, in words for the person.
struct Problem: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The steps of signing in, shared by `bino login` and the voice command.
enum SignInFlow {
    static func nothingSaved(_ site: String) -> String {
        "No login is saved for \(site). Add one on the Vault tab of the Bino window, with the site filled in."
    }

    /// Several accounts are saved for the site and none, a wrong one, or an ambiguous one was named.
    struct WhichAccount: Error {
        var site: String
        var accounts: [String]
        var asked: String?
        var ambiguous = false
        var stop: StopReason { .whichAccount(site: site, accounts: accounts, asked: asked, ambiguous: ambiguous) }
    }

    /// The login saved for a site. Asks for Touch ID, except when it is already known
    /// that nothing is saved, or that an account has to be chosen first. Blocks while the
    /// prompt is up, so keep it off the main thread in the window.
    static func login(forSite site: String, account: String? = nil) throws -> BinoCore.Login {
        let wanted = SitePolicy.normalizeSite(site)
        guard VaultStore.exists else { throw Problem("\(VaultError.noVault)") }
        // Known without unlocking, so there is no Touch ID prompt for a site with nothing saved.
        if LoginIndex.hasLogin(forSite: wanted) == false { throw Problem(nothingSaved(wanted)) }
        // The index knows the names, so a part of one is matched to the whole before Touch ID.
        var chosen = account
        if let names = LoginIndex.accounts(forSite: wanted), !names.isEmpty {
            if let account {
                switch AccountMatch.pick(account, from: names) {
                case .one(let index): chosen = names[index]
                case .several(let fits): throw WhichAccount(site: wanted, accounts: fits, asked: account, ambiguous: true)
                case .none: throw WhichAccount(site: wanted, accounts: names, asked: account)
                }
            } else if names.count > 1 {
                throw WhichAccount(site: wanted, accounts: names, asked: nil)
            }
        }
        let vault = try VaultStore.unlock(reason: chosen.map { "sign in to \(wanted) as \($0)" } ?? "sign in to \(wanted)")
        switch vault.login(forPage: "https://\(wanted)/", account: chosen) {
        case .one(let saved): return saved
        case .none: throw Problem(nothingSaved(wanted))
        case .several(let names): throw WhichAccount(site: wanted, accounts: names, asked: nil)
        case .noSuchAccount(let asked, let names): throw WhichAccount(site: wanted, accounts: names, asked: asked)
        case .ambiguous(let asked, let names): throw WhichAccount(site: wanted, accounts: names, asked: asked, ambiguous: true)
        }
    }

    /// Opens the sign-in page unless the browser is already there, then signs in.
    /// `requested` is the site as asked for (appstoreconnect.apple.com), which may be
    /// more specific than the site the login is saved under (apple.com): that is the host
    /// opened. With no `address`, any page on it, or on a host that signs people in for
    /// the login's site, counts as already there.
    @MainActor
    static func run(_ login: BinoCore.Login, requested: String? = nil, address: URL? = nil, driver: BrowserDriver,
                    progress: @escaping (String) -> Void) async throws -> RunReport {
        let site = SitePolicy.normalizeSite(requested ?? login.site)
        guard let target = SignInTarget.url(requested: site, login: login, address: address) else {
            throw Problem("\"\(site)\" is not a site name.")
        }
        let current = try? await driver.currentURL()
        if !SignInTarget.isAlreadyThere(current: current, requested: site, login: login, address: address) {
            progress("Opening \(RunReport.tidy(target.absoluteString))")
            try await driver.open(target)
        }
        var options = RunOptions()
        options.progress = progress
        return await FormRunner(driver: driver, vault: nil, decider: nil, options: options).signIn(with: login)
    }
}

struct SignIn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Open a site in Safari and sign in with the login saved for it.",
        discussion: """
            Asks for Touch ID, types the saved username and password, presses the sign-in button and \
            stops. The password is only ever typed on the site it was saved for. If Safari's front tab \
            is already on that site, that page is used; otherwise the site opens in a new tab. With \
            --browser chrome the same happens in Google Chrome. With --browser claude the login goes \
            into the page showing in the Claude desktop app's browser pane, which has to be on the \
            site already (Bino cannot open pages there).
            """)

    @Argument(help: "The site as saved in the vault, for example united.com.")
    var site: String

    @Option(name: .long, help: "Open this address instead of the site's front page. It must be on the same site.")
    var url: String?

    @Option(name: .long, help: "Which account, when several are saved for the site: the name next to the login in the vault (\"therethen\", \"beecave\"), a part of it, or its number (1, 2, …). `bino status` lists them.")
    var account: String?

    @Option(name: .long, help: "Work in this tab instead of the front one: part of its address (apply.example.com), or an id from `bino tabs`.")
    var tab: String?

    @Option(name: .long, help: "Which browser: safari (default), chrome, or claude for the Claude desktop app's browser pane.")
    var browser: BrowserChoice = .safari

    @Flag(name: .long, help: "Print one JSON object for another program to read. It never contains the username or password.")
    var json = false

    @Flag(name: .long, help: ArgumentHelp("Use a built-in test browser instead of Safari.", visibility: .hidden))
    var testBrowser = false

    func run() async throws {
        let out = Output(json: json, command: "login")
        let wanted = SitePolicy.normalizeSite(site)
        guard SitePolicy.isAcceptableSite(wanted) else {
            out.fail("\"\(site)\" is not a site name. Use something like united.com.")
        }
        var address: URL?
        if let url {
            guard let given = URL(string: url), SitePolicy.page(url, matchesSite: wanted) else {
                out.fail("That address is not on \(wanted).")
            }
            address = given
        }
        do {
            let login: BinoCore.Login
            do {
                login = try SignInFlow.login(forSite: wanted, account: account)
            } catch let which as SignInFlow.WhichAccount {
                // Nothing was typed: an account has to be chosen first.
                var report = RunReport()
                report.command = "login"
                report.site = wanted
                report.stop = which.stop
                report.finishedAt = Date()
                try out.finish(report)
                return
            }
            let driver: BrowserDriver = testBrowser
                ? await makeDriver(testURL: (address?.absoluteString ?? "https://\(wanted)/"), output: out) : browser.driver(tab: tab)
            // Bino cannot open pages in Claude's pane: say so before Touch ID is asked for.
            if browser == .claude, let tabbed = driver as? TabbedBrowserDriver {
                do { try await MainActor.run { _ = try tabbed.settleTab() } } catch { out.fail("\(error)") }
            }
            let report = try await SignInFlow.run(login, requested: wanted, address: address, driver: driver) { out.progress($0) }
            try out.finish(report)
        } catch let code as ExitCode {
            throw code
        } catch {
            out.fail("\(error)")
        }
    }
}

// MARK: signup

struct SignUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signup",
        abstract: "Fill a sign-up form with a new strong password, and save that password in the vault.",
        discussion: """
            Asks for Touch ID, fills the sign-up form in Safari from your details, makes a random \
            password, saves it in the vault as a login for the site, types it, and stops. The button \
            that creates the account is left for you to press. With no site, the page in Safari's front \
            tab is used; a front page's "Sign up" link is followed once.
            """)

    @Argument(help: "The site to make the account on, for example united.com. Default: the site in Safari's front tab.")
    var site: String?

    @Option(name: .long, help: "Open this address (the sign-up page) first.")
    var url: String?

    @Option(name: .long, help: "The username to ask for. Default: one made from your email address.")
    var username: String?

    @Option(name: .long, help: "Sign up with this email address instead of the one in the vault.")
    var email: String?

    @Option(name: .long, help: "Length of the new password.")
    var length = PasswordMaker.defaultLength

    @Flag(name: .long, help: "Letters and digits only, for a site that refuses other characters.")
    var noSymbols = false

    @Flag(name: .long, help: "Make an account even though a login is already saved for this site.")
    var another = false

    @Option(name: .long, help: "Work in this Safari tab instead of the front one: part of its address (apply.example.com), or an id from `bino tabs`.")
    var tab: String?

    @Flag(name: .long, help: "Only look: show what would be filled. No Touch ID, no password made, nothing typed.")
    var dryRun = false

    @Flag(name: .long, help: "Skip the decision model and use the fixed rules only.")
    var noModel = false

    @Flag(name: .long, help: "Print one JSON object for another program to read. It never contains the username or password.")
    var json = false

    @Option(name: .long, help: ArgumentHelp("Open this address in a built-in test browser instead of Safari.", visibility: .hidden))
    var testURL: String?

    func run() async throws {
        let out = Output(json: json, command: "signup")
        let named = site.map(SitePolicy.normalizeSite)
        if let named, !SitePolicy.isAcceptableSite(named) {
            out.fail("\"\(site ?? "")\" is not a site name. Use something like united.com.")
        }
        var address: URL?
        if let url {
            guard let given = URL(string: url), SitePolicy.host(of: url) != nil else { out.fail("That address is not valid.") }
            if let named, !SitePolicy.page(url, matchesSite: named) { out.fail("That address is not on \(named).") }
            address = given
        }
        if !(PasswordMaker.shortestAllowed...64).contains(length) {
            out.fail("The password length must be between \(PasswordMaker.shortestAllowed) and 64.")
        }

        let driver = await makeDriver(testURL: testURL, tab: tab, output: out)
        do {
            // Go to the page first, so the Touch ID prompt can name the site.
            if testURL == nil, let target = address ?? named.flatMap({ URL(string: "https://\($0)/") }) {
                let current = try? await driver.currentURL()
                let alreadyThere = current.map {
                    address == nil ? SitePolicy.page($0, matchesSite: named ?? "")
                        : RunReport.tidy($0) == RunReport.tidy(target.absoluteString)
                } ?? false
                if !alreadyThere {
                    out.progress("Opening \(RunReport.tidy(target.absoluteString))")
                    try await driver.open(target)
                }
            }
            let page = try await driver.currentURL()
            guard let wanted = named ?? SitePolicy.accountSite(forPage: address?.absoluteString ?? page) else {
                throw Problem("The page in Safari has no site name to save a login for.")
            }

            var options = RunOptions()
            options.dryRun = dryRun
            options.progress = { out.progress($0) }
            var request = SignUpRequest(site: wanted, save: { _ in }, forget: { _ in })
            request.username = username
            request.passwordLength = length
            request.symbols = !noSymbols

            var vault: BinoCore.Vault?
            if !dryRun {
                guard VaultStore.exists else { throw Problem("\(VaultError.noVault)") }
                let taken = "A login is already saved for \(wanted). Use `bino login \(wanted)` to sign in, "
                    + "or add --another to make a second account."
                // Known without unlocking, so there is no Touch ID prompt just to be told no.
                if !another, LoginIndex.hasLogin(forSite: wanted) == true { throw Problem(taken) }
                var unlocked = try VaultStore.unlock(reason: "make an account on \(wanted) and save its new password")
                if !another, unlocked.login(forPage: "https://\(wanted)/") != nil { throw Problem(taken) }
                let keeper = NewLoginKeeper(vault: unlocked)
                request.save = { try keeper.save($0) }
                request.forget = { keeper.forget($0) }
                if let email, !email.isEmpty { unlocked.profile.email = email }
                vault = unlocked
            }

            let decider: DecisionMaker? = noModel ? nil : SidecarDecider()
            if let sidecar = decider as? SidecarDecider {
                do {
                    if !(await sidecar.isRunning()) { out.progress("Loading the decision model…") }
                    let waited = try await sidecar.ensureRunning()
                    if waited > 2 { out.progress("Decision model ready (\(Int(waited)) s).") }
                } catch {
                    out.progress("Carrying on with fixed rules only: \(error)")
                }
            }

            let report = await FormRunner(driver: driver, vault: vault, decider: decider, options: options).signUp(request)
            try out.finish(report)
        } catch let code as ExitCode {
            throw code
        } catch {
            out.fail("\(error)")
        }
    }
}

// MARK: tabs

struct Tabs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tabs",
        abstract: "List the tabs open in Safari, to pick one with --tab. Nothing is read from the pages.")

    @Option(name: .long, help: "Which browser: safari (default), chrome, or claude for the Claude desktop app's browser pane.")
    var browser: BrowserChoice = .safari

    @Flag(name: .long, help: "Print one JSON object for another program to read.")
    var json = false

    struct Payload: Encodable {
        struct Tab: Encodable {
            /// Pass this as --tab. Good until tabs are opened, closed or moved.
            var tab: String
            /// Chrome's own number for the tab, which stays with it when tabs move. --tab takes it too.
            var tabId: Int?
            var window: Int
            var index: Int
            var site: String?
            var address: String
            var title: String
            /// The tab in front, which is the one used when --tab is left out.
            var front: Bool
            /// The tab its window is showing.
            var showing: Bool
            /// Its window is minimized or on another desktop.
            var hidden: Bool
        }

        var ok = true
        var command = "tabs"
        var browser: String
        var tabs: [Tab]
    }

    func run() async throws {
        let out = Output(json: json, command: "tabs")
        do {
            let driver = browser.driver(tab: nil)
            let tabs = try await MainActor.run { try driver.tabs() }.map {
                Payload.Tab(tab: $0.id, tabId: $0.tabID, window: $0.window, index: $0.index, site: SitePolicy.host(of: $0.url),
                            address: RunReport.tidy($0.url), title: $0.title, front: $0.isFront, showing: $0.isCurrent, hidden: $0.hidden)
            }
            if json {
                say(AgentJSON.text(Payload(browser: browser.rawValue, tabs: tabs)))
            } else if tabs.isEmpty {
                say("\(browser.name) has no open tabs.")
            } else {
                for tab in tabs {
                    let id = tab.tabId.map { "\(tab.tab) (\($0))" } ?? tab.tab
                    say("\(tab.front ? "*" : " ") \(id)  \(tab.address)  \(tab.title)\(tab.hidden ? "  [hidden]" : "")")
                }
                say("")
                say("* is the front tab. Use --tab with part of an address, or one of the numbers on the left.")
            }
        } catch {
            out.fail("\(error)")
        }
    }
}
