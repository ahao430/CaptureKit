import AppKit

/// 滚动截图采集 HUD（plan.md §2.5）：帧数计数 + 完成/取消。
@MainActor
final class ScrollCapturePanel: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let frameLabel = NSTextField(labelWithString: "已采集 0 帧")
    private let hintLabel = NSTextField(labelWithString: "在选区内手动滚动页面")
    private var finishButton: NSButton!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        buildsContent()
    }

    private func buildsContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        frameLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        frameLabel.textColor = .labelColor
        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(frameLabel)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintLabel)

        finishButton = NSButton(title: "完成", target: self, action: #selector(finishTapped))
        finishButton.bezelStyle = .texturedRounded
        finishButton.controlSize = .small
        finishButton.keyEquivalent = "\r"
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(finishButton)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .texturedRounded
        cancelButton.controlSize = .small
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            frameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            frameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            hintLabel.leadingAnchor.constraint(equalTo: frameLabel.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: frameLabel.bottomAnchor, constant: 2),
            finishButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            finishButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: finishButton.leadingAnchor, constant: -6),
            cancelButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        contentView = container
    }

    func update(frameCount: Int) {
        frameLabel.stringValue = "已采集 \(frameCount) 帧"
    }

    func setHint(_ text: String) {
        hintLabel.stringValue = text
    }

    func show(near rect: CGRect) {
        position(near: rect)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    private func position(near rect: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: rect.midX, y: rect.midY)) })
            ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - frame.width / 2, y: rect.maxY + 16)
        if origin.y + frame.height > visible.maxY {
            origin.y = max(visible.minY + 8, rect.minY - frame.height - 16)
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - frame.width - 8))
        setFrameOrigin(origin)
    }

    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}
