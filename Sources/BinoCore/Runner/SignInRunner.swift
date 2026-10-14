import Foundation

/// Signing in with one saved login: find the sign-in form, type the username and
/// password, press the sign-in button, and say what the page did next.
///
/// Fixed rules only; the decision model is not involved. Nothing is typed unless the page
/// is on the login's own site, and nothing but the username and password is typed at all.
extension FormRunner {
    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    public static let signInWording = #"sign.?in|log.?in|log.?on|sign.?on"#
    public static let signOutWording = #"sign.?out|log.?out|log.?off|sign.?off"#
    private static let signInWords = rx(signInWording)
    private static let codeWords = rx(
        #"verif|one.?time|\botp\b|authenticat|two.?(factor|step)|\b2fa\b|\bcode\b|passcode"#)
    /// "Trust this browser?", "Stay signed in?", "Remember this device": a choice after the password.
    private static let trustWords = rx(
        #"trust (this|your) (browser|device|computer)|stay signed in|keep me signed in|remember (this|my) (browser|device|computer)|don.?t ask again"#)
    private static let trustButtons = rx(#"^(trust|not now|don.?t trust|yes|no|remember|don.?t remember)$"#)
    private static let signOutWords = rx(signOutWording)

    private static func found(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The box asking for a code, if the page has one.
    private func codeField(_ scan: PageScan) -> PageField? {
        scan.fields.first { field in
            field.autocomplete.contains("one-time-code")
                || Self.found(Self.codeWords, in: field.label + " " + field.placeholder + " " + FieldRules.nameKey(field))
        }
    }

    /// A screen that asks whether to trust or remember this browser.
    private func asksToTrust(_ scan: PageScan) -> Bool {
        guard scan.fields.allSatisfy({ $0.type == "checkbox" || $0.type == "radio" }) else { return false }
        if Self.found(Self.trustWords, in: scan.wording) { return true }
        let buttons = scan.buttons.filter { !$0.disabled }.map { ButtonRules.normalize($0.text) }
        return buttons.contains("trust") && buttons.contains { Self.found(Self.trustButtons, in: $0) && $0 != "trust" }
    }

    /// Stops the run at a code or a trust screen, leaving the keyboard where the person needs it.
    @MainActor
    private func handOver(_ scan: PageScan, page: inout PageReport) async -> StopReason? {
        if let code = codeField(scan) {
            _ = try? await driver.focus(fieldID: code.id)
            page.stage = "two_factor"
            return .twoFactor(field: code.displayName)
        }
        if asksToTrust(scan) {
            page.stage = "trust_prompt"
            return .trustPrompt
        }
        return nil
    }

    /// Where a box may take the saved login: the login's own site, or a host that signs
    /// people in for it (idmsa.apple.com for apple.com). `origin` is empty for the page itself.
    private func mayType(into field: PageField, pageURL: String, login: Login) -> String? {
        let place = field.origin.isEmpty ? pageURL : "https://\(field.origin)/"
        guard SitePolicy.page(place, matchesSiteOrSignInHost: login.site) else {
            let host = SitePolicy.host(of: place) ?? field.origin
            let where_ = field.origin.isEmpty ? "this page is on \(host)" : "the \"\(field.displayName)\" box is in a frame from \(host)"
            return "\(where_), not \(SitePolicy.normalizeSite(login.site)), so nothing was typed"
        }
        return nil
    }

    @MainActor
    public func signIn(with login: Login) async -> RunReport {
        var report = RunReport()
        report.command = "login"
        do {
            report.site = SitePolicy.host(of: try await driver.currentURL()) ?? "unknown site"
            report.stop = try await signInLoop(login, &report)
        } catch {
            report.stop = .failed("\(error)")
        }
        report.finishedAt = Date()
        return report
    }

    /// The box that takes the username: the last one before the password, or on a page
    /// that asks for the username first, the only plausible one.
    private func usernamePlan(_ plans: [FieldPlan], password: FieldPlan?, scan: PageScan) -> FieldPlan? {
        let candidates = plans.filter { plan in
            guard plan.concept == .username || plan.concept == .email,
                  plan.confidence >= options.settings.flagThreshold, !plan.field.readOnly,
                  ["text", "email", "tel", ""].contains(plan.field.type)
            else { return false }
            switch plan.decision {
            case .wouldFill, .leave(.alreadyFilled, _): return true
            default: return false
            }
        }
        if let password {
            guard let at = plans.firstIndex(where: { $0.field.id == password.field.id }) else { return nil }
            let before = Set(plans[..<at].map(\.field.id))
            return candidates.last { before.contains($0.field.id) }
        }
        if let named = candidates.first(where: { $0.concept == .username }) { return named }
        // An email box alone could be a newsletter sign-up; take it only on a page that talks about signing in.
        let pageWords = ([scan.title] + scan.buttons.map(\.text) + candidates.map(\.field.section)).joined(separator: " ")
        return candidates.count == 1 && Self.found(Self.signInWords, in: pageWords) ? candidates[0] : nil
    }

    @MainActor
    private func type(_ value: String, into plan: FieldPlan, as concept: Concept, page: inout PageReport) async throws -> Bool {
        let result = try await driver.fill(fieldID: plan.field.id, value: value)
        page.entries.append(EntryReport(
            field: plan.field.displayName, fieldType: plan.field.type, section: plan.field.section,
            concept: concept.displayName, shown: RunReport.mask(value, concept: concept), confidence: plan.confidence,
            source: plan.source, status: result.ok ? .filled : .failed, leaveKind: nil, reason: result.why,
            required: plan.field.required, frame: plan.field.origin))
        try? await Task.sleep(nanoseconds: 40_000_000)
        return result.ok
    }

    /// A page whose form has not shown up yet: a frame from another site still loading
    /// (Apple's sign-in box arrives after the page around it). Looks again for a while.
    @MainActor
    private func waitForFrames(_ scan: PageScan, timeout: TimeInterval = 8) async -> PageScan {
        var scan = scan
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, scan.fields.isEmpty, scan.frames.contains(where: { !$0.payment }) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let again = try? await driver.scan() else { break }
            scan = again
            if !scan.fields.isEmpty || scan.frames.allSatisfy({ !$0.loading }) {
                // Loaded with nothing to show: one more look in case the boxes come a beat later.
                if scan.fields.isEmpty, let last = try? await driver.scan() { scan = last }
                break
            }
        }
        return scan
    }

    @MainActor
    private func signInLoop(_ login: Login, _ report: inout RunReport) async throws -> StopReason {
        let mapper: FieldMapper = {
            var mapper = FieldMapper(decider: nil)
            mapper.settings = options.settings
            return mapper
        }()
        var followedLink = false
        var typedUsername = false

        for pageNumber in 1...min(options.maxPages, 5) {
            let pageStart = Date()
            await settle()
            var scan = try await driver.scan()
            if scan.fields.isEmpty, scan.frames.contains(where: { !$0.payment }) { scan = await waitForFrames(scan) }
            options.progress("Page \(pageNumber): \(scan.title.isEmpty ? RunReport.tidy(scan.url) : scan.title)")
            var page = PageReport(number: pageNumber, address: RunReport.tidy(scan.url), title: scan.title)
            defer {
                page.seconds = Date().timeIntervalSince(pageStart)
                report.pages.append(page)
            }
            let errorsBefore = Set(scan.errors)

            let plans = await mapper.plan(scan: scan, resolver: nil).plans
            let password = plans.first { plan in
                guard plan.concept == .password, !plan.field.readOnly else { return false }
                if case .leave(.newPassword, _) = plan.decision { return false }
                return true
            }
            let username = typedUsername && password == nil ? nil : usernamePlan(plans, password: password, scan: scan)

            if password == nil, username == nil {
                if typedUsername {
                    if !scan.errors.isEmpty { return .pageErrors(scan.errors) }
                    if let stop = await handOver(scan, page: &page) { return stop }
                    return .noSignInForm
                }
                if let stop = await handOver(scan, page: &page) { return stop }
                // A front page, most likely: follow its "Sign in" link once.
                let buttons = followedLink ? [] : scan.buttons.filter { !$0.disabled && ButtonRules.classify($0.text) == .login }
                let links = followedLink ? [] : try await driver.links(matching: Self.signInWording)
                    .filter { ButtonRules.classify($0.text) == .login }
                guard let target = buttons.first.map({ ($0.id, $0.text) }) ?? links.first.map({ ($0.id, $0.text) }) else {
                    // No form and nothing to follow. Say why, as well as it can be told.
                    if let frame = scan.frames.first(where: { !$0.payment }) { return .formInFrame(origin: frame.host) }
                    let signOut = (try? await driver.links(matching: Self.signOutWording)) ?? []
                    if !signOut.isEmpty || scan.buttons.contains(where: { Self.found(Self.signOutWords, in: $0.text) }) {
                        page.stage = "signed_in"
                        return .alreadySignedIn(why: "the page has a sign-out link")
                    }
                    if !followedLink, !SitePolicy.looksLikeSignInPage(scan.url) {
                        page.stage = "signed_in"
                        return .alreadySignedIn(why: "no sign-in form or link, and the address is not a sign-in page")
                    }
                    return .noSignInForm
                }
                followedLink = true
                options.progress("  following \"\(target.1)\"")
                guard try await driver.click(buttonID: target.0).ok, await waitForChange(from: scan.signature) else {
                    return .pageDidNotChange(button: target.1)
                }
                page.pressed = target.1
                page.stage = "followed_link"
                continue
            }

            guard SitePolicy.page(scan.url, matchesSiteOrSignInHost: login.site) else {
                let host = SitePolicy.host(of: scan.url) ?? "another site"
                return .passwordWithheld("this page is on \(host), not \(SitePolicy.normalizeSite(login.site)), so nothing was typed")
            }
            guard SitePolicy.isSecureContext(scan.url) else {
                return .passwordWithheld("this page is not encrypted (no https), so nothing was typed")
            }
            // A box in a frame from elsewhere takes nothing, whatever the page around it is.
            for plan in [username, password].compactMap({ $0 }) {
                if let why = mayType(into: plan.field, pageURL: scan.url, login: login) { return .passwordWithheld(why) }
            }
            if let username {
                guard try await type(login.username, into: username, as: .username, page: &page) else {
                    return .pageErrors(["the page did not keep what was typed into \"\(username.field.displayName)\""])
                }
                typedUsername = true
                page.stage = "username"
            }
            if let password {
                guard try await type(login.password, into: password, as: .password, page: &page) else {
                    return .pageErrors(["the page did not keep what was typed into \"\(password.field.displayName)\""])
                }
                page.stage = "password"
            }
            if scan.captcha { return .captcha }

            // "Continue" counts here too: after a username or password it can only mean "sign in".
            let forward = scan.buttons.filter { button in
                guard !button.disabled else { return false }
                let kind = ButtonRules.classify(button.text)
                return kind == .login || kind == .next
            }
            guard let button = pick(forward) else { return .noWayForward }
            options.progress("  pressing \"\(button.text)\"")
            guard try await driver.click(buttonID: button.id).ok else { return .pageDidNotChange(button: button.text) }
            page.pressed = button.text

            guard await waitForChange(from: scan.signature) else {
                if let after = try? await driver.scan() {
                    let complaints = after.errors.filter { !errorsBefore.contains($0) }
                    if !complaints.isEmpty { return .pageErrors(complaints) }
                }
                return .pageDidNotChange(button: button.text)
            }
            guard password != nil else { continue }

            // The password has gone in. Report what the site showed next, and stop.
            await settle()
            var after = try await driver.scan()
            if after.fields.isEmpty, after.frames.contains(where: { !$0.payment }) { after = await waitForFrames(after, timeout: 5) }
            let complaints = after.errors.filter { !errorsBefore.contains($0) }
            if !complaints.isEmpty { return .pageErrors(complaints) }
            if after.captcha { return .captcha }
            if let stop = await handOver(after, page: &page) { return stop }
            let stillShowing = after.fields.contains { $0.type == "password" }
            page.stage = stillShowing ? "password" : "signed_in"
            return .signInPressed(button: button.text, formStillShowing: stillShowing)
        }
        return .pageLimit
    }
}
