import AppKit
import Foundation

struct ShortcutDefinition: Codable, Equatable {
    var keyCode: Int64
    var control: Bool
    var option: Bool
    var command: Bool
    var shift: Bool

    static let defaultHold = ShortcutDefinition(keyCode: 49, control: true, option: true, command: false, shift: false)
    static let defaultToggle = ShortcutDefinition(keyCode: 49, control: true, option: true, command: true, shift: false)
    var cgFlags: CGEventFlags {
        var value: CGEventFlags = []
        if control { value.insert(.maskControl) }; if option { value.insert(.maskAlternate) }
        if command { value.insert(.maskCommand) }; if shift { value.insert(.maskShift) }
        return value
    }
    var display: String {
        var value = ""; if control { value += "⌃" }; if option { value += "⌥" }
        if shift { value += "⇧" }; if command { value += "⌘" }
        let names: [Int64: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete"]
        return value + (names[keyCode] ?? "Key\(keyCode)")
    }
    static func from(_ event: NSEvent) -> ShortcutDefinition {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return ShortcutDefinition(keyCode: Int64(event.keyCode), control: flags.contains(.control),
            option: flags.contains(.option), command: flags.contains(.command), shift: flags.contains(.shift))
    }
}

protocol ShortcutDelegate: AnyObject {
    func holdChanged(isDown: Bool)
    func togglePressed()
    func escapePressed()
}

final class ShortcutService {
    weak var delegate: ShortcutDelegate?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var holdIsDown = false
    var holdShortcut = ShortcutDefinition.defaultHold
    var toggleShortcut = ShortcutDefinition.defaultToggle

    func start() throws {
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            throw NSError(domain: "VoiceInput.Shortcut", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "已请求输入监控权限；授权后请退出并重新打开 VoiceInput"])
        }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw NSError(domain: "VoiceInput.Shortcut", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "已请求辅助功能权限；授权后请退出并重新打开 VoiceInput"])
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
                let service = Unmanaged<ShortcutService>.fromOpaque(info!).takeUnretainedValue()
                return service.handle(type: type, event: event)
            }, userInfo: opaque) else {
            throw NSError(domain: "VoiceInput.Shortcut", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "系统仍拒绝全局快捷键监听；请确认输入监控和辅助功能均已授权，然后退出并重新打开 App"])
        }
        self.tap = tap; source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout { if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let repeatEvent = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        if code == 53, type == .keyDown, !repeatEvent { delegate?.escapePressed(); return nil }
        if code == holdShortcut.keyCode, flags == holdShortcut.cgFlags {
            if type == .keyDown, !repeatEvent, !holdIsDown { holdIsDown = true; delegate?.holdChanged(isDown: true) }
            if type == .keyUp, holdIsDown { holdIsDown = false; delegate?.holdChanged(isDown: false) }
            return nil
        }
        if code == toggleShortcut.keyCode, flags == toggleShortcut.cgFlags, type == .keyDown, !repeatEvent { delegate?.togglePressed(); return nil }
        // Any key-up for Space closes a lost-modifier hold session.
        if code == holdShortcut.keyCode, type == .keyUp, holdIsDown { holdIsDown = false; delegate?.holdChanged(isDown: false); return nil }
        return Unmanaged.passUnretained(event)
    }
}
