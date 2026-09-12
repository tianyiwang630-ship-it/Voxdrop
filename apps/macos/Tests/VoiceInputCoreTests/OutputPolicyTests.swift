import XCTest
@testable import VoiceInputCore

final class OutputPolicyTests: XCTestCase {
    let policy = OutputPolicy()
    let focus = FocusSnapshot(pid: 1, windowToken: "window", elementToken: "editor")

    func testEligibleOutputAttemptsPaste() {
        XCTAssertEqual(policy.decide(initial: focus, current: focus, focusChanged: false,
            accessibilityTrusted: true, clipboardOwned: true, modifiersReleased: true), .attemptPaste)
        let recreatedWebEditor = FocusSnapshot(pid: 1, windowToken: "window", elementToken: "new-editor")
        XCTAssertEqual(policy.decide(initial: focus, current: recreatedWebEditor, focusChanged: false,
            accessibilityTrusted: true, clipboardOwned: true, modifiersReleased: true), .attemptPaste)
    }

    func testCurrentCursorWinsAndClipboardChangesSkipPaste() {
        XCTAssertEqual(policy.decide(initial: focus, current: focus, focusChanged: true,
            accessibilityTrusted: true, clipboardOwned: true, modifiersReleased: true), .attemptPaste)
        XCTAssertEqual(policy.decide(initial: focus, current: nil, focusChanged: true,
            accessibilityTrusted: true, clipboardOwned: true, modifiersReleased: true), .attemptPaste)
        XCTAssertEqual(policy.decide(initial: focus, current: focus, focusChanged: false,
            accessibilityTrusted: true, clipboardOwned: false, modifiersReleased: true), .skip("clipboard_changed"))
    }

    func testSecureFieldAndHeldModifierSkipPaste() {
        let secure = FocusSnapshot(pid: 1, windowToken: "window", elementToken: "password", isSecure: true)
        XCTAssertEqual(policy.decide(initial: secure, current: secure, focusChanged: false,
            accessibilityTrusted: true, clipboardOwned: true, modifiersReleased: true), .skip("secure_field"))
        XCTAssertEqual(policy.decide(initial: focus, current: focus, focusChanged: false,
            accessibilityTrusted: true, clipboardOwned: true, modifiersReleased: false), .skip("modifiers_pressed"))
    }
}
