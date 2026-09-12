import XCTest
@testable import VoiceInputCore

@MainActor
private final class FakeOutputState {
    var now: UInt64 = 0
    var clipboard = ""
    var changeCount = 1
    var releaseModifiersAt: UInt64 = 0
    var releaseKeysAt: [Int64: UInt64] = [:]
    var downCount = 0
    var upCount = 0
    var downAt: UInt64?
    var sleepCount = 0
    var throwOnSleep: Int?
    var replaceClipboardOnFirstSleep: String?

    func environment() -> OutputEnvironment {
        OutputEnvironment(
            writeClipboard: { [self] text in clipboard = text; changeCount += 1; return true },
            clipboardChangeCount: { [self] in changeCount },
            clipboardText: { [self] in clipboard },
            accessibilityTrusted: { true },
            modifiersPressed: { [self] in now < releaseModifiersAt },
            keyPressed: { [self] keyCode in now < (releaseKeysAt[keyCode] ?? 0) },
            nowNanoseconds: { [self] in now },
            sleepNanoseconds: { [self] duration in
                sleepCount += 1
                if sleepCount == 1, let replacement = replaceClipboardOnFirstSleep {
                    clipboard = replacement
                    changeCount += 1
                }
                if throwOnSleep == sleepCount { throw CancellationError() }
                now += duration
            },
            makePasteEvents: { [self] in
                PasteEventActions(
                    postDown: { [self] in downCount += 1; downAt = now },
                    postUp: { [self] in upCount += 1 }
                )
            }
        )
    }
}

@MainActor
final class OutputServiceTests: XCTestCase {
    func testImmediateAndDelayedModifierReleaseSendOnce() async {
        let immediate = FakeOutputState()
        let immediateResult = await OutputService(environment: immediate.environment()).deliver(text: "hello")
        XCTAssertEqual(immediateResult.paste, .attempted)
        XCTAssertEqual(immediate.downAt, 60_000_000)
        XCTAssertEqual(immediate.downCount, 1)
        XCTAssertEqual(immediate.upCount, 1)

        let delayed = FakeOutputState()
        delayed.releaseModifiersAt = 200_000_000
        let delayedResult = await OutputService(environment: delayed.environment()).deliver(text: "hello")
        XCTAssertEqual(delayedResult.paste, .attempted)
        XCTAssertEqual(delayed.downAt, 200_000_000)
        XCTAssertEqual(delayed.downCount, 1)
        XCTAssertEqual(delayed.upCount, 1)
    }

    func testModifierTimeoutDoesNotSend() async {
        let state = FakeOutputState()
        state.releaseModifiersAt = .max
        let result = await OutputService(environment: state.environment()).deliver(text: "hello")
        XCTAssertEqual(result.skipReason, "modifiers_timeout")
        XCTAssertEqual(state.now, 500_000_000)
        XCTAssertEqual(state.downCount, 0)
        XCTAssertEqual(state.upCount, 0)
    }

    func testTriggerKeyMustBeReleasedBeforePaste() async {
        let state = FakeOutputState()
        state.releaseKeysAt[0] = 160_000_000
        let result = await OutputService(environment: state.environment())
            .deliver(text: "hello", waitForKeyCodes: [0])
        XCTAssertEqual(result.paste, .attempted)
        XCTAssertEqual(state.downAt, 160_000_000)
        XCTAssertEqual(state.downCount, 1)
        XCTAssertEqual(state.upCount, 1)
    }

    func testSameClipboardTextSurvivesManagerRewrite() async {
        let state = FakeOutputState()
        state.replaceClipboardOnFirstSleep = "hello"
        let result = await OutputService(environment: state.environment()).deliver(text: "hello")
        XCTAssertEqual(result.paste, .attempted)
        XCTAssertEqual(state.downCount, 1)
    }

    func testDifferentClipboardTextPreventsPaste() async {
        let state = FakeOutputState()
        state.replaceClipboardOnFirstSleep = "user copied this"
        let result = await OutputService(environment: state.environment()).deliver(text: "hello")
        XCTAssertEqual(result.skipReason, "clipboard_changed")
        XCTAssertEqual(state.clipboard, "user copied this")
        XCTAssertEqual(state.downCount, 0)
    }

    func testCancellationBeforeSendPostsNoEvents() async {
        let state = FakeOutputState()
        let service = OutputService(environment: state.environment())
        let result = await service.deliver(text: "hello") { state.now < 20_000_000 }
        XCTAssertEqual(result.skipReason, "cancelled")
        XCTAssertEqual(state.downCount, 0)
        XCTAssertEqual(state.upCount, 0)
    }

    func testKeyUpIsPostedWhenCancelledAfterKeyDown() async {
        let state = FakeOutputState()
        state.throwOnSleep = 4
        let result = await OutputService(environment: state.environment()).deliver(text: "hello")
        XCTAssertEqual(result.paste, .attempted)
        XCTAssertEqual(state.downCount, 1)
        XCTAssertEqual(state.upCount, 1)
    }
}
