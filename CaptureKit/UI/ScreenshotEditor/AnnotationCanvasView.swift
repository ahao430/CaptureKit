import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// 画布视口：图像坐标 ↔ 视图坐标转换（纯值类型，可单测）。
/// 视图为非翻转坐标（y 向上），图像坐标 y 向上、原点在图像左下。
struct CanvasViewport: Equatable {
    var zoom: CGFloat = 1
    /// 图像 (0,0) 在视图坐标中的位置
    var origin: CGPoint = .zero

    static let zoomRange: ClosedRange<CGFloat> = 0.1...8

    /// 适应视图（等比缩小显示整图，不放大超过 100%）。
    static func fitted(imageSize: CGSize, in viewSize: CGSize, padding: CGFloat = 24) -> CanvasViewport {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > padding * 2, viewSize.height > padding * 2 else {
            return CanvasViewport(zoom: 1, origin: .zero)
        }
        let zoom = min(
            (viewSize.width - padding * 2) / imageSize.width,
            (viewSize.height - padding * 2) / imageSize.height,
            1
        )
        let origin = CGPoint(
            x: (viewSize.width - imageSize.width * zoom) / 2,
            y: (viewSize.height - imageSize.height * zoom) / 2
        )
        return CanvasViewport(zoom: zoom, origin: origin)
    }

    func viewPoint(forImagePoint p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x * zoom, y: origin.y + p.y * zoom)
    }

    func imagePoint(forViewPoint p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom)
    }

    func imageViewRect(imageSize: CGSize) -> CGRect {
        CGRect(origin: origin, size: CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom))
    }

    /// 锚定某视图点缩放（该点对应图像内容在屏幕上不动）。
    func zoomed(to newZoom: CGFloat, around anchor: CGPoint) -> CanvasViewport {
        let clamped = min(max(newZoom, CanvasViewport.zoomRange.lowerBound), CanvasViewport.zoomRange.upperBound)
        guard clamped != zoom else { return self }
        // 保持 anchor 的图像点映射不变：origin' = anchor - (anchor - origin) * (zoom'/zoom)
        let ratio = clamped / zoom
        return CanvasViewport(
            zoom: clamped,
            origin: CGPoint(
                x: anchor.x - (anchor.x - origin.x) * ratio,
                y: anchor.y - (anchor.y - origin.y) * ratio
            )
        )
    }

    func panned(by delta: CGPoint) -> CanvasViewport {
        CanvasViewport(zoom: zoom, origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
    }
}

/// 画布交互状态。
enum CanvasInteraction {
    case none
    case panning(lastViewPoint: CGPoint)
    case creating(startImagePoint: CGPoint)
    case moving(annotationID: UUID, lastImagePoint: CGPoint)
    case resizing(annotationID: UUID, originalBox: CGRect, handle: SelectionHandle)
    case editingText
}

/// 编辑器画布（AppKit，DESIGN.md §7.2 Canvas）：
/// 显示原始图片 + 标注（统一渲染管线），处理缩放/平移/创建/选中/移动/调整/文字编辑。
@MainActor
final class AnnotationCanvasView: NSView {
    let document: EditorDocument

    var viewport = CanvasViewport() {
        didSet { needsDisplay = true; repositionTextField() }
    }

    var drafting: Annotation?
    var interaction: CanvasInteraction = .none

    /// 用户手动缩放/平移后不再自动适应窗口
    private var isViewportUserModified = false
    private var isSpacePressed = false

    private var imageSize: CGSize {
        CGSize(width: document.effectiveImage.width, height: document.effectiveImage.height)
    }

    // MARK: - 文本编辑

    private lazy var canvasTextField: CanvasTextField = {
        let field = CanvasTextField()
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.controlBackgroundColor
        field.focusRingType = .exterior
        field.target = self
        field.action = #selector(textFieldSubmitted)
        field.onEscape = { [weak self] in self?.finishTextEditing(commit: false) }
        return field
    }()

    /// 正在编辑的文本标注（nil = 新建）
    private var editingAnnotationID: UUID?
    private var editingOrigin: CGPoint = .zero

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        postsFrameChangedNotifications = true
    }

    override func layout() {
        super.layout()
        // 首次布局 & 未被用户改过视口时，随尺寸重适配（窗口从大变小/初次显示都归位）
        if !isViewportUserModified, bounds.width > 1, bounds.height > 1 {
            viewport = .fitted(imageSize: imageSize, in: bounds.size)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if !isViewportUserModified {
            viewport = .fitted(imageSize: imageSize, in: bounds.size)
        }
    }

    // MARK: - 同步（SwiftUI → 画布重绘）

    func syncFromDocument() {
        needsDisplay = true
    }

    // MARK: - 光标 / 响应链

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor = isSpacePressed ? .closedHand : (document.activeTool == .select ? .arrow : .crosshair)
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 画布底色
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(bounds)

        let imageRect = viewport.imageViewRect(imageSize: imageSize)

        // 原始图片（裁剪后的有效图像）
        context.saveGState()
        context.clip(to: imageRect)
        context.interpolationQuality = .medium
        context.draw(document.effectiveImage, in: imageRect)
        context.restoreGState()

        // 标注（统一渲染管线；变换到图像坐标系）
        context.saveGState()
        context.clip(to: imageRect)
        context.translateBy(x: viewport.origin.x, y: viewport.origin.y)
        context.scaleBy(x: viewport.zoom, y: viewport.zoom)
        AnnotationRenderer.draw(document.annotations, baseImage: document.effectiveImage, in: context)
        if let drafting {
            AnnotationRenderer.draw(drafting, baseImage: document.effectiveImage, in: context)
        }
        context.restoreGState()

        // 裁剪草稿（裁剪模式下）
        if document.activeTool == .crop, let draft = document.cropDraft {
            drawCropDraft(context, draft: draft)
        }

        // 选中效果（视图坐标绘制，控制点不随缩放变形）
        if document.activeTool != .crop, let selected = document.selectedAnnotation {
            drawSelectionOverlay(context, annotation: selected)
        }
    }

    /// 裁剪草稿：框外暗化 + 白色边框 + 操作提示。
    private func drawCropDraft(_ context: CGContext, draft: CGRect) {
        let viewRect = imageRectToView(draft)
        // 框外暗化
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fill(bounds)
        // 框内恢复（在原始位置重画图像，clip 限制到框内）
        let imageRect = viewport.imageViewRect(imageSize: imageSize)
        context.saveGState()
        context.clip(to: viewRect)
        context.interpolationQuality = .medium
        context.draw(document.effectiveImage, in: imageRect)
        context.restoreGState()
        // 边框 + 提示
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(viewRect)
        drawCanvasBadge(
            context,
            text: "⏎ 应用裁剪 · ⎋ 取消 · \(Int(draft.width)) × \(Int(draft.height))",
            above: viewRect
        )
    }

    /// 画布内顶部徽标。
    private func drawCanvasBadge(_ context: CGContext, text: String, above rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let badge = CGRect(
            x: max(8, min(rect.midX - size.width / 2 - 8, bounds.width - size.width - 20)),
            y: min(rect.maxY + 8, bounds.height - size.height - 12),
            width: size.width + 16,
            height: size.height + 8
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.fill(badge)
        (text as NSString).draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 4), withAttributes: attributes)
    }

    /// 图像坐标 rect → 视图坐标 rect。
    private func imageRectToView(_ rect: CGRect) -> CGRect {
        CGRect(
            x: viewport.viewPoint(forImagePoint: rect.origin).x,
            y: viewport.viewPoint(forImagePoint: rect.origin).y,
            width: rect.width * viewport.zoom,
            height: rect.height * viewport.zoom
        )
    }

    private func drawSelectionOverlay(_ context: CGContext, annotation: Annotation) {
        let viewRect = imageRectToView(annotation.boundingBox())
        guard viewRect.width > 2, viewRect.height > 2 else { return }

        // 虚线框
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(viewRect)
        context.setLineDash(phase: 0, lengths: [])

        // 8 控制点
        for handle in SelectionHandle.allCases {
            let position = handle.position(on: viewRect)
            let radius: CGFloat = 4
            let rect = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1.2)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    // MARK: - 事件：缩放 / 平移

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // ⌘/⌥ + 滚轮 → 缩放
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let factor: CGFloat = delta > 0 ? 1.1 : 1 / 1.1
            let anchor = convert(event.locationInWindow, from: nil)
            viewport = viewport.zoomed(to: viewport.zoom * factor, around: anchor)
            isViewportUserModified = true
        } else {
            // 普通滚轮 / 触控板滚动 → 平移
            viewport = viewport.panned(by: CGPoint(x: -event.scrollingDeltaX, y: event.scrollingDeltaY))
            isViewportUserModified = true
        }
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        viewport = viewport.zoomed(to: viewport.zoom * (1 + event.magnification), around: anchor)
        isViewportUserModified = true
    }

    // MARK: - 事件：标注交互

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)

        // 空格按住 → 平移优先
        if isSpacePressed {
            interaction = .panning(lastViewPoint: viewPoint)
            return
        }

        let imagePoint = viewport.imagePoint(forViewPoint: viewPoint)

        // 双击：文本标注进入编辑
        if event.clickCount == 2, document.activeTool == .select {
            if let hit = hitAnnotation(at: imagePoint), hit.type == .text {
                beginTextEditing(annotation: hit)
                return
            }
        }

        switch document.activeTool {
        case .select:
            // 已选中的 → 优先控制点
            if let selected = document.selectedAnnotation,
               let handle = handleHit(at: viewPoint, annotation: selected) {
                interaction = .resizing(
                    annotationID: selected.id,
                    originalBox: selected.boundingBox(),
                    handle: handle
                )
                return
            }
            if let hit = hitAnnotation(at: imagePoint) {
                document.selectedAnnotationID = hit.id
                interaction = .moving(annotationID: hit.id, lastImagePoint: imagePoint)
            } else {
                document.selectedAnnotationID = nil
                interaction = .none
            }

        case .crop:
            // 裁剪模式：拖出新裁剪框
            document.selectedAnnotationID = nil
            interaction = .creating(startImagePoint: imagePoint)
            document.cropDraft = CGRect(origin: imagePoint, size: .zero)

        case .arrow, .rectangle, .ellipse, .brush, .mosaic, .blur:
            document.selectedAnnotationID = nil
            interaction = .creating(startImagePoint: imagePoint)
            beginDrafting(at: imagePoint)

        case .numberedMarker:
            // 点击即创建编号标注
            let annotation = Annotation(
                type: .numberedMarker,
                geometry: .numberedMarker(center: imagePoint, number: document.nextMarkerNumber()),
                style: document.toolStyle
            )
            document.add(annotation)
            document.activeTool = .select

        case .text:
            // 点击位置输入文字
            beginTextEditing(at: imagePoint)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = viewport.imagePoint(forViewPoint: viewPoint)

        switch interaction {
        case .none:
            break
        case .panning(let last):
            viewport = viewport.panned(by: CGPoint(x: viewPoint.x - last.x, y: viewPoint.y - last.y))
            isViewportUserModified = true
            interaction = .panning(lastViewPoint: viewPoint)
        case .creating:
            if document.activeTool == .crop {
                // 裁剪框：支持比例约束
                if case .creating(let start) = interaction {
                    document.cropDraft = ScreenGeometry.aspectConstrainedRect(
                        from: start,
                        to: imagePoint,
                        aspect: document.cropAspect
                    )
                }
            } else {
                updateDrafting(to: imagePoint)
            }
        case .moving(let id, let last):
            document.move(id: id, dx: imagePoint.x - last.x, dy: imagePoint.y - last.y)
            interaction = .moving(annotationID: id, lastImagePoint: imagePoint)
        case .resizing(let id, let originalBox, let handle):
            let originalViewBox = CGRect(
                x: viewport.viewPoint(forImagePoint: originalBox.origin).x,
                y: viewport.viewPoint(forImagePoint: originalBox.origin).y,
                width: originalBox.width * viewport.zoom,
                height: originalBox.height * viewport.zoom
            )
            let newViewBox = ScreenGeometry.resizeRect(originalViewBox, handle: handle, to: viewPoint)
            // 视图 box → 图像 box
            let newImageBox = CGRect(
                x: viewport.imagePoint(forViewPoint: newImageOrigin(newViewBox)).x,
                y: viewport.imagePoint(forViewPoint: newImageOrigin(newViewBox)).y,
                width: newViewBox.width / viewport.zoom,
                height: newViewBox.height / viewport.zoom
            )
            document.resize(id: id, from: originalBox, to: newImageBox)
            interaction = .resizing(annotationID: id, originalBox: originalBox, handle: handle)
        case .editingText:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction {
        case .creating:
            if document.activeTool == .crop {
                // 裁剪框松开：太小则丢弃，否则保留等待 Enter 确认
                if let draft = document.cropDraft, draft.width < 8 || draft.height < 8 {
                    document.cropDraft = nil
                }
            } else if let draft = drafting, isDraftValid(draft) {
                document.add(draft)
                if document.activeTool != .select {
                    // 绘制完成切回选择便于继续调整（ui-design.md §2.4.1：绘制完成后进入对象选中状态）
                    document.activeTool = .select
                }
                drafting = nil
            } else {
                drafting = nil
            }
        case .moving, .resizing, .panning, .none, .editingText:
            break
        }
        interaction = .none
        needsDisplay = true
    }

    /// 应用当前裁剪草稿（Enter）。
    private func commitCropDraft() {
        guard let draft = document.cropDraft else { return }
        document.cropDraft = nil
        document.applyCrop(draft)
        document.activeTool = .select
        // 裁剪后重新适应窗口
        viewport = .fitted(imageSize: imageSize, in: bounds.size)
        isViewportUserModified = false
        needsDisplay = true
    }

    /// 取消裁剪草稿（ESC）。
    private func cancelCropDraft() {
        document.cropDraft = nil
        document.activeTool = .select
        needsDisplay = true
    }

    private func newImageOrigin(_ viewRect: CGRect) -> CGPoint {
        // 视图 rect 的左下角 → 图像坐标
        viewport.imagePoint(forViewPoint: CGPoint(x: viewRect.minX, y: viewRect.minY))
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        // ⌘Z / ⌘⇧Z（焦点在画布时的兜底；SwiftUI 按钮另有快捷键）
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) {
                document.redo()
            } else {
                document.undo()
            }
            needsDisplay = true
            return
        }

        // 裁剪草稿确认/取消
        if document.activeTool == .crop {
            switch event.keyCode {
            case 36: // Enter
                commitCropDraft()
                return
            case 53: // ESC
                cancelCropDraft()
                return
            default:
                break
            }
        }

        // 裸键：工具切换 / 删除 / 空格
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad]).isEmpty || event.keyCode == 49 || event.keyCode == 51 || event.keyCode == 117 else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 49: // Space → 平移模式
            isSpacePressed = true
            resetCursorRects()
            NSCursor.closedHand.set()
        case 51, 117: // Delete / Backspace
            if document.selectedAnnotationID != nil {
                document.removeSelected()
                needsDisplay = true
            }
        default:
            if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if let tool = EditorTool.allCases.first(where: { $0.shortcutKey.lowercased() == key }) {
                    // 切换工具时丢弃裁剪草稿
                    if tool != .crop, document.cropDraft != nil {
                        document.cropDraft = nil
                    }
                    document.activeTool = tool
                    document.selectedAnnotationID = nil
                    needsDisplay = true
                }
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpacePressed = false
            resetCursorRects()
            NSCursor.arrow.set()
        }
    }

    // MARK: - 标注创建

    private func beginDrafting(at point: CGPoint) {
        guard let type = document.activeTool.annotationType else { return }
        let style = document.toolStyle
        switch type {
        case .arrow:
            drafting = Annotation(type: .arrow, geometry: .arrow(from: point, to: point), style: style)
        case .rectangle:
            drafting = Annotation(type: .rectangle, geometry: .rect(CGRect(origin: point, size: .zero)), style: style)
        case .ellipse:
            drafting = Annotation(type: .ellipse, geometry: .ellipse(inRect: CGRect(origin: point, size: .zero)), style: style)
        case .brush:
            drafting = Annotation(type: .brush, geometry: .brush(points: [point]), style: style)
        case .mosaic:
            drafting = Annotation(type: .mosaic, geometry: .mosaic(CGRect(origin: point, size: .zero)), style: style)
        case .blur:
            drafting = Annotation(type: .blur, geometry: .blur(CGRect(origin: point, size: .zero)), style: style)
        case .text, .numberedMarker:
            break
        }
    }

    private func updateDrafting(to point: CGPoint) {
        guard var draft = drafting else { return }
        switch draft.geometry {
        case .arrow(let from, _):
            draft.geometry = .arrow(from: from, to: point)
        case .rect:
            draft.geometry = .rect(Self.rect(from: startImagePoint(), to: point))
        case .ellipse:
            draft.geometry = .ellipse(inRect: Self.rect(from: startImagePoint(), to: point))
        case .brush(var points):
            if let last = points.last, hypot(last.x - point.x, last.y - point.y) >= 1.5 {
                points.append(point)
                draft.geometry = .brush(points: points)
            }
        case .mosaic:
            draft.geometry = .mosaic(Self.rect(from: startImagePoint(), to: point))
        case .blur:
            draft.geometry = .blur(Self.rect(from: startImagePoint(), to: point))
        case .text, .numberedMarker:
            break
        }
        drafting = draft
    }

    private func startImagePoint() -> CGPoint {
        if case .creating(let start) = interaction { return start }
        return .zero
    }

    private func isDraftValid(_ draft: Annotation) -> Bool {
        switch draft.geometry {
        case .arrow(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case .rect(let rect), .ellipse(let rect), .mosaic(let rect), .blur(let rect):
            return rect.width >= 4 && rect.height >= 4
        case .brush(let points):
            return points.count >= 2
        case .text, .numberedMarker:
            return false
        }
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - 命中检测

    private func hitAnnotation(at imagePoint: CGPoint) -> Annotation? {
        // 从数组尾部（最上层）向前找
        for annotation in document.annotations.reversed() {
            if annotation.hitTest(contains: imagePoint, tolerance: 6 / viewport.zoom) {
                return annotation
            }
        }
        return nil
    }

    private func handleHit(at viewPoint: CGPoint, annotation: Annotation) -> SelectionHandle? {
        let bbox = annotation.boundingBox()
        let viewRect = CGRect(
            x: viewport.viewPoint(forImagePoint: bbox.origin).x,
            y: viewport.viewPoint(forImagePoint: bbox.origin).y,
            width: bbox.width * viewport.zoom,
            height: bbox.height * viewport.zoom
        )
        return ScreenGeometry.handle(at: viewPoint, of: viewRect, tolerance: 9)
    }

    // MARK: - 文本编辑

    private func beginTextEditing(at imagePoint: CGPoint) {
        finishTextEditing(commit: true)
        editingAnnotationID = nil
        editingOrigin = imagePoint
        showTextField(text: "", at: imagePoint)
    }

    private func beginTextEditing(annotation: Annotation) {
        finishTextEditing(commit: true)
        guard case .text(let origin, let string) = annotation.geometry else { return }
        editingAnnotationID = annotation.id
        editingOrigin = origin
        showTextField(text: string, at: origin)
    }

    private func showTextField(text: String, at imagePoint: CGPoint) {
        let style = document.displayStyle
        canvasTextField.stringValue = text
        canvasTextField.font = .systemFont(ofSize: max(12, style.fontSize * viewport.zoom))
        let viewPoint = viewport.viewPoint(forImagePoint: imagePoint)
        let width: CGFloat = max(160, min(320, bounds.width - viewPoint.x - 8))
        let height = max(24, style.fontSize * viewport.zoom + 10)
        canvasTextField.frame = NSRect(
            x: max(4, min(viewPoint.x, bounds.width - width - 4)),
            y: max(4, min(viewPoint.y, bounds.height - height - 4)),
            width: width,
            height: height
        )
        addSubview(canvasTextField)
        window?.makeFirstResponder(canvasTextField)
        interaction = .editingText
    }

    private func repositionTextField() {
        guard canvasTextField.superview != nil else { return }
        let style = document.displayStyle
        let viewPoint = viewport.viewPoint(forImagePoint: editingOrigin)
        let height = max(24, style.fontSize * viewport.zoom + 10)
        canvasTextField.setFrameOrigin(CGPoint(x: max(4, viewPoint.x), y: max(4, min(viewPoint.y, bounds.height - height - 4))))
    }

    @objc private func textFieldSubmitted() {
        finishTextEditing(commit: true)
    }

    private func finishTextEditing(commit: Bool) {
        guard canvasTextField.superview != nil else {
            interaction = .none
            return
        }
        let text = canvasTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        canvasTextField.removeFromSuperview()

        if commit {
            if let id = editingAnnotationID {
                if let existing = document.annotations.first(where: { $0.id == id }) {
                    var updated = existing
                    if text.isEmpty {
                        document.remove(id: id)
                    } else {
                        updated.geometry = .text(origin: editingOrigin, string: text)
                        document.update(updated)
                    }
                }
            } else if !text.isEmpty {
                let annotation = Annotation(
                    type: .text,
                    geometry: .text(origin: editingOrigin, string: text),
                    style: document.toolStyle
                )
                document.add(annotation)
            }
        }
        editingAnnotationID = nil
        interaction = .none
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

/// 拦截 Esc 的文本字段。
@MainActor
final class CanvasTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// SwiftUI 桥接。
struct AnnotationCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(document: document)
        view.viewport = .fitted(
            imageSize: CGSize(width: document.baseImage.width, height: document.baseImage.height),
            in: CGSize(width: max(600, CGFloat(document.baseImage.width)), height: max(400, CGFloat(document.baseImage.height)))
        )
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        // 文档任何发布变化 → 画布重绘（视口与交互状态归画布所有，不受 SwiftUI 渲染影响）
        nsView.syncFromDocument()
    }
}
