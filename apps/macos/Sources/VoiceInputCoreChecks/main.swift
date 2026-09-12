import Foundation
import VoiceInputCore

@MainActor
private final class OutputCheckState {
    var now: UInt64 = 0
    var text = ""
    var changeCount = 0
    var modifiersUntil: UInt64 = 0
    var keysUntil: [Int64: UInt64] = [:]
    var down = 0
    var up = 0
    var replacement: String?
    var sleepCount = 0
    var throwOnSleep: Int?

    func environment() -> OutputEnvironment {
        OutputEnvironment(
            writeClipboard: { [self] value in text = value; changeCount += 1; return true },
            clipboardChangeCount: { [self] in changeCount },
            clipboardText: { [self] in text },
            accessibilityTrusted: { true },
            modifiersPressed: { [self] in now < modifiersUntil },
            keyPressed: { [self] keyCode in now < (keysUntil[keyCode] ?? 0) },
            nowNanoseconds: { [self] in now },
            sleepNanoseconds: { [self] duration in
                sleepCount += 1
                if throwOnSleep == sleepCount { throw CancellationError() }
                now += duration
                if let replacement {
                    text = replacement
                    changeCount += 1
                    self.replacement = nil
                }
            },
            makePasteEvents: { [self] in
                PasteEventActions(
                    postDown: { [self] in down += 1 },
                    postUp: { [self] in up += 1 }
                )
            }
        )
    }
}

@main
struct VoiceInputCoreChecks {
    @MainActor
    static func main() async throws {
        var engine = SessionEngine(); engine.workerReady()
        precondition(engine.start(.hold, focus: nil, generation: 1))
        precondition(!engine.start(.toggle, focus: nil, generation: 1))
        precondition(!engine.stop(.toggle)); precondition(engine.stop(.hold))
        let requestID = engine.session!.id; engine.cancel()
        precondition(!engine.beginDelivery(requestID: requestID, generation: 1))

        let devicePolicy = AudioDeviceChangePolicy()
        precondition(devicePolicy.decide(
            kind: .connected, eventDeviceID: "aggregate",
            activeInputDeviceID: "microphone", state: .recording(.hold)
        ) == AudioSystemEventDecision(cancelRecording: false, restartShortcuts: false))
        precondition(devicePolicy.decide(
            kind: .disconnected, eventDeviceID: "microphone",
            activeInputDeviceID: "microphone", state: .recording(.toggle)
        ) == AudioSystemEventDecision(cancelRecording: true, restartShortcuts: false))
        precondition(devicePolicy.decide(
            kind: .disconnected, eventDeviceID: "microphone",
            activeInputDeviceID: "microphone", state: .transcribing
        ) == AudioSystemEventDecision(cancelRecording: false, restartShortcuts: false))
        precondition(devicePolicy.decide(
            kind: .wake, eventDeviceID: nil,
            activeInputDeviceID: "microphone", state: .recording(.hold)
        ) == AudioSystemEventDecision(cancelRecording: true, restartShortcuts: true))

        let decision = OutputPolicy().decide(
            accessibilityTrusted: true, clipboardOwned: false, modifiersReleased: true)
        precondition(decision == .skip("clipboard_changed"))

        let normal = OutputCheckState()
        let normalResult = await OutputService(environment: normal.environment()).deliver(text: "正文")
        precondition(normalResult.paste == .attempted)
        precondition(normal.now == 80_000_000)
        precondition(normal.down == 1 && normal.up == 1)

        let delayed = OutputCheckState()
        delayed.modifiersUntil = 200_000_000
        let delayedResult = await OutputService(environment: delayed.environment()).deliver(text: "正文")
        precondition(delayedResult.paste == .attempted)
        precondition(delayed.now == 220_000_000)

        let replaced = OutputCheckState()
        replaced.replacement = "用户复制的新内容"
        let replacedResult = await OutputService(environment: replaced.environment()).deliver(text: "正文")
        precondition(replacedResult.skipReason == "clipboard_changed")
        precondition(replaced.down == 0 && replaced.up == 0)

        let sameTextRewrite = OutputCheckState()
        sameTextRewrite.replacement = "正文"
        let rewrittenResult = await OutputService(environment: sameTextRewrite.environment()).deliver(text: "正文")
        precondition(rewrittenResult.paste == .attempted)
        precondition(sameTextRewrite.down == 1 && sameTextRewrite.up == 1)

        let cancelled = OutputCheckState()
        let cancelledResult = await OutputService(environment: cancelled.environment())
            .deliver(text: "正文") { cancelled.now < 20_000_000 }
        precondition(cancelledResult.skipReason == "cancelled")
        precondition(cancelled.down == 0 && cancelled.up == 0)

        let cancelledAfterDown = OutputCheckState()
        cancelledAfterDown.throwOnSleep = 4
        let afterDownResult = await OutputService(environment: cancelledAfterDown.environment()).deliver(text: "正文")
        precondition(afterDownResult.paste == .attempted)
        precondition(cancelledAfterDown.down == 1 && cancelledAfterDown.up == 1)

        let timedOut = OutputCheckState()
        timedOut.modifiersUntil = .max
        let timeoutResult = await OutputService(environment: timedOut.environment()).deliver(text: "正文")
        precondition(timeoutResult.skipReason == "modifiers_timeout")
        precondition(timedOut.now == 500_000_000)

        let triggerKeyDelayed = OutputCheckState()
        triggerKeyDelayed.keysUntil[0] = 160_000_000
        let triggerKeyResult = await OutputService(environment: triggerKeyDelayed.environment())
            .deliver(text: "正文", waitForKeyCodes: [0])
        precondition(triggerKeyResult.paste == .attempted)
        precondition(triggerKeyDelayed.now == 180_000_000)

        let option: UInt64 = 1 << 19
        let hold = ShortcutChord(keyCode: 0, modifiers: option)
        let toggle = ShortcutChord(keyCode: 1, modifiers: option)
        var shortcut = ShortcutCaptureState()
        precondition(shortcut.handle(
            ShortcutKeyEvent(type: .down, keyCode: 0, modifiers: option),
            hold: hold, toggle: toggle
        ) == ShortcutCaptureDecision(consume: true, action: .holdBegan(keyCode: 0)))
        precondition(shortcut.handle(
            ShortcutKeyEvent(type: .down, keyCode: 0, modifiers: 0, isRepeat: true),
            hold: hold, toggle: toggle
        ) == ShortcutCaptureDecision(consume: true))
        precondition(shortcut.handle(
            ShortcutKeyEvent(type: .up, keyCode: 0, modifiers: 0),
            hold: hold, toggle: toggle
        ) == ShortcutCaptureDecision(consume: true, action: .holdEnded(keyCode: 0)))

        precondition(shortcut.handle(
            ShortcutKeyEvent(type: .down, keyCode: 1, modifiers: option),
            hold: hold, toggle: toggle
        ) == ShortcutCaptureDecision(consume: true, action: .togglePressed(keyCode: 1)))
        precondition(shortcut.handle(
            ShortcutKeyEvent(type: .down, keyCode: 1, modifiers: 0, isRepeat: true),
            hold: hold, toggle: toggle
        ) == ShortcutCaptureDecision(consume: true))
        precondition(shortcut.handle(
            ShortcutKeyEvent(type: .up, keyCode: 1, modifiers: 0),
            hold: hold, toggle: toggle
        ) == ShortcutCaptureDecision(consume: true))
        precondition(shortcut.handle(
            ShortcutKeyEvent(type: .down, keyCode: 9, modifiers: 0,
                             isVoiceInputSynthetic: true),
            hold: hold, toggle: toggle
        ) == ShortcutCaptureDecision(consume: false))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceInputCoreChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try HistoryRepository(path: root.appendingPathComponent("history.sqlite3"))
        let row = TranscriptionRecord(id: "request", createdAt: Date(), text: "正文", audioDurationMS: 1,
            inferenceMS: 2, endToEndMS: 3, modelID: "mock", hotwordsEnabled: false, hotwordCount: 0,
            clipboardStatus: .written, pasteStatus: .skipped, skipReason: "focus_changed")
        try await repository.insert(row); try await repository.insert(row)
        let firstPage = try await repository.page(); precondition(firstPage.count == 1)
        try await repository.delete(id: row.id)
        try await repository.updateOutput(id: row.id, clipboard: .written, paste: .attempted, skipReason: nil)
        let deletedPage = try await repository.page(); precondition(deletedPage.isEmpty)
        print("VoiceInputCoreChecks: passed")
    }
}
