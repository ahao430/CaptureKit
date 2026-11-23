import AppKit

/// 截图前置模式胶囊（DingTalk 式）：顶部悬浮、可拖动。
/// [拖动手柄] 截图 / 滚动截图 / 录屏 / 文字识别；选中项 = 白色圆角卡片 + 黑字。
/// 仅 CaptureCoordinator 的区域截图流程展示（复用 Overlay 的其他协调器不展示）。
@MainActor
final class OverlayModePanel: NSPanel {
    var onIntentChange: ((OverlaySelectionModel.CaptureIntent) -> Void)?

    private let intents: [OverlaySelectionModel.CaptureIntent] = [.screenshot, .scroll, .record, .ocr]
    private var buttons: [OverlaySelectionModel.CaptureIntent: NSButton] = [:]

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 胶囊整体可拖动（按钮点击优先）
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        buildsContent()
    }

    private func buildsContent() {
        // 深色毛玻璃背景
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 52))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        // 细高光描边
        let border = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 52))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        border.layer?.borderWidth = 1
        border.layer?.cornerRadius = 16

        let handle = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动") ?? NSImage())
        handle.contentTintColor = .white
        handle.alphaValue = 0.55
        handle.translatesAutoresizingMaskIntoConstraints = false

        for intent in intents {
            let button = NSButton(title: intent.displayName, target: self, action: #selector(intentTapped(_:)))
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 10
            button.contentTintColor = .white
            button.toolTip = intent.displayName
            button.tag = intents.firstIndex(of: intent) ?? 0
            buttons[intent] = button
        }

        let stack = NSStackView(views: [handle] + intents.map { buttons[$0]! })
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 52))
        container.addSubview(effect)
        container.addSubview(border)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
    }

    // MARK: - 状态

    /// 同步选中态：白色卡片 + 黑字；未选中：白字透明底。
    func reflect(intent: OverlaySelectionModel.CaptureIntent) {
        for (key, button) in buttons {
            let selected = key == intent
            button.layer?.backgroundColor = selected ? NSColor.white.cgColor : NSColor.clear.cgColor
            button.contentTintColor = selected ? .black : .white
        }
    }

    /// 展示在包含鼠标屏幕的顶部（状态栏下方）。
    func showBelowMenuBar(in screen: NSScreen, intent: OverlaySelectionModel.CaptureIntent) {
        reflect(intent: intent)
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 14
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    // MARK: - 动作

    @objc private func intentTapped(_ sender: NSButton) {
        guard intents.indices.contains(sender.tag) else { return }
        let intent = intents[sender.tag]
        reflect(intent: intent)
        onIntentChange?(intent)
    }
}
