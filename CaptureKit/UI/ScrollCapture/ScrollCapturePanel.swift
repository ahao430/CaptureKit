import AppKit

/// 滚动截图会话控制条（钉钉式显式流程，两行）：
/// 上行：提示文字；下行：[☑ 自动滚动] [已采集 N 帧] ｜ [■ 停止] [保存图片] [取消] [✓ 复制]
///
/// - 采集中：四个动作按钮均可用（可直接「保存图片」/「✓ 复制」一步完成，或先「停止」再选）。
/// - 停止后（复核态）：隐藏自动滚动与停止，保留 保存图片 / 取消 / ✓ 复制。
@MainActor
final class ScrollCapturePanel: NSPanel {
    var onStop: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 自动滚动开关（需辅助功能权限；不可用时由协调器回退并引导授权）
    var onAutoScrollToggle: ((Bool) -> Void)?

    private let hintLabel = NSTextField(labelWithString: "")
    private let frameLabel = NSTextField(labelWithString: "已采集 0 帧")
    private let autoScrollCheckbox = NSButton(checkboxWithTitle: "自动滚动", target: nil, action: nil)
    private let stopButton = NSButton(title: "■ 停止", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存图片", target: nil, action: nil)
    private let copyButton = NSButton(title: "✓ 复制", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private let panelSize = NSSize(width: 440, height: 66)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintLabel)

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

        func configure(_ button: NSButton, _ action: Selector, tooltip: String) {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.toolTip = tooltip
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
        }
        configure(stopButton, #selector(stopTapped), tooltip: "停止滚动并拼接，随后可选择保存 / 复制 / 取消")
        configure(saveButton, #selector(saveTapped), tooltip: "拼接并保存为 PNG")
        configure(copyButton, #selector(copyTapped), tooltip: "拼接并复制到剪贴板")
        configure(cancelButton, #selector(cancelTapped), tooltip: "放弃本次滚动截图")

        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            hintLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),

            autoScrollCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            autoScrollCheckbox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            frameLabel.leadingAnchor.constraint(equalTo: autoScrollCheckbox.trailingAnchor, constant: 10),
            frameLabel.centerYAnchor.constraint(equalTo: autoScrollCheckbox.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            copyButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
            saveButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -6),
            stopButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
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

    /// 拼接进行中：禁用动作按钮。
    func setBusy(_ busy: Bool) {
        for button in [stopButton, saveButton, copyButton] {
            button.isEnabled = !busy
        }
    }

    /// 停止后的复核态：隐藏自动滚动与停止，仅保留 保存图片 / 取消 / ✓ 复制。
    func showReviewing(frameCount: Int) {
        autoScrollCheckbox.isHidden = true
        stopButton.isHidden = true
        frameLabel.stringValue = "已拼接 \(frameCount) 帧"
        setHint("已停止：保存图片、✓ 复制到剪贴板，或取消")
        setBusy(false)
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
    @objc private func stopTapped() { onStop?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func cancelTapped() { onCancel?() }
}
