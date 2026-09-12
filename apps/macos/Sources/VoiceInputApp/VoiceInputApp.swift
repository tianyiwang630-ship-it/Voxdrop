import AppKit
import SwiftUI
import VoiceInputCore

@main
struct VoiceInputApp: App {
    @StateObject private var model: AppModel

    var body: some Scene {
        MenuBarExtra(model.stateText, systemImage: model.stateText == "录音中" ? "waveform.circle.fill" : "mic.circle") {
            MenuContent().environmentObject(model)
        }
        .menuBarExtraStyle(.menu)

        Window("转写历史", id: "history") { HistoryView().environmentObject(model).frame(minWidth: 680, minHeight: 460) }
        Settings { SettingsView().environmentObject(model).frame(width: 620, height: 520) }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let instance = AppModel()
        _model = StateObject(wrappedValue: instance)
        DispatchQueue.main.async { instance.launch() }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.stateText).font(.headline)
        if let error = model.errorText { Text(error).font(.caption).foregroundStyle(.red) }
        Divider()
        Button("打开历史") { openWindow(id: "history"); NSApp.activate(ignoringOtherApps: true) }
        Button("设置") { SettingsWindowController.shared.show(model: model) }
        Button("重试加载") { model.retry() }
        Divider(); Button("退出") { model.quit() }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var controller: NSWindowController?

    func show(model: AppModel) {
        if controller == nil {
            let content = SettingsView().environmentObject(model).frame(width: 620, height: 520)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "VoiceInput 设置"
            window.contentViewController = NSHostingController(rootView: content)
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: TranscriptionRecord?
    @State private var confirmClear = false
    var body: some View {
        NavigationSplitView {
            VStack {
                TextField("搜索正文", text: $model.search).onSubmit { Task { await model.reloadHistory() } }
                List(model.records, selection: $selected) { item in
                    VStack(alignment: .leading) {
                        Text(item.text).lineLimit(2); Text(item.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }.tag(item)
                }
                HStack {
                    Button("清空全部", role: .destructive) { confirmClear = true }; Spacer()
                    Button("加载更多") { Task { await model.loadMoreHistory() } }
                    Button("刷新") { Task { await model.reloadHistory() } }
                }
            }.padding()
        } detail: {
            if let selected {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView { Text(selected.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Text("录音 \(selected.audioDurationMS) ms · 推理 \(selected.inferenceMS ?? 0) ms · \(selected.pasteStatus.rawValue)").font(.caption)
                    HStack { Button("复制") { model.copy(selected.text) }; Button("删除", role: .destructive) { model.deleteRecord(selected); self.selected = nil } }
                }.padding()
            } else { Text("选择一条转写").foregroundStyle(.secondary) }
        }
        .alert("清空全部历史？", isPresented: $confirmClear) { Button("取消", role: .cancel) {}; Button("清空", role: .destructive) { model.clearHistory() } }
        .task { await model.reloadHistory() }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingHotword: Hotword?
    @State private var editedText = ""
    var body: some View {
        TabView {
            Form {
                HStack { Text("Hold（按住）"); Spacer(); Text(model.holdShortcut.display).monospaced(); Button(model.recordingShortcut == .hold ? "请按组合键…" : "录制") { model.recordShortcut(.hold) } }
                HStack { Text("Toggle（按一次开始/再按一次停止）"); Spacer(); Text(model.toggleShortcut.display).monospaced(); Button(model.recordingShortcut == .toggle ? "请按组合键…" : "录制") { model.recordShortcut(.toggle) } }
                Button("恢复默认快捷键") { model.restoreShortcutDefaults() }
                Text("Esc 可取消当前录音或识别").foregroundStyle(.secondary)
                Toggle("显示结果提示", isOn: $model.showResultTips)
                LabeledContent("当前默认麦克风", value: model.microphoneName)
                TextField("项目目录", text: $model.projectPath)
                Button("保存并重试") { model.saveSettings(); model.retry() }
            }.padding().tabItem { Label("通用", systemImage: "gear") }
            VStack {
                Toggle("启用热词", isOn: $model.hotwordsEnabled)
                TextEditor(text: $model.bulkHotwords).border(.secondary).frame(height: 100)
                Button("按行添加") { model.addHotwords() }
                Text("当前 \(model.hotwords.count)/128 条；\(model.hotwords.map(\.text.count).reduce(0, +))/16384 字符。Worker 另以 Qwen tokenizer 精确限制 4096 tokens，不会静默截断。").font(.caption).foregroundStyle(.secondary)
                List(model.hotwords) { item in
                    HStack {
                        Toggle(item.text, isOn: Binding(get: { item.enabled }, set: { _ in model.toggleHotword(item) }))
                        Spacer(); Button("编辑") { editingHotword = item; editedText = item.text }
                        Button("删除") { model.deleteHotword(item) }
                    }
                }
            }.padding().tabItem { Label("热词", systemImage: "text.badge.plus") }
            Form {
                LabeledContent("状态", value: model.stateText)
                LabeledContent("架构", value: ProcessInfo.processInfo.machineArchitecture)
                LabeledContent("麦克风权限", value: model.microphonePermission)
                LabeledContent("辅助功能权限", value: model.accessibilityPermission)
                LabeledContent("输入监控权限", value: model.inputMonitoringPermission)
                LabeledContent("模型路径") { Text(model.modelPath).textSelection(.enabled).lineLimit(2) }
                LabeledContent("数据路径") { Text(model.dataPath).textSelection(.enabled).lineLimit(2) }
                LabeledContent("日志") { Text(model.logLocation).textSelection(.enabled).lineLimit(2) }
                Text(model.errorText ?? "未发现错误").foregroundStyle(model.errorText == nil ? Color.secondary : Color.red)
                Button("重新加载 Worker") { model.retry() }
                Button("请求辅助功能权限") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
                Button("请求输入监控权限") { model.requestInputMonitoringPermission() }
            }.padding().tabItem { Label("诊断", systemImage: "stethoscope") }
        }
        .sheet(item: $editingHotword) { item in
            VStack(spacing: 16) {
                Text("编辑热词").font(.headline); TextField("热词", text: $editedText)
                HStack { Button("取消") { editingHotword = nil }; Button("保存") { model.updateHotword(item, text: editedText); editingHotword = nil } }
            }.padding().frame(width: 360)
        }
        .onDisappear { model.cancelShortcutRecording(); model.saveSettings() }
    }
}

extension ProcessInfo {
    var machineArchitecture: String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
    }
}
