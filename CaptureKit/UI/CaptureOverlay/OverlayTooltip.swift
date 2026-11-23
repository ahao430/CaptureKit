import AppKit

/// 工具栏自定义悬浮提示：显示在按钮**上方**、字号更大（系统默认 tooltip 位置偏下且小）。
/// 鼠标穿透（ignoresMouseEvents），层级高于截图 Overlay。
@MainActor
enum OverlayTooltip {
    private static var panel: NSPanel?
    private static var label: NSTextField?

    static func show(_ text: String, above view: NSView) {
        guard !text.isEmpty, let window = view.window else { return }
        let panel = ensurePanel()
        let label = Self.label!

        label.stringValue = text
        let textSize = label.sizeThatFits(NSSize(width: 400, height: 40))
        let size = NSSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 10)
        let content = panel.contentView!
        content.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        label.frame = NSRect(x: 10, y: 5, width: size.width - 20, height: size.height - 10)
        content.layer?.cornerRadius = 6

        // 按钮屏幕 rect → 提示置于其正上方；顶部放不下则放到下方
        let buttonFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = CGPoint(x: buttonFrame.midX - size.width / 2, y: buttonFrame.maxY + 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonFrame.origin) }) {
            let visible = screen.visibleFrame
            if origin.y + size.height > visible.maxY {
                origin.y = buttonFrame.minY - size.height - 6
            }
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    static func hide() {
        panel?.orderOut(nil)
    }

    private static func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        content.layer?.cornerRadius = 6

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(label)

        panel.contentView = content
        self.panel = panel
        self.label = label
        return panel
    }
}
