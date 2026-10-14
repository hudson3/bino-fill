import Foundation

public enum EntryStatus: String, Codable {
    case filled
    /// Filled, but worth a look.
    case check
    case left
    /// Bino tried and the page did not keep the value.
    case failed
    /// Dry run: would be filled.
    case wouldFill = "would-fill"
}

public struct EntryReport: Codable {
    public var field: String
    /// text, select, radio, checkbox, ...
    public var fieldType: String
    public var section: String
    public var concept: String
    /// Masked for anything sensitive.
    public var shown: String
    public var confidence: Double
    public var source: MappingSource
    public var status: EntryStatus
    public var leaveKind: LeaveKind?
    public var reason: String
    public var required: Bool
    /// The host of the embedded frame the box was found in; nil for the page itself.
    public var frame: String?

    public init(field: String, fieldType: String, section: String, concept: String, shown: String, confidence: Double,
                source: MappingSource, status: EntryStatus, leaveKind: LeaveKind?, reason: String, required: Bool,
                frame: String? = nil) {
        self.field = field; self.fieldType = fieldType; self.section = section; self.concept = concept
        self.shown = shown; self.confidence = confidence; self.source = source; self.status = status
        self.leaveKind = leaveKind; self.reason = reason; self.required = required
        self.frame = frame.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Belongs in the short "check these" list.
    public var needsAttention: Bool {
        switch status {
        case .check, .failed: return true
        case .filled, .wouldFill: return false
        case .left:
            switch leaveKind {
            case .unsure, .doesNotFit, .otherPerson, .safety, .newPassword: return true
            // An unanswered dropdown or radio group is a question; an unticked box is just a default.
            case .yourCall: return required || fieldType == "radio" || fieldType == "select"
            case .nothingSaved, .notPersonal: return required
            case .alreadyFilled, nil: return false
            }
        }
    }
}

public struct PageReport: Codable {
    public var number: Int
    public var address: String
    public var title: String
    public var entries: [EntryReport] = []
    /// Embedded boxes from other sites that Bino cannot reach (often card fields).
    public var unreachable: [String] = []
    public var pressed: String?
    public var seconds: Double = 0
    public var modelCalls: Int = 0
    /// Sign-in: how far the flow got on this page ("username", "password", "two_factor", ...).
    public var stage: String?
}

public enum StopReason: Codable, Equatable {
    case finalStep(button: String)
    case paymentPage
    case captcha
    case pageErrors([String])
    case needsYou([String])
    case noWayForward
    case pageDidNotChange(button: String)
    case pageLimit
    case onePageOnly
    case dryRun
    case failed(String)
    /// Sign-in: the saved login was typed and the sign-in button pressed.
    case signInPressed(button: String, formStillShowing: Bool)
    case noSignInForm
    case passwordWithheld(String)
    /// Sign-in: several accounts are saved for the site; `asked` is a name that is not one
    /// of them, or (`ambiguous`) one that fits more than one of `accounts`.
    case whichAccount(site: String, accounts: [String], asked: String?, ambiguous: Bool = false)
    /// Sign-in: the site now wants a code from a text, an app or an email. The box for it
    /// has the keyboard; Bino never types a code.
    case twoFactor(field: String)
    /// Sign-in: the site asks whether to trust or remember this browser. Your choice.
    case trustPrompt
    /// Sign-in: the page shows no sign-in form and looks like one past sign-in. `why` says how that was judged.
    case alreadySignedIn(why: String)
    /// Sign-in: the form sits in an embedded frame from `origin` that Bino could not read.
    case formInFrame(origin: String)
    /// Sign-up: the form is filled and the new password is in the vault. `button` is the
    /// one left for you to press, when Bino could tell which it is; `needs` are the boxes
    /// only you can answer first (agreeing to terms, for one).
    case signUpReady(button: String?, needs: [String])
    case noSignUpForm(String)

    /// Short fixed name for programs reading a report.
    public var code: String {
        switch self {
        case .finalStep: return "final_step"
        case .paymentPage: return "payment_page"
        case .captcha: return "captcha"
        case .pageErrors: return "page_errors"
        case .needsYou: return "needs_you"
        case .noWayForward: return "no_way_forward"
        case .pageDidNotChange: return "page_did_not_change"
        case .pageLimit: return "page_limit"
        case .onePageOnly: return "one_page_only"
        case .dryRun: return "dry_run"
        case .failed: return "failed"
        case .signInPressed: return "sign_in_pressed"
        case .noSignInForm: return "no_sign_in_form"
        case .passwordWithheld: return "password_withheld"
        case .whichAccount: return "which_account"
        case .twoFactor: return "two_factor"
        case .trustPrompt: return "trust_prompt"
        case .alreadySignedIn: return "already_signed_in"
        case .formInFrame: return "form_in_frame"
        case .signUpReady: return "sign_up_ready"
        case .noSignUpForm: return "no_sign_up_form"
        }
    }

    var isSignUpReady: Bool {
        if case .signUpReady = self { return true }
        return false
    }

    public var headline: String {
        switch self {
        case .finalStep(let button):
            return "Stopped at the final step. Check the page, then press \"\(button)\" yourself."
        case .paymentPage:
            return "Stopped on the payment page. Check it, then finish the payment yourself."
        case .captcha:
            return "Stopped: the page has a \"prove you're human\" check, which is yours to do."
        case .pageErrors(let errors):
            return "Stopped: the page reported a problem (\(errors.prefix(2).joined(separator: "; ")))."
        case .needsYou(let fields):
            return "Stopped: this page needs answers from you (\(fields.prefix(4).joined(separator: ", ")))."
        case .noWayForward:
            return "Stopped: no button on this page clearly means \"continue\", so none was pressed."
        case .pageDidNotChange(let button):
            return "Stopped: pressed \"\(button)\" but the page did not move on."
        case .pageLimit:
            return "Stopped after the maximum number of pages."
        case .onePageOnly:
            return "Filled this page only, as asked. Nothing was pressed."
        case .dryRun:
            return "Dry run: nothing was filled or pressed."
        case .failed(let why):
            return "Stopped because something went wrong: \(why)"
        case .signInPressed(let button, let formStillShowing):
            return formStillShowing
                ? "Typed the saved login and pressed \"\(button)\", but the page is still asking for a password. Check it."
                : "Typed the saved login and pressed \"\(button)\". Check the page to confirm you are signed in."
        case .noSignInForm:
            return "Stopped: found no sign-in form on this page, so nothing was typed."
        case .passwordWithheld(let why):
            return "Stopped without typing the password: \(why)."
        case .whichAccount(let site, let accounts, let asked, let ambiguous):
            let list = accounts.joined(separator: ", ")
            if let asked, ambiguous {
                return "\"\(asked)\" fits more than one account saved for \(site): \(list). Say more of the name, or its number (--account 1)."
            }
            if let asked {
                return "No account named \"\(asked)\" is saved for \(site). Saved: \(list). Say which with --account (a part of the name, or its number)."
            }
            return "Several accounts are saved for \(site): \(list). Say which with --account; nothing was typed."
        case .twoFactor(let field):
            return "Typed the saved login. The site now asks for a code (\"\(field)\"): the box has the keyboard, so type it there yourself."
        case .trustPrompt:
            return "Typed the saved login. The site asks whether to trust or remember this browser: that choice is yours."
        case .alreadySignedIn(let why):
            return "This page looks already signed in (\(why)), so nothing was typed."
        case .formInFrame(let origin):
            return "Stopped: the sign-in form is inside an embedded frame from \(origin) that Bino could not read, so nothing was typed."
        case .signUpReady(let button, let needs):
            let press = button.map { "press \"\($0)\" yourself" } ?? "finish it yourself"
            let first = needs.isEmpty ? "Check the page" : "Still yours to answer: \(needs.prefix(4).joined(separator: ", ")). Check the page"
            return "Filled the sign-up form and saved its new password in the vault. \(first), then \(press)."
        case .noSignUpForm(let why):
            return "Stopped: \(why), so nothing was typed and no password was made."
        }
    }
}

/// The login made for a new account.
public struct NewLoginReport: Codable, Equatable {
    public var site: String
    /// What was typed as the username or email. Shown in the report on this Mac only.
    public var username: String
    /// False when the run ended before the password was typed, so nothing was kept.
    public var saved: Bool
}

public struct RunReport: Codable {
    public var startedAt = Date()
    public var finishedAt = Date()
    public var site: String = ""
    /// "fill", "login" or "signup". Missing in reports saved before sign-in existed.
    public var command: String?
    /// Sign-up only.
    public var newLogin: NewLoginReport?
    public var dryRun = false
    public var pages: [PageReport] = []
    public var stop: StopReason = .noWayForward
    public var modelNote: String?

    public init() {}

    public var attention: [(page: Int, entry: EntryReport)] {
        pages.flatMap { page in page.entries.filter(\.needsAttention).map { (page.number, $0) } }
    }

    public var filledCount: Int {
        pages.reduce(0) { $0 + $1.entries.filter { $0.status == .filled || $0.status == .check }.count }
    }

    // MARK: Masking

    /// What a report may show of a value.
    public static func mask(_ value: String, concept: Concept?) -> String {
        switch concept?.sensitivity ?? .normal {
        case .normal: return value
        case .secret: return "•••• (hidden)"
        case .partial:
            let visible = concept == .cardNumber ? 4 : 2
            guard value.count > visible + 2 else { return "••••" }
            return "••••" + value.suffix(visible)
        }
    }

    /// Addresses can carry tokens in the query string; reports keep only host and path.
    public static func tidy(_ url: String) -> String {
        guard var parts = URLComponents(string: url) else { return url }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        let text = (parts.host ?? "") + (parts.port.map { ":\($0)" } ?? "") + parts.path
        return text.isEmpty ? url : text
    }

    // MARK: Text

    public func text(detail: Bool = true) -> String {
        var out: [String] = []
        let pageWord = pages.count == 1 ? "page" : "pages"
        out.append("Bino report: \(site), \(pages.count) \(pageWord)")
        out.append(stop.headline)
        if let modelNote { out.append("Note: \(modelNote)") }
        if let newLogin, newLogin.saved {
            let name = newLogin.username.isEmpty ? "no username yet" : "username \(newLogin.username)"
            out.append("New login saved in the vault for \(newLogin.site) (\(name)). The password is only in the vault.")
            if !stop.isSignUpReady {
                out.append("If you do not go on to create the account, remove that login on the Vault tab.")
            }
        }
        out.append("")

        let flagged = attention
        let frames = pages.flatMap { page in page.unreachable.map { (page.number, $0) } }
        if flagged.isEmpty && frames.isEmpty {
            out.append("Nothing needs checking.")
        } else {
            out.append("Check these (\(flagged.count + frames.count))")
            for (page, entry) in flagged {
                out.append("  p\(page)  \(Self.pad(entry.field, 34)) \(Self.describe(entry))")
            }
            for (page, frame) in frames {
                out.append("  p\(page)  \(Self.pad(frame, 34)) Bino cannot reach this embedded box; fill it yourself")
            }
        }
        out.append("")
        let verb = dryRun ? "Would fill" : "Filled"
        let count = dryRun
            ? pages.reduce(0) { $0 + $1.entries.filter { $0.status == .wouldFill }.count } : filledCount
        let seconds = pages.reduce(0) { $0 + $1.seconds }
        out.append("\(verb) \(count) fields in \(String(format: "%.1f", seconds)) s.")

        guard detail else { return out.joined(separator: "\n") }
        for page in pages {
            out.append("")
            out.append("Page \(page.number): \(page.title.isEmpty ? page.address : page.title) (\(page.address))")
            for entry in page.entries {
                let mark: String
                switch entry.status {
                case .filled: mark = "✓"
                case .check: mark = "!"
                case .failed: mark = "✗"
                case .wouldFill: mark = "→"
                case .left: mark = "·"
                }
                out.append("  \(mark) \(Self.pad(entry.field, 34)) \(Self.describe(entry))")
            }
            if let pressed = page.pressed { out.append("  pressed \"\(pressed)\"") }
            if let stage = page.stage { out.append("  stage: \(stage)") }
        }
        return out.joined(separator: "\n")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func describe(_ entry: EntryReport) -> String {
        let percent = "\(Int((entry.confidence * 100).rounded()))%"
        let frame = entry.frame.map { "  (in a frame from \($0))" } ?? ""
        switch entry.status {
        case .filled:
            return "\(entry.concept): \(entry.shown)  [\(entry.source.rawValue) \(percent)]" + frame
        case .check:
            return "\(entry.concept): \(entry.shown)  [\(entry.source.rawValue) \(percent)] \(entry.reason)" + frame
        case .wouldFill:
            return "\(entry.concept)  [\(entry.source.rawValue) \(percent)]\(entry.reason.isEmpty ? "" : " " + entry.reason)" + frame
        case .failed:
            return "\(entry.concept): could not fill, \(entry.reason)" + frame
        case .left:
            return "left: \(entry.reason)" + frame
        }
    }

    // MARK: Saving

    /// Saves the text and JSON forms and returns where the text went.
    @discardableResult
    public func save() throws -> URL {
        try FileManager.default.createDirectory(at: BinoPaths.reportsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = BinoPaths.reportsDir.appendingPathComponent(formatter.string(from: startedAt))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try BinoPaths.writePrivate(try encoder.encode(self), to: base.appendingPathExtension("json"))
        let textURL = base.appendingPathExtension("txt")
        try BinoPaths.writePrivate(Data(text().utf8), to: textURL)
        return textURL
    }

    /// The most recent saved report, read back from its JSON form.
    public static func loadLatest() -> RunReport? {
        guard let json = latest()?.deletingPathExtension().appendingPathExtension("json"),
              let data = try? Data(contentsOf: json)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunReport.self, from: data)
    }

    public static func latest() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: BinoPaths.reportsDir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.max { $0.lastPathComponent < $1.lastPathComponent }
    }
}
