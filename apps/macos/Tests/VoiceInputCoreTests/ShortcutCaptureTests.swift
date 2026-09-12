import XCTest
@testable import VoiceInputCore

final class ShortcutCaptureTests: XCTestCase {
    private let option: UInt64 = 1 << 19
    private var hold: ShortcutChord { ShortcutChord(keyCode: 0, modifiers: option) }
    private var toggle: ShortcutChord { ShortcutChord(keyCode: 1, modifiers: option) }

    func testHoldConsumesRepeatAndKeyUpAfterModifierReleasedFirst() {
        var state = ShortcutCaptureState()
        XCTAssertEqual(handle(&state, .down, 0, option),
                       ShortcutCaptureDecision(consume: true, action: .holdBegan(keyCode: 0)))
        XCTAssertEqual(handle(&state, .down, 0, 0, isRepeat: true),
                       ShortcutCaptureDecision(consume: true))
        XCTAssertEqual(handle(&state, .up, 0, 0),
                       ShortcutCaptureDecision(consume: true, action: .holdEnded(keyCode: 0)))
        XCTAssertNil(state.capturedKeyCode)
    }

    func testHoldConsumesKeyUpWhenTriggerKeyReleasedFirst() {
        var state = ShortcutCaptureState()
        _ = handle(&state, .down, 0, option)
        XCTAssertEqual(handle(&state, .up, 0, option),
                       ShortcutCaptureDecision(consume: true, action: .holdEnded(keyCode: 0)))
    }

    func testToggleFiresOnceAndConsumesUntilRelease() {
        var state = ShortcutCaptureState()
        XCTAssertEqual(handle(&state, .down, 1, option),
                       ShortcutCaptureDecision(consume: true, action: .togglePressed(keyCode: 1)))
        XCTAssertEqual(handle(&state, .down, 1, 0, isRepeat: true),
                       ShortcutCaptureDecision(consume: true))
        XCTAssertEqual(handle(&state, .up, 1, 0), ShortcutCaptureDecision(consume: true))
    }

    func testCapturedOldKeyIsReleasedEvenAfterShortcutReconfiguration() {
        var state = ShortcutCaptureState()
        _ = handle(&state, .down, 0, option)
        let newHold = ShortcutChord(keyCode: 2, modifiers: option)
        XCTAssertEqual(state.handle(ShortcutKeyEvent(type: .up, keyCode: 0, modifiers: 0),
                                    hold: newHold, toggle: toggle),
                       ShortcutCaptureDecision(consume: true, action: .holdEnded(keyCode: 0)))
    }

    func testTapRecoveryEndsHoldAndSyntheticEventPassesThrough() {
        var state = ShortcutCaptureState()
        _ = handle(&state, .down, 0, option)
        XCTAssertEqual(state.releaseCapturedKeyIfNeeded(), .holdEnded(keyCode: 0))
        XCTAssertEqual(state.releaseCapturedKeyIfNeeded(), .none)
        let synthetic = ShortcutKeyEvent(type: .down, keyCode: 9, modifiers: 1 << 20,
                                         isVoiceInputSynthetic: true)
        XCTAssertEqual(state.handle(synthetic, hold: hold, toggle: toggle),
                       ShortcutCaptureDecision(consume: false))
    }

    private func handle(_ state: inout ShortcutCaptureState, _ type: ShortcutKeyEventType,
                        _ keyCode: Int64, _ modifiers: UInt64,
                        isRepeat: Bool = false) -> ShortcutCaptureDecision {
        state.handle(ShortcutKeyEvent(type: type, keyCode: keyCode, modifiers: modifiers,
                                      isRepeat: isRepeat),
                     hold: hold, toggle: toggle)
    }
}
