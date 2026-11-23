import AppKit

/// 延时截图倒计时面板：屏幕顶部中央小浮条，显示剩余秒数，可取消。
@MainActor
final class DelayedCapturePanel: NSPanel {
    var onCancel: (() -> Void)?

    private var countdownTask: Task<Void, Never>?
    private var completion: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "取消", target: nil, action: #selector(cancelTapped))

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        buildsContent()
    }

    private func buildsContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        cancelButton.controlSize = .small
        cancelButton.bezelStyle = .texturedRounded
        cancelButton.target = self
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            cancelButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])

        contentView = container
    }

    /// 开始倒计时；归零后回调 completion（在主线程）。
    func show(seconds: Int, completion: @escaping () -> Void) {
        self.completion = completion
        positionOnScreen()
        orderFrontRegardless()

        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.label.stringValue = "⏱ \(remaining) 秒后开始截图"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.closePanel()
            self.completion?()
        }
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        closePanel()
        onCancel?()
    }

    private func closePanel() {
        countdownTask?.cancel()
        countdownTask = nil
        orderOut(nil)
    }

    @objc private func cancelTapped() { cancel() }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 24
        ))
    }
}
