import AppKit
import BinoCore
import SwiftUI

/// Runs a fill from the window: the same steps as `bino fill`, with the report shown as a list.
@MainActor
final class FillModel: ObservableObject {
    @Published var site = ""
    @Published var siteProblem = ""
    @Published var running = false
    @Published var progress = ""
    @Published var problem = ""
    @Published var report: RunReport?
    @Published var onlyThisPage = false
    @Published var lookOnly = false

    let makeDriver: @MainActor () -> BrowserDriver

    init(makeDriver: @escaping @MainActor () -> BrowserDriver = { SafariDriver() }) {
        self.makeDriver = makeDriver
    }

    /// Shows which page a fill would act on.
    func refreshSite() {
        guard !running else { return }
        Task {
            do {
                let url = try await makeDriver().currentURL()
                site = SitePolicy.host(of: url) ?? ""
                siteProblem = site.isEmpty ? "Safari's front tab has no web page." : ""
            } catch {
                site = ""
                siteProblem = "\(error)"
            }
        }
    }

    func start() {
        Task { await run() }
    }

    /// One fill from start to finish. The button starts it; a voice command waits for it.
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        problem = ""
        report = nil
        progress = lookOnly ? "Looking at the page…" : "Waiting for Touch ID…"
        let dryRun = lookOnly
        let onePage = onlyThisPage
        let driver = makeDriver()

        var vault: BinoCore.Vault?
        if !dryRun {
            guard VaultStore.exists else {
                problem = "There is no vault yet. Add your details on the Vault tab first."
                return
            }
            do {
                // Checked first so Touch ID is not asked for a page Bino cannot reach, and
                // so the prompt can say which site the vault is being opened for.
                let page = SitePolicy.host(of: try await driver.currentURL()) ?? "this page"
                // Asked for on every fill. Done off the main thread so the window stays responsive.
                vault = try await Task.detached {
                    try VaultStore.unlock(reason: "fill the form on \(page)")
                }.value
            } catch {
                problem = "\(error)"
                return
            }
        }

        let decider = SidecarDecider()
        var usable: DecisionMaker? = decider
        do {
            if !(await decider.isRunning()) { progress = "Loading the decision model…" }
            try await decider.ensureRunning()
        } catch {
            usable = nil
        }

        var options = RunOptions()
        options.dryRun = dryRun
        options.onePage = onePage
        options.progress = { [weak self] line in self?.progress = line.trimmingCharacters(in: .whitespaces) }
        progress = "Reading the page…"
        var result = await FormRunner(driver: driver, vault: vault, decider: usable, options: options).run()
        result.command = "fill"
        vault = nil
        _ = try? result.save()
        report = result
        progress = ""
        if usable == nil, result.modelNote == nil {
            problem = "The decision model could not start, so only the fixed rules were used."
        }
    }
}

struct FillView: View {
    @ObservedObject var model: FillModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls.padding(16)
            Divider()
            if let report = model.report {
                ReportList(report: report)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Text(model.running ? model.progress : "Open the form in Safari, then press the button.")
                        .foregroundStyle(.secondary)
                    Text("Bino fills what it knows, continues through the pages, and stops before anything final.")
                        .font(.callout).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { model.refreshSite() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSite()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Safari's front tab:").foregroundStyle(.secondary)
                if model.site.isEmpty {
                    Text(model.siteProblem.isEmpty ? "checking…" : model.siteProblem)
                        .foregroundStyle(model.siteProblem.isEmpty ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.site).fontWeight(.semibold)
                }
                Spacer()
                Button("Check again") { model.refreshSite() }.disabled(model.running)
            }
            HStack(spacing: 16) {
                Button(model.lookOnly ? "Look at this form" : "Fill this form") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.running)
                    .keyboardShortcut(.return, modifiers: .command)
                Toggle("Only this page", isOn: $model.onlyThisPage).toggleStyle(.checkbox)
                Toggle("Look only, fill nothing", isOn: $model.lookOnly).toggleStyle(.checkbox)
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Text(model.progress).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !model.problem.isEmpty {
                Text(model.problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The report as a list: what stopped the run, what needs checking, then every field.
struct ReportList: View {
    let report: RunReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.stop.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(summary).foregroundStyle(.secondary)
                    if let note = report.modelNote {
                        Text("Note: \(note)").font(.callout).foregroundStyle(.secondary)
                    }
                }

                let flagged = report.attention
                let frames = report.pages.flatMap { page in page.unreachable.map { (page.number, $0) } }
                if !flagged.isEmpty || !frames.isEmpty {
                    section("Check these (\(flagged.count + frames.count))") {
                        ForEach(Array(flagged.enumerated()), id: \.offset) { _, item in
                            EntryRow(entry: item.entry, page: report.pages.count > 1 ? item.page : nil, needsYou: true)
                        }
                        ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                            PlainRow(symbol: "exclamationmark.triangle.fill", tint: .orange, title: frame.1,
                                     detail: "Bino cannot reach this embedded box; fill it yourself",
                                     page: report.pages.count > 1 ? frame.0 : nil)
                        }
                    }
                }

                ForEach(report.pages, id: \.number) { page in
                    section("Page \(page.number): \(page.title.isEmpty ? page.address : page.title)") {
                        ForEach(Array(page.entries.enumerated()), id: \.offset) { _, entry in
                            EntryRow(entry: entry, page: nil)
                        }
                        if let pressed = page.pressed {
                            PlainRow(symbol: "hand.tap.fill", tint: .blue, title: "Pressed \"\(pressed)\"", detail: "", page: nil)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: String {
        let seconds = String(format: "%.0f", report.pages.reduce(0) { $0 + $1.seconds })
        let pages = report.pages.count == 1 ? "1 page" : "\(report.pages.count) pages"
        if report.dryRun {
            let count = report.pages.reduce(0) { $0 + $1.entries.filter { $0.status == .wouldFill }.count }
            return "Would fill \(count) fields on \(report.site). Looked at \(pages) in \(seconds) s."
        }
        return "Filled \(report.filledCount) fields on \(report.site), \(pages), \(seconds) s."
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
        }
    }
}

struct EntryRow: View {
    let entry: EntryReport
    let page: Int?
    /// In the "Check these" list, things left alone are marked as needing you.
    var needsYou = false

    var body: some View {
        PlainRow(symbol: symbol, tint: tint, title: entry.field, detail: detail, page: page, confidence: confidence)
    }

    private var symbol: String {
        switch entry.status {
        case .filled: return "checkmark.circle.fill"
        case .check: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .wouldFill: return "arrow.right.circle.fill"
        case .left: return needsYou ? "exclamationmark.circle.fill" : "minus.circle"
        }
    }

    private var tint: Color {
        switch entry.status {
        case .filled: return .green
        case .check: return .orange
        case .failed: return .red
        case .wouldFill: return .blue
        case .left: return needsYou ? .orange : .secondary
        }
    }

    private var detail: String {
        switch entry.status {
        case .filled: return "\(entry.concept): \(entry.shown)"
        case .check: return "\(entry.concept): \(entry.shown). \(entry.reason)"
        case .wouldFill: return entry.reason.isEmpty ? "Would fill with your \(entry.concept)" : "Would fill with your \(entry.concept). \(entry.reason)"
        case .failed: return "Tried \(entry.concept), but \(entry.reason)"
        case .left: return "Left alone: \(entry.reason)"
        }
    }

    /// Only shown where Bino acted (or would act) on a judgement.
    private var confidence: Double? {
        switch entry.status {
        case .filled, .check, .wouldFill: return entry.confidence
        case .failed, .left: return nil
        }
    }
}

struct PlainRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let page: Int?
    var confidence: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(2)
                    if !detail.isEmpty {
                        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let page {
                    Text("page \(page)").font(.caption).foregroundStyle(.secondary)
                }
                if let confidence {
                    ConfidenceBadge(value: confidence)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().padding(.leading, 40)
        }
    }
}

/// How sure Bino was, as a percentage with a small bar.
struct ConfidenceBadge: View {
    let value: Double

    private var tint: Color {
        value >= 0.9 ? .green : (value >= 0.7 ? .orange : .secondary)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(Int((value * 100).rounded()))% sure").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 64, height: 4)
                Capsule().fill(tint).frame(width: 64 * max(0, min(1, value)), height: 4)
            }
        }
        .frame(width: 72, alignment: .trailing)
    }
}
