import AppKit

/// 标注模式文字输入浮层：选区内点击文字工具后出现的小输入框。
/// Enter / 点击外部提交（onCommit），Esc 取消（onCancel）。字号跟随当前标注样式。
@MainActor
final class OverlayTextEntryPanel: NSPanel, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let textField = NSTextField()
    /// 防止取消后失焦回调再触发提交
    private var isClosed = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.borderWidth = 1

        textField.placeholderString = "输入文字，Enter 确认"
        textField.bezelStyle = .roundedBezel
        textField.controlSize = .small
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.delegate = self
        container.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
    }

    /// 无边框面板默认不能成为 key window，必须显式放开才能接收键盘输入。
    override var canBecomeKey: Bool { true }

    /// 在全局点（文本左下角）附近展示并聚焦。
    func show(at globalPoint: CGPoint, fontSize: CGFloat, color: AnnotationColor) {
        isClosed = false
        textField.font = .systemFont(ofSize: fontSize, weight: .semibold)
        textField.textColor = color.nsColor
        textField.stringValue = ""

        // 面板放在点击点上方（输入框底边对齐文本落点）
        setFrameOrigin(CGPoint(x: max(4, globalPoint.x), y: globalPoint.y))
        // 热键触发时 App 可能未激活：先激活，否则 key window 收不到键盘
        NSApp.activate(ignoringOtherApps: true)
        becomesKeyOnlyIfNeeded = false
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textField)
    }

    override func cancelOperation(_ sender: Any?) {
        guard !isClosed else { return }
        isClosed = true
        closePanel()
        onCancel?()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // Enter / 点击外部（失焦）统一走提交
        guard !isClosed else { return }
        isClosed = true
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        closePanel()
        if text.isEmpty {
            onCancel?()
        } else {
            onCommit?(text)
        }
    }

    private func closePanel() {
        textField.resignFirstResponder()
        orderOut(nil)
    }
}
