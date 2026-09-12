import Foundation

public struct RuntimeConfiguration: Sendable {
    public let python: URL
    public let projectRoot: URL
    public let modelDirectory: URL
    public let sessionDirectory: URL
    public init(python: URL, projectRoot: URL, modelDirectory: URL, sessionDirectory: URL) {
        self.python = python; self.projectRoot = projectRoot; self.modelDirectory = modelDirectory; self.sessionDirectory = sessionDirectory
    }

    public static func development(projectRoot: URL) -> RuntimeConfiguration {
        let python = RuntimeLocator(projectRoot: projectRoot).developmentPython()
        return RuntimeConfiguration(
            python: python, projectRoot: projectRoot,
            modelDirectory: ModelLocator(projectRoot: projectRoot).developmentModel(),
            sessionDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("com.local.VoxDrop/sessions", isDirectory: true))
    }
}

public struct RuntimeLocator: Sendable {
    public let projectRoot: URL
    public init(projectRoot: URL) { self.projectRoot = projectRoot }
    public func developmentPython() -> URL {
        let candidates = [projectRoot.appendingPathComponent("envs/mlx/.venv/bin/python"),
                          projectRoot.appendingPathComponent(".cache/python/cpython-3.11-macos-aarch64-none/bin/python3")]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) ?? candidates[0]
    }
}

public struct ModelLocator: Sendable {
    public let projectRoot: URL
    public init(projectRoot: URL) { self.projectRoot = projectRoot }
    public func developmentModel() -> URL { projectRoot.appendingPathComponent("models/qwen3-asr/Qwen3-ASR-0.6B-4bit") }
}

public struct WorkerResult: Sendable {
    public let requestID: UUID
    public let text: String
    public let language: String?
    public let inferenceMS: Int
    public let generation: Int
}

public enum WorkerError: Error, LocalizedError {
    case configuration(String), startup(String), protocolViolation(String), remote(String)
    public var errorDescription: String? {
        switch self {
        case .configuration(let value), .startup(let value), .protocolViolation(let value), .remote(let value): return value
        }
    }
}

public actor WorkerClient {
    public private(set) var generation = 0
    private var process: Process?
    private var input: FileHandle?
    private var continuations: [UUID: CheckedContinuation<WorkerResult, Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private let config: RuntimeConfiguration
    private var readerTask: Task<Void, Never>?

    public init(configuration: RuntimeConfiguration) { config = configuration }

    public func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: config.python.path) else { throw WorkerError.configuration("Python runtime 不可执行：\(config.python.path)") }
        guard FileManager.default.fileExists(atPath: config.modelDirectory.path) else { throw WorkerError.configuration("模型目录不存在：\(config.modelDirectory.path)") }
        try FileManager.default.createDirectory(at: config.sessionDirectory, withIntermediateDirectories: true)
        stop(reason: WorkerError.startup("Worker 已重启"))
        generation += 1
        let localGeneration = generation
        let child = Process(); let stdinPipe = Pipe(); let stdoutPipe = Pipe(); let stderrPipe = Pipe()
        child.executableURL = config.python
        child.arguments = ["-m", "voice_input", "--model-dir", config.modelDirectory.path, "--session-root", config.sessionDirectory.path]
        child.currentDirectoryURL = config.projectRoot
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = stderrPipe
        do { try child.run() } catch { throw WorkerError.startup("无法启动 ASR Worker：\(error.localizedDescription)") }
        process = child; input = stdinPipe.fileHandleForWriting
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { FileHandle.standardError.write(data) }
        }
        readerTask = Task { [weak self] in
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    await self?.receive(line: line, generation: localGeneration)
                }
                await self?.failed(WorkerError.startup("ASR Worker 已退出"), generation: localGeneration)
            } catch { await self?.failed(error, generation: localGeneration) }
        }
        // Model load may take time; wait for the explicit ready frame with a bounded poll.
        let deadline = ContinuousClock.now + .seconds(120)
        while process === child && ContinuousClock.now < deadline {
            if child.isRunning, readyGeneration == localGeneration { return }
            if !child.isRunning { throw WorkerError.startup("ASR Worker 启动失败") }
            try await Task.sleep(for: .milliseconds(50))
        }
        stop(reason: WorkerError.startup("模型加载超时")); throw WorkerError.startup("模型加载超时")
    }

    private var readyGeneration: Int?

    public func transcribe(requestID: UUID, audio: URL, hotwords: [String]) async throws -> WorkerResult {
        guard readyGeneration == generation, let input else { throw WorkerError.startup("ASR Worker 尚未就绪") }
        let payload: [String: Any] = ["v": 1, "type": "transcribe", "request_id": requestID.uuidString,
                                      "audio_path": audio.path, "hotwords": hotwords, "language": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= 1_048_576 else { throw WorkerError.protocolViolation("请求超过协议上限") }
        let requestGeneration = generation
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
            timeoutTasks[requestID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.timeout(requestID: requestID, generation: requestGeneration)
            }
            do { try input.write(contentsOf: data + Data([0x0a])) }
            catch { timeoutTasks.removeValue(forKey: requestID)?.cancel(); continuations.removeValue(forKey: requestID)?.resume(throwing: error) }
        }
    }

    public func cancelAndRestart() async throws { stop(reason: CancellationError()); try await start() }

    public func stop(reason: Error = CancellationError()) {
        readerTask?.cancel(); readerTask = nil; input?.closeFile(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; readyGeneration = nil
        let pending = continuations; continuations.removeAll()
        for task in timeoutTasks.values { task.cancel() }; timeoutTasks.removeAll()
        for continuation in pending.values { continuation.resume(throwing: reason) }
    }

    private func receive(line: String, generation incomingGeneration: Int) {
        guard incomingGeneration == generation, let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["v"] as? Int == 1, let type = message["type"] as? String else { return }
        if type == "ready" { readyGeneration = incomingGeneration; return }
        guard let rawID = message["request_id"] as? String, let id = UUID(uuidString: rawID),
              let continuation = continuations.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if type == "result", let text = message["text"] as? String {
            continuation.resume(returning: WorkerResult(requestID: id, text: text,
                language: message["language"] as? String, inferenceMS: message["inference_ms"] as? Int ?? 0,
                generation: incomingGeneration))
        } else {
            continuation.resume(throwing: WorkerError.remote(message["message"] as? String ?? "ASR Worker 错误"))
        }
    }

    private func failed(_ error: Error, generation incomingGeneration: Int) {
        guard incomingGeneration == generation else { return }
        readyGeneration = nil
        let pending = continuations; continuations.removeAll()
        for task in timeoutTasks.values { task.cancel() }; timeoutTasks.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
    }

    private func timeout(requestID: UUID, generation incomingGeneration: Int) {
        guard incomingGeneration == generation, continuations[requestID] != nil else { return }
        stop(reason: WorkerError.remote("本地识别超过 120 秒，Worker 已停止"))
    }
}
