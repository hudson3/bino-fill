import BinoCore
import SwiftUI

/// A self-contained screen inside Bino that can do a job or jobs.
///
/// A tool has a stable id (what the saved layout points at), a name and an icon for the
/// sidebar, and one view. Tools don't depend on each other; what they share is Bino's
/// common parts. A new tool is a file in this folder and one line in `Tools.all`, and it
/// starts in Other.
struct Tool: Identifiable {
    let id: String
    let name: String
    /// An SF Symbol name.
    let icon: String
    /// Reserved: a tool that also exists elsewhere. Unused in this edition.
    let mobile: Bool
    let view: @MainActor (AppState) -> AnyView

    init<Content: View>(id: String, name: String, icon: String, mobile: Bool = false,
                        @ViewBuilder view: @escaping @MainActor (AppState) -> Content) {
        self.id = id
        self.name = name
        self.icon = icon
        self.mobile = mobile
        self.view = { AnyView(view($0)) }
    }
}

enum Tools {
    static let fill = Tool(id: "fill", name: "Fill", icon: "doc.text") { state in
        FillView(model: state.fill)
    }
    static let vault = Tool(id: "vault", name: "Vault", icon: "lock.shield") { state in
        VaultTool(state: state)
    }

    /// Every tool Bino has. Order here is only the order of first-time defaults.
    static let all: [Tool] = [fill, vault]

    /// Where tools sit the first time Bino runs.
    static let defaultLayout = ToolLayout(main: [fill, vault].map(\.id))

    static func named(_ id: String) -> Tool? {
        all.first { $0.id == id }
    }
}

/// The Vault tool: the editor when unlocked, otherwise the Unlock button.
struct VaultTool: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let editor = state.editor {
            EditorView(model: editor, onLock: VaultStore.exists ? { lock(editor) } : nil)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Your vault is locked").font(.title3)
                Text("Unlock it to see or change what Bino knows about you.").foregroundStyle(.secondary)
                Button(state.unlocking ? "Waiting for Touch ID…" : "Unlock with Touch ID") { state.unlockVault() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(state.unlocking)
                if !state.unlockProblem.isEmpty {
                    Text(state.unlockProblem).foregroundStyle(.red)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func lock(_ editor: EditorModel) {
        if !state.lockVault() {
            editor.status = "Save your changes before locking."
            editor.statusIsProblem = true
        }
    }
}
