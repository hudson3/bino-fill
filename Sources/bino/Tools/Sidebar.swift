import BinoCore
import SwiftUI

/// The window's arrangement of tools, kept on disk whenever it changes.
@MainActor
final class LayoutModel: ObservableObject {
    @Published private(set) var layout: ToolLayout

    init() {
        layout = ToolLayout.load(existing: Tools.all.map(\.id), defaults: Tools.defaultLayout)
    }

    func tools(in section: ToolLayout.Section) -> [Tool] {
        layout.ids(in: section).compactMap(Tools.named)
    }

    var sidebarHidden: Bool {
        get { layout.sidebarHidden }
        set { layout.sidebarHidden = newValue; layout.save() }
    }

    func move(_ id: String, to section: ToolLayout.Section, before: String? = nil) {
        layout.move(id, to: section, before: before)
        layout.save()
    }
}

/// The collapsible list of tools: Main, then Other. Drag a tool to move it, or use its
/// right-click menu. Main tools also appear in the toggle at the top of the window.
struct Sidebar: View {
    @ObservedObject var layout: LayoutModel
    @ObservedObject var updates: UpdateModel
    @Binding var selection: String

    static let width: CGFloat = 190

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    section(.main, title: "Main", hint: "Also in the toggle at the top.")
                    section(.other, title: "Other", hint: "Sidebar only.")
                        .padding(.top, 12)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }
            UpdateStrip(model: updates)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section(_ which: ToolLayout.Section, title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
                .accessibilityLabel("\(title) tools")
            let tools = layout.tools(in: which)
            ForEach(tools) { tool in
                row(tool, in: which)
            }
            // Room to drop a tool at the end of the section, and the hint when it is empty.
            Text(tools.isEmpty ? "Drag a tool here. \(hint)" : hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    layout.move(id, to: which)
                    return true
                }
        }
    }

    private func row(_ tool: Tool, in which: ToolLayout.Section) -> some View {
        let selected = tool.id == selection
        return Button {
            selection = tool.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tool.icon).frame(width: 18)
                Text(tool.name).lineLimit(1)
                Spacer()
                if tool.mobile {
                    Text("M")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.purple, in: Capsule())
                        .help("Also available elsewhere")
                        .accessibilityLabel("on mobile")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.name)
        .accessibilityValue(selected ? "selected" : "")
        .draggable(tool.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != tool.id else { return false }
            layout.move(id, to: which, before: tool.id)
            return true
        }
        .contextMenu {
            let elsewhere: ToolLayout.Section = which == .main ? .other : .main
            Button("Move to \(elsewhere == .main ? "Main" : "Other")") { layout.move(tool.id, to: elsewhere) }
            let ids = layout.layout.ids(in: which)
            if let at = ids.firstIndex(of: tool.id) {
                Button("Move Up") { layout.move(tool.id, to: which, before: ids[at - 1]) }.disabled(at == 0)
                Button("Move Down") {
                    layout.move(tool.id, to: which, before: at + 2 < ids.count ? ids[at + 2] : nil)
                }.disabled(at == ids.count - 1)
            }
        }
    }
}

/// The toggle at the top of the window: the Main tools, with Cmd-1, Cmd-2, … for each.
struct MainToggle: View {
    @ObservedObject var layout: LayoutModel
    @Binding var selection: String

    var body: some View {
        let tools = layout.tools(in: .main)
        HStack(spacing: 2) {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                let selected = tool.id == selection
                let button = Button(tool.name) { selection = tool.id }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 1, y: 1)
                    .contentShape(Rectangle())
                    .accessibilityValue(selected ? "selected" : "")
                if index < 9 {
                    button.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                } else {
                    button
                }
            }
        }
        .padding(2)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main tools")
    }
}
