import XCTest
@testable import VoiceInputCore

final class OutputPolicyTests: XCTestCase {
    let policy = OutputPolicy()

    func testEligibleOutputAttemptsPaste() {
        XCTAssertEqual(policy.decide(accessibilityTrusted: true, clipboardOwned: true,
                                     modifiersReleased: true), .attemptPaste)
    }

    func testClipboardChangesSkipPaste() {
        XCTAssertEqual(policy.decide(accessibilityTrusted: true, clipboardOwned: false,
                                     modifiersReleased: true), .skip("clipboard_changed"))
    }

    func testPermissionAndHeldModifierSkipPaste() {
        XCTAssertEqual(policy.decide(accessibilityTrusted: false, clipboardOwned: true,
                                     modifiersReleased: true), .skip("permission_missing"))
        XCTAssertEqual(policy.decide(accessibilityTrusted: true, clipboardOwned: true,
                                     modifiersReleased: false), .skip("modifiers_timeout"))
    }
}
