import AppKit
import SwiftUI

/// 菜单栏管理（ui-design.md §4）：
/// 左键 → Popover（主要入口）；右键 → NSMenu（完整功能 + 退出）。
@MainActor
final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    /// 菜单动作回调（由 AppEnvironment 绑定）
    var onRegionCapture: (() -> Void)?
    var onFullscreenCapture: (() -> Void)?
    var onWindowCapture: (() -> Void)?
    var onDelayedCapture: (() -> Void)?
    var onRecordRegion: (() -> Void)?
    var onRecordRegionGIF: (() -> Void)?
    var onRecordFullscreen: (() -> Void)?
    var onRecordWindow: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onAbout: (() -> Void)?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "CaptureKit")
            button.image?.isTemplate = true
            button.toolTip = "CaptureKit"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        Log.app.info("Menu bar ready")
    }

    func teardown() {
        closePopover()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - 点击分发

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showMenu()
        default:
            togglePopover()
        }
    }

    // MARK: - Popover

    private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        let p: NSPopover
        if let existing = popover {
            p = existing
        } else {
            p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.contentSize = NSSize(width: 320, height: 360)
            let view = MenuBarPopoverView(
                onRegionCapture: { [weak self] in self?.perform { $0.onRegionCapture?() } },
                onRecordRegion: { [weak self] in self?.perform { $0.onRecordRegion?() } },
                onFullscreenCapture: { [weak self] in self?.perform { $0.onFullscreenCapture?() } },
                onWindowCapture: { [weak self] in self?.perform { $0.onWindowCapture?() } },
                onDelayedCapture: { [weak self] in self?.perform { $0.onDelayedCapture?() } },
                onScrollCapture: { [weak self] in self?.perform { $0.onScrollCapture?() } },
                onSettings: { [weak self] in self?.perform { $0.onSettings?() } },
                onQuit: { [weak self] in
                    self?.closePopover()
                    NSApp.terminate(nil)
                }
            )
            p.contentViewController = NSHostingController(rootView: view)
            popover = p
        }
        if let button = statusItem?.button {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    /// 文档截图演示（--demo-popover）：直接弹出 Popover 供 `screencapture` 抓取。
    func showPopoverForDemo() {
        showPopover()
    }

    /// 执行动作前先关闭 Popover（Overlay 全屏窗口需要立即接管交互）。
    private func perform(_ action: (MenuBarManager) -> Void) {
        closePopover()
        action(self)
    }

    // MARK: - 右键菜单

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        menu.addItem(item("区域截图", action: #selector(regionCaptureTapped), keyEquivalent: "a", modifierMask: [.command, .shift]))
        menu.addItem(item("全屏截图（鼠标所在屏幕）", action: #selector(fullscreenCaptureTapped), keyEquivalent: ""))
        menu.addItem(item("窗口截图（单击/双击选择）", action: #selector(windowCaptureTapped), keyEquivalent: ""))
        menu.addItem(item("延时截图…", action: #selector(delayedCaptureTapped), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(item("录制视频（区域）", action: #selector(recordRegionTapped), keyEquivalent: "r", modifierMask: [.command, .shift]))
        menu.addItem(item("录制 GIF（区域）", action: #selector(recordRegionGIFTapped), keyEquivalent: ""))
        menu.addItem(item("录制视频（全屏）", action: #selector(recordFullscreenTapped), keyEquivalent: ""))
        menu.addItem(item("录制窗口（双击选择）", action: #selector(recordWindowTapped), keyEquivalent: ""))
        menu.addItem(item("滚动截图（手动滚动）", action: #selector(scrollCaptureTapped), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(item("设置…", action: #selector(settingsTapped), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(item("检查更新…", action: #selector(checkForUpdatesTapped), keyEquivalent: ""))
        menu.addItem(item("关于 CaptureKit", action: #selector(aboutTapped), keyEquivalent: ""))
        menu.addItem(item("退出 CaptureKit", action: #selector(quitTapped), keyEquivalent: "q"))

        menu.popUp(positioning: nil, at: .zero, in: button)
    }

    private func item(_ title: String, action: Selector, keyEquivalent: String, modifierMask: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.target = self
        menuItem.keyEquivalentModifierMask = modifierMask
        return menuItem
    }

    // MARK: - 动作

    @objc private func regionCaptureTapped() { onRegionCapture?() }
    @objc private func fullscreenCaptureTapped() { onFullscreenCapture?() }
    @objc private func windowCaptureTapped() { onWindowCapture?() }
    @objc private func delayedCaptureTapped() { onDelayedCapture?() }
    @objc private func recordRegionTapped() { onRecordRegion?() }
    @objc private func recordRegionGIFTapped() { onRecordRegionGIF?() }
    @objc private func recordFullscreenTapped() { onRecordFullscreen?() }
    @objc private func recordWindowTapped() { onRecordWindow?() }
    @objc private func scrollCaptureTapped() { onScrollCapture?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func checkForUpdatesTapped() { onCheckForUpdates?() }
    @objc private func aboutTapped() { onAbout?() }
    @objc private func quitTapped() { NSApp.terminate(nil) }
}
