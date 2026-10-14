import XCTest
@testable import BinoCore

/// Main and Other: where tools sit in the window.
final class ToolLayoutTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bino-test-\(UUID().uuidString)")
        setenv("BINO_HOME", home.path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        unsetenv("BINO_HOME")
    }

    private let defaults = ToolLayout(main: ["orange", "fill", "vault", "voice"])

    func testMovingBetweenAndWithinSections() {
        var layout = defaults
        layout.move("vault", to: .other)
        XCTAssertEqual(layout.main, ["orange", "fill", "voice"])
        XCTAssertEqual(layout.other, ["vault"])
        layout.move("voice", to: .other, before: "vault")
        XCTAssertEqual(layout.other, ["voice", "vault"])
        layout.move("vault", to: .main, before: "orange")
        XCTAssertEqual(layout.main, ["vault", "orange", "fill"])
        layout.move("fill", to: .main, before: "fill")
        XCTAssertEqual(layout.main, ["vault", "orange", "fill"], "moving a tool before itself changes nothing")
        layout.move("nothing", to: .main)
        XCTAssertEqual(layout.section(of: "nothing"), nil)
    }

    func testANewToolStartsInOtherAndAGoneToolDisappears() {
        var layout = defaults
        layout.move("voice", to: .other)
        let now = layout.reconciled(with: ["orange", "fill", "voice", "grok"])
        XCTAssertEqual(now.main, ["orange", "fill"])
        XCTAssertEqual(now.other, ["voice", "grok"])
    }

    func testTheArrangementIsKept() throws {
        var layout = defaults
        layout.move("fill", to: .other)
        layout.sidebarHidden = true
        layout.save()
        let back = ToolLayout.load(existing: ["orange", "fill", "vault", "voice"], defaults: defaults)
        XCTAssertEqual(back, layout)
        // Nothing saved yet: the defaults, with anything new in Other.
        try FileManager.default.removeItem(at: BinoPaths.toolsFile)
        let fresh = ToolLayout.load(existing: ["orange", "fill", "vault", "voice", "grok"], defaults: defaults)
        XCTAssertEqual(fresh.main, defaults.main)
        XCTAssertEqual(fresh.other, ["grok"])
        XCTAssertFalse(fresh.sidebarHidden)
    }
}
