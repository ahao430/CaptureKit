import AppKit

/// 标注线宽三档（细/中/粗）。
enum OverlayLineWidth: Int, CaseIterable {
    case thin
    case medium
    case thick

    var value: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4
        case .thick: return 8
        }
    }

    /// 与任意线宽值匹配到最近的档位。
    static func nearest(to lineWidth: CGFloat) -> OverlayLineWidth {
        allCases.min { abs($0.value - lineWidth) < abs($1.value - lineWidth) } ?? .medium
    }
}

/// 选区标注工具栏（DingTalk 式）：单行深色毛玻璃胶囊，贴选区上方。
/// [色圆（点击展开色板+线宽）] 矩形/椭圆/箭头/画笔/马赛克/模糊/文字/编号 | 撤销 | 贴图 保存 ✕ ✓
/// 不选任何工具 = 选择（拖动 = 移动选区/标注）；再点当前工具 = 取消回到选择。
@MainActor
final class SelectionToolbarPanel: NSPanel {
    var onToolChange: ((AnnotationType?) -> Void)?
    var onColorChange: ((AnnotationColor) -> Void)?
    var onWidthChange: ((OverlayLineWidth) -> Void)?
    var onUndo: (() -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    /// ✓ 完成（截图意图 = 复制含标注）
    var onFinish: (() -> Void)?

    private var toolButtons: [AnnotationType: NSButton] = [:]
    private var colorButtons: [AnnotationColor: NSButton] = [:]
    private var widthButtons: [OverlayLineWidth: NSButton] = [:]
    private let colorCircle = NSButton(title: "", target: nil, action: nil)
    private let expandGroup = NSStackView()
    private let colorCircleLayer = CALayer()
    private weak var contentStack: NSStackView?
    private var glassViews: [NSView] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 52),
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

    // MARK: - 构建

    private func buildsContent() {
        // 深色毛玻璃胶囊
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 560, height: 52))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width]
        let border = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 52))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        border.layer?.borderWidth = 1
        border.layer?.cornerRadius = 14
        border.autoresizingMask = [.width]
        glassViews = [effect, border]

        func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
            let button: NSButton
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
                button = NSButton(image: image, target: self, action: action)
            } else {
                button = NSButton(title: tooltip, target: self, action: action)
            }
            button.isBordered = false
            button.font = .systemFont(ofSize: 16)
            button.contentTintColor = .white
            button.toolTip = tooltip
            button.imageScaling = .scaleProportionallyDown
            button.setButtonType(.momentaryPushIn)
            return button
        }

        // 色圆（当前颜色；点击展开色板 + 线宽）
        colorCircle.target = self
        colorCircle.action = #selector(colorCircleTapped)
        colorCircle.isBordered = false
        colorCircle.wantsLayer = true
        colorCircleLayer.cornerRadius = 11
        colorCircleLayer.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        colorCircleLayer.borderWidth = 1.5
        colorCircle.layer = colorCircleLayer
        colorCircle.toolTip = "颜色 / 线宽"
        let colorCircleBox = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        colorCircle.translatesAutoresizingMaskIntoConstraints = false
        colorCircleBox.addSubview(colorCircle)
        NSLayoutConstraint.activate([
            colorCircle.widthAnchor.constraint(equalToConstant: 22),
            colorCircle.heightAnchor.constraint(equalToConstant: 22),
            colorCircle.centerXAnchor.constraint(equalTo: colorCircleBox.centerXAnchor),
            colorCircle.centerYAnchor.constraint(equalTo: colorCircleBox.centerYAnchor),
        ])

        // 展开组：8 色板 + 线宽三档（默认隐藏）
        for color in AnnotationColor.allCases {
            let swatch = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            swatch.isBordered = false
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.nsColor.cgColor
            swatch.layer?.cornerRadius = 7
            swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
            swatch.layer?.borderWidth = 1
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 14).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 14).isActive = true
            swatch.tag = AnnotationColor.allCases.firstIndex(of: color) ?? 0
            colorButtons[color] = swatch
        }
        let swatchRow = NSStackView(views: AnnotationColor.allCases.map { colorButtons[$0]! })
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 5

        for width in OverlayLineWidth.allCases {
            let dot = NSButton(title: "", target: self, action: #selector(widthTapped(_:)))
            dot.isBordered = false
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.cgColor
            let d = 5 + CGFloat(width.rawValue) * 3
            dot.layer?.cornerRadius = d / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: d).isActive = true
            dot.heightAnchor.constraint(equalToConstant: d).isActive = true
            dot.tag = width.rawValue
            widthButtons[width] = dot
        }
        let widthRow = NSStackView(views: OverlayLineWidth.allCases.map { widthButtons[$0]! })
        widthRow.orientation = .horizontal
        widthRow.spacing = 8

        expandGroup.orientation = .horizontal
        expandGroup.spacing = 12
        expandGroup.setViews([swatchRow, widthRow], in: .leading)
        expandGroup.isHidden = true

        // 绘制工具
        let toolSymbols: [(AnnotationType, String)] = [
            (.rectangle, "rectangle"), (.ellipse, "oval"), (.arrow, "arrow.up.right"),
            (.brush, "pencil.tip"), (.mosaic, "square.grid.3x3"), (.blur, "drop.halffull"),
            (.text, "textformat"), (.numberedMarker, "number.circle"),
        ]
        for (type, symbol) in toolSymbols {
            let button = makeIconButton(symbol: symbol, tooltip: type.displayName, action: #selector(toolTapped(_:)))
            button.tag = toolSymbols.firstIndex(where: { $0.0 == type }) ?? 0
            toolButtons[type] = button
        }
        let toolRow = NSStackView(views: toolSymbols.map { toolButtons[$0.0]! })
        toolRow.orientation = .horizontal
        toolRow.spacing = 6

        func separator() -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return line
        }

        let undo = makeIconButton(symbol: "arrow.uturn.backward", tooltip: "撤销 ⌘Z", action: #selector(undoTapped))
        let pin = makeIconButton(symbol: "pin", tooltip: "贴图（钉在屏幕上）", action: #selector(pinTapped))
        let save = makeIconButton(symbol: "square.and.arrow.down", tooltip: "保存", action: #selector(saveTapped))
        let cancel = makeIconButton(symbol: "xmark", tooltip: "取消 ⎋", action: #selector(cancelTapped))
        let finish = makeIconButton(symbol: "checkmark", tooltip: "完成 ⏎（复制含标注）", action: #selector(finishTapped))

        let stack = NSStackView(views: [
            colorCircleBox, toolRow, expandGroup, separator(), undo, separator(), pin, save, cancel, finish,
        ])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 52))
        container.addSubview(effect)
        container.addSubview(border)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
        contentStack = stack
    }

    /// 按内容重设胶囊宽度（展开/收起色板后调用；左上角锚定）。
    private func syncPanelWidth() {
        guard let stack = contentStack, let container = contentView else { return }
        let target = max(320, ceil(stack.fittingSize.width) + 8)
        guard abs(target - container.frame.width) > 1 else { return }
        var frame = self.frame
        frame.size.width = target
        // 左上角锚定（AppKit 原点在左下）
        frame.origin.y = frame.maxY - 52
        setFrame(frame, display: true)
        container.frame = NSRect(x: 0, y: 0, width: target, height: 52)
        for view in glassViews {
            view.frame = NSRect(x: 0, y: 0, width: target, height: 52)
        }
        stack.needsLayout = true
    }

    // MARK: - 状态同步

    /// 同步工具/颜色/线宽选中态与色圆颜色。
    func reflect(tool: AnnotationType?, style: AnnotationStyle) {
        for (key, button) in toolButtons {
            let active = key == tool
            button.contentTintColor = active ? NSColor.systemBlue : .white
        }
        for (color, button) in colorButtons {
            button.layer?.borderWidth = color == style.color ? 2.5 : 1
        }
        let width = OverlayLineWidth.nearest(to: style.lineWidth)
        for (key, button) in widthButtons {
            button.alphaValue = key == width ? 1 : 0.45
        }
        colorCircleLayer.backgroundColor = style.color.nsColor.cgColor
    }

    /// 收起色板/线宽展开组。
    func collapseExpandGroup() {
        expandGroup.isHidden = true
        syncPanelWidth()
    }

    // MARK: - 定位

    /// 放置到选区上方（空间不足时下方），并 clamp 到屏幕内。
    func position(above selection: CGRect, in screen: NSScreen) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 10
        var origin = CGPoint(
            x: selection.minX,
            y: selection.maxY + gap
        )
        if origin.y + frame.height > visible.maxY {
            origin.y = selection.minY - gap - frame.height
        }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - frame.width - 4))
        origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - frame.height - 4))
        setFrameOrigin(origin)
    }

    // MARK: - 动作

    @objc private func colorCircleTapped() {
        expandGroup.isHidden.toggle()
        syncPanelWidth()
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let symbols: [AnnotationType] = [.rectangle, .ellipse, .arrow, .brush, .mosaic, .blur, .text, .numberedMarker]
        guard symbols.indices.contains(sender.tag) else { return }
        onToolChange?(symbols[sender.tag])
    }

    @objc private func colorTapped(_ sender: NSButton) {
        let colors = AnnotationColor.allCases
        guard colors.indices.contains(sender.tag) else { return }
        onColorChange?(colors[sender.tag])
        collapseExpandGroup()
    }

    @objc private func widthTapped(_ sender: NSButton) {
        guard let width = OverlayLineWidth(rawValue: sender.tag) else { return }
        onWidthChange?(width)
        collapseExpandGroup()
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func finishTapped() { onFinish?() }
}
