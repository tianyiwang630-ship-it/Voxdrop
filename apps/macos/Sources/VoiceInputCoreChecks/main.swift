import Foundation
import VoiceInputCore

@main
struct VoiceInputCoreChecks {
    static func main() async throws {
        var engine = SessionEngine(); engine.workerReady()
        precondition(engine.start(.hold, focus: nil, generation: 1))
        precondition(!engine.start(.toggle, focus: nil, generation: 1))
        precondition(!engine.stop(.toggle)); precondition(engine.stop(.hold))
        let requestID = engine.session!.id; engine.cancel()
        precondition(!engine.beginDelivery(requestID: requestID, generation: 1))

        let focus = FocusSnapshot(pid: 1, windowToken: "w", elementToken: "e")
        let decision = OutputPolicy().decide(initial: focus, current: focus, focusChanged: false,
            accessibilityTrusted: true, clipboardOwned: false, modifiersReleased: true)
        precondition(decision == .skip("clipboard_changed"))

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
