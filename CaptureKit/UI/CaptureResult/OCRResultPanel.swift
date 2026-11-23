import AppKit

/// OCR 结果窗口：先展示识别文字，不自动关闭（钉钉行为）。
/// 文字可选中复制；「复制全部」写入剪贴板；「关闭」退出。
@MainActor
final class OCRResultPanelController {
    static let shared = OCRResultPanelController()

    private var panel: NSPanel?
    private let textView = NSTextView()

    /// 在捕获区域附近展示识别结果。
    func show(text: String, anchorRect: CGRect) {
        let size = NSSize(width: 380, height: 300)

        let existing = panel
        let container: NSView
        if let existing, let view = existing.contentView {
            view.frame = NSRect(origin: .zero, size: size)
            container = view
        } else {
            container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            container.layer?.cornerRadius = 12
            container.layer?.borderColor = NSColor.separatorColor.cgColor
            container.layer?.borderWidth = 1
            buildContent(in: container)
        }

        let newPanel: NSPanel
        if let existing {
            newPanel = existing
        } else {
            newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.title = "文字识别结果"
            newPanel.isReleasedWhenClosed = false
            // 层级高于截图 Overlay（screenSaver）：内联 OCR 时截图保持打开
            newPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.contentView = container
            newPanel.standardWindowButton(.zoomButton)?.isHidden = true
            panel = newPanel
        }

        textView.string = text.isEmpty ? "（未识别到文字）" : text

        // 定位：区域下方，空间不足时上方，clamp 屏幕内
        let center = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first {
            $0.frame.insetBy(dx: -2, dy: -2).contains(center)
        } ?? NSScreen.main
        var origin = CGPoint(
            x: anchorRect.minX,
            y: anchorRect.minY - 12 - size.height
        )
        if let screen {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = anchorRect.maxY + 12
            }
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        }
        newPanel.setFrameOrigin(origin)
        newPanel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent(in container: NSView) {
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .regular
        copyButton.keyEquivalent = "\r"
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(close))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .regular
        closeButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [copyButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    @objc private func copyAll() {
        let text = textView.string
        guard text != "（未识别到文字）" else { return }
        ClipboardWriter.copyText(text)
        if let panel {
            CaptureResultToast.showText(message: "已复制识别文字", anchorRect: panel.frame)
        }
    }

    @objc private func close() {
        panel?.orderOut(nil)
    }
}
