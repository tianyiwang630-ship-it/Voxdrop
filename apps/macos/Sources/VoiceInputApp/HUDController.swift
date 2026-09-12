import AppKit
import SwiftUI

@MainActor
final class HUDController {
    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(_ text: String, persistent: Bool = true) {
        dismissTask?.cancel()
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 9) {
                Image(systemName: text.hasPrefix("录音") ? "waveform" : "mic.fill")
                Text(text).font(.system(size: 14, weight: .medium))
            }.padding(.horizontal, 16).frame(width: 220, height: 44)
                .background(.ultraThickMaterial, in: Capsule()))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 110, y: screen.visibleFrame.maxY - 76))
        }
        panel.orderFrontRegardless()
        if !persistent {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2)); guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        }
    }

    func hide() { dismissTask?.cancel(); panel.orderOut(nil) }
}

