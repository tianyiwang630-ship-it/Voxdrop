import XCTest
@testable import VoiceInputCore

final class SessionEngineTests: XCTestCase {
    func testHoldLifecycle() {
        var engine = SessionEngine(); engine.workerReady()
        XCTAssertTrue(engine.start(.hold, focus: FocusSnapshot(pid: 1, windowToken: "w", elementToken: "e"), generation: 2))
        XCTAssertFalse(engine.start(.toggle, focus: nil, generation: 2))
        XCTAssertFalse(engine.stop(.toggle)); XCTAssertTrue(engine.stop(.hold))
        let id = engine.session!.id
        XCTAssertTrue(engine.beginDelivery(requestID: id, generation: 2))
        engine.finish(); XCTAssertEqual(engine.state, .ready)
    }

    func testCancelRejectsLateResult() {
        var engine = SessionEngine(); engine.workerReady(); _ = engine.start(.toggle, focus: nil, generation: 1)
        _ = engine.stop(.toggle); let id = engine.session!.id; engine.cancel()
        XCTAssertFalse(engine.beginDelivery(requestID: id, generation: 1))
    }

    func testFocusChangeIsSticky() {
        let first = FocusSnapshot(pid: 1, windowToken: "w", elementToken: "a")
        var engine = SessionEngine(); engine.workerReady(); _ = engine.start(.hold, focus: first, generation: 1)
        engine.observeFocus(FocusSnapshot(pid: 1, windowToken: "w", elementToken: "b"))
        engine.observeFocus(FocusSnapshot(pid: 1, windowToken: "w", elementToken: "a"))
        XCTAssertFalse(engine.session!.focusChanged)
        engine.observeFocus(FocusSnapshot(pid: 1, windowToken: "other-window", elementToken: "a"))
        XCTAssertTrue(engine.session!.focusChanged)
    }
}
