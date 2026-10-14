import AppKit
import ArgumentParser
import BinoCore
import Foundation

/// A command that runs the Mac app event loop itself (the vault window).
///
/// It has to start directly on the main thread. Started from inside an async task, the
/// event loop sits on top of that task forever and no other background work in the
/// window (such as auto-sort asking the model) ever gets a turn.
protocol RunsOwnEventLoop: ParsableCommand {}

@main
enum Entry {
    static func main() {
        do {
            let parsed = try Bino.parseAsRoot()
            if var windowed = parsed as? any RunsOwnEventLoop {
                try windowed.run()
                return
            }
            Task {
                do {
                    var command = parsed
                    if var asyncCommand = command as? any AsyncParsableCommand {
                        try await asyncCommand.run()
                    } else {
                        try command.run()
                    }
                    Foundation.exit(0)
                } catch {
                    Bino.exit(withError: error)
                }
            }
            // Keeps the main thread free to serve Safari, the test browser and async work.
            CFRunLoopRun()
        } catch {
            Bino.exit(withError: error)
        }
    }
}

struct Bino: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bino",
        abstract: "Fills web forms in Safari from your encrypted vault, and tells you what it wasn't sure about.",
        subcommands: [App.self, Fill.self, SignIn.self, SignUp.self, Tabs.self, Update.self, StatusCommand.self, VaultCommand.self, Doctor.self, Report.self,
                      Model.self, Dev.self],
        defaultSubcommand: App.self)
}

// MARK: app

struct App: RunsOwnEventLoop {
    static let configuration = CommandConfiguration(
        commandName: "app", abstract: "Open the Bino window: a Fill button with its report, and your vault.")

    func run() throws {
        MainActor.assumeIsolated { BinoApp.run(tab: .fill) }
    }
}

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    Foundation.exit(1)
}

// MARK: fill

struct Fill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fill the form in Safari's front tab and click through until the final step.")

    @Flag(name: .long, help: "Only look: show what would be filled. No Touch ID, nothing typed or pressed.")
    var dryRun = false

    @Flag(name: .long, help: "Fill the current page and stop without pressing anything.")
    var thisPage = false

    @Option(name: .long, help: "Most pages to go through before stopping.")
    var maxPages = 12

    @Flag(name: .long, help: "Skip the decision model and use the fixed rules only.")
    var noModel = false

    @Option(name: .long, help: "Which account to fill a sign-in with, when several are saved for the site: the name next to the login in the vault.")
    var account: String?

    @Option(name: .long, help: "Fill this tab instead of the front one: part of its address (apply.example.com), or an id from `bino tabs`.")
    var tab: String?

    @Option(name: .long, help: "Which browser: safari (default), chrome, or claude for the Claude desktop app's browser pane.")
    var browser: BrowserChoice = .safari

    @Flag(name: .long, help: "Print one JSON object for another program to read. It never contains the values typed.")
    var json = false

    @Option(name: .long, help: ArgumentHelp("Open this address in a built-in test browser instead of Safari.", visibility: .hidden))
    var testURL: String?

    func run() async throws {
        let out = Output(json: json, command: "fill")
        var options = RunOptions()
        options.dryRun = dryRun
        options.onePage = thisPage
        options.maxPages = max(1, maxPages)
        options.account = account
        options.progress = { out.progress($0) }

        let driver = await makeDriver(testURL: testURL, tab: tab, browser: browser, output: out)
        // Settled now, so a tab that cannot be found is reported before Touch ID is asked for.
        if let tabbed = driver as? TabbedBrowserDriver {
            do { try await MainActor.run { _ = try tabbed.settleTab() } } catch { out.fail("\(error)") }
        }

        var vault: Vault?
        if !dryRun {
            guard VaultStore.exists else { out.fail("\(VaultError.noVault)") }
            do {
                // Checked first so Touch ID is not asked for a page Bino cannot reach, and
                // so the prompt can say which site the vault is being opened for.
                let site = SitePolicy.host(of: try await driver.currentURL()) ?? "this page"
                vault = try VaultStore.unlock(reason: "fill the form on \(site)")
            } catch {
                out.fail("\(error)")
            }
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

        var report = await FormRunner(driver: driver, vault: vault, decider: decider, options: options).run()
        report.command = "fill"
        try out.finish(report)
    }
}

// MARK: vault

struct VaultCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault", abstract: "Your encrypted vault.",
        subcommands: [Edit.self, Status.self, Rename.self, SeedTest.self], defaultSubcommand: Status.self)

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give a saved login a short name (\"beecave\"), leaving its username and password as they are.",
            discussion: "Asks for Touch ID. The name is what --account and `bino status` use. Nothing from the vault is printed.")

        @Argument(help: "The site the login is saved for, for example apple.com.")
        var site: String

        @Option(name: .long, help: "Which login, when several are saved for the site: its current name, a part of it, or its number.")
        var account: String?

        @Option(name: .long, help: "The new name.")
        var to: String

        @Flag(name: .long, help: "Print one JSON object for another program to read.")
        var json = false

        struct Payload: Encodable {
            var ok = true
            var command = "vault rename"
            var site: String
            var accounts: [String]
        }

        func run() async throws {
            let out = Output(json: json, command: "vault rename")
            let wanted = SitePolicy.normalizeSite(site)
            let name = to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SitePolicy.isAcceptableSite(wanted) else { out.fail("\"\(site)\" is not a site name. Use something like apple.com.") }
            guard !name.isEmpty else { out.fail("Give the new name with --to.") }
            guard VaultStore.exists else { out.fail("\(VaultError.noVault)") }
            do {
                var vault = try VaultStore.unlock(reason: "rename a login saved for \(wanted)")
                let saved = vault.accounts(forSite: wanted)
                guard !saved.isEmpty else { out.fail(SignInFlow.nothingSaved(wanted)) }
                let index: Int
                if let account {
                    switch AccountMatch.pick(account, from: saved.map(\.name)) {
                    case .one(let i): index = i
                    case .several(let fits): out.fail("\"\(account)\" fits more than one login for \(wanted): \(fits.joined(separator: ", ")). Say more of the name, or its number.")
                    case .none: out.fail("No login named \"\(account)\" is saved for \(wanted). Saved: \(saved.map(\.name).joined(separator: ", ")).")
                    }
                } else if saved.count == 1 {
                    index = 0
                } else {
                    out.fail("Several logins are saved for \(wanted): \(saved.map(\.name).joined(separator: ", ")). Say which with --account.")
                }
                guard let at = vault.logins.firstIndex(where: { $0.id == saved[index].login.id }) else { out.fail("That login is no longer in the vault.") }
                vault.logins[at].note = name
                try VaultStore.save(vault)
                let names = vault.accounts(forSite: wanted).map(\.name)
                if json {
                    say(AgentJSON.text(Payload(site: wanted, accounts: names)))
                } else {
                    say("Renamed. Logins saved for \(wanted): \(names.joined(separator: ", "))")
                }
            } catch let code as ExitCode {
                throw code
            } catch {
                out.fail("\(error)")
            }
        }
    }

    struct Edit: RunsOwnEventLoop {
        static let configuration = CommandConfiguration(abstract: "Open the Bino window on the Vault tab, unlocked.")

        func run() throws {
            var vault: BinoCore.Vault?
            if VaultStore.exists {
                do {
                    vault = try VaultStore.unlock(reason: "open your vault for editing")
                } catch {
                    fail("\(error)")
                }
            }
            MainActor.assumeIsolated { BinoApp.run(tab: .vault, unlocked: vault) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Say whether a vault exists. Never shows its contents.")

        func run() async throws {
            if VaultStore.exists {
                say("Vault: \(BinoPaths.vaultFile.path)")
                say(VaultStore.isTestVault ? "This is a test vault (no Touch ID)." : "Protected by this Mac's Secure Enclave; opening it needs Touch ID.")
            } else {
                say("No vault yet. Run `bino vault edit` to create one.")
            }
        }
    }

    struct SeedTest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "seed-test", abstract: "Create a vault of made-up data for practice.", shouldDisplay: false)

        func run() async throws {
            guard BinoPaths.isRedirected else {
                fail("Refusing: set BINO_HOME to a separate folder first, so the practice vault cannot replace your real one.")
            }
            try VaultStore.save(.sample, createTestVault: true)
            say("Practice vault written to \(BinoPaths.vaultFile.path)")
        }
    }
}

// MARK: report

struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the most recent report again.")

    @Flag(name: .long, help: "Print one JSON object for another program to read. It never contains the values typed.")
    var json = false

    func run() async throws {
        if json {
            guard let report = RunReport.loadLatest() else {
                Output(json: true, command: "report").fail("No reports yet.")
            }
            say(AgentJSON.text(AgentReport(report, reportFile: RunReport.latest()?.path)))
            return
        }
        guard let latest = RunReport.latest(), let text = try? String(contentsOf: latest, encoding: .utf8) else {
            say("No reports yet.")
            return
        }
        say(text)
    }
}

// MARK: model

struct Model: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The local decision model.", subcommands: [Start.self, Stop.self])

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Load the model now so the next fill starts faster.")

        func run() async throws {
            do {
                let waited = try await SidecarDecider().ensureRunning()
                say(waited > 0.5 ? "Model loaded in \(Int(waited)) s." : "Model was already running.")
            } catch {
                fail("\(error)")
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unload the model to free memory.")

        func run() async throws {
            SidecarDecider().stop()
            say("Model stopped.")
        }
    }
}

// MARK: update

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bring this Mac's Bino level with GitHub: pull main, rebuild, reinstall, reopen the app.")

    @Flag(name: .long, help: "Only say whether an update is available.")
    var check = false

    func run() async throws {
        guard let build = BuildInfo.current() else {
            fail("This copy of bino does not know which commit it was built from. Run `make install` in the bino-fill folder.")
        }
        say("Built from \(build.shortCommit)\(build.isDirty ? " with local changes" : "") in \(build.repo.path)")
        do {
            let status = try await Updater.check(build)
            switch status {
            case .upToDate:
                say("Up to date with main.")
                return
            case .ahead:
                say("This build is not on main (local changes or another branch); not updating over it.")
                throw ExitCode(1)
            case .available(let remote):
                say("main is at \(remote.prefix(7)).")
                if check { return }
            }
            try await Updater.install(build) { chunk in
                FileHandle.standardOutput.write(Data(chunk.utf8))
            }
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.bino.fill").isEmpty
            if running {
                say("Reopening Bino…")
                Updater.reopenApp()
            }
            say("Updated.")
        } catch let code as ExitCode {
            throw code
        } catch {
            fail("\(error)")
        }
    }
}

// MARK: doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that everything Bino needs is in place.")

    func run() async throws {
        var problems = 0
        func line(_ ok: Bool, _ good: String, _ bad: String) {
            say((ok ? "  ok   " : "  FIX  ") + (ok ? good : bad))
            if !ok { problems += 1 }
        }
        /// Worth knowing, not worth fixing for Bino's sake.
        func note(_ ok: Bool, _ good: String, _ text: String) {
            say((ok ? "  ok   " : "  note ") + (ok ? good : text))
        }

        say("Vault")
        line(VaultStore.exists, "vault exists" + (VaultStore.isTestVault ? " (test vault)" : ", protected by Touch ID"),
             "no vault yet: run `bino vault edit`")

        say("Decision model")
        if let config = BinoConfig.load() {
            line(FileManager.default.isExecutableFile(atPath: config.python), "Python environment found",
                 "Python environment missing at \(config.python): run `make setup` in the bino-fill folder")
            do {
                let sidecar = SidecarDecider()
                let waited = try await sidecar.ensureRunning()
                let answer = try await sidecar.decide([DecisionRequest(
                    state: "Web form field.\nLabel: Surname", question: "What information should be entered in this field?",
                    options: Concept.allCases.map(\.label))])
                line(answer.first?.choice == Concept.lastName.label,
                     "model \(config.model) answers correctly" + (waited > 1 ? " (loaded in \(Int(waited)) s)" : ""),
                     "model answered unexpectedly: \(answer.first?.choice ?? "nothing")")
            } catch {
                line(false, "", "\(error)")
            }
        } else {
            line(false, "", "not set up: run `make setup` in the bino-fill folder")
        }

        say("Safari")
        do {
            let driver = SafariDriver()
            let url = try await driver.currentURL()
            _ = try await driver.evaluate("1 + 1")
            line(true, "can read the front tab (\(SitePolicy.host(of: url) ?? "no address"))", "")
        } catch let error as BrowserError {
            line(false, "", "\(error)")
        } catch {
            line(false, "", "\(error)")
        }

        say("Chrome")
        if ChromeTabAuthority.isRunning {
            let chrome = ChromeTabAuthority()
            do {
                let tabs = try chrome.tabs()
                line(true, "can list its tabs (\(tabs.count) open)", "")
                do {
                    note(try chrome.canRunJavaScript(), "allows JavaScript from Apple Events",
                         "does not allow JavaScript from Apple Events (View > Developer > Allow JavaScript from Apple Events). Bino signs in without it; it only matters for scripts.")
                } catch let error as BrowserError {
                    switch error {
                    case .noPage: line(true, "no tab to try a script in", "")
                    default: line(false, "", "\(error)")
                    }
                }
                let driver = AccessibilityDriver(source: AccessibilityDriver.chrome, tabs: chrome)
                if let front = tabs.first(where: \.isFront), AccessibilityDriver.isPage(front.url) {
                    do {
                        try await MainActor.run { _ = try driver.settleTab() }
                        line(true, "can read the page on screen (\(SitePolicy.host(of: front.url) ?? "no address"))", "")
                    } catch {
                        line(false, "", "\(error)")
                    }
                } else {
                    line(AXIsProcessTrusted(), "allowed to read its pages (open a web page there to try)",
                         "macOS has not allowed Bino to read other apps' windows: System Settings > Privacy & Security > Accessibility, switch on the app you run bino from")
                }
            } catch {
                line(false, "", "\(error)")
            }
        } else {
            line(true, "not open (nothing to check)", "")
        }

        say("Claude's browser pane")
        if AccessibilityDriver.claude.isRunning {
            do {
                let driver = AccessibilityDriver(source: AccessibilityDriver.claude)
                let tabs = try await MainActor.run { try driver.tabs() }
                line(true, tabs.isEmpty ? "allowed to read it (no web page showing there right now)" : "can see \(tabs.count) page\(tabs.count == 1 ? "" : "s") showing there", "")
            } catch {
                line(false, "", "\(error)")
            }
        } else {
            line(true, "Claude is not open (nothing to check)", "")
        }

        say("")
        say(problems == 0 ? "All good." : "\(problems) thing\(problems == 1 ? "" : "s") to fix.")
        if problems > 0 { throw ExitCode(1) }
    }
}
