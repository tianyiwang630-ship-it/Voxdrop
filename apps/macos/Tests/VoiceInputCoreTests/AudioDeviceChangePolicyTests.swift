import XCTest
@testable import VoiceInputCore

final class AudioDeviceChangePolicyTests: XCTestCase {
    private let policy = AudioDeviceChangePolicy()

    func testConnectedDeviceNeverCancelsOrRestartsShortcuts() {
        XCTAssertEqual(
            policy.decide(kind: .connected, eventDeviceID: "aggregate",
                          activeInputDeviceID: "microphone", state: .recording(.hold)),
            AudioSystemEventDecision(cancelRecording: false, restartShortcuts: false)
        )
    }

    func testOnlyActiveMicrophoneDisconnectionCancelsRecording() {
        XCTAssertEqual(
            policy.decide(kind: .disconnected, eventDeviceID: "microphone",
                          activeInputDeviceID: "microphone", state: .recording(.toggle)),
            AudioSystemEventDecision(cancelRecording: true, restartShortcuts: false)
        )
        XCTAssertFalse(policy.decide(kind: .disconnected, eventDeviceID: "other",
                                     activeInputDeviceID: "microphone", state: .recording(.hold)).cancelRecording)
    }

    func testMicrophoneDisconnectionDoesNotCancelAfterRecording() {
        XCTAssertFalse(policy.decide(kind: .disconnected, eventDeviceID: "microphone",
                                     activeInputDeviceID: "microphone", state: .transcribing).cancelRecording)
    }

    func testWakeCancelsRecordingAndRestartsShortcuts() {
        XCTAssertEqual(
            policy.decide(kind: .wake, eventDeviceID: nil,
                          activeInputDeviceID: "microphone", state: .recording(.hold)),
            AudioSystemEventDecision(cancelRecording: true, restartShortcuts: true)
        )
        XCTAssertEqual(
            policy.decide(kind: .wake, eventDeviceID: nil,
                          activeInputDeviceID: nil, state: .ready),
            AudioSystemEventDecision(cancelRecording: false, restartShortcuts: true)
        )
    }
}
