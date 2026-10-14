import Foundation

/// Where each tool sits in the window: Main (sidebar and the top toggle) or Other
/// (sidebar only), and in what order. The window's own arrangement, saved as a small
/// file; tools themselves are code.
public struct ToolLayout: Codable, Equatable {
    public enum Section: String, Codable, CaseIterable {
        case main, other
    }

    public var main: [String]
    public var other: [String]
    public var sidebarHidden = false

    public init(main: [String], other: [String] = []) {
        self.main = main
        self.other = other
    }

    /// A file saved before `sidebarHidden` existed has no key for it.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        main = try values.decodeIfPresent([String].self, forKey: .main) ?? []
        other = try values.decodeIfPresent([String].self, forKey: .other) ?? []
        sidebarHidden = try values.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? false
    }

    public func section(of id: String) -> Section? {
        if main.contains(id) { return .main }
        if other.contains(id) { return .other }
        return nil
    }

    public func ids(in section: Section) -> [String] {
        section == .main ? main : other
    }

    /// Puts a tool into a section, before `before` (or at the end), whichever section it
    /// came from. Unknown ids are ignored.
    public mutating func move(_ id: String, to section: Section, before: String? = nil) {
        guard self.section(of: id) != nil, before != id else { return }
        main.removeAll { $0 == id }
        other.removeAll { $0 == id }
        var list = ids(in: section)
        if let before, let at = list.firstIndex(of: before) {
            list.insert(id, at: at)
        } else {
            list.append(id)
        }
        if section == .main { main = list } else { other = list }
    }

    /// Keeps only tools that exist, and puts tools this layout has never seen into Other,
    /// where a new tool starts.
    public func reconciled(with existing: [String]) -> ToolLayout {
        var out = self
        out.main = main.filter { existing.contains($0) }
        out.other = other.filter { existing.contains($0) && !out.main.contains($0) }
        for id in existing where out.section(of: id) == nil { out.other.append(id) }
        return out
    }

    // MARK: On disk

    public static func load(existing: [String], defaults: ToolLayout) -> ToolLayout {
        guard let data = try? Data(contentsOf: BinoPaths.toolsFile),
              let saved = try? JSONDecoder().decode(ToolLayout.self, from: data)
        else { return defaults.reconciled(with: existing) }
        return saved.reconciled(with: existing)
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? BinoPaths.writePrivate(data, to: BinoPaths.toolsFile)
    }
}
