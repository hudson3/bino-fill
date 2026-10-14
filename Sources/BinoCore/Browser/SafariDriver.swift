#if os(macOS)
import AppKit
import Carbon
import Foundation

/// One open browser tab, as `bino tabs` lists it (Safari's, Chrome's or a page in
/// Claude's pane; the name is historical).
public struct SafariTab: Equatable {
    public var window: Int
    public var index: Int
    /// The tab showing in its window.
    public var isCurrent: Bool
    public var inFrontWindow: Bool
    public var url: String
    public var title: String
    /// Chrome gives every tab a number that stays with it when tabs move; Safari does not.
    public var tabID: Int?
    /// The window is minimized, or on another desktop: not on screen right now.
    public var hidden: Bool

    public init(window: Int, index: Int, isCurrent: Bool = false, inFrontWindow: Bool = false, url: String, title: String = "",
                tabID: Int? = nil, hidden: Bool = false) {
        self.window = window; self.index = index; self.isCurrent = isCurrent
        self.inFrontWindow = inFrontWindow; self.url = url; self.title = title; self.tabID = tabID; self.hidden = hidden
    }

    /// What to pass as `--tab` to mean exactly this one. Good until tabs are opened, closed or moved.
    public var id: String { "\(window).\(index)" }
    public var isFront: Bool { isCurrent && inFrontWindow }

    private static func plain(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s
    }

    /// The tab a `--tab` value means: "front", an id from `bino tabs` ("4821.3"), or some
    /// text from the tab's address ("apply.example.com", "example.com/form") or, failing
    /// that, its title. Exactly one tab has to fit.
    public static func choose(_ wanted: String, from tabs: [SafariTab]) throws -> SafariTab {
        let needle = plain(wanted)
        if needle.isEmpty || needle == "front" {
            guard let front = tabs.first(where: \.isFront) ?? tabs.first(where: \.isCurrent) else { throw BrowserError.noPage() }
            return front
        }
        if needle.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil {
            guard let exact = tabs.first(where: { $0.id == needle }) else { throw BrowserError.noSuchTab(wanted) }
            return exact
        }
        // A bare number is a Chrome tab id from `bino tabs --browser chrome`.
        if let number = Int(needle), tabs.contains(where: { $0.tabID != nil }) {
            guard let exact = tabs.first(where: { $0.tabID == number }) else { throw BrowserError.noSuchTab(wanted) }
            return exact
        }
        var fits = tabs.filter { plain($0.url).contains(needle) }
        if fits.isEmpty { fits = tabs.filter { $0.title.lowercased().contains(needle) } }
        // The same page open twice: the one you can see is the one meant.
        if fits.count > 1, Set(fits.map { plain($0.url) }).count == 1, let showing = fits.first(where: \.isCurrent) { fits = [showing] }
        guard let found = fits.first else { throw BrowserError.noSuchTab(wanted) }
        guard fits.count == 1 else {
            throw BrowserError.ambiguousTab(wanted, fits.map { "\($0.id)\($0.tabID.map { " (\($0))" } ?? "")  \(RunReport.tidy($0.url))" })
        }
        return found
    }
}

/// A browser with tabs Bino can list and pick from with `--tab`.
public protocol TabbedBrowserDriver: BrowserDriver {
    /// "Safari", "Claude's browser pane": for messages.
    var browserName: String { get }
    /// Every open tab, front window first.
    @MainActor func tabs() throws -> [SafariTab]
    /// Settles which tab this driver works in. Returns its id, as `bino tabs` shows it.
    @MainActor @discardableResult func settleTab() throws -> String
}

/// Drives one tab of the real Safari through Apple Events.
///
/// The tab is chosen once, at first use: the one named, or the front tab. Every later
/// step goes to that same tab, even if another tab or window comes to the front while
/// Bino is working. Safari only knows tabs by position, so the tab carries a mark (a
/// random value in its own session storage) and is found again by it if tabs are opened,
/// closed or moved.
///
/// The JavaScript is handed over as a parameter, not pasted into script text, so a value
/// being filled never appears in a command line or a script file.
public final class SafariDriver: ScriptedBrowserDriver, TabbedBrowserDriver {
    public let browserName = "Safari"

    private let script: NSAppleScript
    private let wanted: String?

    private struct Pin {
        var window: Int
        var tab: Int
        /// How many tabs the window had when the tab was last seen where it should be.
        var count: Int
        var marked = false
    }

    private var pin: Pin?
    private let mark = UUID().uuidString
    private static let lost = "\u{1}BINO_LOST_TAB"

    private var markCode: String {
        "(function(){try{sessionStorage.setItem('__bino_tab','\(mark)');return 'ok'}catch(e){return 'no'}})()"
    }

    /// "ok" on the marked tab, "no" on any other, "unknown" where the page allows no storage.
    private var checkCode: String {
        "(function(){try{return sessionStorage.getItem('__bino_tab')==='\(mark)'?'ok':'no'}catch(e){return 'unknown'}})()"
    }

    /// `tab`: which tab to work in (see `SafariTab.choose`). nil means the front tab.
    public init(tab: String? = nil) {
        wanted = tab
        let source = """
            property sep : (ASCII character 9)
            property nl : (ASCII character 10)
            property lost : (ASCII character 1) & "BINO_LOST_TAB"

            on bino_front()
                tell application "Safari"
                    repeat with w in windows
                        try
                            set t to current tab of w
                            return ((id of w) as text) & sep & ((index of t) as text) & sep & ((count of tabs of w) as text)
                        end try
                    end repeat
                end tell
                error "NO_PAGE"
            end bino_front

            on bino_tabs()
                set out to ""
                tell application "Safari"
                    set frontID to 0
                    repeat with w in windows
                        try
                            set cur to index of current tab of w
                            set wid to id of w
                            if frontID is 0 then set frontID to wid
                            repeat with t in tabs of w
                                set u to URL of t
                                if u is missing value then set u to ""
                                set nm to name of t
                                if nm is missing value then set nm to ""
                                set out to out & wid & sep & (index of t) & sep & ((index of t) is cur) & sep & (wid is frontID) & sep & u & sep & nm & nl
                            end repeat
                        end try
                    end repeat
                end tell
                return out
            end bino_tabs

            on bino_eval(code, wid, idx, checkCode)
                tell application "Safari"
                    if not (exists tab (idx as integer) of window id (wid as integer)) then return lost
                    set t to tab (idx as integer) of window id (wid as integer)
                    if checkCode is not "" then
                        set seen to do JavaScript checkCode in t
                        if seen is "no" then return lost
                    end if
                    set outcome to do JavaScript code in t
                end tell
                if outcome is missing value then return ""
                return outcome as text
            end bino_eval

            on bino_url(wid, idx, checkCode)
                tell application "Safari"
                    if not (exists tab (idx as integer) of window id (wid as integer)) then return lost
                    set t to tab (idx as integer) of window id (wid as integer)
                    if checkCode is not "" then
                        set seen to "unknown"
                        try
                            set seen to do JavaScript checkCode in t
                        end try
                        if seen is "no" then return lost
                    end if
                    set u to URL of t
                end tell
                if u is missing value then return ""
                return u
            end bino_url

            on bino_find(wid, checkCode)
                tell application "Safari"
                    if not (exists window id (wid as integer)) then return "gone"
                    set n to count of tabs of window id (wid as integer)
                    repeat with i from 1 to n
                        try
                            if (do JavaScript checkCode in tab i of window id (wid as integer)) is "ok" then return (i as text) & sep & (n as text)
                        end try
                    end repeat
                    return "0" & sep & (n as text)
                end tell
            end bino_find

            on bino_show(wid, idx)
                tell application "Safari"
                    set w to window id (wid as integer)
                    set current tab of w to tab (idx as integer) of w
                    set index of w to 1
                    activate
                end tell
                return ""
            end bino_show

            on bino_open(address)
                tell application "Safari"
                    if (count of documents) is 0 then
                        make new document with properties {URL:address}
                    else
                        try
                            tell front window to set current tab to (make new tab with properties {URL:address})
                        on error
                            make new document with properties {URL:address}
                        end try
                    end if
                end tell
                return bino_front()
            end bino_open
            """
        script = NSAppleScript(source: source)!
    }

    @MainActor private func run(_ handler: String, _ arguments: [String], launching: Bool = false) throws -> String {
        // Asking Safari anything would launch it; if it is not open there is no form to fill.
        guard launching || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
            throw BrowserError.noPage()
        }
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setDescriptor(parameters, forKeyword: keyDirectObject)

        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if message.contains("NO_PAGE") { throw BrowserError.noPage() }
            if number == -1743 || message.localizedCaseInsensitiveContains("not authorized") {
                throw BrowserError.automationDenied()
            }
            if message.localizedCaseInsensitiveContains("Allow JavaScript from Apple Events") {
                throw BrowserError.javascriptBlocked()
            }
            throw BrowserError.script(message)
        }
        return result.stringValue ?? ""
    }

    // MARK: Which tab

    /// Every open tab, front window first.
    @MainActor public func tabs() throws -> [SafariTab] {
        try run("bino_tabs", []).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6, let window = Int(parts[0]), let index = Int(parts[1]) else { return nil }
            return SafariTab(window: window, index: index, isCurrent: parts[2] == "true", inFrontWindow: parts[3] == "true",
                             url: parts[4], title: parts[5])
        }
    }

    private func parsePin(_ text: String) throws -> Pin {
        let parts = text.split(separator: "\t").compactMap { Int($0) }
        guard parts.count == 3 else { throw BrowserError.badReply("tab") }
        return Pin(window: parts[0], tab: parts[1], count: parts[2])
    }

    /// Settles which tab this driver works in. Returns its id, as `bino tabs` shows it.
    @MainActor @discardableResult public func settleTab() throws -> String {
        if let pin { return "\(pin.window).\(pin.tab)" }
        let chosen: Pin
        if let wanted, !wanted.isEmpty, wanted.lowercased() != "front" {
            let all = try tabs()
            let tab = try SafariTab.choose(wanted, from: all)
            chosen = Pin(window: tab.window, tab: tab.index, count: all.filter { $0.window == tab.window }.count)
        } else {
            chosen = try parsePin(try run("bino_front", []))
        }
        pin = chosen
        return "\(chosen.window).\(chosen.tab)"
    }

    /// The tab is not where it was. Finds it by its mark, or works out that it has simply
    /// moved on to another site (which wipes the mark) and marks it again.
    @MainActor private func findAgain() throws {
        guard var known = pin else { return }
        let reply = try run("bino_find", [String(known.window), checkCode])
        let parts = reply.split(separator: "\t").compactMap { Int($0) }
        guard parts.count == 2 else { throw BrowserError.lostTab() }
        if parts[0] > 0 {
            known.tab = parts[0]
        } else if parts[1] == known.count {
            // Same tabs in the same places: the page went to a different site. Mark it afresh.
            _ = try run("bino_eval", [markCode, String(known.window), String(known.tab), ""])
        } else {
            throw BrowserError.lostTab()
        }
        known.count = parts[1]
        pin = known
    }

    @MainActor private func inTab(_ handler: String, _ leading: [String], check: Bool) throws -> String {
        try settleTab()
        for attempt in 0..<2 {
            guard let pin else { break }
            let reply = try run(handler, leading + [String(pin.window), String(pin.tab), check ? checkCode : ""])
            if reply != Self.lost { return reply }
            if attempt == 0 { try findAgain() }
        }
        throw BrowserError.lostTab()
    }

    @MainActor public func evaluate(_ javascript: String) async throws -> String {
        try settleTab()
        if pin?.marked == false {
            _ = try inTab("bino_eval", [markCode], check: false)
            pin?.marked = true
        }
        return try inTab("bino_eval", [javascript], check: true)
    }

    @MainActor public func currentURL() async throws -> String {
        try settleTab()
        // Before the first script runs there is no mark to check, and reading an address needs none.
        let url = try inTab("bino_url", [], check: pin?.marked == true)
        if url.isEmpty { throw BrowserError.noPage() }
        return url
    }

    /// Brings an open tab to the front: its window forward, that tab showing, Safari active.
    @MainActor public func show(_ tab: SafariTab) throws {
        _ = try run("bino_show", [String(tab.window), String(tab.index)])
    }

    /// The open tab showing a page, if there is one: the one at that very address first,
    /// otherwise any tab on the same site (a form moves between pages as it is filled).
    @MainActor public func tab(showing address: String) throws -> SafariTab? {
        let wanted = RunReport.tidy(address)
        let all = try tabs()
        if let exact = all.first(where: { RunReport.tidy($0.url) == wanted }) { return exact }
        if let under = all.first(where: { RunReport.tidy($0.url).hasPrefix(wanted) }) { return under }
        guard let site = SitePolicy.accountSite(forPage: address) else { return nil }
        return all.first { SitePolicy.page($0.url, matchesSite: site) }
    }

    /// Opens the address in a new tab, so whatever was in the front tab is left as it
    /// was, and works in that new tab from then on.
    @MainActor public func open(_ url: URL) async throws {
        pin = try parsePin(try run("bino_open", [url.absoluteString], launching: true))
        // Until the new page takes over, scripts still run in the empty tab.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let here = try? inTab("bino_eval", ["location.href"], check: false), here.hasPrefix("http") { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
#endif
