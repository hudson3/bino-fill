import Foundation

public enum MappingSource: String, Codable {
    /// The page itself declares what the field is.
    case declared
    case rules
    case model
    case rulesAndModel = "rules+model"
    /// A line from your note, matched to the field by its wording.
    case notes
    case none
}

public enum LeaveKind: String, Codable {
    case alreadyFilled, yourCall, notPersonal, unsure, nothingSaved, safety, doesNotFit, otherPerson, newPassword
}

public enum PlanDecision: Equatable {
    case type(String)
    case choose(FieldOption)
    /// No vault was opened (dry run): Bino would fill this.
    case wouldFill
    case leave(LeaveKind, String)
}

/// What Bino intends to do with one field, and how sure it is.
public struct FieldPlan {
    public var field: PageField
    public var concept: Concept?
    public var part: Part = .whole
    public var confidence: Double = 0
    public var source: MappingSource = .none
    public var decision: PlanDecision
    public var notes: [String] = []

    public var willFill: Bool {
        switch decision {
        case .type, .choose, .wouldFill: return true
        case .leave: return false
        }
    }
}

public struct MapperSettings {
    // Set from sidecar/bench/RESULTS.md: above 0.90 the model was right 99% of the time,
    // between 0.70 and 0.90 about 9 times in 10, and below 0.70 about 2 times in 3.
    /// At or above this, fill without comment.
    public var fillThreshold = 0.90
    /// At or above this, fill but list it under "check these". Below: leave blank.
    public var flagThreshold = 0.70
    public init() {}
}

/// Builds the text the model sees for a field. Keep in step with field_state() in
/// sidecar/bench/bench.py, which is what the accuracy numbers were measured on.
enum FieldDescriber {
    static func state(_ field: PageField) -> String {
        var lines = ["Web form field."]
        if !field.section.isEmpty { lines.append("Section: " + String(field.section.prefix(80))) }
        let label = field.label.isEmpty ? field.placeholder : field.label
        if !label.isEmpty { lines.append("Label: " + String(label.prefix(120))) }
        if !field.name.isEmpty { lines.append("Name attribute: " + String(field.name.prefix(80))) }
        return lines.joined(separator: "\n")
    }

    static let question = "What information should be entered in this field?"
}

public struct FieldMapper {
    public var settings = MapperSettings()
    public let decider: DecisionMaker?

    public init(decider: DecisionMaker?) {
        self.decider = decider
    }

    private struct Draft {
        var field: PageField
        var hit: RuleHit?
        var concept: Concept?
        var part: Part = .whole
        var confidence: Double = 0
        var source: MappingSource = .none
        var leave: (LeaveKind, String)?
        var notes: [String] = []
    }

    private static let otherPerson = try! NSRegularExpression(
        pattern: #"emergency|guardian|parent|spouse|partner|companion|recipient|gift|beneficiary|(passenger|travell?er|adult|guest|driver|person) ?#? ?([2-9]|two|three|four)|\b(child|infant|minor)\b|second(ary)? (passenger|travell?er|driver|applicant)|additional (passenger|travell?er|driver)|co-?applicant"#,
        options: [.caseInsensitive])

    static let creatingPassword = try! NSRegularExpression(
        pattern: #"create|confirm|re-?enter|re-?type|retype|repeat|new|choose|verify|again"#, options: [.caseInsensitive])

    private static func found(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Classifies every field on the page. With a resolver, also works out the value;
    /// without one (dry run), reports what it would fill.
    public func plan(scan: PageScan, resolver: ValueResolver?) async -> (plans: [FieldPlan], modelNote: String?) {
        var drafts = scan.fields.map { field -> Draft in
            var draft = Draft(field: field)
            if field.readOnly {
                draft.leave = (.alreadyFilled, "the page does not allow this field to be changed")
            } else if field.type == "checkbox" {
                draft.leave = (.yourCall, "tick boxes are left for you to decide")
            } else if field.type == "textarea" {
                draft.leave = (.notPersonal, "free-text box")
            } else {
                draft.hit = FieldRules.classify(field)
            }
            return draft
        }

        // Ask the model about anything the rules could not settle.
        var modelNote: String?
        let askIndexes = drafts.indices.filter { index in
            let draft = drafts[index]
            return draft.leave == nil && (draft.hit == nil || draft.hit?.strength == .weak)
        }
        var answers: [Int: Decision] = [:]
        if !askIndexes.isEmpty {
            if let decider {
                let options = Concept.allCases.map(\.label)
                let requests = askIndexes.map {
                    DecisionRequest(state: FieldDescriber.state(drafts[$0].field), question: FieldDescriber.question,
                                    options: options)
                }
                do {
                    let decisions = try await decider.decide(requests)
                    for (index, decision) in zip(askIndexes, decisions) { answers[index] = decision }
                } catch {
                    modelNote = "\(error)"
                }
            } else {
                modelNote = "the decision model was not used"
            }
        }

        for index in drafts.indices where drafts[index].leave == nil {
            combine(&drafts[index], answer: answers[index])
        }

        applyPageContext(&drafts)
        settleRuns(&drafts)
        markOtherPeople(&drafts)

        let plans = drafts.map { draft -> FieldPlan in
            finish(draft, resolver: resolver)
        }
        return (plans, modelNote)
    }

    /// Merges the rule's view with the model's.
    private func combine(_ draft: inout Draft, answer: Decision?) {
        let modelConcept = answer.flatMap { Concept.from(label: $0.choice) }
        let modelConfidence = answer?.confidence ?? 0

        guard let hit = draft.hit else {
            if let modelConcept {
                draft.concept = modelConcept
                draft.confidence = modelConfidence
                draft.source = .model
            } else {
                draft.leave = (.unsure, "could not tell what this field wants")
            }
            return
        }
        switch hit.strength {
        case .certain:
            draft.concept = hit.concept
            draft.confidence = 0.99
            draft.source = FieldRules.fromAutocomplete(draft.field.autocomplete) != nil ? .declared : .rules
        case .strong:
            draft.concept = hit.concept
            draft.confidence = 0.93
            draft.source = .rules
        case .weak:
            if let modelConcept, modelConcept == hit.concept {
                draft.concept = hit.concept
                draft.confidence = max(modelConfidence, 0.9)
                draft.source = .rulesAndModel
            } else if let modelConcept, modelConfidence >= settings.fillThreshold {
                draft.concept = modelConcept
                // The rule disagreed, so never treat this as a quiet fill.
                draft.confidence = min(modelConfidence, settings.fillThreshold - 0.01)
                draft.source = .model
                draft.notes.append("the label suggested \(hit.concept.displayName); the model chose \(modelConcept.displayName)")
            } else {
                // A weak hint the model did not back: recorded as the best guess, never filled.
                draft.concept = hit.concept
                draft.confidence = 0.6
                draft.source = .rules
                if let modelConcept, modelConcept != hit.concept {
                    draft.notes.append("the model leaned towards \(modelConcept.displayName)")
                }
            }
        }
        if let part = hit.part, draft.concept == hit.concept { draft.part = part }
    }

    private func applyPageContext(_ drafts: inout [Draft]) {
        // Parts for anything the model classified.
        for index in drafts.indices {
            guard let concept = drafts[index].concept, drafts[index].hit?.concept != concept else { continue }
            drafts[index].part = PartRules.part(for: concept, field: drafts[index].field) ?? .whole
        }

        let hasCardNumber = drafts.contains { $0.concept == .cardNumber }
        let passwordIndexes = drafts.indices.filter { drafts[$0].concept == .password }
        let creating = passwordIndexes.count >= 2 || passwordIndexes.contains { index in
            let field = drafts[index].field
            return drafts[index].hit?.newPassword == true
                || Self.found(Self.creatingPassword, in: field.label + " " + field.placeholder + " " + FieldRules.words(field.name))
        }

        for index in drafts.indices {
            guard let concept = drafts[index].concept else { continue }
            let field = drafts[index].field
            let context = (field.section + " " + field.label + " " + FieldRules.nameKey(field)).lowercased()

            if concept == .password, creating {
                drafts[index].leave = (.newPassword, "this looks like creating or confirming a new password, which is left to you")
            }
            // "Security code" with no card on the page is usually a captcha or a texted code.
            if concept == .cardCVV, !hasCardNumber, drafts[index].source != .declared,
               !context.contains("cvv"), !context.contains("cvc"), !context.contains("card") {
                drafts[index].concept = Concept.none
            }
            // A name box inside the card section is the name on the card.
            if concept == .fullName, hasCardNumber, context.contains("card") {
                drafts[index].concept = .cardName
            }
        }
    }

    /// Dates and phone numbers split over neighbouring boxes.
    private func settleRuns(_ drafts: inout [Draft]) {
        var index = 0
        while index < drafts.count {
            guard drafts[index].leave == nil, let concept = drafts[index].concept,
                  concept.isDate || concept == .phone
            else { index += 1; continue }
            var end = index
            while end + 1 < drafts.count, drafts[end + 1].leave == nil, drafts[end + 1].concept == concept,
                  drafts[end + 1].field.section == drafts[index].field.section {
                end += 1
            }
            let run = Array(index...end)
            if run.count > 1 {
                let parts = run.map { drafts[$0].part }
                if concept.isDate {
                    let settled = PartRules.settleDateRun(parts)
                    for (slot, part) in zip(run, settled.parts) { drafts[slot].part = part }
                    if settled.assumed {
                        for slot in run {
                            drafts[slot].notes.append("assumed the boxes are in month, day, year order")
                            drafts[slot].confidence = min(drafts[slot].confidence, settings.fillThreshold - 0.01)
                        }
                    }
                } else {
                    let settled = PartRules.settlePhoneRun(run.map { drafts[$0].field }, parts)
                    for (slot, part) in zip(run, settled) { drafts[slot].part = part }
                }
            }
            index = end + 1
        }
    }

    /// A second set of personal details on one page usually belongs to someone else.
    private func markOtherPeople(_ drafts: inout [Draft]) {
        var firstSection: [String: String] = [:]
        for index in drafts.indices {
            guard drafts[index].leave == nil, let concept = drafts[index].concept, concept != Concept.none else { continue }
            let field = drafts[index].field
            let where_ = field.section + " " + field.label
            let contactish = concept.isPersonal || concept == .phone || concept == .email
            if contactish, Self.found(Self.otherPerson, in: where_) {
                drafts[index].leave = (.otherPerson, "this looks like someone else's details")
                continue
            }
            guard concept.isPersonal else { continue }
            let key = concept.rawValue + "/" + drafts[index].part.rawValue
            if let first = firstSection[key] {
                if first != field.section {
                    drafts[index].leave = (.otherPerson, "a second \(concept.displayName) on this page; it may be for another person")
                }
            } else {
                firstSection[key] = field.section
            }
        }
    }

    private func finish(_ draft: Draft, resolver: ValueResolver?) -> FieldPlan {
        var plan = FieldPlan(field: draft.field, concept: draft.concept, part: draft.part,
                             confidence: draft.confidence, source: draft.source,
                             decision: .leave(.unsure, "could not tell what this field wants"), notes: draft.notes)
        // Your note can answer a box the vault's fields never could ("EIN", "gate code"),
        // or one Bino could not even classify.
        func fromNote() -> Bool {
            guard let resolver, draft.concept != .password, draft.field.type != "password", !draft.field.isChoice,
                  !draft.field.hasValue, !draft.field.readOnly,
                  let hit = NoteLookup.value(for: draft.field, in: resolver.vault.notes)
            else { return false }
            plan.decision = .type(hit.value)
            plan.source = .notes
            if plan.concept == Concept.none { plan.concept = nil }
            plan.notes.append("from the line \"\(hit.label)\" in your note")
            // Worth a look: the note was matched by wording, not by a known kind of field.
            plan.confidence = min(max(plan.confidence, settings.flagThreshold), settings.fillThreshold - 0.01)
            return true
        }
        if let (kind, reason) = draft.leave {
            if kind == .unsure, fromNote() { return plan }
            plan.decision = .leave(kind, reason)
            return plan
        }
        guard let concept = draft.concept else {
            _ = fromNote()
            return plan
        }
        if concept == Concept.none {
            if fromNote() { return plan }
            let isChoice = draft.field.isChoice
            plan.decision = .leave(isChoice ? .yourCall : .notPersonal,
                                   isChoice ? "a choice only you can make" : "not something the vault holds")
            return plan
        }
        if draft.confidence < settings.flagThreshold {
            plan.decision = draft.field.isChoice
                ? .leave(.yourCall, "a choice only you can make")
                : .leave(.unsure, "best guess was \(concept.displayName), but not sure enough to fill it")
            return plan
        }
        if draft.field.hasValue {
            let shown = draft.field.current.isEmpty ? "" : " (\(draft.field.current))"
            plan.decision = .leave(.alreadyFilled, "already had a value\(shown)")
            return plan
        }
        guard let resolver else {
            plan.decision = .wouldFill
            return plan
        }
        let context = (draft.field.section + " " + draft.field.label + " " + FieldRules.nameKey(draft.field)).lowercased()
        let resolved = resolver.resolve(concept, part: draft.part, field: draft.field, billing: context.contains("bill"))
        plan.notes.append(contentsOf: resolved.notes)
        if !resolved.notes.isEmpty { plan.confidence = min(plan.confidence, settings.fillThreshold - 0.01) }
        switch resolved.resolution {
        case .text(let value):
            // Setting a value from outside ignores the box's length limit, so check it here.
            if draft.field.maxLength > 0, value.count > draft.field.maxLength {
                plan.decision = .leave(.doesNotFit, "your \(concept.displayName) is longer than this box allows")
            } else {
                plan.decision = .type(value)
            }
        case .option(let option): plan.decision = .choose(option)
        case .missing(let why):
            if !fromNote() { plan.decision = .leave(.nothingSaved, why) }
        case .blocked(let why): plan.decision = .leave(.safety, why)
        case .unsupported(let why): plan.decision = .leave(.doesNotFit, why)
        }
        return plan
    }
}
