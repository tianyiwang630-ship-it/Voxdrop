import Foundation
import XCTest
@testable import VoiceInputCore

final class RuntimeConfigurationTests: XCTestCase {
    func testReleaseMarkerSelectsBundledApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertFalse(RuntimeConfiguration.isBundledApplication(resourcesDirectory: root))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent("release-manifest.json").path,
            contents: Data("{}".utf8)
        ))
        XCTAssertTrue(RuntimeConfiguration.isBundledApplication(resourcesDirectory: root))
    }

    func testBundledConfigurationUsesOnlyBundleAndSessionPaths() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: resources) }
        let python = resources.appendingPathComponent("runtime/bin/python3.11")
        let model = resources.appendingPathComponent("models/qwen3-asr/Qwen3-ASR-0.6B-4bit")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: python.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        XCTAssertTrue(FileManager.default.createFile(atPath: model.appendingPathComponent("config.json").path, contents: Data()))
        let weights = model.appendingPathComponent("model.safetensors")
        XCTAssertTrue(FileManager.default.createFile(atPath: weights.path, contents: Data()))
        let weightsHandle = try FileHandle(forWritingTo: weights)
        try weightsHandle.truncate(atOffset: 708_236_945)
        try weightsHandle.close()
        let sessions = resources.appendingPathComponent("outside-bundle-sessions")

        let configuration = try RuntimeConfiguration.bundled(
            resourcesDirectory: resources,
            sessionDirectory: sessions
        )

        XCTAssertEqual(configuration.mode, .bundled)
        XCTAssertEqual(configuration.python, python)
        XCTAssertEqual(configuration.projectRoot, resources)
        XCTAssertEqual(configuration.modelDirectory.path, model.path)
        XCTAssertEqual(configuration.sessionDirectory, sessions)
    }

    func testIncompleteBundledRuntimeIsRejected() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        XCTAssertThrowsError(try RuntimeConfiguration.bundled(
            resourcesDirectory: resources,
            sessionDirectory: resources.appendingPathComponent("sessions")
        ))
    }
}
