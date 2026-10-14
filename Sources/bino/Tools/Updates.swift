import AppKit
import BinoCore
import SwiftUI

/// The update check at the bottom of the sidebar: at launch, once an hour, and on request.
@MainActor
final class UpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, available, ahead, installing, installed, failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var log = ""
    @Published var checkedAt: Date?
    let build = BuildInfo.current()
    private var timer: Timer?

    func start() {
        guard build != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check() async {
        guard let build, phase != .installing, phase != .installed else { return }
        phase = .checking
        do {
            switch try await Updater.check(build) {
            case .upToDate: phase = .upToDate
            case .available: phase = .available
            case .ahead: phase = .ahead
            }
            checkedAt = Date()
        } catch {
            phase = .failed("\(error)")
        }
    }

    func install() async {
        guard let build, phase == .available else { return }
        phase = .installing
        log = ""
        do {
            try await Updater.install(build) { [weak self] chunk in
                Task { @MainActor in self?.log += chunk }
            }
            phase = .installed
        } catch {
            phase = .failed("\(error)")
        }
    }

    /// Quits this (old) copy and opens the newly installed one.
    func reopen() {
        Updater.reopenApp()
    }
}

struct UpdateStrip: View {
    @ObservedObject var model: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Group {
                if let build = model.build {
                    Text("Built from \(build.shortCommit)\(build.isDirty ? " (edited)" : "")")
                        .font(.caption2).foregroundStyle(.tertiary)
                    switch model.phase {
                    case .idle:
                        Button("Check for updates") { Task { await model.check() } }
                    case .checking:
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…") }
                    case .upToDate:
                        Text("Up to date").foregroundStyle(.secondary)
                        Button("Check for updates") { Task { await model.check() } }
                    case .ahead:
                        Text("This build is off main; not updating over it.").foregroundStyle(.secondary)
                        Button("Check for updates") { Task { await model.check() } }
                    case .available:
                        Text("Update available").fontWeight(.semibold)
                        Button("Update now") { Task { await model.install() } }
                            .buttonStyle(.borderedProminent)
                    case .installing:
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Updating, about a minute…") }
                        Text(lastLine).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    case .installed:
                        Text("Installed. Reopen to use it.").fontWeight(.semibold)
                        Button("Reopen Bino") { model.reopen() }.buttonStyle(.borderedProminent)
                    case .failed(let why):
                        Text("Update check failed").foregroundStyle(.secondary)
                        Text(why).font(.caption2).foregroundStyle(.tertiary).lineLimit(3).help(why)
                        Button("Try again") { Task { await model.check() } }
                    }
                } else {
                    Text("Not built with make install, so it cannot update itself.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Updates")
    }

    private var lastLine: String {
        model.log.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}
