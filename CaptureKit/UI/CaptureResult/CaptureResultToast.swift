import AppKit
import CoreGraphics

/// 捕获结果浮动提示：缩略图 + 消息，短暂展示后自动关闭。
/// 定位在捕获区域下方（或屏幕底部），不遮挡主要内容。
@MainActor
final class CaptureResultToast {
    private static var currentPanel: NSPanel?
    static var hideWorkItem: DispatchWorkItem?

    static func show(image: CGImage, message: String, anchorRect: CGRect) {
        hide()

        let thumbnailMaxSize = CGSize(width: 160, height: 100)
        let thumbnail = makeThumbnail(image: image, maxSize: thumbnailMaxSize)

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        contentView.layer?.cornerRadius = 12
        contentView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        contentView.layer?.borderWidth = 0.5

        let imageView = NSImageView(image: thumbnail)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let size = NSSize(width: max(220, thumbnail.size.width + label.fittingSize.width + 60), height: 64)
        contentView.frame = NSRect(origin: .zero, size: size)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 44),
        ])

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = contentView
        setFrame(panel: panel, anchorRect: anchorRect)
        panel.orderFrontRegardless()
        currentPanel = panel

        // 自动关闭；鼠标悬停延长展示
        scheduleHide(after: 3.2)
        let trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: ToastHoverObserver.shared,
            userInfo: nil
        )
        contentView.addTrackingArea(trackingArea)
    }

    static func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        currentPanel?.orderOut(nil)
        currentPanel = nil
    }

    static func scheduleHide(after seconds: Double) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 定位：anchorRect 下方居中；空间不足时上方；再 clamp 到屏幕。
    private static func setFrame(panel: NSPanel, anchorRect: CGRect) {
        let center = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first {
            $0.frame.insetBy(dx: -2, dy: -2).contains(center)
        } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame

        var origin = CGPoint(
            x: anchorRect.midX - panel.frame.width / 2,
            y: anchorRect.minY - panel.frame.height - 16
        )
        if origin.y < visible.minY {
            origin.y = anchorRect.maxY + 16
        }
        if origin.y + panel.frame.height > visible.maxY {
            origin.y = visible.maxY - panel.frame.height - 8
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - panel.frame.width - 8))
        panel.setFrameOrigin(origin)
    }

    private static func makeThumbnail(image: CGImage, maxSize: CGSize) -> NSImage {
        let scale = min(maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height), 1)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let nsImage = NSImage(size: size)
        nsImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            .draw(in: NSRect(origin: .zero, size: size))
        nsImage.unlockFocus()
        return nsImage
    }
}

/// 悬停检测：进入暂停自动关闭，离开重新计时。
/// 作为 NSTrackingArea 的 owner 接收 mouseEntered/Exited 事件。
@MainActor
final class ToastHoverObserver: NSResponder {
    static let shared = ToastHoverObserver()

    override func mouseEntered(with event: NSEvent) {
        CaptureResultToast.hideWorkItem?.cancel()
    }

    override func mouseExited(with event: NSEvent) {
        CaptureResultToast.scheduleHide(after: 1.0)
    }
}
