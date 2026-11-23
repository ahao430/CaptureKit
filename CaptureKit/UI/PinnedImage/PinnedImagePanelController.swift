import AppKit
import CoreGraphics

/// 贴图浮动窗口：截图钉在屏幕原位，置顶显示（批次 3）。
/// 交互（参考钉钉贴图）：拖动移动 · 滚轮缩放 · ⌥+滚轮调透明度 ·
/// 双击还原原始大小 · 悬停显示关闭按钮 · 右键菜单（复制/关闭）。
@MainActor
final class PinnedImagePanelController {
    /// 关闭回调（管理器移除引用）
    var onClose: (() -> Void)?

    private let panel: NSPanel
    private let contentView: PinnedImageView
    private let originalSize: CGSize

    init(image: CGImage, screenRect: CGRect) {
        // 显示尺寸 = 选区逻辑尺寸（图像像素 / 选区 pt 的缩放比已隐含在 screenRect）
        let displaySize = screenRect.size.width > 1 && screenRect.size.height > 1
            ? screenRect.size
            : CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        originalSize = displaySize

        contentView = PinnedImageView(image: image)
        contentView.frame = NSRect(origin: .zero, size: displaySize)

        panel = NSPanel(
            contentRect: NSRect(origin: screenRect.origin, size: displaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = contentView

        contentView.onZoom = { [weak self] delta, isOpacity in
            self?.handleScroll(delta: delta, isOpacity: isOpacity)
        }
        contentView.onResetZoom = { [weak self] in
            self?.resetZoom()
        }
        contentView.onCloseRequested = { [weak self] in
            self?.close()
        }
        contentView.onCopyRequested = { [weak self] in
            guard let self else { return }
            try? ClipboardWriter.copy(self.contentView.image)
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        onClose?()
    }

    // MARK: - 缩放 / 透明度

    private func handleScroll(delta: CGFloat, isOpacity: Bool) {
        if isOpacity {
            contentView.opacity = PinnedImageMath.steppedOpacity(current: contentView.opacity, delta: delta)
            return
        }
        let maxSide = max(NSScreen.main?.frame.width ?? 3000, NSScreen.main?.frame.height ?? 3000) * 1.5
        let newSize = PinnedImageMath.zoomedSize(
            current: panel.frame.size,
            delta: delta,
            maxSide: maxSide
        )
        guard abs(newSize.width - panel.frame.width) > 0.5 || abs(newSize.height - panel.frame.height) > 0.5 else {
            return
        }
        // 以窗口中心为锚缩放
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let newFrame = NSRect(
            x: center.x - newSize.width / 2,
            y: center.y - newSize.height / 2,
            width: newSize.width,
            height: newSize.height
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }

    private func resetZoom() {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setFrame(
            NSRect(
                x: center.x - originalSize.width / 2,
                y: center.y - originalSize.height / 2,
                width: originalSize.width,
                height: originalSize.height
            ),
            display: true,
            animate: false
        )
        contentView.opacity = 1
    }
}

/// 贴图内容视图：绘制图像 + 悬停关闭按钮 + 滚轮事件 + 右键菜单。
@MainActor
final class PinnedImageView: NSView {
    let image: CGImage
    /// 窗口透明度（0.15 ~ 1；由 alphaValue 生效）
    var opacity: CGFloat = 1 {
        didSet { window?.alphaValue = opacity }
    }

    var onZoom: ((CGFloat, Bool) -> Void)?
    var onResetZoom: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onCopyRequested: (() -> Void)?

    private var isHovering = false
    private let closeArea = NSRect(x: 0, y: 0, width: 22, height: 22)

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        // 悬停显隐关闭按钮
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // 图像铺满（内容尺寸始终与图像等比：缩放作用于窗口）
        context.saveGState()
        context.clip(to: bounds)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        context.restoreGState()

        // 细边框
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.stroke(bounds)

        // 悬停时显示左上角关闭按钮
        if isHovering {
            let rect = closeArea.offsetBy(dx: bounds.width - closeArea.width - 6, dy: bounds.height - closeArea.height - 6)
            context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.fillEllipse(in: rect)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let x = NSAttributedString(string: "✕", attributes: attributes)
            x.draw(at: CGPoint(x: rect.midX - x.size().width / 2, y: rect.midY - x.size().height / 2))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // 双击 → 还原原始大小与不透明度
        if event.clickCount >= 2 {
            onResetZoom?()
            return
        }
        // 悬停态点击右上角 ✕ 区域 → 关闭
        if isHovering {
            let rect = closeArea.offsetBy(dx: bounds.width - closeArea.width - 6, dy: bounds.height - closeArea.height - 6)
            if rect.contains(convert(event.locationInWindow, from: nil)) {
                onCloseRequested?()
                return
            }
        }
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // ⌥+滚轮 = 透明度；普通滚轮 = 缩放
        onZoom?(delta, event.modifierFlags.contains(.option))
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制图片", action: #selector(copyAction), keyEquivalent: "")
        copyItem.target = self
        let closeItem = NSMenuItem(title: "关闭贴图", action: #selector(closeAction), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())
        menu.addItem(closeItem)
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func copyAction() { onCopyRequested?() }
    @objc private func closeAction() { onCloseRequested?() }

    /// 双击还原缩放。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
