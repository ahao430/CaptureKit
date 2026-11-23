import AppKit

/// 标注线宽三档（细/中/粗），钉钉式。
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

/// 一体化选区工具栏（DingTalk 式）：
/// 上行 = 标注工具（选择/矩形/椭圆/箭头/画笔/马赛克/文字/编号）+ 颜色 + 线宽 + 撤销；
/// 下行 = 动作（贴图/OCR/长截图/录制/保存/复制/取消）。
/// 默认「选择」工具：拖动 = 移动选区；点标注工具后在选区内直接绘制，无模式切换。
@MainActor
final class SelectionToolbarPanel: NSPanel {
    var onToolChange: ((OverlaySelectionModel.OverlayTool) -> Void)?
    var onColorChange: ((AnnotationColor) -> Void)?
    var onWidthChange: ((OverlayLineWidth) -> Void)?
    var onUndo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onRecognizeText: (() -> Void)?
    var onRecordVideo: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onPin: (() -> Void)?
    var onCancel: (() -> Void)?

    private var toolButtons: [OverlaySelectionModel.OverlayTool: NSButton] = [:]
    private var colorButtons: [AnnotationColor: NSButton] = [:]
    private var widthButtons: [OverlayLineWidth: NSButton] = [:]

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 84),
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 84))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 0.5

        func makeToggle(
            symbol: String, tooltip: String, action: Selector,
            circularDiameter: CGFloat = 0, filledColor: NSColor? = nil
        ) -> NSButton {
            let button: NSButton
            if let filledColor {
                // 颜色/线宽圆点按钮
                button = NSButton(title: "", target: self, action: action)
                button.wantsLayer = true
                button.layer?.backgroundColor = filledColor.cgColor
                button.layer?.cornerRadius = circularDiameter / 2
                button.layer?.borderColor = NSColor.separatorColor.cgColor
                button.layer?.borderWidth = 1
                button.frame = NSRect(x: 0, y: 0, width: circularDiameter, height: circularDiameter)
            } else {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
                if let image {
                    button = NSButton(image: image, target: self, action: action)
                } else {
                    button = NSButton(title: tooltip, target: self, action: action)
                }
                button.bezelStyle = .texturedRounded
                button.controlSize = .small
                button.imageScaling = .scaleProportionallyDown
            }
            button.toolTip = tooltip
            button.setButtonType(.toggle)
            return button
        }

        // —— 上行：工具 + 颜色 + 线宽 + 撤销 ——
        let select = makeToggle(symbol: "cursorarrow.click", tooltip: "选择（拖动移动选区/标注）", action: #selector(selectTapped))
        toolButtons[.select] = select

        let toolSymbols: [(AnnotationType, String)] = [
            (.rectangle, "rectangle"), (.ellipse, "oval"), (.arrow, "arrow.up.right"),
            (.brush, "pencil.tip"), (.mosaic, "square.grid.3x3"),
            (.numberedMarker, "number.circle"), (.text, "textformat"),
        ]
        for (type, symbol) in toolSymbols {
            let button = makeToggle(symbol: symbol, tooltip: type.displayName, action: #selector(toolTapped(_:)))
            button.tag = toolButtons.count
            toolButtons[.annotate(type)] = button
        }
        let toolRow = NSStackView(views: [select] + toolSymbols.map { toolButtons[.annotate($0.0)]! })
        toolRow.orientation = .horizontal
        toolRow.spacing = 3

        for color in AnnotationColor.allCases {
            let button = makeToggle(
                symbol: "", tooltip: "颜色", action: #selector(colorTapped(_:)),
                circularDiameter: 16, filledColor: color.nsColor
            )
            button.tag = AnnotationColor.allCases.firstIndex(of: color) ?? 0
            colorButtons[color] = button
        }
        let colorRow = NSStackView(views: AnnotationColor.allCases.map { colorButtons[$0]! })
        colorRow.orientation = .horizontal
        colorRow.spacing = 3

        for width in OverlayLineWidth.allCases {
            let button = makeToggle(
                symbol: "", tooltip: "线宽 \(width.rawValue + 1)", action: #selector(widthTapped(_:)),
                circularDiameter: 6 + CGFloat(width.rawValue) * 4,
                filledColor: .labelColor
            )
            button.tag = width.rawValue
            widthButtons[width] = button
        }
        let widthRow = NSStackView(views: OverlayLineWidth.allCases.map { widthButtons[$0]! })
        widthRow.orientation = .horizontal
        widthRow.spacing = 3

        let undo = makeToggle(symbol: "arrow.uturn.backward", tooltip: "撤销 ⌘Z", action: #selector(undoTapped))

        func separator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }

        let topRow = NSStackView(views: [toolRow, separator(), colorRow, separator(), widthRow, separator(), undo])
        topRow.orientation = .horizontal
        topRow.spacing = 8

        // —— 下行：动作 ——
        func makeAction(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
            let button = makeToggle(symbol: symbol, tooltip: tooltip, action: action)
            button.setButtonType(.momentaryPushIn)
            return button
        }

        let actions: [(NSButton, String)] = [
            (makeAction("pin", tooltip: "贴图（钉在屏幕上）", action: #selector(pinTapped)), "pin"),
            (makeAction("text.viewfinder", tooltip: "识别文字（OCR）", action: #selector(recognizeTapped)), "ocr"),
            (makeAction("scroll", tooltip: "长截图（滚动拼接）", action: #selector(scrollTapped)), "scroll"),
            (makeAction("record.circle", tooltip: "录制视频", action: #selector(recordTapped)), "record"),
            (makeAction("square.and.arrow.down", tooltip: "保存", action: #selector(saveTapped)), "save"),
            (makeAction("doc.on.doc", tooltip: "复制 ⏎（含标注）", action: #selector(copyTapped)), "copy"),
            (makeAction("xmark.circle", tooltip: "取消 ⎋", action: #selector(cancelTapped)), "cancel"),
        ]
        let bottomRow = NSStackView(views: actions.map(\.0))
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 6

        let rows = NSStackView(views: [topRow, bottomRow])
        rows.orientation = .vertical
        rows.spacing = 6
        rows.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        rows.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            rows.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        contentView = container
    }

    // MARK: - 状态同步

    /// 同步工具/颜色/线宽选中态（面板自己管理 toggle state）。
    func reflect(tool: OverlaySelectionModel.OverlayTool, style: AnnotationStyle) {
        for (key, button) in toolButtons {
            button.state = key == tool ? .on : .off
        }
        for (color, button) in colorButtons {
            button.state = color == style.color ? .on : .off
        }
        let width = OverlayLineWidth.nearest(to: style.lineWidth)
        for (key, button) in widthButtons {
            button.state = key == width ? .on : .off
        }
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

    @objc private func selectTapped() { onToolChange?(.select) }

    @objc private func toolTapped(_ sender: NSButton) {
        // tag = 构建顺序对应 toolSymbols 索引（select 为 0 号之前的独立按钮）
        let symbols: [AnnotationType] = [.rectangle, .ellipse, .arrow, .brush, .mosaic, .numberedMarker, .text]
        let index = sender.tag - 1
        guard symbols.indices.contains(index) else { return }
        onToolChange?(.annotate(symbols[index]))
    }

    @objc private func colorTapped(_ sender: NSButton) {
        let colors = AnnotationColor.allCases
        guard colors.indices.contains(sender.tag) else { return }
        onColorChange?(colors[sender.tag])
    }

    @objc private func widthTapped(_ sender: NSButton) {
        guard let width = OverlayLineWidth(rawValue: sender.tag) else { return }
        onWidthChange?(width)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func recognizeTapped() { onRecognizeText?() }
    @objc private func recordTapped() { onRecordVideo?() }
    @objc private func scrollTapped() { onScrollCapture?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func cancelTapped() { onCancel?() }
}
