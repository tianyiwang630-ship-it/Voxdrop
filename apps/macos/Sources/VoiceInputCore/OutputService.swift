import AppKit
import ApplicationServices
import Foundation

public struct OutputResult: Sendable {
    public let clipboard: ClipboardStatus
    public let paste: PasteStatus
    public let skipReason: String?
}

public enum OutputDecision: Equatable, Sendable { case attemptPaste, skip(String) }

public struct OutputPolicy: Sendable {
    public init() {}
    public func decide(initial: FocusSnapshot?, current: FocusSnapshot?, focusChanged: Bool,
                       accessibilityTrusted: Bool, clipboardOwned: Bool,
                       modifiersReleased: Bool) -> OutputDecision {
        // Delivery intentionally follows the *current* system cursor, matching a
        // physical Command-V. Browser/Electron/WeChat editors often expose unstable
        // or non-standard accessibility nodes, so neither the original focus nor an
        // AX "editable" classification is a reliable prerequisite.
        if let current, current.isSecure { return .skip("secure_field") }
        guard accessibilityTrusted else { return .skip("permission_missing") }
        guard clipboardOwned else { return .skip("clipboard_changed") }
        guard modifiersReleased else { return .skip("modifiers_pressed") }
        return .attemptPaste
    }
}

public final class FocusTracker: @unchecked Sendable {
    public init() {}
    public func capture() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let system = AXUIElementCreateSystemWide(); var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var window: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXWindowAttribute as CFString, &window)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        var valueSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element as! AXUIElement, kAXValueAttribute as CFString, &valueSettable)
        let secure = (subrole as? String) == kAXSecureTextFieldSubrole
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        let editable = valueSettable.boolValue || textRoles.contains(role as? String ?? "")
        return FocusSnapshot(pid: app.processIdentifier,
            windowToken: window.map { String(CFHash($0)) }, elementToken: String(CFHash(element)),
            isSecure: secure, isEditable: editable)
    }
}

public final class OutputService: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let policy = OutputPolicy()
    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public func deliver(text: String, initialFocus: FocusSnapshot?, focusChanged: Bool,
                        currentFocus: FocusSnapshot?) -> OutputResult {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return OutputResult(clipboard: .failed, paste: .skipped, skipReason: "clipboard_failed")
        }
        let ownedChangeCount = pasteboard.changeCount
        // Clipboard managers observe NSPasteboard asynchronously. Give them a brief
        // chance to settle before emitting Command-V, then verify that our payload is
        // still the current clipboard item.
        Thread.sleep(forTimeInterval: 0.06)
        let modifiers = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        switch policy.decide(initial: initialFocus, current: currentFocus, focusChanged: focusChanged,
                             accessibilityTrusted: AXIsProcessTrusted(), clipboardOwned: pasteboard.changeCount == ownedChangeCount,
                             modifiersReleased: modifiers.isEmpty) {
        case .skip(let reason): return OutputResult(clipboard: .written, paste: .skipped, skipReason: reason)
        case .attemptPaste: break
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return OutputResult(clipboard: .written, paste: .failed, skipReason: "event_creation_failed")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Resolve the destination at delivery time (not recording start), then put
        // the shortcut directly on that process' event queue. WeChat uses different
        // editor implementations for normal chats and File Transfer Assistant; the
        // latter can drop a synthetic HID broadcast even though manual paste works.
        guard let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return OutputResult(clipboard: .written, paste: .skipped, skipReason: "focus_unknown")
        }
        down.postToPid(targetPID)
        Thread.sleep(forTimeInterval: 0.02)
        up.postToPid(targetPID)
        return OutputResult(clipboard: .written, paste: .attempted, skipReason: nil)
    }
}
