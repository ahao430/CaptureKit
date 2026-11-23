import AppKit
import ServiceManagement
import SwiftUI

/// 设置窗口（AppKit 托管 + SwiftUI 内容）。
@MainActor
final class SettingsWindowController {
    private let store: SettingsStore
    private let history: HistoryService?
    private var window: NSWindow?
    private var updateCoordinator: UpdateCoordinator?

    var windowRef: NSWindow? { window }

    init(store: SettingsStore, history: HistoryService? = nil) {
        self.store = store
        self.history = history
    }

    func attach(updater: UpdateCoordinator) {
        updateCoordinator = updater
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsRootView()
            .environmentObject(store)
            .environment(\.historyService, history)
            .environment(\.updateCoordinator, updateCoordinator)
        let hosting = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hosting)
        window.title = "CaptureKit 设置"
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.setContentSize(NSSize(width: 480, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// 登录启动（SMAppService，macOS 13+）。
enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.settings.info("Launch at login set to \(enabled)")
        } catch {
            // 开发期 ad-hoc 签名可能注册失败；记录日志，不崩溃
            Log.settings.error("Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}
