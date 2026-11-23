import AppKit

/// 选区确认后的浮动工具栏（ui-design.md §5.5）。
/// 独立非激活面板：复制 ⏎ / 编辑 / 保存 / 重选 / 取消 ⎋。
@MainActor
final class SelectionToolbarPanel: NSPanel {
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSave: (() -> Void)?
    var onReselect: (() -> Void)?
    var onCancel: (() -> Void)?

    private let buttonHeight: CGFloat = 30

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: buttonHeight + 16),
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
        buildsContent()
    }

    private func buildsContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: buttonHeight + 16))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        func makeButton(_ title: String, action: Selector, keyEquivalent: String = "") -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.keyEquivalent = keyEquivalent
            return button
        }

        let copy = makeButton("复制 ⏎", action: #selector(copyTapped))
        let edit = makeButton("编辑", action: #selector(editTapped))
        let save = makeButton("保存", action: #selector(saveTapped))
        let reselect = makeButton("重选", action: #selector(reselectTapped))
        let cancel = makeButton("取消 ⎋", action: #selector(cancelTapped))

        let stack = NSStackView(views: [copy, edit, save, reselect, cancel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        contentView = container
    }

    // MARK: - 定位

    /// 将工具栏放置到选区正下方（空间不足时上方），并 clamp 到屏幕内。
    func position(below selection: CGRect, in screen: NSScreen) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        var origin = CGPoint(
            x: selection.midX - frame.width / 2,
            y: selection.minY - gap - frame.height
        )
        // 选区下方放不下 → 放到选区上方
        if origin.y < visible.minY {
            origin.y = selection.maxY + gap
        }
        // 水平 clamp 到可见范围
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - frame.width - 4))
        origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - frame.height - 4))
        setFrameOrigin(origin)
    }

    // MARK: - 动作

    @objc private func copyTapped() { onCopy?() }
    @objc private func editTapped() { onEdit?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func reselectTapped() { onReselect?() }
    @objc private func cancelTapped() { onCancel?() }
}
