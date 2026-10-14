import Foundation

/// What another program (an AI agent) is told about a run.
///
/// The same facts as the saved report with every typed value left out: the agent learns
/// which kind of information went into which field and how sure Bino was, never the
/// information itself. Field names, button wording and error text are the page's own.
public struct AgentReport: Encodable {
    public struct Stop: Encodable {
        public var reason: String
        public var message: String
        public var button: String?
        public var fields: [String]?
        public var errors: [String]?
        public var signInFormStillShowing: Bool?
        /// The names of the accounts saved for the site, when one has to be chosen.
        public var accounts: [String]?
        /// form_in_frame: the host of the frame the form is in.
        public var origin: String?
        /// Sign-in: how the stop was judged (already_signed_in), in words.
        public var how: String?
    }

    public struct Field: Encodable {
        public var field: String
        public var type: String
        public var section: String
        public var kind: String
        public var status: String
        public var confidence: Double
        public var decidedBy: String
        public var required: Bool
        public var why: String
        /// The host of the embedded frame the box is in; absent for the page itself.
        public var frame: String?
    }

    public struct Page: Encodable {
        public var number: Int
        public var address: String
        public var title: String
        public var pressed: String?
        public var fields: [Field]
        /// Embedded boxes from other sites that Bino cannot reach.
        public var unreachable: [String]
        /// Sign-in: how far the flow got on this page ("username", "password", "two_factor", ...).
        public var stage: String?
    }

    public struct NewLogin: Encodable {
        public var site: String
        public var saved: Bool
    }

    public struct Check: Encodable {
        public var page: Int
        public var field: String
        public var status: String
        public var why: String
    }

    public var ok: Bool
    public var command: String
    public var site: String
    public var dryRun: Bool
    public var stopped: Stop
    /// Fields Bino typed into or chose (on a dry run, the ones it would).
    public var filled: Int
    /// The short list a person should look over before going on.
    public var check: [Check]
    public var pages: [Page]
    public var note: String?
    /// Sign-up only: the site the new login was saved for, and whether it was saved.
    /// Never the username or the password.
    public var newLogin: NewLogin?
    public var startedAt: Date
    public var finishedAt: Date
    /// The full report on this Mac, values included, for the person to read.
    public var reportFile: String?

    public init(_ report: RunReport, reportFile: String? = nil) {
        if case .failed = report.stop { ok = false } else { ok = true }
        command = report.command ?? "fill"
        site = report.site
        dryRun = report.dryRun
        stopped = Stop(reason: report.stop.code, message: report.stop.headline)
        switch report.stop {
        case .finalStep(let button), .pageDidNotChange(let button): stopped.button = button
        case .signUpReady(let button, let needs):
            stopped.button = button
            if !needs.isEmpty { stopped.fields = needs }
        case .signInPressed(let button, let formStillShowing):
            stopped.button = button
            stopped.signInFormStillShowing = formStillShowing
        case .needsYou(let fields): stopped.fields = fields
        case .twoFactor(let field): stopped.fields = [field]
        case .whichAccount(_, let accounts, _, _): stopped.accounts = accounts
        case .pageErrors(let errors): stopped.errors = errors
        case .formInFrame(let origin): stopped.origin = origin
        case .alreadySignedIn(let why): stopped.how = why
        default: break
        }
        filled = report.dryRun
            ? report.pages.reduce(0) { $0 + $1.entries.filter { $0.status == .wouldFill }.count } : report.filledCount
        check = report.attention.map { page, entry in
            Check(page: page, field: entry.field, status: entry.status.rawValue, why: entry.reason)
        } + report.pages.flatMap { page in
            page.unreachable.map {
                Check(page: page.number, field: $0, status: "unreachable", why: "Bino cannot reach this embedded box")
            }
        }
        pages = report.pages.map { page in
            Page(number: page.number, address: page.address, title: page.title, pressed: page.pressed,
                 fields: page.entries.map { entry in
                     Field(field: entry.field, type: entry.fieldType, section: entry.section, kind: entry.concept,
                           status: entry.status.rawValue, confidence: (entry.confidence * 100).rounded() / 100,
                           decidedBy: entry.source.rawValue, required: entry.required, why: entry.reason, frame: entry.frame)
                 },
                 unreachable: page.unreachable, stage: page.stage)
        }
        note = report.modelNote
        newLogin = report.newLogin.map { NewLogin(site: $0.site, saved: $0.saved) }
        startedAt = report.startedAt
        finishedAt = report.finishedAt
        self.reportFile = reportFile
    }
}

/// A command that could not run at all.
public struct AgentFailure: Encodable {
    public var ok = false
    public var command: String
    public var error: String

    public init(command: String, error: String) {
        self.command = command
        self.error = error
    }
}

public enum AgentJSON {
    /// One JSON object with snake_case keys.
    public static func text(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return #"{"ok": false, "error": "could not encode the result"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
