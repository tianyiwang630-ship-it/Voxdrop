import AppKit
import AVFoundation
import Foundation
import OSLog
import VoiceInputCore

private struct AudioSystemEvent: Sendable {
    let kind: AudioSystemEventKind
    let deviceName: String
    let deviceID: String?
    var source: String { kind.rawValue }

    init(kind: AudioSystemEventKind, notification: Notification? = nil) {
        self.kind = kind
        if let device = notification?.object as? AVCaptureDevice {
            deviceName = device.localizedName
            deviceID = device.uniqueID
        } else {
            deviceName = "none"
            deviceID = nil
        }
    }
}

@MainActor
final class AppModel: ObservableObject, ShortcutDelegate {
    @Published var stateText = "启动中"
    @Published var errorText: String?
    @Published var records: [TranscriptionRecord] = []
    @Published var hotwords: [Hotword] = []
    @Published var search = ""
    @Published var bulkHotwords = ""
    @Published var showResultTips = AppModel.loadBool("showResultTips", fallback: true)
    @Published var hotwordsEnabled = AppModel.loadBool("hotwordsEnabled", fallback: true)
    @Published var projectPath = AppModel.loadString("projectPath")
        ?? ProcessInfo.processInfo.environment["VOXDROP_PROJECT_ROOT"]
        ?? ProcessInfo.processInfo.environment["VOICE_INPUT_PROJECT_ROOT"]
        ?? ""
    @Published var holdShortcut = AppModel.loadShortcut("holdShortcut", fallback: .defaultHold)
    @Published var toggleShortcut = AppModel.loadShortcut("toggleShortcut", fallback: .defaultToggle)
    @Published var recordingShortcut: TriggerMode?
    @Published var microphoneName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "未检测到默认麦克风"
    @Published var microphonePermission = "检测中"
    @Published var accessibilityPermission = AXIsProcessTrusted() ? "已授权" : "未授权"
    @Published var inputMonitoringPermission = CGPreflightListenEventAccess() ? "已授权" : "未授权"
    var modelPath: String { URL(fileURLWithPath: projectPath).appendingPathComponent("models/qwen3-asr/Qwen3-ASR-0.6B-4bit").path }
    var dataPath: String { AppIdentity.applicationSupportDirectory.path }
    var logLocation: String { "Console.app → 进程 VoxDrop（Worker stderr 随父进程收集）" }

    private var engine = SessionEngine()
    private let audio = AudioCapture()
    private let output = OutputService()
    private let shortcuts = ShortcutService()
    private let hud = HUDController()
    private var worker: WorkerClient?
    private var history: HistoryRepository?
    private var audioURL: URL?
    private var audioDuration = 0
    private var toggleActive = false
    private var focusTimer: Timer?
    private var recordingLimitTimer: Timer?
    private var deliveryTask: Task<OutputResult, Never>?
    private var deliveryID: UUID?
    private var shortcutMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        migrateLegacyDefaultsIfNeeded()
        migrateLegacyApplicationSupportIfNeeded()
        migrateLegacyDefaultShortcutsIfNeeded()
        shortcuts.delegate = self; shortcuts.holdShortcut = holdShortcut; shortcuts.toggleShortcut = toggleShortcut
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] notification in
            let event = AudioSystemEvent(kind: .connected, notification: notification)
            Task { @MainActor in self?.systemAudioChanged(event) }
        })
        notificationTokens.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] notification in
            let event = AudioSystemEvent(kind: .disconnected, notification: notification)
            Task { @MainActor in self?.systemAudioChanged(event) }
        })
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] notification in
            let event = AudioSystemEvent(kind: .wake, notification: notification)
            Task { @MainActor in self?.systemAudioChanged(event) }
        })
    }

    func launch() {
        guard ProcessInfo.processInfo.machineArchitecture == "arm64" else {
            AppDiagnostics.logger.error("app_launch_blocked launch_id=\(AppDiagnostics.launchID, privacy: .public) reason=architecture")
            engine.block("首版仅支持 Apple Silicon Mac"); publish(); return
        }
        guard !projectPath.isEmpty else {
            AppDiagnostics.logger.error("app_launch_blocked launch_id=\(AppDiagnostics.launchID, privacy: .public) reason=project_path")
            engine.block("请在设置中选择项目目录"); publish(); return
        }
        let root = URL(fileURLWithPath: projectPath, isDirectory: true)
        let support = AppIdentity.applicationSupportDirectory
        do { history = try HistoryRepository(path: support.appendingPathComponent("history.sqlite3")) }
        catch { errorText = "历史数据库无法打开：\(error.localizedDescription)" }
        worker = WorkerClient(configuration: .development(projectRoot: root))
        Task {
            do {
                guard await requestMicrophonePermission() else { microphonePermission = "未授权"; throw WorkerError.configuration("麦克风权限未授权") }
                microphonePermission = "已授权"
                accessibilityPermission = AXIsProcessTrusted() ? "已授权" : "未授权"
                inputMonitoringPermission = CGPreflightListenEventAccess() ? "已授权" : "未授权"
                cleanupStaleSessions(root: root)
                try shortcuts.start()
                try await startWorkerWithRetry()
                engine.workerReady()
                publish(); await reloadAll()
                savePermissionDiagnostics(lastError: nil)
            } catch {
                AppDiagnostics.logger.error("app_launch_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) state=\(self.diagnosticState, privacy: .public)")
                savePermissionDiagnostics(lastError: error.localizedDescription)
                engine.block(error.localizedDescription); publish()
            }
        }
    }

    func retry() {
        cancelPendingDelivery()
        if engine.session != nil {
            let sessionID = engine.session?.id
            engine.cancel()
            audio.cancel(reason: "retry", sessionID: sessionID)
            if let audioURL { cleanup(audioURL) }
            finishTimers()
            engine.finish()
        }
        shortcuts.stop()
        Task { await worker?.stop(); launch() }
    }
    func quit() {
        cancelPendingDelivery()
        Task { await worker?.stop(); NSApplication.shared.terminate(nil) }
    }

    nonisolated func holdChanged(isDown: Bool, keyCode: Int64) {
        Task { @MainActor in
            isDown ? begin(.hold, triggerKeyCode: keyCode, source: "hold_key_down")
                   : end(.hold, source: "hold_key_up")
        }
    }
    nonisolated func togglePressed(keyCode: Int64) { Task { @MainActor in
        if toggleActive { toggleActive = false; end(.toggle, source: "toggle_stop_press") }
        else { toggleActive = true; begin(.toggle, triggerKeyCode: keyCode, source: "toggle_start_press") }
    } }
    nonisolated func escapePressed() { Task { @MainActor in
        cancel(source: "escape")
    } }

    func begin(_ mode: TriggerMode, triggerKeyCode: Int64, source: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AppDiagnostics.logger.warning("session_begin_rejected launch_id=\(AppDiagnostics.launchID, privacy: .public) source=\(source, privacy: .public) reason=microphone_permission")
            engine.block("麦克风权限已撤销，请在系统设置中重新授权"); publish(); return
        }
        Task {
            let generation = await worker?.generation ?? 0
            guard engine.start(mode, focus: nil, generation: generation,
                               triggerKeyCode: triggerKeyCode) else {
                AppDiagnostics.logger.warning("session_begin_rejected launch_id=\(AppDiagnostics.launchID, privacy: .public) source=\(source, privacy: .public) reason=engine_state state=\(self.diagnosticState, privacy: .public)")
                if showResultTips { hud.show("正在处理上一段语音", persistent: false) }; return
            }
            let sessionID = engine.session!.id
            let root = RuntimeConfiguration.development(projectRoot: URL(fileURLWithPath: projectPath)).sessionDirectory
            let url = root.appendingPathComponent("\(engine.session!.id.uuidString).wav")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try audio.start(to: url, sessionID: sessionID); audioURL = url
                focusTimer?.invalidate()
                focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .recording = self.engine.state, let started = self.audio.startedAt {
                            let seconds = Int(Date().timeIntervalSince(started)); self.hud.show(String(format: "录音中 %02d:%02d", seconds / 60, seconds % 60))
                        }
                    }
                }
                recordingLimitTimer?.invalidate()
                recordingLimitTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.end(mode, source: "recording_limit") }
                }
                publish()
            }
            catch {
                AppDiagnostics.logger.error("audio_start_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) session_id=\(AppDiagnostics.sessionID(sessionID), privacy: .public)")
                engine.block("录音启动失败：\(error.localizedDescription)"); errorText = error.localizedDescription; publish()
            }
        }
    }

    func end(_ mode: TriggerMode, source: String) {
        guard engine.stop(mode), let session = engine.session, let url = audioURL else {
            AppDiagnostics.logger.warning("session_end_rejected launch_id=\(AppDiagnostics.launchID, privacy: .public) source=\(source, privacy: .public) mode=\(mode.rawValue, privacy: .public) state=\(self.diagnosticState, privacy: .public)")
            return
        }
        recordingLimitTimer?.invalidate(); recordingLimitTimer = nil
        audioDuration = audio.stop(reason: source, sessionID: session.id); publish()
        Task {
            let words = hotwordsEnabled ? hotwords.filter(\.enabled).map(\.text) : []
            do {
                let result = try await worker!.transcribe(requestID: session.id, audio: url, hotwords: words)
                guard engine.beginDelivery(requestID: result.requestID, generation: result.generation) else {
                    AppDiagnostics.logger.warning("delivery_rejected launch_id=\(AppDiagnostics.launchID, privacy: .public) session_id=\(AppDiagnostics.sessionID(session.id), privacy: .public) state=\(self.diagnosticState, privacy: .public)")
                    finishTimers(); cleanup(url); return
                }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    finishSession(url); return
                }
                let provisional = TranscriptionRecord(id: session.id.uuidString, createdAt: Date(), text: text,
                    audioDurationMS: audioDuration, inferenceMS: result.inferenceMS,
                    endToEndMS: Int(Date().timeIntervalSince(session.startedAt) * 1000), modelID: "qwen3-asr-0.6b-mlx-4bit",
                    hotwordsEnabled: hotwordsEnabled, hotwordCount: words.count,
                    clipboardStatus: .failed, pasteStatus: .skipped, skipReason: "delivery_pending")
                var stored = history != nil
                do { try await history?.insert(provisional) } catch { stored = false }
                let requestID = session.id
                let task = Task { [weak self] in
                    guard let self else {
                        return OutputResult(clipboard: .failed, paste: .skipped, skipReason: "cancelled")
                    }
                    let keysToRelease = Set([session.triggerKeyCode].compactMap { $0 })
                    return await self.output.deliver(text: text, waitForKeyCodes: keysToRelease) { [weak self] in
                        guard let self, let current = self.engine.session else { return false }
                        return current.id == requestID && self.engine.state == .delivering
                    }
                }
                let currentDeliveryID = UUID()
                deliveryID = currentDeliveryID
                deliveryTask = task
                let delivered = await task.value
                if deliveryID == currentDeliveryID {
                    deliveryTask = nil
                    deliveryID = nil
                }
                if stored {
                    do { try await history?.updateOutput(id: session.id.uuidString, clipboard: delivered.clipboard,
                                                        paste: delivered.paste, skipReason: delivered.skipReason) }
                    catch { errorText = "转写已保存，但输出状态更新失败" }
                } else { errorText = "转写已尝试复制，但历史保存失败" }
                guard engine.session?.id == requestID, engine.state == .delivering else {
                    cleanup(url)
                    await reloadHistory()
                    return
                }
                finishSession(url)
                if showResultTips, delivered.skipReason != "cancelled" {
                    hud.show(outputMessage(for: delivered), persistent: false)
                }
                await reloadHistory()
            } catch is CancellationError {
                cleanup(url)
            }
            catch {
                AppDiagnostics.logger.error("transcription_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) session_id=\(AppDiagnostics.sessionID(session.id), privacy: .public)")
                engine.recover(error.localizedDescription); finishTimers(); cleanup(url); publish()
                do { try await startWorkerWithRetry(); engine.workerReady(); publish() }
                catch { engine.block(error.localizedDescription); publish() }
            }
        }
    }

    func cancel(source: String) {
        let sessionID = engine.session?.id
        guard engine.session != nil else { return }
        let wasTranscribing = engine.state == .transcribing
        cancelPendingDelivery()
        engine.cancel(); audio.cancel(reason: source, sessionID: sessionID); if let url = audioURL { cleanup(url) }; toggleActive = false; publish()
        Task {
            if wasTranscribing { try? await worker?.cancelAndRestart() }
            finishTimers(); engine.finish(); publish()
        }
    }

    func reloadAll() async { await reloadHistory(); await reloadHotwords() }
    func reloadHistory() async { do { records = try await history?.page(search: search) ?? [] } catch { errorText = error.localizedDescription } }
    func loadMoreHistory() async {
        guard let last = records.last else { return }
        do { records += try await history?.page(search: search, before: last.createdAt, beforeID: last.id) ?? [] }
        catch { errorText = error.localizedDescription }
    }
    func reloadHotwords() async { do { hotwords = try await history?.hotwords() ?? [] } catch { errorText = error.localizedDescription } }
    func addHotwords() {
        let incoming = bulkHotwords.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let combined = hotwords.map(\.text) + incoming
        guard Set(combined).count <= 128, Set(combined).reduce(0, { $0 + $1.count }) <= 16384 else {
            errorText = "热词预算最多 128 条且总计 16384 字符；本次未添加"; return
        }
        let folded = combined.map { $0.lowercased() }
        if Set(folded).count < Set(combined).count { errorText = "存在仅大小写不同或完全重复的热词，请确认" }
        Task { try? await history?.addHotwords(incoming); bulkHotwords = ""; await reloadHotwords() }
    }
    func toggleHotword(_ item: Hotword) { Task { try? await history?.setHotword(id: item.id, enabled: !item.enabled); await reloadHotwords() } }
    func deleteHotword(_ item: Hotword) { Task { try? await history?.deleteHotword(id: item.id); await reloadHotwords() } }
    func updateHotword(_ item: Hotword, text: String) { Task { do { try await history?.updateHotword(id: item.id, text: text); await reloadHotwords() } catch { errorText = "热词为空或完全重复" } } }
    func deleteRecord(_ item: TranscriptionRecord) { Task { try? await history?.delete(id: item.id); await reloadHistory() } }
    func clearHistory() { Task { try? await history?.deleteAll(); await reloadHistory() } }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); _ = NSPasteboard.general.setString(text, forType: .string) }
    func saveSettings() {
        UserDefaults.standard.set(showResultTips, forKey: "showResultTips")
        UserDefaults.standard.set(hotwordsEnabled, forKey: "hotwordsEnabled")
        UserDefaults.standard.set(projectPath, forKey: "projectPath")
        if let data = try? JSONEncoder().encode(holdShortcut) { UserDefaults.standard.set(data, forKey: "holdShortcut") }
        if let data = try? JSONEncoder().encode(toggleShortcut) { UserDefaults.standard.set(data, forKey: "toggleShortcut") }
        shortcuts.holdShortcut = holdShortcut; shortcuts.toggleShortcut = toggleShortcut
    }

    func recordShortcut(_ mode: TriggerMode) {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        recordingShortcut = mode
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.captureShortcut(event, mode: mode) }; return nil
        }
    }

    func restoreShortcutDefaults() {
        holdShortcut = .defaultHold; toggleShortcut = .defaultToggle; errorText = nil; saveSettings()
    }
    func cancelShortcutRecording() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
        recordingShortcut = nil
    }
    func requestInputMonitoringPermission() {
        let granted = CGRequestListenEventAccess()
        inputMonitoringPermission = CGPreflightListenEventAccess() ? "已授权" : "未授权（授权后需重启 App）"
        if !granted { openPrivacySettings(anchor: "Privacy_ListenEvent", permissionName: "输入监控") }
    }
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityPermission = AXIsProcessTrusted() ? "已授权" : "未授权（授权后需重启 App）"
        if !granted { openPrivacySettings(anchor: "Privacy_Accessibility", permissionName: "辅助功能") }
    }
    func requestMicrophonePermissionFromUI() {
        Task {
            microphonePermission = await requestMicrophonePermission() ? "已授权" : "未授权"
        }
    }
    func refreshPermissionStatus() {
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "已授权" : "未授权"
        accessibilityPermission = AXIsProcessTrusted() ? "已授权" : "未授权"
        inputMonitoringPermission = CGPreflightListenEventAccess() ? "已授权" : "未授权"
    }

    private func captureShortcut(_ event: NSEvent, mode: TriggerMode) {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
        recordingShortcut = nil
        let candidate = ShortcutDefinition.from(event)
        guard candidate.control || candidate.option || candidate.command || candidate.shift else {
            errorText = "快捷键必须包含至少一个修饰键"; return
        }
        guard candidate.keyCode != 53 else { errorText = "Esc 保留用于取消"; return }
        let other = mode == .hold ? toggleShortcut : holdShortcut
        guard candidate != other else { errorText = "Hold 与 Toggle 快捷键不能相同"; return }
        if mode == .hold { holdShortcut = candidate } else { toggleShortcut = candidate }
        errorText = nil; saveSettings()
    }

    private func openPrivacySettings(anchor: String, permissionName: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"),
              NSWorkspace.shared.open(url) else {
            errorText = "无法自动打开\(permissionName)设置，请手动进入系统设置 → 隐私与安全性 → \(permissionName)"
            return
        }
    }

    private static func loadShortcut(_ key: String, fallback: ShortcutDefinition) -> ShortcutDefinition {
        let data = UserDefaults.standard.data(forKey: key)
            ?? UserDefaults(suiteName: AppIdentity.legacyBundleIdentifier)?.data(forKey: key)
        guard let data, let value = try? JSONDecoder().decode(ShortcutDefinition.self, from: data) else { return fallback }
        return value
    }

    private static func loadBool(_ key: String, fallback: Bool) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool { return value }
        if let value = UserDefaults(suiteName: AppIdentity.legacyBundleIdentifier)?.object(forKey: key) as? Bool { return value }
        return fallback
    }

    private static func loadString(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
            ?? UserDefaults(suiteName: AppIdentity.legacyBundleIdentifier)?.string(forKey: key)
    }

    private func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateVoxDropBrandV1"),
              let legacy = UserDefaults(suiteName: AppIdentity.legacyBundleIdentifier) else { return }
        let keys = [
            "showResultTips", "hotwordsEnabled", "projectPath", "holdShortcut", "toggleShortcut",
            "hasShownWelcomeV1", "diagnosticMicrophoneGranted", "diagnosticAccessibilityGranted",
            "diagnosticInputMonitoringGranted", "diagnosticLastStartupError", "diagnosticLastStartupAt"
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "didMigrateVoxDropBrandV1")
    }

    private func migrateLegacyApplicationSupportIfNeeded() {
        let fileManager = FileManager.default
        let source = AppIdentity.legacyApplicationSupportDirectory
        let destination = AppIdentity.applicationSupportDirectory
        guard fileManager.fileExists(atPath: source.path) else { return }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                if !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: item, to: target) }
            }
        } catch {
            errorText = "旧版数据迁移失败：\(error.localizedDescription)"
        }
    }

    private func migrateLegacyDefaultShortcutsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateShortcutDefaultsV1") else { return }
        if holdShortcut == .legacyDefaultHold { holdShortcut = .defaultHold }
        if toggleShortcut == .legacyDefaultToggle { toggleShortcut = .defaultToggle }
        if let data = try? JSONEncoder().encode(holdShortcut) { defaults.set(data, forKey: "holdShortcut") }
        if let data = try? JSONEncoder().encode(toggleShortcut) { defaults.set(data, forKey: "toggleShortcut") }
        defaults.set(true, forKey: "didMigrateShortcutDefaultsV1")
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url); if audioURL == url { audioURL = nil } }
    private var diagnosticState: String {
        switch engine.state {
        case .starting: return "starting"
        case .ready: return "ready"
        case .recording(let mode): return "recording_\(mode.rawValue)"
        case .transcribing: return "transcribing"
        case .delivering: return "delivering"
        case .cancelling: return "cancelling"
        case .blocked: return "blocked"
        case .recovering: return "recovering"
        }
    }
    private func cancelPendingDelivery() {
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveryID = nil
    }
    private func outputMessage(for result: OutputResult) -> String {
        if result.paste == .attempted { return "已发送粘贴" }
        switch result.skipReason {
        case "modifiers_timeout": return "快捷键未松开，已复制，可手动粘贴"
        case "clipboard_changed": return "剪贴板已变化，未自动粘贴"
        default: return "已复制，可按 ⌘V 粘贴"
        }
    }
    private func finishSession(_ url: URL) {
        finishTimers(); engine.finish(); cleanup(url); publish()
    }
    private func finishTimers() { focusTimer?.invalidate(); focusTimer = nil; recordingLimitTimer?.invalidate(); recordingLimitTimer = nil }
    private func startWorkerWithRetry() async throws {
        var lastError: Error = WorkerError.startup("Worker 启动失败")
        for attempt in 0..<3 {
            do {
                try await worker?.start()
                return
            }
            catch {
                AppDiagnostics.logger.warning("worker_start_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) attempt=\(attempt + 1, privacy: .public)")
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(250 * (1 << attempt))) }
            }
        }
        throw lastError
    }
    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }
    private func savePermissionDiagnostics(lastError: String?) {
        let defaults = UserDefaults.standard
        defaults.set(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, forKey: "diagnosticMicrophoneGranted")
        defaults.set(AXIsProcessTrusted(), forKey: "diagnosticAccessibilityGranted")
        defaults.set(CGPreflightListenEventAccess(), forKey: "diagnosticInputMonitoringGranted")
        defaults.set(lastError, forKey: "diagnosticLastStartupError")
        defaults.set(Date(), forKey: "diagnosticLastStartupAt")
    }
    private func cleanupStaleSessions(root: URL) {
        let directory = RuntimeConfiguration.development(projectRoot: root).sessionDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension.lowercased() == "wav" { try? FileManager.default.removeItem(at: item) }
    }
    private func systemAudioChanged(_ event: AudioSystemEvent) {
        let decision = AudioDeviceChangePolicy().decide(
            kind: event.kind,
            eventDeviceID: event.deviceID,
            activeInputDeviceID: audio.activeInputDeviceID,
            state: engine.state
        )
        microphoneName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "未检测到默认麦克风"
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "已授权" : "未授权"
        accessibilityPermission = AXIsProcessTrusted() ? "已授权" : "未授权"
        inputMonitoringPermission = CGPreflightListenEventAccess() ? "已授权" : "未授权"
        if decision.cancelRecording {
            AppDiagnostics.logger.notice("recording_cancelled_by_audio_system launch_id=\(AppDiagnostics.launchID, privacy: .public) source=\(event.source, privacy: .public) device_name=\(event.deviceName, privacy: .private)")
            cancel(source: event.source)
        }
        if decision.restartShortcuts {
            do {
                shortcuts.stop(); try shortcuts.start()
            }
            catch {
                AppDiagnostics.logger.error("shortcut_restart_failed launch_id=\(AppDiagnostics.launchID, privacy: .public) source=\(event.source, privacy: .public)")
                engine.block(error.localizedDescription); publish()
            }
        }
    }
    private func publish() {
        switch engine.state {
        case .starting: stateText = "启动中"
        case .ready: stateText = "Ready"; hud.hide()
        case .recording: stateText = "录音中"; hud.show("录音中 00:00")
        case .transcribing: stateText = "识别中"; hud.show("识别中")
        case .delivering: stateText = "输出中"; hud.show("输出中")
        case .cancelling: stateText = "正在取消"; hud.show("正在取消")
        case .blocked(let reason): stateText = "不可用"; errorText = reason
        case .recovering: stateText = "恢复中"
        }
    }
}
