import AppKit
import BinoCore
import Carbon
import SwiftUI

/// The ids of the tools Bino's own code points at.
enum BinoTab: String {
    case fill, vault
}

/// What the one Bino window is showing.
@MainActor
final class AppState: ObservableObject {
    /// The id of the tool showing.
    @Published var tool: String
    /// nil while the vault is locked.
    @Published var editor: EditorModel?
    @Published var unlocking = false
    @Published var unlockProblem = ""
    let fill: FillModel
    let layout = LayoutModel()
    let updates = UpdateModel()
    /// Brings the window forward. Set by the app; does nothing when there is no window.
    var showWindow: () -> Void = {}

    /// Switches tool and brings the window forward.
    func show(_ tab: BinoTab) {
        show(tool: tab.rawValue)
    }

    func show(tool id: String) {
        guard Tools.named(id) != nil else { return }
        tool = id
        showWindow()
    }

    init(tab: BinoTab, fill: FillModel? = nil) {
        self.tool = tab.rawValue
        self.fill = fill ?? FillModel()
        // Nothing to unlock yet: go straight to an empty vault to fill in.
        if !VaultStore.exists { editor = EditorModel(vault: BinoCore.Vault(), isNew: true) }
    }

    func unlockVault() {
        guard editor == nil, !unlocking else { return }
        unlocking = true
        unlockProblem = ""
        Task {
            do {
                let vault = try await Task.detached {
                    try VaultStore.unlock(reason: "open your vault for editing")
                }.value
                editor = EditorModel(vault: vault, isNew: false)
            } catch {
                unlockProblem = "\(error)"
            }
            unlocking = false
        }
    }

    /// Drops the decrypted vault from the window. Returns false if there are unsaved changes.
    @discardableResult
    func lockVault() -> Bool {
        guard let editor, VaultStore.exists else { return true }
        if editor.hasUnsavedChanges { return false }
        self.editor = nil
        return true
    }
}

/// The window: a collapsible sidebar of tools on the left, the Main tools as a toggle
/// along the top, and the chosen tool filling the rest.
struct BinoRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var layout: LayoutModel

    init(state: AppState) {
        self.state = state
        layout = state.layout
    }

    var body: some View {
        HStack(spacing: 0) {
            if !layout.sidebarHidden {
                Sidebar(layout: layout, updates: state.updates, selection: $state.tool)
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { layout.sidebarHidden.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("0", modifiers: .command)
                    .accessibilityLabel(layout.sidebarHidden ? "Show sidebar" : "Hide sidebar")
                    .help("Show or hide the sidebar (Cmd-0)")
                    Spacer()
                    MainToggle(layout: layout, selection: $state.tool)
                    Spacer()
                    // Keeps the toggle centred.
                    Image(systemName: "sidebar.left").hidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if let tool = Tools.named(state.tool) {
                    tool.view(state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No such tool").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
    }
}

@MainActor
final class BinoWindowDelegate: NSObject, NSWindowDelegate, NSApplicationDelegate {
    let state: AppState
    /// Asked to start without the window (`bino app --hidden`).
    let startsHidden: Bool

    init(state: AppState, startsHidden: Bool) {
        self.state = state
        self.startsHidden = startsHidden
    }

    /// True when macOS started Bino as a login item, which should not throw a window at you.
    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventID(keyAELaunchedAsLogInItem)
    }

    /// The Bino window, to close it whichever window or app happens to be in front.
    weak var window: NSWindow?

    @objc func hideToMenuBar(_ sender: Any?) {
        window?.performClose(sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if startsHidden || launchedAtLogin {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            state.showWindow()
        }
    }

    /// True when it is fine to let go of the vault editor.
    private func settleUnsavedChanges() -> Bool {
        guard let editor = state.editor, editor.hasUnsavedChanges else { return true }
        state.show(.vault)
        let alert = NSAlert()
        alert.messageText = "Save your changes to the vault?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return editor.save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        settleUnsavedChanges()
    }

    /// Closing the window ends Bino: there is nothing to keep running without it.
    func windowWillClose(_ notification: Notification) {
        windowAlreadyAsked = true
        NSApplication.shared.terminate(nil)
    }

    /// Closing the window has already asked about unsaved changes; quitting must not ask twice.
    private var windowAlreadyAsked = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowAlreadyAsked || settleUnsavedChanges() ? .terminateNow : .terminateCancel
    }

    /// Opening Bino again brings its window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state.showWindow()
        return false
    }
}

/// Starts the Mac app event loop and shows the Bino window. Must be called directly on
/// the main thread (see RunsOwnEventLoop), never from inside an async task.
@MainActor
enum BinoApp {
    private static var keep: [AnyObject] = []

    /// `unlocked`: a vault already decrypted by the caller, shown straight away on the Vault tab.
    static func run(tab: BinoTab, unlocked: BinoCore.Vault? = nil, hidden: Bool = false) {
        let app = NSApplication.shared
        app.setActivationPolicy(hidden ? .accessory : .regular)

        let state = AppState(tab: tab)
        if let unlocked { state.editor = EditorModel(vault: unlocked, isNew: false) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = BinoPaths.isRedirected ? "Bino (practice)" : "Bino"
        window.contentView = NSHostingView(rootView: BinoRootView(state: state))
        window.isReleasedWhenClosed = false
        let delegate = BinoWindowDelegate(state: state, startsHidden: hidden)
        window.delegate = delegate
        delegate.window = window
        app.delegate = delegate
        app.mainMenu = menu(hideTarget: delegate)
        state.showWindow = {
            app.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        keep = [window, delegate, state]
        window.center()
        // Only the installed app keeps itself level with GitHub; a practice copy is left alone.
        if !BinoPaths.isRedirected { state.updates.start() }
        app.run()
    }

    /// Runs the same code the window's buttons run, without showing a window, then prints
    /// the outcome and exits. `work` starts something; `finished` says when it is over.
    static func runHeadless(timeout: TimeInterval, start: @MainActor @escaping () -> Void,
                            finished: @MainActor @escaping () -> Bool,
                            report: @MainActor @escaping () -> Int32) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let began = Date()
        start()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let waited = Date().timeIntervalSince(began)
                if finished() {
                    print("finished in \(String(format: "%.1f", waited)) s")
                    exit(report())
                }
                if waited > timeout {
                    print("STUCK: not finished after \(Int(timeout)) s")
                    exit(2)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keep.append(timer)
        app.run()
    }

    /// Draws a view into a PNG without putting it on screen.
    static func snapshot<V: View>(_ view: V, size: NSSize, to path: String) -> Bool {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Without an Edit menu, Cmd-V and friends do nothing in a bare app.
    private static func menu(hideTarget: BinoWindowDelegate) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Bino", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        _ = hideTarget
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
