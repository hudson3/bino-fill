#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// One element of an app's accessibility tree, as Bino reads it. The real one wraps an
/// AXUIElement; tests build a fake tree.
public protocol AXNode: AnyObject {
    var role: String { get }
    var subrole: String { get }
    var roleDescription: String { get }
    var title: String { get }
    /// AXDescription: where Chromium puts a control's label when it has no title.
    var detail: String { get }
    var placeholder: String { get }
    var value: String { get }
    var url: String { get }
    /// The element's id in the page, when Chromium passes it on.
    var domID: String { get }
    var enabled: Bool { get }
    var required: Bool { get }
    /// For a web area: whether its page has finished loading.
    var loaded: Bool { get }
    var y: Int { get }
    var children: [AXNode] { get }
    var isAlive: Bool { get }
    /// Whether the keyboard is in this box right now.
    var isFocused: Bool { get }
    func setValue(_ text: String) -> Bool
    func press() -> Bool
    func focus() -> Bool
}

/// Where the windows come from: a running app, or a fake tree in tests.
public protocol AXSource {
    /// "Claude's browser pane", for messages.
    var name: String { get }
    func windows() throws -> [AXNode]
    /// The app to the front, so keystrokes reach it.
    func activate()
    /// Types into whatever has the keyboard, after `activate()`.
    func typeKeys(_ text: String)
    /// Selects everything in the focused box.
    func selectAll()
    /// Asks the app to show a page in a new tab. False when the app takes no such request.
    func open(_ url: URL) -> Bool
}

/// A real element.
final class AXElement: AXNode {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    private func attribute(_ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ name: String) -> String {
        guard let raw = attribute(name) else { return "" }
        if let text = raw as? String { return text }
        if let url = raw as? URL { return url.absoluteString }
        if let number = raw as? NSNumber { return number.stringValue }
        return ""
    }

    var role: String { string(kAXRoleAttribute) }
    var subrole: String { string(kAXSubroleAttribute) }
    var roleDescription: String { string(kAXRoleDescriptionAttribute) }
    var title: String { string(kAXTitleAttribute) }
    var detail: String { string(kAXDescriptionAttribute) }
    var placeholder: String { string(kAXPlaceholderValueAttribute) }
    var value: String { string(kAXValueAttribute) }
    var url: String { string(kAXURLAttribute) }
    var domID: String { string("AXDOMIdentifier") }
    var enabled: Bool { (attribute(kAXEnabledAttribute) as? Bool) ?? true }
    var required: Bool { (attribute("AXRequired") as? Bool) ?? false }
    var loaded: Bool { (attribute("AXLoaded") as? Bool) ?? true }

    var y: Int {
        guard let raw = attribute(kAXPositionAttribute), CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() else { return 0 }
        var point = CGPoint.zero
        AXValueGetValue(raw as! AXValue, .cgPoint, &point)
        return Int(point.y)
    }

    var children: [AXNode] {
        ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { AXElement($0) }
    }

    var isAlive: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    var isFocused: Bool { (attribute(kAXFocusedAttribute) as? Bool) ?? false }

    func setValue(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    func press() -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }

    func focus() -> Bool { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success }
}

/// A running app, by bundle id.
public struct AppSource: AXSource {
    public let bundleID: String
    public let name: String
    /// The word after `--browser` that means this app, for hints in messages.
    public let flag: String
    /// Whether the app opens addresses handed to it (a browser does; Claude's pane does not).
    public let opensPages: Bool

    public init(bundleID: String, name: String, flag: String, opensPages: Bool = false) {
        self.bundleID = bundleID; self.name = name; self.flag = flag; self.opensPages = opensPages
    }

    private var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    public var isRunning: Bool { app != nil }

    public func windows() throws -> [AXNode] {
        guard AXIsProcessTrusted() else {
            throw BrowserError.other("""
                macOS has not allowed Bino to read other apps' windows. Open System Settings > Privacy & \
                Security > Accessibility and switch on the app you run bino from.
                """)
        }
        guard let app else { throw BrowserError.other("\(name) is not open.") }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium only builds its accessibility tree for a client that asks for it: Electron
        // listens for the first attribute, Chrome for the second.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows.map { AXElement($0) }
    }

    public func activate() {
        app?.activate(options: [])
        usleep(150_000)
    }

    public func typeKeys(_ text: String) {
        for scalar in text.unicodeScalars {
            var units = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            // A modifier left over from Cmd+A would turn letters into shortcuts (Cmd+W closes a tab).
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    public func open(_ url: URL) -> Bool {
        guard opensPages, let appURL = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        return true
    }

    public func selectAll() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

/// Drives a page inside another app through the macOS accessibility tree: the Claude
/// desktop app's browser pane, or Google Chrome, both Chromium web content with no
/// scripting from outside. Each page is a web area under the app's window; Bino reads
/// its fields and buttons from there (frames from other sites included: Chromium puts
/// them in the same tree), sets values on them and presses them.
///
/// The tree shows only the tab each window is showing, and only windows on this
/// desktop. A browser that can be asked for more (`TabAuthority`: Chrome, through
/// Apple Events) lists every tab that way, and brings the chosen one on screen before
/// the tree is read.
public final class AccessibilityDriver: BrowserDriver, TabbedBrowserDriver {
    public static let claude = AppSource(bundleID: "com.anthropic.claudefordesktop", name: "Claude's browser pane", flag: "claude")
    public static let chrome = AppSource(bundleID: "com.google.Chrome", name: "Chrome", flag: "chrome", opensPages: true)

    private let source: AXSource
    private let authority: TabAuthority?
    private let wanted: String?
    private var pinned: AXNode?
    private var pinnedID = ""
    /// The authority's number for the pinned tab, to find its page again after it navigates.
    private var pinnedTabID: Int?
    /// Fields, buttons and links from the last look at the page, by the ids Bino gave them.
    private var nodes: [String: AXNode] = [:]
    private var counter = 0

    public var browserName: String { source.name }
    /// "bino tabs --browser chrome": how to list this browser's tabs.
    private var listHint: String { "bino tabs --browser \((source as? AppSource)?.flag ?? "claude")" }

    /// `tab`: which page to work in (see `SafariTab.choose`). nil means the first page
    /// showing (or, with an authority, the front tab).
    public init(source: AXSource = AccessibilityDriver.claude, tabs authority: TabAuthority? = nil, tab: String? = nil) {
        self.source = source
        self.authority = authority
        self.wanted = tab
    }

    /// Web areas that are pages, not the app's own interface: on http(s), and not Claude's own site.
    public static func isPage(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let host = SitePolicy.host(of: url) else { return false }
        return host != "claude.ai" && !host.hasSuffix(".claude.ai")
    }

    private func webAreas() throws -> [(window: Int, node: AXNode)] {
        var out: [(Int, AXNode)] = []
        func walk(_ node: AXNode, window: Int, depth: Int) {
            guard depth < 40 else { return }
            if node.role == "AXWebArea" {
                if Self.isPage(node.url) { out.append((window, node)) }
                return
            }
            for child in node.children { walk(child, window: window, depth: depth + 1) }
        }
        for (index, window) in try source.windows().enumerated() { walk(window, window: index, depth: 0) }
        return out
    }

    /// Whether a web area on screen is the tab's page: the same address, or at least the
    /// same site (the tab may have moved on since it was listed).
    private static func area(_ areaURL: String, shows tabURL: String) -> Bool {
        if RunReport.tidy(areaURL) == RunReport.tidy(tabURL) { return true }
        guard let a = SitePolicy.host(of: areaURL), let b = SitePolicy.host(of: tabURL) else { return false }
        return SitePolicy.normalizeSite(a) == SitePolicy.normalizeSite(b)
    }

    @MainActor public func tabs() throws -> [SafariTab] {
        if let authority { return try authority.tabs() }
        var tabs: [SafariTab] = []
        // Chromium builds its tree the first time it is asked; give it a moment.
        for attempt in 0..<4 {
            let areas = try webAreas()
            if !areas.isEmpty || attempt == 3 {
                tabs = areas.enumerated().map { order, area in
                    SafariTab(window: area.window + 1, index: order + 1, isCurrent: true, inFrontWindow: area.window == 0,
                              url: area.node.url, title: area.node.title)
                }
                break
            }
            usleep(400_000)
        }
        return tabs
    }

    private func choose(_ text: String, from all: [SafariTab]) throws -> SafariTab {
        do {
            return try SafariTab.choose(text, from: all)
        } catch BrowserError.noPage {
            throw BrowserError.other("\(source.name) is not showing a page. Open the page there first, then try again.")
        } catch BrowserError.noSuchTab(let text, _, _) {
            throw BrowserError.other("No page in \(source.name) matches \"\(text)\". Run `\(listHint)` to see what is open there.")
        } catch BrowserError.ambiguousTab(let text, let which, _) {
            throw BrowserError.other("More than one page in \(source.name) matches \"\(text)\". Say more of the address, or use one of these with --tab: "
                + which.joined(separator: "; "))
        }
    }

    /// Waits for the tab's page to appear in the tree: a moment for Chromium to build it,
    /// and if the window is on another desktop, brings the app forward so it is on this one.
    private func pin(tabID: Int, within seconds: Double) throws -> Bool {
        guard let authority else { return false }
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)
        var activated = false
        while true {
            guard let tab = try authority.tab(id: tabID) else { throw BrowserError.lostTab(browser: source.name) }
            if Self.isPage(tab.url) {
                let areas = try webAreas()
                if let at = areas.firstIndex(where: { Self.area($0.node.url, shows: tab.url) }) {
                    pinned = areas[at].node
                    pinnedID = tab.id
                    pinnedTabID = tabID
                    return true
                }
            }
            guard Date() < deadline else { return false }
            if !activated, Date().timeIntervalSince(started) > 1.5 {
                // Still not on screen: a minimized window or another desktop. Bring the app forward.
                source.activate()
                activated = true
            }
            usleep(300_000)
        }
    }

    @MainActor @discardableResult public func settleTab() throws -> String {
        if let authority, let pinnedTabID {
            // The page may have moved on (a sign-in that goes to the next page): the same
            // tab, a new web area. The old one can linger in the tree for a moment with
            // the old page still in it, so the browser's own address for the tab decides.
            guard let tab = try authority.tab(id: pinnedTabID) else { throw BrowserError.lostTab(browser: source.name) }
            if let pinned, pinned.isAlive, Self.isPage(pinned.url), RunReport.tidy(pinned.url) == RunReport.tidy(tab.url) { return pinnedID }
            let areas = try webAreas()
            if let at = areas.firstIndex(where: { RunReport.tidy($0.node.url) == RunReport.tidy(tab.url) })
                ?? areas.firstIndex(where: { Self.area($0.node.url, shows: tab.url) }) {
                pinned = areas[at].node
                return pinnedID
            }
            // Mid-navigation, with the new page not in the tree yet: the old one will do until it is.
            if let pinned, pinned.isAlive, Self.isPage(pinned.url) { return pinnedID }
            throw BrowserError.lostTab(browser: source.name)
        }
        if let pinned, pinned.isAlive, Self.isPage(pinned.url) { return pinnedID }
        if let authority {
            let all = try authority.tabs()
            guard !all.isEmpty else { throw BrowserError.other("\(source.name) has no open tabs. Open the page there first, then try again.") }
            let chosen = try choose(wanted ?? "", from: all)
            guard let tabID = chosen.tabID else { throw BrowserError.badReply("tab") }
            try authority.show(chosen)
            guard try pin(tabID: tabID, within: 5) else {
                throw BrowserError.other("\(source.name) did not show \(RunReport.tidy(chosen.url)) on screen. Bring that window to the front and try again.")
            }
            return pinnedID
        }
        let all = try tabs()
        let chosen = try choose(wanted ?? "", from: all)
        let areas = try webAreas()
        guard chosen.index - 1 < areas.count else { throw BrowserError.lostTab(browser: source.name) }
        pinned = areas[chosen.index - 1].node
        pinnedID = chosen.id
        return pinnedID
    }

    @MainActor private func area() throws -> AXNode {
        try settleTab()
        guard let pinned else { throw BrowserError.lostTab(browser: source.name) }
        return pinned
    }

    @MainActor public func currentURL() async throws -> String { try area().url }
    @MainActor public func title() async throws -> String { try area().title }

    /// "complete" once the page and every frame in it have loaded.
    @MainActor public func readyState() async throws -> String {
        let area = try area()
        guard area.loaded else { return "loading" }
        var loading = false
        var seen = 0
        func walk(_ node: AXNode, depth: Int) {
            seen += 1
            guard !loading, depth < 60, seen < 15000 else { return }
            if depth > 0, node.role == "AXWebArea", !node.loaded { loading = true; return }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(area, depth: 0)
        return loading ? "loading" : "complete"
    }

    /// Opens the address in a new tab of the app and works in that tab from then on. Claude's
    /// pane takes no such request, so there the page has to be showing already.
    @MainActor public func open(_ url: URL) async throws {
        let wanted = RunReport.tidy(url.absoluteString)
        if let authority {
            let tab = try authority.open(url)
            guard let tabID = tab.tabID else { throw BrowserError.badReply("tab") }
            guard try pin(tabID: tabID, within: 20) else {
                throw BrowserError.other("\(source.name) did not show \(wanted) in time.")
            }
            return
        }
        guard source.open(url) else {
            throw BrowserError.other("Bino cannot open pages in \(source.name). Open \(wanted) there first, then run the command again with --tab.")
        }
        // The page may redirect (apple.com to www.apple.com): any page on the site counts.
        let family = SitePolicy.accountSite(forPage: url.absoluteString)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let areas = try webAreas()
            if let at = areas.firstIndex(where: { area in
                let here = RunReport.tidy(area.node.url)
                if here == wanted || here.hasPrefix(wanted) { return true }
                return family.map { SitePolicy.page(area.node.url, matchesSite: $0) } ?? false
            }) {
                pinned = areas[at].node
                pinnedID = "\(areas[at].window + 1).\(at + 1)"
                return
            }
        }
        throw BrowserError.other("\(source.name) did not show \(wanted) in time.")
    }

    private func nextID(_ prefix: String, _ node: AXNode) -> String {
        counter += 1
        let id = "\(prefix)\(counter)"
        nodes[id] = node
        return id
    }

    private static func name(_ node: AXNode) -> String {
        for candidate in [node.title, node.detail] where !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        return ""
    }

    private static func text(under node: AXNode, depth: Int = 0) -> String {
        var parts: [String] = []
        if node.role == "AXStaticText" || depth > 0 && !node.value.isEmpty && node.children.isEmpty { parts.append(node.value) }
        else if !node.title.isEmpty, node.children.isEmpty { parts.append(node.title) }
        if depth < 12 { for child in node.children { parts.append(Self.text(under: child, depth: depth + 1)) } }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    @MainActor public func scan() async throws -> PageScan {
        let area = try area()
        nodes = [:]
        counter = 0
        var fields: [PageField] = []
        var buttons: [PageButton] = []
        var frames: [PageFrame] = []
        var errors: [String] = []
        var headings: [String] = []
        var captcha = false
        var seen = 0
        var frameCount = 0
        /// The heading last passed: what the page calls the part of the form a box sits in.
        var section = ""
        let topHost = SitePolicy.host(of: area.url) ?? ""

        /// `frame`/`origin`: the embedded page the node sits in (0 and "" for the page itself).
        func walk(_ node: AXNode, depth: Int, frame: Int, origin: String) {
            seen += 1
            guard depth < 60, seen < 15000 else { return }
            var frame = frame
            var origin = origin
            let role = node.role
            let name = Self.name(node)
            if depth > 0, role == "AXWebArea" {
                // An embedded page. One from another site is a frame worth naming: its boxes
                // are listed with that site as their origin, and if it has nothing to show
                // yet, the frame itself is reported so the wait and the report can say why.
                frameCount += 1
                frame = frameCount
                let host = SitePolicy.host(of: node.url) ?? ""
                if !host.isEmpty, host != topHost { origin = host }
                let children = node.children
                if !origin.isEmpty, children.isEmpty || !node.loaded {
                    frames.append(PageFrame(host: origin, title: node.title, payment: false, section: section, loading: !node.loaded))
                }
                for child in children { walk(child, depth: depth + 1, frame: frame, origin: origin) }
                return
            }
            if role == "AXHeading" {
                let heading = name.isEmpty ? Self.text(under: node) : name
                if !heading.isEmpty {
                    section = String(heading.prefix(120))
                    if headings.count < 40 { headings.append(section) }
                }
            }
            let everything = (name + " " + node.placeholder + " " + node.domID + " " + node.url).lowercased()
            if everything.contains("captcha") { captcha = true }
            if node.subrole == "AXApplicationAlert" || node.roleDescription.lowercased() == "alert" {
                let said = Self.text(under: node).trimmingCharacters(in: .whitespacesAndNewlines)
                if !said.isEmpty { errors.append(said) }
            }
            switch role {
            case "AXTextField", "AXSecureTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox":
                let type: String
                // Chromium's password box is a text field with the secure subrole.
                switch role == "AXTextField" && node.subrole == "AXSecureTextField" ? "AXSecureTextField" : role {
                case "AXSecureTextField": type = "password"
                case "AXTextArea": type = "textarea"
                case "AXCheckBox": type = "checkbox"
                case "AXRadioButton": type = "radio"
                case "AXPopUpButton", "AXComboBox": type = "select"
                default: type = node.subrole == "AXSearchField" ? "search" : "text"
                }
                let value = node.value
                let hasValue = type == "checkbox" || type == "radio" ? value == "1" : !value.isEmpty
                fields.append(PageField(
                    id: nextID("ax", node), tag: type == "textarea" ? "textarea" : type == "select" ? "select" : "input",
                    type: type, name: "", domId: node.domID, placeholder: node.placeholder, label: name, section: section,
                    required: node.required, hasValue: hasValue, current: type == "select" ? value : "",
                    frame: frame, readOnly: !node.enabled, origin: origin))
            case "AXButton":
                let text = name.isEmpty ? node.value : name
                buttons.append(PageButton(id: nextID("ax", node), tag: "button", type: "", text: text,
                                          disabled: !node.enabled, inForm: true, primary: false, y: node.y, frame: frame, origin: origin))
            default:
                break
            }
            for child in node.children { walk(child, depth: depth + 1, frame: frame, origin: origin) }
        }
        walk(area, depth: 0, frame: 0, origin: "")

        let signature = Self.signature(url: area.url, title: area.title, fields: fields, buttons: buttons)
        return PageScan(url: area.url, title: area.title, fields: fields, buttons: buttons, frames: frames, errors: errors,
                        captcha: captcha, signature: signature, headings: headings)
    }

    static func signature(url: String, title: String, fields: [PageField], buttons: [PageButton]) -> String {
        let parts = [url, title] + fields.map { "\($0.type):\($0.label):\($0.placeholder):\($0.hasValue)" } + buttons.map { "b:\($0.text):\($0.disabled)" }
        return String(parts.joined(separator: "|").hashValue)
    }

    @MainActor public func signature() async throws -> String {
        try await scan().signature
    }

    @MainActor public func links(matching pattern: String) async throws -> [PageLink] {
        let area = try area()
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var out: [PageLink] = []
        func walk(_ node: AXNode, depth: Int) {
            guard depth < 60, out.count < 50 else { return }
            if node.role == "AXLink" {
                let text = Self.name(node).isEmpty ? Self.text(under: node) : Self.name(node)
                if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    out.append(PageLink(id: nextID("lk", node), text: text))
                }
            }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(area, depth: 0)
        return out
    }

    // Chromium applies a value or a focus change in its page process a moment later.
    @MainActor private func soon(_ check: @MainActor () -> Bool, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if check() { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor public func fill(fieldID: String, value: String) async throws -> ActionResult {
        guard let node = nodes[fieldID], node.isAlive else { return ActionResult(ok: false, why: "the box is no longer on the page") }
        let secure = node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
        func kept() -> Bool {
            let now = node.value
            // A password box reads back as bullets, one per character.
            return now == value || (secure && !now.isEmpty && now.count == value.count)
        }
        if node.setValue(value), await soon(kept, within: 1.5) { return ActionResult(ok: true, why: "set") }
        // The page ignored the value: type it the way a person would, but only into this very
        // box. Keystrokes that landed anywhere else would be shortcuts or stray text.
        source.activate()
        guard node.focus(), await soon({ node.isFocused }, within: 1) else {
            return ActionResult(ok: false, why: "the page did not take the value, and the box would not take the keyboard")
        }
        source.selectAll()
        guard node.isFocused else { return ActionResult(ok: false, why: "the keyboard left the box before typing") }
        source.typeKeys(value)
        return await soon(kept, within: 1.5) ? ActionResult(ok: true, why: "typed") : ActionResult(ok: false, why: "the page did not keep what was typed")
    }

    @MainActor public func pick(fieldID: String, optionID: String) async throws -> ActionResult {
        ActionResult(ok: false, why: "choosing from a list in \(source.name) is not supported yet")
    }

    @MainActor public func click(buttonID: String) async throws -> ActionResult {
        guard let node = nodes[buttonID], node.isAlive else { return ActionResult(ok: false, why: "the button is no longer on the page") }
        return node.press() ? ActionResult(ok: true, why: "pressed") : ActionResult(ok: false, why: "the button did not take the press")
    }

    /// Puts the keyboard in the box without bringing the app forward or typing anything.
    @MainActor public func focus(fieldID: String) async throws -> ActionResult {
        guard let node = nodes[fieldID], node.isAlive else { return ActionResult(ok: false, why: "the box is no longer on the page") }
        guard node.focus(), await soon({ node.isFocused }, within: 1) else {
            return ActionResult(ok: false, why: "the box did not take the keyboard")
        }
        return ActionResult(ok: true, why: "focused")
    }
}
#endif
