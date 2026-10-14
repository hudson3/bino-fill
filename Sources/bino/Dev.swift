import AppKit
import ArgumentParser
import BinoCore
import Foundation
import SwiftUI

/// Tools for measuring and testing Bino itself.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Developer tools.", shouldDisplay: false, subcommands: [SortNote.self, Rules.self, SnapshotEditor.self, EditorSelfTest.self, FillSelfTest.self, MakeIcon.self])

    struct SortNote: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sort-note", abstract: "Run auto-sort on a text file and list which fields it would fill.")

        @Argument var file: String

        func run() async throws {
            let note = try String(contentsOfFile: file, encoding: .utf8)
            var vault = BinoCore.Vault()
            do {
                let started = Date()
                let parsed = NoteParser.parse(note)
                let added = NoteParser.apply(parsed, to: &vault)
                say("Rules: \(added) logins in \(String(format: "%.3f", Date().timeIntervalSince(started))) s; sites guessed for: \(parsed.guessedSites)")
                var touched: [String] = []
                if NoteParser.isWorthReading(parsed.leftover) {
                    let modelStart = Date()
                    let suggestion = try await NoteSorter().sort(note: parsed.leftover)
                    touched = NoteSorter.apply(suggestion, to: &vault)
                    say("Model: read \(parsed.leftover.components(separatedBy: .newlines).count) leftover lines in \(String(format: "%.1f", Date().timeIntervalSince(modelStart))) s")
                } else {
                    say("Model: not needed")
                }
                say("Would fill \(touched.count) entries: " + touched.joined(separator: ", "))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                say(String(data: try encoder.encode(vault), encoding: .utf8) ?? "")
            } catch {
                fail("\(error)")
            }
        }
    }

    struct Rules: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Score the fixed rules, alone and combined with saved model answers, on the labelled field set.")

        @Option(help: "Path to fields.jsonl") var data: String
        @Option(help: "Path to a model results file from bench.py") var model: String?
        @Option(help: "dev, test or all") var split = "all"
        @Flag(help: "List the mistakes") var showErrors = false

        func run() async throws {
            try await RulesBench(dataPath: data, modelPath: model, split: split, showErrors: showErrors).run()
        }
    }

    struct SnapshotEditor: RunsOwnEventLoop {
        static let configuration = CommandConfiguration(
            commandName: "snapshot-editor", abstract: "Draw the Vault tab with made-up data into a PNG, without showing it.")

        @Argument var output: String

        func run() throws {
            let ok: Bool = MainActor.assumeIsolated {
                _ = NSApplication.shared
                let state = AppState(tab: .vault)
                let model = EditorModel(vault: .sample, isNew: false)
                model.vault.notes = "Name: Alex Jordan Rivera\nborn March 14 1990\n..."
                model.status = "Saved and encrypted. 1 logins, 1 cards."
                state.editor = model
                return BinoApp.snapshot(BinoRootView(state: state), size: NSSize(width: 1040, height: 900), to: output)
            }
            guard ok else { fail("Could not draw the window.") }
            say("Wrote \(output)")
        }
    }

    struct EditorSelfTest: RunsOwnEventLoop {
        static let configuration = CommandConfiguration(
            commandName: "editor-selftest",
            abstract: "Run the Vault tab's auto-sort on a text file the way the button does, without showing a window.")

        @Argument var file: String

        func run() throws {
            guard BinoPaths.isRedirected else { fail("Set BINO_HOME to a practice folder first.") }
            let note = try String(contentsOfFile: file, encoding: .utf8)
            MainActor.assumeIsolated {
                let model = EditorModel(vault: BinoCore.Vault(), isNew: true)
                model.vault.notes = note
                BinoApp.runHeadless(timeout: 120, start: { model.autoSort() }, finished: { !model.sorting }, report: {
                    print(model.status)
                    return model.statusIsProblem ? 1 : 0
                })
            }
        }
    }

    struct FillSelfTest: RunsOwnEventLoop {
        static let configuration = CommandConfiguration(
            commandName: "fill-selftest",
            abstract: "Run the Fill tab's button against a page in the built-in test browser, without showing a window.")

        @Argument var url: String
        @Flag var thisPage = false
        @Flag var lookOnly = false
        @Option(help: "Also draw the finished Fill tab into this PNG") var snapshot: String?

        func run() throws {
            guard BinoPaths.isRedirected else { fail("Set BINO_HOME to a practice folder first.") }
            guard let address = URL(string: url) else { fail("That address is not valid.") }
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                let driver = WebViewDriver()
                let model = FillModel(makeDriver: { driver })
                model.onlyThisPage = thisPage
                model.lookOnly = lookOnly
                var begun = false
                BinoApp.runHeadless(timeout: 240, start: {
                    Task {
                        try? await driver.load(url: address)
                        model.refreshSite()
                        model.start()
                        begun = true
                    }
                }, finished: { begun && !model.running }, report: {
                    print("site shown: \(model.site)")
                    if !model.problem.isEmpty { print("problem: \(model.problem)") }
                    if let report = model.report { print(report.text(detail: false)) }
                    if let snapshot {
                        let state = AppState(tab: .fill, fill: model)
                        _ = BinoApp.snapshot(BinoRootView(state: state), size: NSSize(width: 1040, height: 1500), to: snapshot)
                    }
                    return model.report == nil ? 1 : 0
                })
            }
        }
    }

    struct MakeIcon: RunsOwnEventLoop {
        static let configuration = CommandConfiguration(commandName: "make-icon", abstract: "Draw the app icon into a 1024px PNG.")

        @Argument var output: String

        func run() throws {
            let ok: Bool = MainActor.assumeIsolated {
                _ = NSApplication.shared
                let icon = ZStack {
                    RoundedRectangle(cornerRadius: 230, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.22), Color(red: 0.05, green: 0.07, blue: 0.10)],
                                             startPoint: .top, endPoint: .bottom))
                        .padding(100)
                    VStack(spacing: 46) {
                        ForEach(0..<3, id: \.self) { row in
                            HStack(spacing: 40) {
                                RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.22)).frame(width: row == 1 ? 300 : 380, height: 84)
                                Image(systemName: "checkmark.circle.fill").resizable().frame(width: 84, height: 84)
                                    .foregroundStyle(row == 2 ? Color.orange : Color.green)
                            }
                            .frame(width: 520, alignment: .leading)
                        }
                    }
                }
                .frame(width: 1024, height: 1024)
                let hosting = NSHostingView(rootView: icon)
                hosting.frame = NSRect(x: 0, y: 0, width: 1024, height: 1024)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.backingType = .buffered
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return false }
                bitmap.size = NSSize(width: 1024, height: 1024)
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
                return (try? data.write(to: URL(fileURLWithPath: output))) != nil
            }
            guard ok else { fail("Could not draw the icon.") }
            say("Wrote \(output)")
        }
    }
}
