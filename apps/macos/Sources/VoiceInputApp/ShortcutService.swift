import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog
import VoiceInputCore

struct ShortcutDefinition: Codable, Equatable {
    var keyCode: Int64
    var control: Bool
    var option: Bool
    var command: Bool
    var shift: Bool

    static let defaultHold = ShortcutDefinition(keyCode: 0, control: false, option: true, command: false, shift: false)
    static let defaultToggle = ShortcutDefinition(keyCode: 1, control: false, option: true, command: false, shift: false)
    static let legacyDefaultHold = ShortcutDefinition(keyCode: 49, control: true, option: true, command: false, shift: false)
    static let legacyDefaultToggle = ShortcutDefinition(keyCode: 49, control: true, option: true, command: true, shift: false)
    var cgFlags: CGEventFlags {
        var value: CGEventFlags = []
        if control { value.insert(.maskControl) }; if option { value.insert(.maskAlternate) }
        if command { value.insert(.maskCommand) }; if shift { value.insert(.maskShift) }
        return value
    }
    var chord: ShortcutChord {
        ShortcutChord(keyCode: keyCode, modifiers: cgFlags.rawValue)
    }
    var display: String {
        var value = ""; if control { value += "⌃" }; if option { value += "⌥" }
        if shift { value += "⇧" }; if command { value += "⌘" }
        return value + Self.keyName(for: keyCode)
    }
    static func from(_ event: NSEvent) -> ShortcutDefinition {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return ShortcutDefinition(keyCode: Int64(event.keyCode), control: flags.contains(.control),
            option: flags.contains(.option), command: flags.contains(.command), shift: flags.contains(.shift))
    }

    private static func keyName(for keyCode: Int64) -> String {
        let specialKeys: [Int64: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End",
            121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = specialKeys[keyCode] { return name }

        guard keyCode >= 0, keyCode <= UInt16.max,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallbackKeyName(for: keyCode)
        }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return fallbackKeyName(for: keyCode) }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = characters.withUnsafeMutableBufferPointer { buffer in
            UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &deadKeyState, buffer.count, &length, buffer.baseAddress!)
        }
        guard status == noErr, length > 0 else { return fallbackKeyName(for: keyCode) }
        let label = String(utf16CodeUnits: characters, count: length).uppercased()
        return label.isEmpty ? fallbackKeyName(for: keyCode) : label
    }

    private static func fallbackKeyName(for keyCode: Int64) -> String {
        let ansiKeys: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`"
        ]
        return ansiKeys[keyCode] ?? "Key \(keyCode)"
    }
}

protocol ShortcutDelegate: AnyObject {
    func holdChanged(isDown: Bool, keyCode: Int64)
    func togglePressed(keyCode: Int64)
    func escapePressed()
}

final class ShortcutService {
    weak var delegate: ShortcutDelegate?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var captureState = ShortcutCaptureState()
    var holdShortcut = ShortcutDefinition.defaultHold
    var toggleShortcut = ShortcutDefinition.defaultToggle

    func start() throws {
        captureState.reset()
        guard CGPreflightListenEventAccess() else {
            AppDiagnostics.logger.error("shortcut_service_start_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) reason=input_monitoring")
            _ = CGRequestListenEventAccess()
            throw NSError(domain: "VoxDrop.Shortcut", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "已请求输入监控权限；授权后请退出并重新打开言落"])
        }
        guard AXIsProcessTrusted() else {
            AppDiagnostics.logger.error("shortcut_service_start_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) reason=accessibility")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw NSError(domain: "VoxDrop.Shortcut", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "已请求辅助功能权限；授权后请退出并重新打开言落"])
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
                let service = Unmanaged<ShortcutService>.fromOpaque(info!).takeUnretainedValue()
                return service.handle(type: type, event: event)
            }, userInfo: opaque) else {
            AppDiagnostics.logger.error("shortcut_service_start_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) reason=event_tap")
            throw NSError(domain: "VoxDrop.Shortcut", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "系统仍拒绝全局快捷键监听；请确认输入监控和辅助功能均已授权，然后退出并重新打开 App"])
        }
        self.tap = tap; source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        captureState.reset()
        tap = nil; source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppDiagnostics.logger.warning("shortcut_tap_disabled launch_id=\(AppDiagnostics.launchID, privacy: .public) type=\(type.rawValue, privacy: .public)")
            recoverCapturedKeyIfReleased()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == voiceInputSyntheticEventMarker
        let keyEvent = ShortcutKeyEvent(
            type: type == .keyUp ? .up : .down,
            keyCode: code,
            modifiers: flags.rawValue,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isVoiceInputSynthetic: synthetic
        )
        let decision = captureState.handle(keyEvent, hold: holdShortcut.chord, toggle: toggleShortcut.chord)
        perform(decision.action)
        return decision.consume ? nil : Unmanaged.passUnretained(event)
    }

    private func recoverCapturedKeyIfReleased() {
        guard let keyCode = captureState.capturedKeyCode,
              !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else { return }
        perform(captureState.releaseCapturedKeyIfNeeded())
    }

    private func perform(_ action: ShortcutCaptureAction) {
        switch action {
        case .holdBegan(let keyCode): delegate?.holdChanged(isDown: true, keyCode: keyCode)
        case .holdEnded(let keyCode): delegate?.holdChanged(isDown: false, keyCode: keyCode)
        case .togglePressed(let keyCode): delegate?.togglePressed(keyCode: keyCode)
        case .escapePressed: delegate?.escapePressed()
        case .none: break
        }
    }

}
