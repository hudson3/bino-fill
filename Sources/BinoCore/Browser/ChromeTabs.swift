#if os(macOS)
import AppKit
import Carbon
import Foundation

/// Where a browser's tabs are listed, shown and opened when the accessibility tree
/// cannot do it: the tree shows only each window's active tab, and only windows on
/// this desktop. Chrome answers these through Apple Events instead.
public protocol TabAuthority {
    /// Every tab in every window, front window first: minimized windows, other
    /// desktops and tab groups included.
    func tabs() throws -> [SafariTab]
    /// Makes the tab the one showing in its window and brings that window to the front.
    func show(_ tab: SafariTab) throws
    /// Opens the address in a new tab of the front window and returns that tab.
    func open(_ url: URL) throws -> SafariTab
    /// The tab with this id, read afresh (its address may have moved on). nil when it is gone.
    func tab(id: Int) throws -> SafariTab?
}

/// Google Chrome's tabs through Apple Events. Nothing from the page is read this way:
/// only each tab's address, title and position, which Chrome gives any scripter.
public struct ChromeTabAuthority: TabAuthority {
    public static let bundleID = "com.google.Chrome"
    private let script: NSAppleScript

    public init() {
        let source = """
            property sep : (ASCII character 9)
            property nl : (ASCII character 10)

            on bino_tabs()
                set out to ""
                tell application "Google Chrome"
                    set frontID to 0
                    set wi to 0
                    repeat with w in windows
                        set wi to wi + 1
                        try
                            set cur to active tab index of w
                            set wid to id of w
                            set hid to (minimized of w) as text
                            if frontID is 0 then set frontID to wid
                            set ti to 0
                            repeat with t in tabs of w
                                set ti to ti + 1
                                set u to URL of t
                                if u is missing value then set u to ""
                                set nm to title of t
                                if nm is missing value then set nm to ""
                                set out to out & wi & sep & ti & sep & (ti is cur) & sep & (wid is frontID) & sep & (id of t) & sep & hid & sep & u & sep & nm & nl
                            end repeat
                        end try
                    end repeat
                end tell
                return out
            end bino_tabs

            on bino_show(tabID)
                tell application "Google Chrome"
                    repeat with w in windows
                        set ti to 0
                        repeat with t in tabs of w
                            set ti to ti + 1
                            if ((id of t) as text) is tabID then
                                set active tab index of w to ti
                                if minimized of w then set minimized of w to false
                                set index of w to 1
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return "gone"
            end bino_show

            on bino_open(address)
                tell application "Google Chrome"
                    if (count of windows) is 0 then
                        set w to make new window
                        set URL of active tab of w to address
                        return (id of active tab of w) as text
                    end if
                    set w to front window
                    set t to make new tab at end of tabs of w with properties {URL:address}
                    return (id of t) as text
                end tell
            end bino_open

            on bino_tab(tabID)
                tell application "Google Chrome"
                    set wi to 0
                    repeat with w in windows
                        set wi to wi + 1
                        set ti to 0
                        repeat with t in tabs of w
                            set ti to ti + 1
                            if ((id of t) as text) is tabID then
                                set u to URL of t
                                if u is missing value then set u to ""
                                set nm to title of t
                                if nm is missing value then set nm to ""
                                return "" & wi & sep & ti & sep & ((active tab index of w) is ti) & sep & (wi is 1) & sep & (id of t) & sep & ((minimized of w) as text) & sep & u & sep & nm
                            end if
                        end repeat
                    end repeat
                end tell
                return ""
            end bino_tab

            on bino_js(code)
                tell application "Google Chrome"
                    if (count of windows) is 0 then error "NO_PAGE"
                    return (execute active tab of front window javascript code) as text
                end tell
            end bino_js
            """
        script = NSAppleScript(source: source)!
    }

    public static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func run(_ handler: String, _ arguments: [String]) throws -> String {
        guard Self.isRunning else { throw BrowserError.noPage(browser: "Chrome") }
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
            if message.contains("NO_PAGE") { throw BrowserError.noPage(browser: "Chrome") }
            if number == -1743 || message.localizedCaseInsensitiveContains("not authorized") {
                throw BrowserError.automationDenied(browser: "Chrome")
            }
            if message.localizedCaseInsensitiveContains("Apple Events") || number == -2700 && message.localizedCaseInsensitiveContains("javascript") {
                throw BrowserError.javascriptBlocked(browser: "Chrome")
            }
            throw BrowserError.script(message, browser: "Chrome")
        }
        return result.stringValue ?? ""
    }

    private func parse(_ line: Substring) -> SafariTab? {
        let parts = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 8, let window = Int(parts[0]), let index = Int(parts[1]) else { return nil }
        return SafariTab(window: window, index: index, isCurrent: parts[2] == "true", inFrontWindow: parts[3] == "true",
                         url: parts[6], title: parts[7], tabID: Int(parts[4]), hidden: parts[5] == "true")
    }

    public func tabs() throws -> [SafariTab] {
        try run("bino_tabs", []).split(separator: "\n").compactMap(parse)
    }

    public func show(_ tab: SafariTab) throws {
        guard let id = tab.tabID else { return }
        if try run("bino_show", [String(id)]) != "ok" { throw BrowserError.lostTab(browser: "Chrome") }
    }

    public func open(_ url: URL) throws -> SafariTab {
        let reply = try run("bino_open", [url.absoluteString])
        guard let id = Int(reply.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw BrowserError.badReply("tab") }
        return try tab(id: id) ?? SafariTab(window: 1, index: 0, url: url.absoluteString, tabID: id)
    }

    public func tab(id: Int) throws -> SafariTab? {
        let reply = try run("bino_tab", [String(id)])
        return reply.isEmpty ? nil : parse(Substring(reply))
    }

    /// Whether Chrome lets Bino run a script in a page (View > Developer > Allow JavaScript
    /// from Apple Events). Bino does not need it to sign in; `bino doctor` reports it.
    public func canRunJavaScript() throws -> Bool {
        do {
            return try run("bino_js", ["1+1"]) == "2"
        } catch BrowserError.javascriptBlocked {
            return false
        }
    }
}
#endif
