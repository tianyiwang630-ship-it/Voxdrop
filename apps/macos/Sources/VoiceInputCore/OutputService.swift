import AppKit
import ApplicationServices
import Foundation

public let voiceInputSyntheticEventMarker: Int64 = 0x564F494345494D45

public struct OutputResult: Sendable {
    public let clipboard: ClipboardStatus
    public let paste: PasteStatus
    public let skipReason: String?

    public init(clipboard: ClipboardStatus, paste: PasteStatus, skipReason: String?) {
        self.clipboard = clipboard
        self.paste = paste
        self.skipReason = skipReason
    }
}

public enum OutputDecision: Equatable, Sendable { case attemptPaste, skip(String) }

public struct OutputPolicy: Sendable {
    public init() {}

    public func decide(accessibilityTrusted: Bool, clipboardOwned: Bool,
                       modifiersReleased: Bool) -> OutputDecision {
        guard accessibilityTrusted else { return .skip("permission_missing") }
        guard clipboardOwned else { return .skip("clipboard_changed") }
        guard modifiersReleased else { return .skip("modifiers_timeout") }
        return .attemptPaste
    }
}

@MainActor
public struct PasteEventActions {
    public let postDown: () -> Void
    public let postUp: () -> Void

    public init(postDown: @escaping () -> Void, postUp: @escaping () -> Void) {
        self.postDown = postDown
        self.postUp = postUp
    }
}

@MainActor
public struct OutputEnvironment {
    public var writeClipboard: (String) -> Bool
    public var clipboardChangeCount: () -> Int
    public var clipboardText: () -> String?
    public var accessibilityTrusted: () -> Bool
    public var modifiersPressed: () -> Bool
    public var keyPressed: (Int64) -> Bool
    public var nowNanoseconds: () -> UInt64
    public var sleepNanoseconds: (UInt64) async throws -> Void
    public var makePasteEvents: () -> PasteEventActions?

    public init(writeClipboard: @escaping (String) -> Bool,
                clipboardChangeCount: @escaping () -> Int,
                clipboardText: @escaping () -> String?,
                accessibilityTrusted: @escaping () -> Bool,
                modifiersPressed: @escaping () -> Bool,
                keyPressed: @escaping (Int64) -> Bool,
                nowNanoseconds: @escaping () -> UInt64,
                sleepNanoseconds: @escaping (UInt64) async throws -> Void,
                makePasteEvents: @escaping () -> PasteEventActions?) {
        self.writeClipboard = writeClipboard
        self.clipboardChangeCount = clipboardChangeCount
        self.clipboardText = clipboardText
        self.accessibilityTrusted = accessibilityTrusted
        self.modifiersPressed = modifiersPressed
        self.keyPressed = keyPressed
        self.nowNanoseconds = nowNanoseconds
        self.sleepNanoseconds = sleepNanoseconds
        self.makePasteEvents = makePasteEvents
    }

    public static func live(pasteboard: NSPasteboard = .general) -> OutputEnvironment {
        OutputEnvironment(
            writeClipboard: { text in
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            },
            clipboardChangeCount: { pasteboard.changeCount },
            clipboardText: { pasteboard.string(forType: .string) },
            accessibilityTrusted: { AXIsProcessTrusted() },
            modifiersPressed: {
                !CGEventSource.flagsState(.combinedSessionState)
                    .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                    .isEmpty
            },
            keyPressed: { keyCode in
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
            },
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            sleepNanoseconds: { try await Task.sleep(nanoseconds: $0) },
            makePasteEvents: {
                guard let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    return nil
                }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.setIntegerValueField(.eventSourceUserData, value: voiceInputSyntheticEventMarker)
                up.setIntegerValueField(.eventSourceUserData, value: voiceInputSyntheticEventMarker)
                return PasteEventActions(
                    postDown: { down.post(tap: .cghidEventTap) },
                    postUp: { up.post(tap: .cghidEventTap) }
                )
            }
        )
    }
}

@MainActor
public final class OutputService {
    private static let clipboardPreparationNanoseconds: UInt64 = 60_000_000
    private static let modifierPollNanoseconds: UInt64 = 20_000_000
    private static let modifierTimeoutNanoseconds: UInt64 = 500_000_000
    private static let keyIntervalNanoseconds: UInt64 = 20_000_000

    private let policy = OutputPolicy()
    private var environment: OutputEnvironment

    public init() {
        self.environment = .live()
    }

    public init(environment: OutputEnvironment) {
        self.environment = environment
    }

    public func deliver(text: String, waitForKeyCodes: Set<Int64> = [],
                        isCurrent: @escaping @MainActor () -> Bool = { true }) async -> OutputResult {
        guard environment.writeClipboard(text) else {
            return OutputResult(clipboard: .failed, paste: .skipped, skipReason: "clipboard_failed")
        }
        let ownedChangeCount = environment.clipboardChangeCount()
        let startedAt = environment.nowNanoseconds()
        var elapsed: UInt64 = 0
        var inputPressed = environment.modifiersPressed()
            || waitForKeyCodes.contains(where: environment.keyPressed)

        while elapsed < Self.clipboardPreparationNanoseconds || inputPressed {
            guard !Task.isCancelled, isCurrent() else {
                return OutputResult(clipboard: .written, paste: .skipped, skipReason: "cancelled")
            }
            if elapsed >= Self.modifierTimeoutNanoseconds, inputPressed {
                return OutputResult(clipboard: .written, paste: .skipped, skipReason: "modifiers_timeout")
            }
            let remainingPreparation = Self.clipboardPreparationNanoseconds > elapsed
                ? Self.clipboardPreparationNanoseconds - elapsed : Self.modifierPollNanoseconds
            let interval = min(Self.modifierPollNanoseconds, remainingPreparation)
            do {
                try await environment.sleepNanoseconds(interval)
            } catch {
                return OutputResult(clipboard: .written, paste: .skipped, skipReason: "cancelled")
            }
            elapsed = environment.nowNanoseconds() - startedAt
            inputPressed = environment.modifiersPressed()
                || waitForKeyCodes.contains(where: environment.keyPressed)
        }

        guard !Task.isCancelled, isCurrent() else {
            return OutputResult(clipboard: .written, paste: .skipped, skipReason: "cancelled")
        }
        let clipboardOwned = environment.clipboardChangeCount() == ownedChangeCount
            || environment.clipboardText() == text
        switch policy.decide(accessibilityTrusted: environment.accessibilityTrusted(),
                             clipboardOwned: clipboardOwned,
                             modifiersReleased: !environment.modifiersPressed()
                                && !waitForKeyCodes.contains(where: environment.keyPressed)) {
        case .skip(let reason):
            return OutputResult(clipboard: .written, paste: .skipped, skipReason: reason)
        case .attemptPaste:
            break
        }

        guard let events = environment.makePasteEvents() else {
            return OutputResult(clipboard: .written, paste: .failed, skipReason: "event_creation_failed")
        }
        events.postDown()
        // Once key-down has been posted, key-up must always follow, even if the
        // delivery task is cancelled during this short interval.
        try? await environment.sleepNanoseconds(Self.keyIntervalNanoseconds)
        events.postUp()
        return OutputResult(clipboard: .written, paste: .attempted, skipReason: nil)
    }
}
