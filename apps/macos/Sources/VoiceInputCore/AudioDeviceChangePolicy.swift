import Foundation

public enum AudioSystemEventKind: String, Sendable {
    case connected = "device_connected"
    case disconnected = "device_disconnected"
    case wake = "system_wake"
}

public struct AudioSystemEventDecision: Equatable, Sendable {
    public let cancelRecording: Bool
    public let restartShortcuts: Bool

    public init(cancelRecording: Bool, restartShortcuts: Bool) {
        self.cancelRecording = cancelRecording
        self.restartShortcuts = restartShortcuts
    }
}

public struct AudioDeviceChangePolicy: Sendable {
    public init() {}

    public func decide(kind: AudioSystemEventKind, eventDeviceID: String?,
                       activeInputDeviceID: String?, state: SessionState) -> AudioSystemEventDecision {
        switch kind {
        case .connected:
            return AudioSystemEventDecision(cancelRecording: false, restartShortcuts: false)
        case .disconnected:
            guard case .recording = state,
                  let eventDeviceID, !eventDeviceID.isEmpty,
                  eventDeviceID == activeInputDeviceID else {
                return AudioSystemEventDecision(cancelRecording: false, restartShortcuts: false)
            }
            return AudioSystemEventDecision(cancelRecording: true, restartShortcuts: false)
        case .wake:
            if case .recording = state {
                return AudioSystemEventDecision(cancelRecording: true, restartShortcuts: true)
            }
            return AudioSystemEventDecision(cancelRecording: false, restartShortcuts: true)
        }
    }
}
