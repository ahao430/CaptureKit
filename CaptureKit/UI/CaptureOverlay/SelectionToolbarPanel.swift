import AppKit

/// 选区确认后的浮动图标工具栏（ui-design.md §5.5，参考钉钉截图工具栏）。
/// 独立非激活面板：复制 / 编辑（标注）/ 保存 / OCR / 录屏 / 长截图 / 贴图 / 取消。
/// 图标按钮 + tooltip（含快捷键提示），重选等低频操作走右键菜单。
@MainActor
final class SelectionToolbarPanel: NSPanel {
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSave: (() -> Void)?
    var onRecognizeText: (() -> Void)?
    var onRecordVideo: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onPin: (() -> Void)?
    var onCancel: (() -> Void)?

    private let buttonSize = NSSize(width: 34, height: 30)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: buttonSize.height + 12),
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: buttonSize.height + 12))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        func makeIconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            let button: NSButton
            if let image {
                button = NSButton(image: image, target: self, action: action)
            } else {
                // SF Symbol 不可用时的兜底（不阻塞功能）
                button = NSButton(title: tooltip, target: self, action: action)
            }
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.toolTip = tooltip
            button.imageScaling = .scaleProportionallyDown
            button.setButtonType(.momentaryPushIn)
            return button
        }

        let copy = makeIconButton("doc.on.doc", tooltip: "复制 ⏎", action: #selector(copyTapped))
        let edit = makeIconButton("pencil", tooltip: "编辑（选区内标注）", action: #selector(editTapped))
        let save = makeIconButton("square.and.arrow.down", tooltip: "保存", action: #selector(saveTapped))
        let ocr = makeIconButton("text.viewfinder", tooltip: "识别文字（OCR）", action: #selector(recognizeTapped))
        let record = makeIconButton("record.circle", tooltip: "录制视频", action: #selector(recordTapped))
        let scroll = makeIconButton("scroll", tooltip: "长截图（滚动拼接）", action: #selector(scrollTapped))
        let pin = makeIconButton("pin", tooltip: "贴图（钉在屏幕上）", action: #selector(pinTapped))
        let cancel = makeIconButton("xmark.circle", tooltip: "取消 ⎋", action: #selector(cancelTapped))

        let stack = NSStackView(views: [copy, edit, save, ocr, record, scroll, pin, cancel])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: buttonSize.height),
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
    @objc private func recognizeTapped() { onRecognizeText?() }
    @objc private func recordTapped() { onRecordVideo?() }
    @objc private func scrollTapped() { onScrollCapture?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func cancelTapped() { onCancel?() }
}
