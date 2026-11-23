import AppKit

/// 滚动截图会话控制条（钉钉式显式流程）：
/// [☑ 自动滚动] [已采集 N 帧 · 提示] ｜ [结束并保存] [取消]
/// 会话由用户显式开始（选区中央 ▶）与显式结束；不会自动完成。
@MainActor
final class ScrollCapturePanel: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 自动滚动开关（需辅助功能权限；不可用时由协调器回退并引导授权）
    var onAutoScrollToggle: ((Bool) -> Void)?

    private let frameLabel = NSTextField(labelWithString: "已采集 1 帧")
    private let hintLabel = NSTextField(labelWithString: "在选区内手动滚动，或把鼠标移到选区下边缘滚动")
    private let autoScrollCheckbox = NSButton(checkboxWithTitle: "自动滚动", target: nil, action: nil)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 44),
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

    /// 纯点击目标：不成为 key window，避免偷走键盘焦点
    override var canBecomeKey: Bool { false }

    private func buildsContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 44))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        autoScrollCheckbox.target = self
        autoScrollCheckbox.action = #selector(autoScrollToggled)
        autoScrollCheckbox.controlSize = .small
        autoScrollCheckbox.toolTip = "自动向下滚动（需辅助功能权限）"
        autoScrollCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(autoScrollCheckbox)

        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        frameLabel.textColor = .labelColor
        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(frameLabel)

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintLabel)

        let finishButton = NSButton(title: "结束并保存", target: self, action: #selector(finishTapped))
        finishButton.bezelStyle = .rounded
        finishButton.controlSize = .small
        finishButton.keyEquivalent = "\r"
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(finishButton)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            autoScrollCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            autoScrollCheckbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            frameLabel.leadingAnchor.constraint(equalTo: autoScrollCheckbox.trailingAnchor, constant: 10),
            frameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: frameLabel.trailingAnchor, constant: 8),
            hintLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            cancelButton.trailingAnchor.constraint(equalTo: finishButton.leadingAnchor, constant: -6),
            cancelButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            finishButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            finishButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        contentView = container
    }

    // MARK: - 状态

    func update(frameCount: Int) {
        frameLabel.stringValue = "已采集 \(frameCount) 帧"
    }

    func setHint(_ text: String) {
        hintLabel.stringValue = text
    }

    func setAutoScroll(_ on: Bool) {
        autoScrollCheckbox.state = on ? .on : .off
    }

    /// 辅助功能权限是否可用（不可用：自动滚动/鼠标滚动禁用并提示）。
    func setAutoScrollAvailable(_ available: Bool) {
        autoScrollCheckbox.isEnabled = available
        if !available {
            autoScrollCheckbox.state = .off
        }
    }

    // MARK: - 显隐

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
        var origin = CGPoint(x: rect.midX - frame.width / 2, y: rect.maxY + 12)
        if origin.y + frame.height > visible.maxY {
            origin.y = max(visible.minY + 8, rect.minY - frame.height - 12)
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - frame.width - 8))
        setFrameOrigin(origin)
    }

    // MARK: - 动作

    @objc private func autoScrollToggled() {
        onAutoScrollToggle?(autoScrollCheckbox.state == .on)
    }
    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}
