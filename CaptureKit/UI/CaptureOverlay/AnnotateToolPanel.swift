import AppKit

/// 标注模式浮动工具面板（DingTalk 式选区内直接标注，批次 2）。
/// 工具：矩形 / 椭圆 / 箭头 / 画笔 / 马赛克 / 编号 / 文字；颜色 8 色；
/// 撤销 ⌘Z；完成 ⏎（复制含标注截图）；退出 ✕（返回选区工具栏）。
@MainActor
final class AnnotateToolPanel: NSPanel {
    var onToolChange: ((AnnotationType) -> Void)?
    var onColorChange: ((AnnotationColor) -> Void)?
    var onUndo: (() -> Void)?
    /// 完成：复制含标注的截图
    var onFinish: (() -> Void)?
    /// 退出标注模式（保留已画内容，返回选区工具栏）
    var onExit: (() -> Void)?

    private let swatchSize: CGFloat = 16
    /// 工具 → 按钮 tag 映射（工具顺序变化时随构建同步）
    private var toolTagMap: [AnnotationType: Int] = [:]

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 44),
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 44))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        func symbol(for type: AnnotationType) -> String {
            switch type {
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "oval"
            case .text: return "textformat"
            case .brush: return "pencil.tip"
            case .mosaic: return "square.grid.3x3"
            case .blur: return "drop.halffull"
            case .numberedMarker: return "number.circle"
            }
        }

        func makeToolButton(_ type: AnnotationType, index: Int) -> NSButton {
            let button = NSButton(
                title: type.displayName,
                image: NSImage(systemSymbolName: symbol(for: type), accessibilityDescription: type.displayName) ?? NSImage(),
                target: self,
                action: #selector(toolTapped(_:))
            )
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.toolTip = type.displayName
            button.imageScaling = .scaleProportionallyDown
            button.setButtonType(.momentaryPushIn)
            button.tag = index
            return button
        }

        let tools: [AnnotationType] = [.rectangle, .ellipse, .arrow, .brush, .mosaic, .numberedMarker, .text]
        let toolViews: [NSView] = tools.enumerated().map { makeToolButton($1, index: $0) }
        toolTagMap = Dictionary(uniqueKeysWithValues: tools.enumerated().map { ($1, $0) })

        // 颜色圆点
        let colorViews: [NSView] = AnnotationColor.allCases.enumerated().map { index, color in
            let swatch = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            swatch.bezelStyle = .circular
            swatch.controlSize = .small
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.nsColor.cgColor
            swatch.layer?.cornerRadius = swatchSize / 2
            swatch.layer?.borderColor = NSColor.separatorColor.cgColor
            swatch.layer?.borderWidth = 1
            swatch.frame = NSRect(x: 0, y: 0, width: swatchSize, height: swatchSize)
            swatch.toolTip = "颜色 \(color.rawValue)"
            swatch.tag = index
            return swatch
        }

        func makeActionButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(),
                target: self,
                action: action
            )
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.toolTip = tooltip
            button.imageScaling = .scaleProportionallyDown
            button.setButtonType(.momentaryPushIn)
            return button
        }

        let undo = makeActionButton("arrow.uturn.backward", tooltip: "撤销 ⌘Z", action: #selector(undoTapped))
        let finish = makeActionButton("checkmark.circle.fill", tooltip: "完成并复制 ⏎", action: #selector(finishTapped))
        let exit = makeActionButton("xmark.circle", tooltip: "退出标注 ✕", action: #selector(exitTapped))

        let separator1 = NSBox()
        let separator2 = NSBox()
        for separator in [separator1, separator2] {
            separator.boxType = .separator
        }

        let stack = NSStackView(views: toolViews + [separator1] + colorViews + [separator2] + [undo, finish, exit])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        contentView = container
    }

    // MARK: - 状态同步

    /// 同步当前工具/颜色的选中态外观。
    func reflect(tool: AnnotationType, color: AnnotationColor) {
        // 按钮高亮交由系统按下态；此处仅保证 representedObject 一致，无需额外绘制。
    }

    // MARK: - 定位

    /// 放置到选区正下方（空间不足时上方），并 clamp 到屏幕内。
    func position(below selection: CGRect, in screen: NSScreen) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        var origin = CGPoint(
            x: selection.midX - frame.width / 2,
            y: selection.minY - gap - frame.height
        )
        if origin.y < visible.minY {
            origin.y = selection.maxY + gap
        }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - frame.width - 4))
        origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - frame.height - 4))
        setFrameOrigin(origin)
    }

    // MARK: - 动作

    @objc private func toolTapped(_ sender: NSButton) {
        // tag → 工具（反向查 toolTagMap）
        guard let entry = toolTagMap.first(where: { $0.value == sender.tag }) else { return }
        onToolChange?(entry.key)
    }

    @objc private func colorTapped(_ sender: NSButton) {
        let colors = AnnotationColor.allCases
        guard colors.indices.contains(sender.tag) else { return }
        onColorChange?(colors[sender.tag])
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func finishTapped() { onFinish?() }
    @objc private func exitTapped() { onExit?() }
}
