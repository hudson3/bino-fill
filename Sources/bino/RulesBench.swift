import BinoCore
import Foundation

/// Replays the labelled field set through the real mapper. Model answers come from a
/// results file written by sidecar/bench/bench.py, so this runs in seconds.
struct RulesBench {
    let dataPath: String
    let modelPath: String?
    let split: String
    let showErrors: Bool

    struct Row: Codable {
        var source: String
        var file: String
        var section: String
        var name: String
        var label: String
        var expected: String
        var predicted: String?
        var confidence: Double?
    }

    struct ModelFile: Codable {
        var model: String
        var median_ms: Double
        var rows: [Row]
    }

    /// Answers from the saved model run, looked up by field.
    struct Replay: DecisionMaker {
        var answers: [String: Decision]

        func decide(_ requests: [DecisionRequest]) async throws -> [Decision] {
            requests.map { answers[$0.state] ?? Decision(choice: Concept.none.label, confidence: 0) }
        }
    }

    /// Stable half-and-half split by site, so rules tuned on one half are judged on the other.
    static func isDev(_ row: Row) -> Bool {
        let key = row.file.isEmpty ? row.name : row.file
        var hash: UInt32 = 5381
        for byte in key.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return hash % 2 == 0
    }

    static func stateText(_ row: Row) -> String {
        var lines = ["Web form field."]
        if !row.section.isEmpty { lines.append("Section: " + String(row.section.prefix(80))) }
        if !row.label.isEmpty { lines.append("Label: " + String(row.label.prefix(120))) }
        if !row.name.isEmpty { lines.append("Name attribute: " + String(row.name.prefix(80))) }
        return lines.joined(separator: "\n")
    }

    func run() async throws {
        var rows: [Row]
        var replay: Replay?
        var modelName = "none"
        var medianMs = 0.0
        if let modelPath {
            let file = try JSONDecoder().decode(ModelFile.self, from: Data(contentsOf: URL(fileURLWithPath: modelPath)))
            rows = file.rows
            modelName = file.model
            medianMs = file.median_ms
            var answers: [String: Decision] = [:]
            for row in rows {
                guard let predicted = row.predicted, let concept = Concept(rawValue: predicted) else { continue }
                answers[Self.stateText(row)] = Decision(choice: concept.label, confidence: row.confidence ?? 0)
            }
            replay = Replay(answers: answers)
        } else {
            let text = try String(contentsOfFile: dataPath, encoding: .utf8)
            rows = try text.split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        }
        switch split {
        case "dev": rows = rows.filter(Self.isDev)
        case "test": rows = rows.filter { !Self.isDev($0) }
        default: break
        }

        let mapper = FieldMapper(decider: replay)
        let settings = mapper.settings
        var total = 0, correct = 0, modelCalls = 0
        var quiet = 0, quietWrong = 0, flagged = 0, flaggedWrong = 0, leftUnsure = 0, leftRight = 0, missed = 0
        var ruleCovered = 0, ruleRight = 0
        var bySource: [String: (n: Int, right: Int)] = [:]
        var mistakes: [String] = []

        // Fields from the same site are mapped together, as they would be on a real page.
        var pages: [[Row]] = []
        var pageIndex: [String: Int] = [:]
        for row in rows {
            if row.file.isEmpty {
                pages.append([row])
            } else if let index = pageIndex[row.file] {
                pages[index].append(row)
            } else {
                pageIndex[row.file] = pages.count
                pages.append([row])
            }
        }

        for page in pages {
            let fields = page.enumerated().map { index, row in
                // A distinct section per field stops the "second traveller" rule firing on sampled rows.
                PageField(id: String(index), name: row.name, label: row.label, section: row.section)
            }
            let result = await mapper.plan(scan: PageScan(url: "https://example.com", fields: fields), resolver: nil)
            for (row, plan) in zip(page, result.plans) {
                if let hit = FieldRules.classify(plan.field), hit.strength != .weak {
                    ruleCovered += 1
                    if hit.concept.rawValue == row.expected { ruleRight += 1 }
                } else {
                    modelCalls += 1
                }
                var got = plan.concept?.rawValue ?? "none"
                var wouldFill = plan.willFill
                // Sampled rows repeat the same kind of field; on a real page that rule is right.
                if case .leave(.otherPerson, _) = plan.decision { wouldFill = true }
                if case .leave(.newPassword, _) = plan.decision { got = "password" }
                // Near-equivalents that put the same value in the box.
                let same = got == row.expected
                    || Set([got, row.expected]) == Set(["card_name", "full_name"])
                total += 1
                if same { correct += 1 }
                var entry = bySource[row.source] ?? (0, 0)
                entry.n += 1
                if same { entry.right += 1 }
                bySource[row.source] = entry

                if wouldFill, plan.confidence >= settings.fillThreshold {
                    quiet += 1
                    if !same { quietWrong += 1 }
                } else if wouldFill {
                    flagged += 1
                    if !same { flaggedWrong += 1 }
                } else {
                    leftUnsure += 1
                    if row.expected == "none" || same { leftRight += 1 } else { missed += 1 }
                }
                if !same, showErrors {
                    let how = wouldFill ? (plan.confidence >= settings.fillThreshold ? "QUIET" : "flag ") : "left "
                    mistakes.append("\(how) exp=\(row.expected) got=\(got) \(plan.source.rawValue) \(String(format: "%.2f", plan.confidence)) name=\(row.name.prefix(40)) label=\(row.label.prefix(50))")
                }
            }
        }

        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(a) / Double(b)) }
        print("fields: \(total)  split: \(split)  model: \(modelName)")
        print("rules alone: decide \(pct(ruleCovered, total)) of fields without the model, right \(pct(ruleRight, ruleCovered)) of the time")
        print("rules + model: right kind of information for \(pct(correct, total)) of fields")
        for (source, entry) in bySource.sorted(by: { $0.key < $1.key }) {
            print("  \(source.padding(toLength: 20, withPad: " ", startingAt: 0)) \(pct(entry.right, entry.n))  (n=\(entry.n))")
        }
        print("what Bino would do:")
        print("  fill quietly     \(pct(quiet, total)) of fields, wrong in \(quietWrong) (\(pct(quietWrong, quiet)))")
        print("  fill and flag    \(pct(flagged, total)) of fields, wrong in \(flaggedWrong) (\(pct(flaggedWrong, flagged)))")
        print("  leave blank      \(pct(leftUnsure, total)) of fields: \(leftRight) rightly, \(missed) it could have filled")
        print("model asked for \(pct(modelCalls, total)) of fields" + (medianMs > 0 ? String(format: " (about %.0f ms each)", medianMs) : ""))
        if showErrors { mistakes.sorted().forEach { print($0) } }
    }
}
