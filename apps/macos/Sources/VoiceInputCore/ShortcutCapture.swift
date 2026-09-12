import Foundation

public struct ShortcutChord: Equatable, Sendable {
    public let keyCode: Int64
    public let modifiers: UInt64

    public init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum ShortcutKeyEventType: Sendable { case down, up }

public struct ShortcutKeyEvent: Sendable {
    public let type: ShortcutKeyEventType
    public let keyCode: Int64
    public let modifiers: UInt64
    public let isRepeat: Bool
    public let isVoiceInputSynthetic: Bool

    public init(type: ShortcutKeyEventType, keyCode: Int64, modifiers: UInt64,
                isRepeat: Bool = false, isVoiceInputSynthetic: Bool = false) {
        self.type = type
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.isVoiceInputSynthetic = isVoiceInputSynthetic
    }
}

public enum ShortcutCaptureAction: Equatable, Sendable {
    case none
    case holdBegan(keyCode: Int64)
    case holdEnded(keyCode: Int64)
    case togglePressed(keyCode: Int64)
    case escapePressed
}

public struct ShortcutCaptureDecision: Equatable, Sendable {
    public let consume: Bool
    public let action: ShortcutCaptureAction

    public init(consume: Bool, action: ShortcutCaptureAction = .none) {
        self.consume = consume
        self.action = action
    }
}

public struct ShortcutCaptureState: Sendable {
    private enum Owner: Sendable { case hold, toggle }
    public private(set) var capturedKeyCode: Int64?
    private var owner: Owner?

    public init() {}

    public mutating func handle(_ event: ShortcutKeyEvent, hold: ShortcutChord,
                                toggle: ShortcutChord) -> ShortcutCaptureDecision {
        if event.isVoiceInputSynthetic {
            return ShortcutCaptureDecision(consume: false)
        }

        if event.keyCode == capturedKeyCode {
            if event.type == .up {
                let releasedCode = capturedKeyCode!
                let releasedOwner = owner
                capturedKeyCode = nil
                owner = nil
                return ShortcutCaptureDecision(
                    consume: true,
                    action: releasedOwner == .hold ? .holdEnded(keyCode: releasedCode) : .none
                )
            }
            return ShortcutCaptureDecision(consume: true)
        }

        guard event.type == .down, !event.isRepeat else {
            return ShortcutCaptureDecision(consume: false)
        }
        if event.keyCode == 53 {
            return ShortcutCaptureDecision(consume: true, action: .escapePressed)
        }
        if event.keyCode == hold.keyCode, event.modifiers == hold.modifiers {
            capturedKeyCode = event.keyCode
            owner = .hold
            return ShortcutCaptureDecision(consume: true, action: .holdBegan(keyCode: event.keyCode))
        }
        if event.keyCode == toggle.keyCode, event.modifiers == toggle.modifiers {
            capturedKeyCode = event.keyCode
            owner = .toggle
            return ShortcutCaptureDecision(consume: true, action: .togglePressed(keyCode: event.keyCode))
        }
        return ShortcutCaptureDecision(consume: false)
    }

    public mutating func releaseCapturedKeyIfNeeded() -> ShortcutCaptureAction {
        guard let capturedKeyCode else { return .none }
        let releasedOwner = owner
        self.capturedKeyCode = nil
        owner = nil
        return releasedOwner == .hold ? .holdEnded(keyCode: capturedKeyCode) : .none
    }

    public mutating func reset() {
        capturedKeyCode = nil
        owner = nil
    }
}
