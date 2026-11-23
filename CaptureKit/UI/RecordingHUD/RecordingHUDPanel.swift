import AppKit

/// 录制 HUD（ui-design.md §7）：小、轻、清晰的悬浮控制条。
/// 状态 ● REC / Ⅱ PAUSED，时间实时更新；暂停(继续)/停止/取消。
/// 本窗口属于 CaptureKit，被 SCContentFilter 排除，不会录入视频。
@MainActor
final class RecordingHUDPanel: NSPanel {
    enum DisplayState {
        case recording(startedAt: Date, pausedDuration: Double)
        case paused(startedAt: Date, pausedDuration: Double)
    }

    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private let statusDot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    private let timeLabel = NSTextField(labelWithString: "00:00")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 244, height: 44),
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 244, height: 44))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        statusDot.layer?.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusDot)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .labelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(timeLabel)

        func makeButton(_ symbol: String, action: Selector, help: String) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.toolTip = help
            return button
        }

        let pause = makeButton("pause.fill", action: #selector(pauseTapped), help: "暂停 / 继续")
        let stop = makeButton("stop.fill", action: #selector(stopTapped), help: "停止并保存")
        let cancel = makeButton("xmark", action: #selector(cancelTapped), help: "取消录制")

        let stack = NSStackView(views: [statusDot, timeLabel, pause, stop, cancel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        contentView = container
    }

    // MARK: - 展示与状态

    func show() {
        positionOnScreen()
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    /// 更新显示状态（REC/PAUSED + 计时）。由 coordinator 周期调用（携带最新暂停时长）。
    func update(state: DisplayState) {
        switch state {
        case .recording(let startedAt, let pausedDuration):
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            updateElapsed(startedAt: startedAt, pausedDuration: pausedDuration)
        case .paused(let startedAt, let pausedDuration):
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            updateElapsed(startedAt: startedAt, pausedDuration: pausedDuration)
        }
    }

    private func updateElapsed(startedAt: Date, pausedDuration: Double) {
        timeLabel.stringValue = Self.format(max(0, Date().timeIntervalSince(startedAt) - pausedDuration))
    }

    nonisolated static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 16
        ))
    }

    // MARK: - 动作

    @objc private func pauseTapped() { onPauseToggle?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func cancelTapped() { onCancel?() }
}
