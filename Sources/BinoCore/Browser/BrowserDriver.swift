import Foundation

public enum BrowserError: Error, CustomStringConvertible {
    /// The browser named has no page open.
    case noPage(browser: String = "Safari")
    case javascriptBlocked(browser: String = "Safari")
    case automationDenied(browser: String = "Safari")
    case script(String, browser: String = "Safari")
    case badReply(String)
    /// No tab matches the `--tab` text; `hint` is the command that lists the tabs.
    case noSuchTab(String, browser: String = "Safari", hint: String = "bino tabs")
    case ambiguousTab(String, [String], browser: String = "Safari")
    case lostTab(browser: String = "Safari")
    /// A problem in another browser's own words.
    case other(String)

    public var description: String {
        switch self {
        case .noPage(let browser):
            return "\(browser) has no open page. Open the form in \(browser) and try again."
        case .javascriptBlocked(let browser):
            if browser == "Chrome" {
                return """
                    Chrome is not allowing scripts from Bino. In Chrome: View > Developer > tick \
                    "Allow JavaScript from Apple Events".
                    """
            }
            return """
                Safari is not yet allowing Bino to read pages. In Safari: Settings > Advanced > tick \
                "Show features for web developers", then Settings > Developer > tick \
                "Allow JavaScript from Apple Events".
                """
        case .automationDenied(let browser):
            return """
                macOS blocked Bino from controlling \(browser). Open System Settings > Privacy & Security > \
                Automation and switch on \(browser) for the app you run bino from (Terminal, for example).
                """
        case .noSuchTab(let wanted, let browser, let hint):
            return "No \(browser) tab matches \"\(wanted)\". Run `\(hint)` to see the open tabs."
        case .ambiguousTab(let wanted, let tabs, let browser):
            return "More than one \(browser) tab matches \"\(wanted)\". Say more of the address, or use one of these with --tab: "
                + tabs.joined(separator: "; ")
        case .lostTab(let browser):
            return "The \(browser) tab Bino was working in was closed or moved, so it stopped."
        case .script(let message, let browser): return "\(browser) reported: \(message)"
        case .badReply(let what): return "The page returned something unexpected (\(what))."
        case .other(let message): return message
        }
    }
}

/// What a page did with a request to fill, pick or click.
public struct ActionResult: Codable {
    public var ok: Bool
    public var why: String

    public init(ok: Bool, why: String = "") {
        self.ok = ok; self.why = why
    }
}

/// The few things Bino needs from a browser tab. Safari and the test web view answer
/// through JavaScript (`ScriptedBrowserDriver`); the Claude desktop app's browser pane
/// answers through the accessibility tree (`AccessibilityDriver`).
public protocol BrowserDriver {
    @MainActor func currentURL() async throws -> String
    /// Goes to an address and returns once that page has started to load.
    @MainActor func open(_ url: URL) async throws
    @MainActor func scan() async throws -> PageScan
    /// Changes when the page does: what to compare before and after pressing a button.
    @MainActor func signature() async throws -> String
    /// "complete" once the page has loaded.
    @MainActor func readyState() async throws -> String
    @MainActor func title() async throws -> String
    /// Visible plain links whose wording matches `pattern` (a JavaScript regular expression).
    @MainActor func links(matching pattern: String) async throws -> [PageLink]
    @MainActor func fill(fieldID: String, value: String) async throws -> ActionResult
    @MainActor func pick(fieldID: String, optionID: String) async throws -> ActionResult
    @MainActor func click(buttonID: String) async throws -> ActionResult
    /// Puts the keyboard in a box and types nothing: for a code only the person can enter.
    @MainActor func focus(fieldID: String) async throws -> ActionResult
}

/// A browser Bino can run JavaScript in. Everything else is done through the page script.
public protocol ScriptedBrowserDriver: BrowserDriver {
    /// Runs JavaScript in the front page and returns its string result.
    @MainActor func evaluate(_ javascript: String) async throws -> String
}

extension ScriptedBrowserDriver {
    @MainActor func call(_ expression: String) async throws -> String {
        // The page may have navigated since the last call, so make sure the helper is there.
        let installed = try await evaluate("typeof window.__bino === 'object' && window.__bino.v === 7 ? 'y' : 'n'")
        if installed != "y" {
            _ = try await evaluate(PageScript.install)
        }
        return try await evaluate(expression)
    }

    @MainActor public func scan() async throws -> PageScan {
        let json = try await call("window.__bino.scan()")
        guard let data = json.data(using: .utf8),
              let scan = try? JSONDecoder().decode(PageScan.self, from: data)
        else { throw BrowserError.badReply("scan") }
        return scan
    }

    @MainActor public func signature() async throws -> String {
        try await call("window.__bino.signature()")
    }

    @MainActor public func readyState() async throws -> String {
        try await evaluate("document.readyState")
    }

    @MainActor public func title() async throws -> String {
        try await evaluate("document.title")
    }

    @MainActor public func links(matching pattern: String) async throws -> [PageLink] {
        let json = try await call("window.__bino.links(\(PageScript.quote(pattern)))")
        guard let data = json.data(using: .utf8),
              let links = try? JSONDecoder().decode([PageLink].self, from: data)
        else { throw BrowserError.badReply("links") }
        return links
    }

    @MainActor func action(_ expression: String) async throws -> ActionResult {
        let json = try await call(expression)
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(ActionResult.self, from: data)
        else { throw BrowserError.badReply("action") }
        return result
    }

    @MainActor public func fill(fieldID: String, value: String) async throws -> ActionResult {
        try await action("window.__bino.fill(\(PageScript.quote(fieldID)), \(PageScript.quote(value)))")
    }

    @MainActor public func pick(fieldID: String, optionID: String) async throws -> ActionResult {
        try await action("window.__bino.pick(\(PageScript.quote(fieldID)), \(PageScript.quote(optionID)))")
    }

    @MainActor public func click(buttonID: String) async throws -> ActionResult {
        try await action("window.__bino.click(\(PageScript.quote(buttonID)))")
    }

    @MainActor public func focus(fieldID: String) async throws -> ActionResult {
        try await action("window.__bino.focus(\(PageScript.quote(fieldID)))")
    }
}
