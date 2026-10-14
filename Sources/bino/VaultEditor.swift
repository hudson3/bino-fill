import AppKit
import BinoCore
import SwiftUI

@MainActor
final class EditorModel: ObservableObject {
    @Published var vault: BinoCore.Vault
    @Published var status = ""
    @Published var statusIsProblem = false
    @Published var sorting = false
    @Published var showSecrets = false
    private var lastSaved: BinoCore.Vault
    /// The vault file as it was when this window last read or wrote it.
    private var stamp: Data?
    private var catchingUp = false
    let isNew: Bool

    init(vault: BinoCore.Vault, isNew: Bool) {
        self.vault = vault
        self.lastSaved = vault
        self.isNew = isNew
        self.stamp = VaultStore.stamp()
    }

    var hasUnsavedChanges: Bool { vault != lastSaved }

    /// Problems that would stop Bino using an entry safely.
    func problems() -> [String] {
        var found: [String] = []
        for login in vault.logins where !login.site.isEmpty {
            if !SitePolicy.isAcceptableSite(login.site) {
                found.append("Login site \"\(login.site)\" needs to be a full site such as united.com")
            }
        }
        let dates = [("Date of birth", vault.profile.dateOfBirth), ("Passport issue date", vault.profile.passport.issueDate),
                     ("Passport expiry date", vault.profile.passport.expiryDate)]
        for (name, value) in dates where !value.isEmpty {
            if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
                found.append("\(name) should look like 1990-03-14")
            }
        }
        if !vault.profile.ssn.isEmpty, vault.profile.ssn.filter(\.isNumber).count != 9 {
            found.append("Social Security number should have 9 digits")
        }
        for card in vault.cards where !card.number.isEmpty {
            if !(12...19).contains(card.digits.count) { found.append("Card \"\(card.label)\" number looks too short or long") }
            if Int(card.expMonth).map({ !(1...12).contains($0) }) ?? true { found.append("Card \"\(card.label)\" needs an expiry month 1-12") }
            if Int(card.expYear) == nil { found.append("Card \"\(card.label)\" needs an expiry year") }
        }
        return found
    }

    @discardableResult
    func save() -> Bool {
        let found = problems()
        guard found.isEmpty else {
            status = found.joined(separator: "\n")
            statusIsProblem = true
            return false
        }
        // A command can save a new account's login while this window is open. Saving
        // over that would lose its password, so bring it in first.
        if VaultStore.exists, VaultStore.stamp() != stamp {
            catchUpThenSave()
            return false
        }
        var cleaned = vault
        cleaned.logins = cleaned.logins
            .filter { !$0.site.isEmpty || !$0.username.isEmpty || !$0.password.isEmpty || !$0.note.isEmpty }
            .map { login in
                var login = login
                login.site = SitePolicy.normalizeSite(login.site)
                return login
            }
        cleaned.cards = cleaned.cards.filter { !$0.number.isEmpty }
        if !cleaned.cards.isEmpty, !cleaned.cards.contains(where: \.isDefault) { cleaned.cards[0].isDefault = true }
        cleaned.profile.loyalty = cleaned.profile.loyalty.filter { !$0.number.isEmpty }
        do {
            try VaultStore.save(cleaned, createTestVault: BinoPaths.isRedirected)
            vault = cleaned
            lastSaved = cleaned
            stamp = VaultStore.stamp()
            let siteless = cleaned.logins.filter { $0.site.isEmpty }.count
            status = "Saved and encrypted. \(cleaned.logins.count) logins, \(cleaned.cards.count) cards."
                + (siteless > 0 ? "\n\(siteless) logins have no site, so they are stored but Bino will never type them into a page." : "")
            statusIsProblem = false
            return true
        } catch {
            status = "Could not save: \(error)"
            statusIsProblem = true
            return false
        }
    }

    /// Reads the vault file again (Touch ID), adds the logins it has that this window
    /// has never seen, and then saves.
    private func catchUpThenSave() {
        guard !catchingUp else { return }
        catchingUp = true
        status = "The vault was changed outside this window (a new account's password, for example). "
            + "Use Touch ID to bring that in; your changes here are kept."
        statusIsProblem = false
        Task {
            defer { catchingUp = false }
            do {
                let (onDisk, read) = try await Task.detached {
                    let read = VaultStore.stamp()
                    return (try VaultStore.unlock(reason: "bring in changes made outside the Bino window"), read)
                }.value
                let seen = Set((lastSaved.logins + vault.logins).map(\.id))
                let added = onDisk.logins.filter { !seen.contains($0.id) }
                vault.logins.append(contentsOf: added)
                stamp = read
                if save(), !added.isEmpty {
                    status += "\nBrought in \(added.count) login\(added.count == 1 ? "" : "s") saved outside this window."
                }
            } catch {
                status = "Not saved. The vault was changed outside this window and could not be read again: \(error)"
                statusIsProblem = true
            }
        }
    }

    func autoSort() {
        let text = vault.notes
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Logins written as "label, username, password" are read by fixed rules: instant, nothing invented.
        let parsed = NoteParser.parse(text)
        var updated = vault
        let added = NoteParser.apply(parsed, to: &updated)
        vault = updated
        var lines: [String] = []
        if added > 0 {
            let siteless = parsed.logins.filter { $0.site.isEmpty }.count
            lines.append("Added \(added) logins from your note.")
            if !parsed.guessedSites.isEmpty {
                lines.append("Sites guessed from the label, check them: " + parsed.guessedSites.joined(separator: ", ") + ".")
            }
            if siteless > 0 {
                lines.append("\(siteless) have no site yet. Type one (such as united.com) for any you want Bino to fill in; the rest are just stored.")
            }
        }
        statusIsProblem = false

        guard NoteParser.isWorthReading(parsed.leftover) else {
            status = lines.isEmpty ? "Nothing recognised in the note. Fill the fields by hand." : lines.joined(separator: "\n")
            return
        }
        sorting = true
        status = (lines + ["Reading the rest of the note with the local model…"]).joined(separator: "\n")
        Task {
            do {
                let suggestion = try await NoteSorter().sort(note: parsed.leftover)
                var updated = vault
                let touched = NoteSorter.apply(suggestion, to: &updated)
                vault = updated
                if !touched.isEmpty {
                    lines.append("Filled in from the rest of the note, check each one: " + touched.joined(separator: ", ") + ".")
                }
                status = lines.isEmpty ? "Nothing new found in the note. Fill the fields by hand." : lines.joined(separator: "\n")
                statusIsProblem = false
            } catch {
                status = (lines + ["\(error)"]).joined(separator: "\n")
                statusIsProblem = lines.isEmpty
            }
            sorting = false
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    /// Shown as a "Lock" button when the vault can be locked again.
    var onLock: (() -> Void)?
    @State private var loginSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                notePane.frame(minWidth: 260, idealWidth: 320)
                fieldsPane.frame(minWidth: 540)
            }
            Divider()
            footer
        }
    }

    private var notePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your note").font(.headline)
            Text("Paste your note here (the whole thing from Notes is fine). It is saved in the vault, encrypted, and when a form asks for something the fields on the right do not hold, Bino looks for a \"label: value\" line here. Password lines are never used from it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.vault.notes)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Your note")
            HStack {
                Button(model.sorting ? "Sorting…" : "Auto-sort into fields") { model.autoSort() }
                    .disabled(model.sorting || model.vault.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.sorting { ProgressView().controlSize(.small) }
            }
            Text("Auto-sort uses the Ollama model on this Mac. It only fills empty fields, and it can get things wrong, so check every entry.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var fieldsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Spacer()
                    Toggle("Show passwords and card numbers", isOn: $model.showSecrets).toggleStyle(.checkbox)
                    if let onLock {
                        Button("Lock", action: onLock)
                    }
                }
                group("You") {
                    row("Title", $model.vault.profile.title, "Mr, Ms, Dr")
                    row("First name", $model.vault.profile.firstName)
                    row("Middle name", $model.vault.profile.middleName)
                    row("Last name", $model.vault.profile.lastName)
                    row("Suffix", $model.vault.profile.suffix, "Jr, III")
                    row("Date of birth", $model.vault.profile.dateOfBirth, "1990-03-14")
                    row("Gender", $model.vault.profile.gender, "Male, Female, X")
                    row("Nationality", $model.vault.profile.nationality, "United States")
                    secretRow("Social Security number", $model.vault.profile.ssn, "Stored for you to look up; Bino never types it")
                }
                group("Contact") {
                    row("Email", $model.vault.profile.email)
                    row("Phone", $model.vault.profile.phone, "+1 512 555 0142")
                    row("Company", $model.vault.profile.company)
                }
                group("Home address") { addressRows($model.vault.profile.address) }
                group("Travel documents") {
                    row("Passport number", $model.vault.profile.passport.number)
                    row("Issuing country", $model.vault.profile.passport.issuingCountry)
                    row("Issue date", $model.vault.profile.passport.issueDate, "2021-06-01")
                    row("Expiry date", $model.vault.profile.passport.expiryDate, "2031-05-31")
                    row("Known traveler number", $model.vault.profile.knownTravelerNumber)
                    row("Redress number", $model.vault.profile.redressNumber)
                }
                loyaltySection
                cardsSection
                loginsSection
            }
            .padding(16)
        }
    }

    private var loyaltySection: some View {
        group("Frequent flyer and member numbers") {
            ForEach($model.vault.profile.loyalty) { $entry in
                HStack {
                    TextField("Programme, e.g. United MileagePlus", text: $entry.program)
                    TextField("Number", text: $entry.number)
                    TextField("Site, e.g. united.com", text: $entry.site)
                    Button("Remove") { model.vault.profile.loyalty.removeAll { $0.id == entry.id } }
                }
            }
            Button("Add a member number") { model.vault.profile.loyalty.append(Loyalty()) }
        }
    }

    private var cardsSection: some View {
        group("Payment cards") {
            ForEach($model.vault.cards) { $card in
                VStack(alignment: .leading, spacing: 6) {
                    row("Nickname", $card.label, "Travel Visa")
                    row("Name on card", $card.cardholderName)
                    secretRow("Card number", $card.number)
                    HStack {
                        Text("Expires").frame(width: 170, alignment: .trailing)
                        TextField("Month", text: $card.expMonth).frame(width: 70)
                        TextField("Year", text: $card.expYear).frame(width: 80)
                        Text("Security code")
                        secretField($card.cvv).frame(width: 80)
                        Spacer()
                    }
                    DisclosureGroup("Billing address (leave empty to use your home address)") {
                        addressRows($card.billingAddress)
                    }
                    .padding(.leading, 178)
                    HStack {
                        Spacer().frame(width: 178)
                        Toggle("Use this card by default", isOn: Binding(
                            get: { card.isDefault },
                            set: { on in
                                for index in model.vault.cards.indices {
                                    model.vault.cards[index].isDefault = on && model.vault.cards[index].id == card.id
                                }
                            })).toggleStyle(.checkbox)
                        Spacer()
                        Button("Remove card") { model.vault.cards.removeAll { $0.id == card.id } }
                    }
                    Divider()
                }
            }
            Button("Add a card") { model.vault.cards.append(Card()) }
        }
    }

    private var loginsSection: some View {
        group("Logins") {
            Text("Bino types a password only on the site saved next to it. A login with no site is stored but never typed anywhere. Two logins for one site: name them (\"therethen\", \"beecave\") and say which with --account. The sign-in page is optional, for a site whose front page is not where you sign in.")
                .font(.callout).foregroundStyle(.secondary)
            loginSearchField
            ForEach($model.vault.logins) { $login in
                if login.matches(search: loginSearch) {
                    HStack {
                        TextField("Name, e.g. work", text: $login.note)
                        TextField("Site, e.g. united.com", text: $login.site)
                        TextField("Username or email", text: $login.username)
                        secretField($login.password, prompt: "Password")
                        TextField("Sign-in page (optional)", text: $login.url)
                        Button("Remove") { model.vault.logins.removeAll { $0.id == login.id } }
                    }
                }
            }
            if !model.vault.logins.isEmpty, !model.vault.logins.contains(where: { $0.matches(search: loginSearch) }) {
                Text("No logins match \"\(loginSearch.trimmingCharacters(in: .whitespaces))\".")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // A new login is empty, so it would be hidden by a search still in the box.
            Button("Add a login") {
                loginSearch = ""
                model.vault.logins.append(Login())
            }
        }
    }

    /// Searches the label, site and username of each login. Passwords are not searched.
    private var loginSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search logins by name, site or username", text: $loginSearch)
                .textFieldStyle(.plain)
                .onExitCommand { loginSearch = "" }
            if !loginSearch.isEmpty {
                Button { loginSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private var footer: some View {
        HStack(alignment: .top) {
            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.statusIsProblem ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    // MARK: Building blocks

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ title: String, _ text: Binding<String>, _ prompt: String = "") -> some View {
        HStack {
            Text(title).frame(width: 170, alignment: .trailing)
            TextField(prompt, text: text)
        }
    }

    private func secretRow(_ title: String, _ text: Binding<String>, _ prompt: String = "") -> some View {
        HStack {
            Text(title).frame(width: 170, alignment: .trailing)
            secretField(text, prompt: prompt)
        }
    }

    @ViewBuilder
    private func secretField(_ text: Binding<String>, prompt: String = "") -> some View {
        if model.showSecrets {
            TextField(prompt, text: text)
        } else {
            SecureField(prompt, text: text)
        }
    }

    @ViewBuilder
    private func addressRows(_ address: Binding<Address>) -> some View {
        row("Street address", address.line1)
        row("Apartment, suite, unit", address.line2)
        row("City", address.city)
        row("State or province", address.state)
        row("Zip or postal code", address.postalCode)
        row("Country", address.country)
    }
}
