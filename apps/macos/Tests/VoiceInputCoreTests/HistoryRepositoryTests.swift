import Foundation
import XCTest
@testable import VoiceInputCore

final class HistoryRepositoryTests: XCTestCase {
    func testDuplicateRequestAndDeleteAreStable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try HistoryRepository(path: root.appendingPathComponent("history.sqlite3"))
        let row = TranscriptionRecord(id: "same-request", createdAt: Date(), text: "测试正文",
            audioDurationMS: 500, inferenceMS: 20, endToEndMS: 550, modelID: "mock",
            hotwordsEnabled: false, hotwordCount: 0, clipboardStatus: .written,
            pasteStatus: .skipped, skipReason: "focus_changed")
        try await repository.insert(row); try await repository.insert(row)
        XCTAssertEqual(try await repository.page().count, 1)
        try await repository.delete(id: row.id)
        try await repository.updateOutput(id: row.id, clipboard: .written, paste: .attempted, skipReason: nil)
        XCTAssertTrue(try await repository.page().isEmpty)
    }

    func testSearchAndHotwordDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try HistoryRepository(path: root.appendingPathComponent("history.sqlite3"))
        let row = TranscriptionRecord(id: "one", createdAt: Date(), text: "FastAPI 项目",
            audioDurationMS: 1, inferenceMS: nil, endToEndMS: nil, modelID: "mock",
            hotwordsEnabled: true, hotwordCount: 1, clipboardStatus: .written,
            pasteStatus: .attempted, skipReason: nil)
        try await repository.insert(row)
        XCTAssertEqual(try await repository.page(search: "FastAPI").count, 1)
        XCTAssertTrue(try await repository.page(search: "不存在").isEmpty)
        try await repository.addHotwords([" FastAPI ", "", "FastAPI"])
        XCTAssertEqual(try await repository.hotwords().map(\.text), ["FastAPI"])
    }
}

