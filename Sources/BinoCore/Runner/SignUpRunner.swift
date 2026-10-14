import Foundation

/// What a sign-up needs besides the vault.
public struct SignUpRequest {
    /// The site the new login is saved for. The new password is typed only on its pages.
    public var site: String
    /// For a "username" box. With none given, one is made from your email address.
    public var username: String?
    public var passwordLength = PasswordMaker.defaultLength
    public var symbols = true
    /// Puts the new login in the vault, or updates the copy put there earlier in the run.
    /// Called before the password is typed anywhere, so a typed password is never unsaved.
    public var save: (Login) throws -> Void
    /// Takes it out again when the password never reached the page.
    public var forget: (Login) -> Void

    public init(site: String, save: @escaping (Login) throws -> Void, forget: @escaping (Login) -> Void) {
        self.site = site
        self.save = save
        self.forget = forget
    }
}

/// How far one sign-up has got.
final class SignUpState {
    let request: SignUpRequest
    var password: String?
    /// The login as it is in the vault now.
    var login: Login?
    var typedPassword = false
    var passwordFailed = false
    var username = ""
    var email = ""
    var followedLink = false
    /// A sign-up form has been started (an email typed on a page before the password's).
    var started = false

    init(_ request: SignUpRequest) {
        self.request = request
    }
}

enum SignUpGate {
    /// This page is part of a sign-up form: fill it.
    case fill
    /// Not the form, but a "Sign up" link was there and has been pressed.
    case followed(String)
    case stop(StopReason)
}

/// Making a new account: fill the sign-up form from the vault, make a strong password,
/// save it in the vault, type it, and stop. The button that creates the account is never
/// pressed.
///
/// The password is typed only on the site it is saved for, only over https, and only
/// into boxes on a page that reads as a sign-up form. A page that looks like sign-in is
/// left alone.
extension FormRunner {
    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// For finding a link by its wording; a JavaScript regular expression.
    static let signUpLinkWording = #"sign.?up|register|create.{0,10}account|join|open an account"#
    private static let signUpLink = rx(
        #"^(sign up|register|create (an |a |a new |my |your |new )?account|join now|join free|join for free|open an account)\b"#)
    private static let signUpWords = rx(
        #"sign.?up|register|registration|create (an? |a new |your |my |new )?account|new account|open an account"#)

    private static func found(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isSignUpLink(_ text: String) -> Bool {
        found(signUpLink, in: ButtonRules.normalize(text))
    }

    @MainActor
    public func signUp(_ request: SignUpRequest) async -> RunReport {
        var report = RunReport()
        report.command = "signup"
        report.dryRun = options.dryRun
        let state = SignUpState(request)
        do {
            report.site = SitePolicy.host(of: try await driver.currentURL()) ?? "unknown site"
            report.stop = try await loop(&report, signUp: state)
        } catch {
            report.stop = .failed("\(error)")
        }
        // Saved but never typed: the page has no use for it, so neither has the vault.
        if let login = state.login, !state.typedPassword {
            request.forget(login)
            state.login = nil
        }
        report.newLogin = NewLoginReport(site: SitePolicy.normalizeSite(request.site),
                                         username: state.login?.username ?? "", saved: state.login != nil)
        report.finishedAt = Date()
        return report
    }

    /// Password boxes a new password could go in: not one the page marks as the current password.
    private func newPasswordFields(_ scan: PageScan) -> [PageField] {
        scan.fields.filter { field in
            field.type == "password" && !field.readOnly && !field.autocomplete.contains("current-password")
                && FieldRules.classify(field)?.concept == .password
        }
    }

    @MainActor
    func signUpGate(_ scan: PageScan, _ state: SignUpState) async throws -> SignUpGate {
        let formButtons = scan.buttons.filter { $0.inForm && !$0.disabled }.map(\.text)
        let passwords = newPasswordFields(scan)
        if !passwords.isEmpty {
            // Two password boxes, or one the page says is new, can only be a sign-up (or a password change).
            let marked = passwords.count >= 2 || passwords.contains { field in
                field.autocomplete.contains("new-password") || Self.found(
                    FieldMapper.creatingPassword, in: field.label + " " + field.placeholder + " " + FieldRules.words(field.name))
            }
            if marked { return .fill }
            let signInButton = scan.buttons.contains { !$0.disabled && ButtonRules.classify($0.text) == .login }
            let reads = state.started || Self.found(Self.signUpWords, in: ([scan.title] + formButtons).joined(separator: " "))
            if reads, !signInButton { return .fill }
            return .stop(.noSignUpForm("this looks like a sign-in page, not a sign-up form"))
        }

        // No password box yet. Some sites ask for the email first.
        let asksWho = scan.fields.filter { field in
            guard !field.readOnly, let concept = FieldRules.classify(field)?.concept else { return false }
            return concept == .email || concept == .username
        }
        let words = ([scan.title] + formButtons + asksWho.map(\.section)).joined(separator: " ")
        if !asksWho.isEmpty, state.started || Self.found(Self.signUpWords, in: words) {
            state.started = true
            return .fill
        }

        // A front page, most likely: follow its "Sign up" link once.
        let nothing = StopReason.noSignUpForm("found no sign-up form on this page")
        guard !state.followedLink, !options.dryRun else { return .stop(nothing) }
        let buttons = scan.buttons.filter { !$0.disabled && Self.isSignUpLink($0.text) }
        let links = try await driver.links(matching: Self.signUpLinkWording).filter { Self.isSignUpLink($0.text) }
        guard let target = buttons.first.map({ ($0.id, $0.text) }) ?? links.first.map({ ($0.id, $0.text) }) else {
            return .stop(nothing)
        }
        state.followedLink = true
        options.progress("  following \"\(target.1)\"")
        guard try await driver.click(buttonID: target.0).ok, await waitForChange(from: scan.signature) else {
            return .stop(.pageDidNotChange(button: target.1))
        }
        return .followed(target.1)
    }

    /// Turns the plan for an ordinary fill into the plan for a sign-up: the username and
    /// the new password go in where a fill would leave the boxes alone. Saves the login
    /// before any password is typed. Returns a reason to stop instead, if there is one.
    func prepareSignUp(_ plans: inout [FieldPlan], scan: PageScan, _ state: SignUpState) throws -> StopReason? {
        let request = state.request
        let site = SitePolicy.normalizeSite(request.site)
        let boxes = newPasswordFields(scan)
        let passwordIDs = Set(boxes.map(\.id))

        if plans.contains(where: { passwordIDs.contains($0.field.id) }) {
            guard SitePolicy.page(scan.url, matchesSite: site) else {
                let host = SitePolicy.host(of: scan.url) ?? "another site"
                return .passwordWithheld("this page is on \(host), not \(site), so no password was made")
            }
            guard SitePolicy.isSecureContext(scan.url) else {
                return .passwordWithheld("this page is not encrypted (no https), so no password was made")
            }
        }

        var typesPassword = false
        for index in plans.indices {
            let plan = plans[index]
            if plan.concept == .email, case .type(let value) = plan.decision { state.email = value }

            if plan.concept == .username, !plan.field.readOnly, case .leave(.nothingSaved, _) = plan.decision {
                let email = vault?.profile.email ?? ""
                let wantsEmail = (plan.field.label + " " + plan.field.placeholder).lowercased().contains("mail")
                if let given = request.username, !given.isEmpty {
                    plans[index].decision = .type(given)
                } else if !email.isEmpty {
                    let made = wantsEmail ? email : String(email.prefix { $0 != "@" })
                    plans[index].decision = .type(made)
                    if !wantsEmail {
                        plans[index].notes.append("made from your email address; if you change it here, change it on the Vault tab too")
                    }
                }
                if case .type(let value) = plans[index].decision { state.username = value }
            }

            guard passwordIDs.contains(plan.field.id) else { continue }
            if options.dryRun {
                plans[index].decision = .wouldFill
                plans[index].notes = ["a new password would be made and saved in the vault"]
                continue
            }
            if state.password == nil {
                let limit = boxes.map(\.maxLength).filter { $0 > 0 }.min() ?? Int.max
                guard limit >= PasswordMaker.shortestAllowed else {
                    plans[index].decision = .leave(.doesNotFit, "this box allows only \(limit) characters, too few for a strong password")
                    continue
                }
                state.password = PasswordMaker.make(length: min(request.passwordLength, limit), symbols: request.symbols)
            }
            guard let password = state.password else { continue }
            plans[index].decision = .type(password)
            plans[index].notes = []
            typesPassword = true
        }

        // Into the vault first, so there is never a typed password that was not saved.
        guard let password = state.password, typesPassword || state.login != nil else { return nil }
        var login = state.login ?? Login()
        let name = state.username.isEmpty ? state.email : state.username
        guard state.login == nil || login.username != name else { return nil }
        login.site = site
        login.username = name
        login.password = password
        if login.note.isEmpty {
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            login.note = "\(site) (made by Bino, \(day.string(from: Date())))"
        }
        try request.save(login)
        state.login = login
        return nil
    }

    /// Records how typing the new password went.
    func noteNewPassword(_ plan: FieldPlan, _ entry: inout EntryReport, _ state: SignUpState) {
        guard plan.concept == .password, case .type = plan.decision else { return }
        if entry.status == .failed {
            if !state.typedPassword { state.passwordFailed = true }
        } else {
            state.typedPassword = true
            state.passwordFailed = false
            entry.reason = "a new password, saved in the vault"
        }
    }
}
