import AppKit

/// 单屏 Overlay 视图：暗化遮罩、选区、控制点、尺寸标签、放大镜、窗口高亮。
/// 所有坐标先转换为全局坐标再写入共享 model，保证跨屏一致。
@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    /// 选区或交互状态发生变化（需要全屏重绘、更新工具栏）
    func overlaySelectionDidChange()
    /// 用户按下 Enter / 点击工具栏复制
    func overlayRequestsConfirm(action: CaptureDeliveryAction)
    /// 用户按下 ESC
    func overlayRequestsCancel()
    /// 用户双击（窗口捕获）
    func overlayDidDoubleClick(at globalPoint: CGPoint)
    /// 用户按 C 复制放大镜中心颜色
    func overlayDidRequestCopyColor(at globalPoint: CGPoint)
    /// 用户在选区内右键（上下文菜单）
    func overlayRequestsContextMenu(at globalPoint: CGPoint)
    /// 标注模式下点击文字工具落点（弹出文字输入）
    func overlayRequestsTextAnnotation(at globalPoint: CGPoint)
}

@MainActor
final class CaptureOverlayView: NSView {
    weak var delegate: CaptureOverlayViewDelegate?
    let model: OverlaySelectionModel
    /// 本视图覆盖屏幕的全局 frame（= window.frame）
    let screenFrame: CGRect

    private let selectionBorderColor = NSColor.systemBlue
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    /// 尺寸标签常驻标志：mouseUp 后保留显示
    private var needsSizeLabel = false

    /// 放大镜参数
    private let magnifierMagnification: CGFloat = 4
    private var magnifierSize: CGSize { CGSize(width: 120, height: 90) }
    private let magnifierSourceSize = CGSize(width: 30, height: 22.5)

    init(model: OverlaySelectionModel, screenFrame: CGRect) {
        self.model = model
        self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 光标

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. 整屏暗化
        context.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        context.fill(bounds)

        // 2. 悬停窗口高亮（无选区且非交互时）
        if model.selection == nil, !model.isInteracting, let hover = model.hoverWindowFrame {
            drawHighlight(context, rect: hover)
        }

        // 3. 选区提亮（清除交集暗化）+ 边框
        if let selection = model.selection {
            let intersection = selection.intersection(screenFrame)
            if !intersection.isNull, intersection.width >= 1, intersection.height >= 1 {
                let local = toLocal(intersection)
                context.setBlendMode(.clear)
                context.fill(local)
                context.setBlendMode(.normal)
                context.setStrokeColor(selectionBorderColor.cgColor)
                context.setLineWidth(1.5)
                context.stroke(local)
            }

            // 3.5 标注模式：选区内直接绘制标注（已提交 + 草稿），复用统一渲染管线
            if model.annotateMode {
                drawAnnotations(context, selection: selection)
            }
        }

        // 4. 拖拽创建中：十字准线
        if case .creating = model.interaction, let current = model.currentDragPoint {
            drawCrosshair(context, at: current)
        }

        // 5. 跟随放大镜（创建/调整/移动中 + 无选区悬停取色；只在本屏鼠标附近绘制）
        if model.showsMagnifier, let current = model.currentDragPoint {
            if screenFrame.insetBy(dx: -magnifierSize.width, dy: -magnifierSize.height).contains(current) {
                drawMagnifier(context, at: current)
            }
        }

        // 6. 控制点（有选区且非创建交互时；标注模式下禁用调整）
        if let selection = model.selection, !model.annotateMode {
            for handle in SelectionHandle.allCases {
                drawHandle(context, handle: handle, on: selection)
            }
        }

        // 7. 尺寸标签（仅选区中心所在屏绘制；标注模式下不显示）
        if let selection = model.selection, !model.annotateMode, model.isInteracting || needsSizeLabel {
            let center = CGPoint(x: selection.midX, y: selection.midY)
            if screenFrame.contains(center) {
                drawSizeLabel(context, for: selection)
            }
        }

        // 8. 顶部提示（无选区且非交互时）
        if model.selection == nil, !model.isInteracting, !model.hint.isEmpty {
            drawHint(context)
        }
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        let point = globalPoint(event)

        // 标注模式：选区内绘制标注，选区外忽略（不新建/移动选区）
        if model.annotateMode {
            annotateMouseDown(at: point)
            return
        }

        // 双击检测 → 窗口捕获
        if let last = model.lastClick,
           Date().timeIntervalSince(last.time) < 0.35,
           hypot(point.x - last.point.x, point.y - last.point.y) < 6 {
            model.lastClick = nil
            delegate?.overlayDidDoubleClick(at: point)
            return
        }
        model.lastClick = (Date(), point)

        model.currentDragPoint = point

        // 命中控制点 → 调整大小
        if let selection = model.selection,
           let handle = ScreenGeometry.handle(at: point, of: selection) {
            model.interaction = .resizing(handle: handle)
        }
        // 空格按住 或 选区内按下 → 移动
        else if model.isSpacePressed || (model.selection?.insetBy(dx: -4, dy: -4).contains(point) ?? false) {
            if let selection = model.selection {
                model.interaction = .moving(dragOrigin: point, selectionOrigin: selection)
            } else {
                model.interaction = .creating(start: snapped(point))
            }
        }
        // 新建选区（起点吸附窗口边缘）
        else {
            model.selection = nil
            needsSizeLabel = false
            model.interaction = .creating(start: snapped(point))
        }
        delegate?.overlaySelectionDidChange()
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = globalPoint(event)

        // 标注草稿拖拽
        if model.annotateMode, model.draftAnnotation != nil {
            annotateDragged(to: raw)
            return
        }

        let point = snapped(raw)
        model.currentDragPoint = raw
        switch model.interaction {
        case .creating(let start):
            model.selection = Self.rect(from: start, to: point)
        case .moving(let dragOrigin, let selectionOrigin):
            model.selection = ScreenGeometry.movedRect(
                selectionOrigin,
                dx: raw.x - dragOrigin.x,
                dy: raw.y - dragOrigin.y
            )
        case .resizing(let handle):
            if model.selection != nil {
                model.selection = ScreenGeometry.resizeRect(model.selection!, handle: handle, to: point)
            }
        case .none:
            break
        }
        delegate?.overlaySelectionDidChange()
    }

    override func mouseUp(with event: NSEvent) {
        let point = globalPoint(event)

        // 标注草稿提交
        if model.annotateMode, model.draftAnnotation != nil {
            commitAnnotateDraft()
            return
        }

        switch model.interaction {
        case .creating:
            if let s = model.selection, s.width >= 4, s.height >= 4 {
                needsSizeLabel = true
            } else {
                // 单击（无拖拽）→ 选中悬停窗口为选区
                if let windowFrame = smallestWindowFrame(containing: point) {
                    model.selection = windowFrame
                    needsSizeLabel = true
                } else {
                    model.selection = nil
                    needsSizeLabel = false
                }
            }
        case .moving, .resizing:
            needsSizeLabel = true
        case .none:
            break
        }
        model.interaction = .none
        model.currentDragPoint = nil
        delegate?.overlaySelectionDidChange()
    }

    override func mouseMoved(with event: NSEvent) {
        // 无选区且非交互时：窗口悬停高亮 + 放大镜悬停取色
        guard model.selection == nil, !model.isInteracting else { return }
        let point = globalPoint(event)
        let newHover = smallestWindowFrame(containing: point)
        let hoverChanged = newHover != model.hoverWindowFrame
        let pointMoved = model.currentDragPoint != point
        model.hoverWindowFrame = newHover
        model.currentDragPoint = point
        if hoverChanged || pointMoved {
            delegate?.overlaySelectionDidChange()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = globalPoint(event)
        // 选区内右键 → 上下文菜单；选区外右键 → 清除选区（标注模式下忽略，保护已画内容）
        if model.selection?.insetBy(dx: -2, dy: -2).contains(point) == true {
            delegate?.overlayRequestsContextMenu(at: point)
        } else if model.selection != nil, !model.annotateMode {
            model.selection = nil
            model.hoverWindowFrame = nil
            needsSizeLabel = false
            delegate?.overlaySelectionDidChange()
        }
    }

    override func keyDown(with event: NSEvent) {
        // 标注模式：⌘Z 撤销上一条标注
        if model.annotateMode, event.keyCode == 6, event.modifierFlags.contains(.command) {
            if !model.annotations.isEmpty {
                model.annotations.removeLast()
                delegate?.overlaySelectionDidChange()
            }
            return
        }

        switch event.keyCode {
        case 36: // Return → 确认（标注模式下 = 完成并复制）
            if model.selection != nil {
                delegate?.overlayRequestsConfirm(action: .copy)
            }
        case 8: // C → 复制放大镜中心颜色（悬停/拖拽取色）
            if model.showsMagnifier, let point = model.currentDragPoint {
                delegate?.overlayDidRequestCopyColor(at: point)
            }
        case 49: // Space → 标记（空格 + 拖动 = 移动选区）
            if model.annotateMode { break }
            model.isSpacePressed = true
        case 123...126: // 方向键微调选区
            if let selection = model.selection, !model.isInteracting {
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
                let dy: CGFloat = event.keyCode == 126 ? step : (event.keyCode == 125 ? -step : 0)
                model.selection = ScreenGeometry.movedRect(selection, dx: dx, dy: dy)
                delegate?.overlaySelectionDidChange()
            }
        case 53: // ESC
            delegate?.overlayRequestsCancel()
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            model.isSpacePressed = false
        }
    }

    // MARK: - 坐标与工具

    /// 事件位置 → 全局 AppKit 坐标。
    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        guard let window else { return local }
        return window.convertToScreen(NSRect(origin: local, size: .zero)).origin
    }

    /// 全局 rect → 本视图本地 rect。
    private func toLocal(_ global: CGRect) -> CGRect {
        CGRect(
            x: global.minX - screenFrame.minX,
            y: global.minY - screenFrame.minY,
            width: global.width,
            height: global.height
        )
    }

    /// 拖拽坐标吸附到附近窗口边缘。
    private func snapped(_ point: CGPoint) -> CGPoint {
        ScreenGeometry.snappedPoint(point, toEdgesIn: model.windowFramesNear(point), threshold: 6)
    }

    /// 包含全局点的最小窗口 frame（悬停 / 单击选中）。
    private func smallestWindowFrame(containing point: CGPoint) -> CGRect? {
        model.windowFrames
            .filter { $0.width > 1 && $0.height > 1 && $0.contains(point) }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    /// 任意两点构成的正向矩形（全局坐标）。
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    // MARK: - 选区内标注（批次 2）

    /// 全局点 → 选区本地坐标（原点 = 选区左下角，y 向上，与标注模型一致）。
    private func annotateLocal(_ global: CGPoint, selection: CGRect) -> CGPoint {
        CGPoint(x: global.x - selection.minX, y: global.y - selection.minY)
    }

    private func annotateMouseDown(at globalPoint: CGPoint) {
        guard let selection = model.selection,
              selection.insetBy(dx: -2, dy: -2).contains(globalPoint) else { return }
        let local = annotateLocal(globalPoint, selection: selection)
        model.annotateDragStart = local

        let tool = model.annotateTool
        let style = model.annotateStyle
        switch tool {
        case .numberedMarker:
            // 单击即放置：编号 = 已有编号最大值 + 1
            let number = model.annotations.compactMap { annotation -> Int? in
                if case .numberedMarker(_, let n) = annotation.geometry { return n }
                return nil
            }.max() ?? 0
            model.annotations.append(Annotation(
                type: .numberedMarker,
                geometry: .numberedMarker(center: local, number: number + 1),
                style: style
            ))
            delegate?.overlaySelectionDidChange()
        case .text:
            // 文字：点击处弹出输入浮层，提交后由控制器落标注
            model.annotateDragStart = nil
            delegate?.overlayRequestsTextAnnotation(at: globalPoint)
        case .arrow:
            model.draftAnnotation = Annotation(
                type: .arrow,
                geometry: .arrow(from: local, to: local),
                style: style
            )
            delegate?.overlaySelectionDidChange()
        case .brush:
            model.draftAnnotation = Annotation(
                type: .brush,
                geometry: .brush(points: [local]),
                style: style
            )
            delegate?.overlaySelectionDidChange()
        case .rectangle, .ellipse, .mosaic, .blur:
            model.draftAnnotation = Annotation(
                type: tool,
                geometry: .rect(CGRect(origin: local, size: .zero)),
                style: style
            )
            delegate?.overlaySelectionDidChange()
        }
    }

    private func annotateDragged(to globalPoint: CGPoint) {
        guard let selection = model.selection,
              let start = model.annotateDragStart,
              var draft = model.draftAnnotation else { return }
        let local = annotateLocal(globalPoint, selection: selection)

        switch draft.geometry {
        case .arrow(let from, _):
            draft.geometry = .arrow(from: from, to: local)
        case .brush(let points):
            draft.geometry = .brush(points: points + [local])
        case .rect:
            draft.geometry = .rect(Self.rect(from: start, to: local))
        case .ellipse:
            draft.geometry = .ellipse(inRect: Self.rect(from: start, to: local))
        case .mosaic:
            draft.geometry = .mosaic(Self.rect(from: start, to: local))
        case .blur:
            draft.geometry = .blur(Self.rect(from: start, to: local))
        case .text, .numberedMarker:
            break
        }
        model.draftAnnotation = draft
        delegate?.overlaySelectionDidChange()
    }

    /// 提交草稿（过小的形状丢弃）。
    private func commitAnnotateDraft() {
        defer {
            model.draftAnnotation = nil
            model.annotateDragStart = nil
            delegate?.overlaySelectionDidChange()
        }
        guard let draft = model.draftAnnotation else { return }
        let box = draft.boundingBox()
        switch draft.type {
        case .arrow:
            if box.width < 4 && box.height < 4 { return }
        case .rectangle, .ellipse, .mosaic, .blur:
            if box.width < 3 || box.height < 3 { return }
        case .brush, .text, .numberedMarker:
            break
        }
        model.annotations.append(draft)
    }

    /// 绘制标注（已提交 + 草稿）：CTM 平移到选区本地坐标系，复用统一渲染管线。
    private func drawAnnotations(_ context: CGContext, selection: CGRect) {
        guard selection.intersects(screenFrame) else { return }
        // 马赛克/模糊预览数据源：选区内容像素快照（控制器在进入标注模式时准备）
        var all = model.annotations
        if let draft = model.draftAnnotation { all.append(draft) }
        guard !all.isEmpty else { return }

        context.saveGState()
        context.translateBy(
            x: selection.minX - screenFrame.minX,
            y: selection.minY - screenFrame.minY
        )
        AnnotationRenderer.draw(all, baseImage: model.selectionBaseImage, in: context)
        context.restoreGState()
    }

    // MARK: - 绘制细节

    private func drawCrosshair(_ context: CGContext, at global: CGPoint) {
        let local = CGPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(0.8)
        context.beginPath()
        context.move(to: CGPoint(x: local.x, y: 0))
        context.addLine(to: CGPoint(x: local.x, y: bounds.height))
        context.move(to: CGPoint(x: 0, y: local.y))
        context.addLine(to: CGPoint(x: bounds.width, y: local.y))
        context.strokePath()
    }

    private func drawHighlight(_ context: CGContext, rect global: CGRect) {
        let intersection = global.intersection(screenFrame)
        guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else { return }
        let local = toLocal(intersection)
        // 轻微提亮 + 蓝色描边
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.08).cgColor)
        context.fill(local)
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.stroke(local)
    }

    private func drawHandle(_ context: CGContext, handle: SelectionHandle, on selection: CGRect) {
        let position = handle.position(on: selection)
        // 只绘制落在本屏（含容差）的控制点
        let tolerance: CGFloat = 12
        guard screenFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(position) else { return }
        let center = CGPoint(x: position.x - screenFrame.minX, y: position.y - screenFrame.minY)
        let radius: CGFloat = 4.5
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(selectionBorderColor.cgColor)
        context.setLineWidth(1.5)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
    }

    private func drawSizeLabel(_ context: CGContext, for selection: CGRect) {
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        drawBadge(text, context: context, below: selection)
    }

    private func drawHint(_ context: CGContext) {
        drawBadge(model.hint, context: context, below: nil)
    }

    /// 全局 rect 附近绘制徽标；below 为 nil 时绘制在本屏顶部中央。
    private func drawBadge(_ text: String, context: CGContext, below selection: CGRect?) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let badgeSize = CGSize(width: size.width + padding * 2, height: size.height + padding)

        var origin: CGPoint
        if let selection {
            let localMidX = selection.midX - screenFrame.minX
            let aboveY = selection.maxY - screenFrame.minY + 8
            let belowY = selection.minY - screenFrame.minY - 8 - badgeSize.height
            origin = CGPoint(x: localMidX - badgeSize.width / 2, y: aboveY)
            if aboveY + badgeSize.height > bounds.height {
                origin.y = min(belowY, selection.maxY - screenFrame.minY - badgeSize.height - 4)
            }
        } else {
            origin = CGPoint(x: bounds.midX - badgeSize.width / 2, y: bounds.height - 48)
        }
        origin.x = max(8, min(origin.x, bounds.width - badgeSize.width - 8))
        origin.y = max(8, origin.y)

        let badgeRect = CGRect(origin: origin, size: badgeSize)
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.fillPath()

        (text as NSString).draw(
            at: CGPoint(x: origin.x + padding, y: origin.y + padding - 1),
            withAttributes: attributes
        )
    }

    // MARK: - 放大镜

    /// 在全局点附近绘制放大镜：从屏幕快照裁剪源区域放大显示，附坐标。
    private func drawMagnifier(_ context: CGContext, at global: CGPoint) {
        guard model.showsMagnifier else { return }

        // 源区域（逻辑坐标）
        let sourceRect = CGRect(
            x: global.x - magnifierSourceSize.width / 2,
            y: global.y - magnifierSourceSize.height / 2,
            width: magnifierSourceSize.width,
            height: magnifierSourceSize.height
        )

        // 找到包含该点的屏幕快照
        guard let snapshot = model.snapshots.first(where: { $0.frame.contains(global) }) else { return }
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixelRect = ScreenGeometry.pixelRect(
            logicalRect: sourceRect,
            displayFrame: snapshot.frame,
            imagePixelSize: imageSize
        )
        guard let clamped = ScreenGeometry.clampedPixelRect(pixelRect, in: imageSize),
              let cropped = snapshot.image.cropping(to: clamped)
        else { return }

        // 目标位置：鼠标右下 20pt，越界换象限
        let size = magnifierSize
        var origin = CGPoint(
            x: global.x - screenFrame.minX + 20,
            y: global.y - screenFrame.minY - size.height - 20
        )
        if origin.x + size.width > bounds.width { origin.x = global.x - screenFrame.minX - size.width - 20 }
        if origin.y < 0 { origin.y = global.y - screenFrame.minY + 20 }
        origin.x = max(4, min(origin.x, bounds.width - size.width - 4))
        origin.y = max(4, min(origin.y, bounds.height - size.height - 4))
        let target = CGRect(origin: origin, size: size)

        // 边框背景
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.fill(target)
        // 图像（等比放大填充；源裁剪已按比例对齐，直接拉伸即可）
        context.saveGState()
        context.clip(to: target)
        context.interpolationQuality = .none
        context.draw(cropped, in: target)
        context.restoreGState()

        // 中心十字线
        let center = CGPoint(x: target.midX, y: target.midY)
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.beginPath()
        context.move(to: CGPoint(x: center.x - 8, y: center.y))
        context.addLine(to: CGPoint(x: center.x + 8, y: center.y))
        context.move(to: CGPoint(x: center.x, y: center.y - 8))
        context.addLine(to: CGPoint(x: center.x, y: center.y + 8))
        context.strokePath()

        // 外框 + 坐标/颜色
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.stroke(target)

        let color = PixelColorReader.color(at: global, snapshots: model.snapshots)
        let coordText = "\(Int(global.x.rounded())), \(Int(global.y.rounded()))"
        let infoText = color.map { "\(coordText)  \($0.hex)" } ?? coordText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (infoText as NSString).size(withAttributes: attributes)
        // 色板占位（有颜色时在文本左侧绘制 10×10 色块）
        let swatchWidth: CGFloat = color != nil ? 14 : 0
        let badgeWidth = textSize.width + 10 + swatchWidth
        let badgeHeight = textSize.height + 4
        let badgeOrigin = CGPoint(
            x: target.midX - badgeWidth / 2,
            y: target.minY - badgeHeight - 6
        )
        if badgeOrigin.y >= 0 {
            let badgeRect = CGRect(origin: badgeOrigin, size: CGSize(width: badgeWidth, height: badgeHeight))
            context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
            context.fill(badgeRect)
            if let color {
                let swatchRect = CGRect(x: badgeRect.minX + 4, y: badgeRect.midY - 5, width: 10, height: 10)
                context.setFillColor(CGColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1))
                context.fill(swatchRect)
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                context.setLineWidth(0.8)
                context.stroke(swatchRect)
            }
            (infoText as NSString).draw(
                at: CGPoint(x: badgeRect.minX + swatchWidth + 5, y: badgeRect.minY + 2),
                withAttributes: attributes
            )
        }

        // 取色复制反馈（"已复制 #RRGGBB"）
        if let feedback = model.colorCopyFeedback {
            let feedbackAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let feedbackSize = (feedback as NSString).size(withAttributes: feedbackAttributes)
            let feedbackRect = CGRect(
                x: target.midX - feedbackSize.width / 2 - 5,
                y: target.maxY + 6,
                width: feedbackSize.width + 10,
                height: feedbackSize.height + 4
            )
            context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
            context.fill(feedbackRect)
            (feedback as NSString).draw(at: CGPoint(x: feedbackRect.minX + 5, y: feedbackRect.minY + 2), withAttributes: feedbackAttributes)
        }
    }
}
