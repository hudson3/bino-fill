import Foundation

public struct RunOptions {
    /// Look and report only: no vault, nothing typed, nothing pressed.
    public var dryRun = false
    /// Fill the current page and stop without pressing anything.
    public var onePage = false
    public var maxPages = 12
    public var settings = MapperSettings()
    /// Which of several accounts saved for the site to sign in with or fill, by its name.
    public var account: String?
    /// Called with short progress lines.
    public var progress: (String) -> Void = { _ in }

    public init() {}
}

/// Fills a multi-page form: read the page, decide, fill, press "continue", repeat, and
/// stop before anything final.
public struct FormRunner {
    let driver: BrowserDriver
    let vault: Vault?
    let decider: DecisionMaker?
    let options: RunOptions

    public init(driver: BrowserDriver, vault: Vault?, decider: DecisionMaker?, options: RunOptions = RunOptions()) {
        self.driver = driver
        self.vault = vault
        self.decider = decider
        self.options = options
    }

    @MainActor
    public func run() async -> RunReport {
        var report = RunReport()
        report.dryRun = options.dryRun
        do {
            report.site = SitePolicy.host(of: try await driver.currentURL()) ?? "unknown site"
            report.stop = try await loop(&report)
        } catch {
            report.stop = .failed("\(error)")
        }
        report.finishedAt = Date()
        return report
    }

    // MARK: Waiting

    /// Waits until the page has finished loading and stopped rearranging itself.
    @MainActor
    func settle(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = ""
        while Date() < deadline {
            // A page in the middle of navigating can refuse scripts; just try again.
            if let state = try? await driver.readyState(), state == "complete",
               let signature = try? await driver.signature() {
                if signature == previous { return }
                previous = signature
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    // MARK: The loop

    /// `signUp`: set when making a new account, which changes what happens to password
    /// boxes and where the run stops (see SignUpRunner.swift).
    @MainActor
    func loop(_ report: inout RunReport, signUp: SignUpState? = nil) async throws -> StopReason {
        let mapper: FieldMapper = {
            var mapper = FieldMapper(decider: decider)
            mapper.settings = options.settings
            return mapper
        }()

        for pageNumber in 1...options.maxPages {
            let pageStart = Date()
            await settle()
            var scan = try await driver.scan()
            options.progress("Page \(pageNumber): \(scan.title.isEmpty ? RunReport.tidy(scan.url) : scan.title), \(scan.fields.count) fields")
            var page = PageReport(number: pageNumber, address: RunReport.tidy(scan.url), title: scan.title)
            let errorsBefore = Set(scan.errors)

            if let signUp {
                switch try await signUpGate(scan, signUp) {
                case .fill: break
                case .followed(let link):
                    page.pressed = link
                    page.seconds = Date().timeIntervalSince(pageStart)
                    report.pages.append(page)
                    continue
                case .stop(let reason):
                    report.pages.append(page)
                    return reason
                }
            }
            // A saved login for this site belongs to another account: keep it out of a sign-up form.
            let source = signUp == nil ? vault : vault.map { vault in
                var vault = vault
                vault.logins = []
                return vault
            }

            // Fill, then look again: choosing a country can reveal a state box, and so on.
            var handled: [String: EntryReport] = [:]
            var order: [String] = []
            var sawCardFields = false
            for pass in 0..<3 {
                let fresh = scan.fields.filter { handled[$0.id] == nil }
                if fresh.isEmpty { break }
                var subset = scan
                subset.fields = pass == 0 ? scan.fields : fresh
                let resolver = source.map { ValueResolver(vault: $0, pageURL: scan.url, account: options.account) }
                var planned = await mapper.plan(scan: subset, resolver: options.dryRun ? nil : resolver)
                if let signUp, let stop = try prepareSignUp(&planned.plans, scan: scan, signUp) {
                    page.entries = order.compactMap { handled[$0] }
                    report.pages.append(page)
                    return stop
                }
                if let note = planned.modelNote { report.modelNote = note }
                page.modelCalls += planned.plans.filter { $0.source == .model || $0.source == .rulesAndModel }.count
                var changedSomething = false
                for plan in planned.plans {
                    if plan.concept?.isCard == true { sawCardFields = true }
                    var entry = try await carryOut(plan)
                    if let signUp { noteNewPassword(plan, &entry, signUp) }
                    if handled[plan.field.id] == nil { order.append(plan.field.id) }
                    handled[plan.field.id] = entry
                    if entry.status == .filled || entry.status == .check { changedSomething = true }
                }
                if !changedSomething || options.dryRun { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
                scan = try await driver.scan()
            }
            page.entries = order.compactMap { handled[$0] }
            page.unreachable = scan.frames.map { frame in
                let what = frame.payment ? "Payment box" : "Embedded box"
                let name = frame.title.isEmpty ? frame.host : frame.title
                return name.isEmpty ? what : "\(what) (\(name))"
            }
            page.seconds = Date().timeIntervalSince(pageStart)
            defer { report.pages.append(page) }

            if options.dryRun { return .dryRun }
            if options.onePage { return .onePageOnly }
            if scan.captcha { return .captcha }

            // Anything about money ends the run here, whatever the buttons say.
            if sawCardFields || scan.frames.contains(where: \.payment) { return .paymentPage }

            let waiting = page.entries.filter { entry in
                guard entry.status == .left || entry.status == .failed else { return false }
                if entry.leaveKind == .alreadyFilled { return false }
                // An unanswered radio group is a question the page is asking you.
                return entry.required || (entry.fieldType == "radio" && entry.leaveKind != .notPersonal)
            }
            if let signUp {
                if signUp.passwordFailed {
                    return .pageErrors(["the page did not keep the new password, so no login was saved"])
                }
                // Whatever the button on this page says, pressing it now makes the account. That is yours to do.
                if signUp.typedPassword {
                    let kinds = scan.buttons.filter { !$0.disabled }.map { ($0, ButtonRules.classify($0.text)) }
                    let button = kinds.first(where: { $0.1 == .final })?.0 ?? pick(kinds.filter { $0.1 == .next }.map(\.0))
                    return .signUpReady(button: button?.text, needs: waiting.map(\.field))
                }
            }
            if !waiting.isEmpty { return .needsYou(waiting.map(\.field)) }

            let newErrors = scan.errors.filter { !errorsBefore.contains($0) }
            if !newErrors.isEmpty { return .pageErrors(newErrors) }

            let usable = scan.buttons.filter { !$0.disabled }
            let kinds = usable.map { ($0, ButtonRules.classify($0.text)) }
            let signedIn = signUp == nil
                && page.entries.contains { $0.concept == Concept.password.displayName && $0.status == .filled }
            let forward = kinds.filter { $0.1 == .next || (signedIn && $0.1 == .login) }.map(\.0)

            guard let button = pick(forward) else {
                if let final = kinds.first(where: { $0.1 == .final })?.0 { return .finalStep(button: final.text) }
                return .noWayForward
            }

            let before = scan.signature
            options.progress("  pressing \"\(button.text)\"")
            let pressed = try await driver.click(buttonID: button.id)
            guard pressed.ok else { return .pageDidNotChange(button: button.text) }
            page.pressed = button.text

            let moved = await waitForChange(from: before)
            if !moved {
                // Same page: most often the site rejected something.
                if let after = try? await driver.scan() {
                    let complaints = after.errors.filter { !errorsBefore.contains($0) }
                    if !complaints.isEmpty { return .pageErrors(complaints) }
                }
                return .pageDidNotChange(button: button.text)
            }
        }
        return .pageLimit
    }

    /// Prefers the form's own submit button, then a highlighted one, then the lowest on the page.
    func pick(_ buttons: [PageButton]) -> PageButton? {
        buttons.max { a, b in
            func score(_ button: PageButton) -> Int {
                (button.inForm ? 4 : 0) + (button.type == "submit" ? 2 : 0) + (button.primary ? 1 : 0)
            }
            return score(a) == score(b) ? a.y < b.y : score(a) < score(b)
        }
    }

    @MainActor
    func waitForChange(from signature: String, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let state = try? await driver.readyState(), state == "complete",
               let now = try? await driver.signature(), now != signature {
                return true
            }
        }
        return false
    }

    // MARK: One field

    @MainActor
    private func carryOut(_ plan: FieldPlan) async throws -> EntryReport {
        var entry = EntryReport(
            field: plan.field.displayName, fieldType: plan.field.type, section: plan.field.section,
            concept: plan.concept?.displayName ?? "", shown: "", confidence: plan.confidence, source: plan.source,
            status: .left, leaveKind: nil, reason: plan.notes.joined(separator: "; "), required: plan.field.required,
            frame: plan.field.origin)

        let result: ActionResult
        switch plan.decision {
        case .leave(let kind, let why):
            entry.leaveKind = kind
            entry.reason = why
            return entry
        case .wouldFill:
            entry.status = .wouldFill
            if plan.confidence < options.settings.fillThreshold, entry.reason.isEmpty {
                entry.reason = "would be flagged: not fully sure"
            }
            return entry
        case .type(let value):
            entry.shown = RunReport.mask(value, concept: plan.concept)
            result = try await driver.fill(fieldID: plan.field.id, value: value)
        case .choose(let option):
            entry.shown = RunReport.mask(option.t.isEmpty ? option.v : option.t, concept: plan.concept)
            result = try await driver.pick(fieldID: plan.field.id, optionID: option.id)
        }

        if !result.ok {
            entry.status = .failed
            entry.reason = result.why
        } else if plan.confidence < options.settings.fillThreshold || !plan.notes.isEmpty {
            entry.status = .check
            if entry.reason.isEmpty { entry.reason = "not fully sure this is what the field wants" }
        } else {
            entry.status = .filled
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        return entry
    }
}
