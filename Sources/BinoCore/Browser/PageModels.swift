import Foundation

/// One choice in a dropdown or radio group.
public struct FieldOption: Codable, Equatable {
    /// Text the person sees.
    public var t: String
    /// Value the page submits.
    public var v: String
    /// Handle used to select it.
    public var id: String

    public init(t: String, v: String, id: String) {
        self.t = t; self.v = v; self.id = id
    }
}

/// A form control as found on the page. Carries no typed values.
public struct PageField: Codable, Equatable {
    public var id: String
    public var tag: String
    /// text, email, tel, password, select, radio, checkbox, textarea, date, ...
    public var type: String
    public var name: String
    public var domId: String
    public var autocomplete: String
    public var placeholder: String
    public var label: String
    public var section: String
    public var required: Bool
    public var maxLength: Int
    public var pattern: String
    public var hasValue: Bool
    /// Selected option text for dropdowns and radio groups; empty otherwise.
    public var current: String
    public var options: [FieldOption]
    public var frame: Int
    public var readOnly: Bool
    /// The host of the frame the box sits in; empty for the page itself.
    public var origin: String

    public init(id: String, tag: String = "input", type: String = "text", name: String = "", domId: String = "",
                autocomplete: String = "", placeholder: String = "", label: String = "", section: String = "",
                required: Bool = false, maxLength: Int = 0, pattern: String = "", hasValue: Bool = false,
                current: String = "", options: [FieldOption] = [], frame: Int = 0, readOnly: Bool = false,
                origin: String = "") {
        self.id = id; self.tag = tag; self.type = type; self.name = name; self.domId = domId
        self.autocomplete = autocomplete; self.placeholder = placeholder; self.label = label
        self.section = section; self.required = required; self.maxLength = maxLength; self.pattern = pattern
        self.hasValue = hasValue; self.current = current; self.options = options; self.frame = frame
        self.readOnly = readOnly; self.origin = origin
    }

    /// Every key but the id may be missing (an older page script, a test's hand-made JSON).
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(String.self, forKey: .id)
        tag = try v.decodeIfPresent(String.self, forKey: .tag) ?? "input"
        type = try v.decodeIfPresent(String.self, forKey: .type) ?? "text"
        name = try v.decodeIfPresent(String.self, forKey: .name) ?? ""
        domId = try v.decodeIfPresent(String.self, forKey: .domId) ?? ""
        autocomplete = try v.decodeIfPresent(String.self, forKey: .autocomplete) ?? ""
        placeholder = try v.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        label = try v.decodeIfPresent(String.self, forKey: .label) ?? ""
        section = try v.decodeIfPresent(String.self, forKey: .section) ?? ""
        required = try v.decodeIfPresent(Bool.self, forKey: .required) ?? false
        maxLength = try v.decodeIfPresent(Int.self, forKey: .maxLength) ?? 0
        pattern = try v.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        hasValue = try v.decodeIfPresent(Bool.self, forKey: .hasValue) ?? false
        current = try v.decodeIfPresent(String.self, forKey: .current) ?? ""
        options = try v.decodeIfPresent([FieldOption].self, forKey: .options) ?? []
        frame = try v.decodeIfPresent(Int.self, forKey: .frame) ?? 0
        readOnly = try v.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        origin = try v.decodeIfPresent(String.self, forKey: .origin) ?? ""
    }

    public var isChoice: Bool { type == "select" || type == "radio" }

    /// Short name for reports.
    public var displayName: String {
        for candidate in [label, placeholder, name, domId] where !candidate.isEmpty {
            return candidate.count > 60 ? String(candidate.prefix(60)) + "…" : candidate
        }
        return "unnamed \(type) field"
    }
}

public struct PageButton: Codable, Equatable {
    public var id: String
    public var tag: String
    public var type: String
    public var text: String
    public var disabled: Bool
    public var inForm: Bool
    public var primary: Bool
    public var y: Int
    public var frame: Int
    /// The host of the frame the button sits in; empty for the page itself.
    public var origin: String

    public init(id: String, tag: String = "button", type: String = "", text: String, disabled: Bool = false,
                inForm: Bool = true, primary: Bool = false, y: Int = 0, frame: Int = 0, origin: String = "") {
        self.id = id; self.tag = tag; self.type = type; self.text = text; self.disabled = disabled
        self.inForm = inForm; self.primary = primary; self.y = y; self.frame = frame; self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(String.self, forKey: .id)
        tag = try v.decodeIfPresent(String.self, forKey: .tag) ?? "button"
        type = try v.decodeIfPresent(String.self, forKey: .type) ?? ""
        text = try v.decodeIfPresent(String.self, forKey: .text) ?? ""
        disabled = try v.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        inForm = try v.decodeIfPresent(Bool.self, forKey: .inForm) ?? true
        primary = try v.decodeIfPresent(Bool.self, forKey: .primary) ?? false
        y = try v.decodeIfPresent(Int.self, forKey: .y) ?? 0
        frame = try v.decodeIfPresent(Int.self, forKey: .frame) ?? 0
        origin = try v.decodeIfPresent(String.self, forKey: .origin) ?? ""
    }
}

/// A plain link, found only when Bino goes looking for one by its wording.
public struct PageLink: Codable, Equatable {
    public var id: String
    public var text: String
}

/// An embedded frame from another site that Bino cannot see into (or, through the
/// accessibility tree, one it can: then its boxes are in `fields` with this host as
/// their `origin`, and the frame is listed here only while it is still loading).
public struct PageFrame: Codable, Equatable {
    public var host: String
    public var title: String
    public var payment: Bool
    public var section: String
    /// The frame has not finished loading, so its boxes may not be there yet.
    public var loading: Bool

    public init(host: String, title: String = "", payment: Bool = false, section: String = "", loading: Bool = false) {
        self.host = host; self.title = title; self.payment = payment; self.section = section; self.loading = loading
    }

    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        host = try v.decodeIfPresent(String.self, forKey: .host) ?? ""
        title = try v.decodeIfPresent(String.self, forKey: .title) ?? ""
        payment = try v.decodeIfPresent(Bool.self, forKey: .payment) ?? false
        section = try v.decodeIfPresent(String.self, forKey: .section) ?? ""
        loading = try v.decodeIfPresent(Bool.self, forKey: .loading) ?? false
    }
}

public struct PageScan: Codable, Equatable {
    public var url: String
    public var title: String
    public var fields: [PageField]
    public var buttons: [PageButton]
    public var frames: [PageFrame]
    public var errors: [String]
    public var captcha: Bool
    public var signature: String
    /// The visible headings, in page order: what the page says it is asking for.
    public var headings: [String]

    public init(url: String, title: String = "", fields: [PageField] = [], buttons: [PageButton] = [],
                frames: [PageFrame] = [], errors: [String] = [], captcha: Bool = false, signature: String = "",
                headings: [String] = []) {
        self.url = url; self.title = title; self.fields = fields; self.buttons = buttons
        self.frames = frames; self.errors = errors; self.captcha = captcha; self.signature = signature
        self.headings = headings
    }

    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        url = try v.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try v.decodeIfPresent(String.self, forKey: .title) ?? ""
        fields = try v.decodeIfPresent([PageField].self, forKey: .fields) ?? []
        buttons = try v.decodeIfPresent([PageButton].self, forKey: .buttons) ?? []
        frames = try v.decodeIfPresent([PageFrame].self, forKey: .frames) ?? []
        errors = try v.decodeIfPresent([String].self, forKey: .errors) ?? []
        captcha = try v.decodeIfPresent(Bool.self, forKey: .captcha) ?? false
        signature = try v.decodeIfPresent(String.self, forKey: .signature) ?? ""
        headings = try v.decodeIfPresent([String].self, forKey: .headings) ?? []
    }

    /// The text a person reads on the page: title and headings together, for checks
    /// like "is this asking me to trust the browser?".
    public var wording: String { ([title] + headings).joined(separator: " ") }
}
