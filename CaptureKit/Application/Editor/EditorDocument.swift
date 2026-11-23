import Combine
import CoreGraphics
import Foundation

/// 编辑命令（Command Pattern，DESIGN.md §7.4）。
/// 只保存操作数据，不保存图片副本；add/remove/update 覆盖移动、缩放、改样式、改文字。
/// setCrop 同时记录裁剪区与标注集合（非破坏性裁剪的撤销）。
enum EditorCommand: Equatable {
    case add(Annotation)
    case remove(Annotation)
    case update(from: Annotation, to: Annotation)
    case setCrop(from: CropState, to: CropState)

    struct CropState: Equatable {
        /// 原始图像坐标系内的裁剪区（nil = 未裁剪）
        var cropRect: CGRect?
        var annotations: [Annotation]
    }

    /// 应用到标注数组（纯函数，可单测；setCrop 的 cropRect 由 EditorDocument 处理）。
    static func apply(_ command: EditorCommand, to annotations: inout [Annotation]) {
        switch command {
        case .add(let annotation):
            annotations.append(annotation)
        case .remove(let annotation):
            annotations.removeAll { $0.id == annotation.id }
        case .update(_, let to):
            if let index = annotations.firstIndex(where: { $0.id == to.id }) {
                annotations[index] = to
            }
        case .setCrop(_, let to):
            annotations = to.annotations
        }
    }

    /// 逆应用（撤销）。
    static func revert(_ command: EditorCommand, to annotations: inout [Annotation]) {
        switch command {
        case .add(let annotation):
            annotations.removeAll { $0.id == annotation.id }
        case .remove(let annotation):
            annotations.append(annotation)
        case .update(let from, _):
            if let index = annotations.firstIndex(where: { $0.id == from.id }) {
                annotations[index] = from
            }
        case .setCrop(let from, _):
            annotations = from.annotations
        }
    }
}

/// 编辑器工具（含选择工具，ui-design.md §6.4）。
enum EditorTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case rectangle
    case ellipse
    case text
    case brush
    case mosaic
    case blur
    case numberedMarker
    case crop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .select: return "选择"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .brush: return "画笔"
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        case .numberedMarker: return "编号"
        case .crop: return "裁剪"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow.click"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .text: return "textformat"
        case .brush: return "pencil.tip"
        case .mosaic: return "square.grid.3x3"
        case .blur: return "drop.halffull"
        case .numberedMarker: return "number.circle"
        case .crop: return "crop"
        }
    }

    /// 快捷键（ui-design.md §6.4）。
    var shortcutKey: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .text: return "T"
        case .brush: return "P"
        case .mosaic: return "M"
        case .blur: return "B"
        case .numberedMarker: return "N"
        case .crop: return "C"
        }
    }

    var annotationType: AnnotationType? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .brush: return .brush
        case .mosaic: return .mosaic
        case .blur: return .blur
        case .numberedMarker: return .numberedMarker
        }
    }

    /// 拖拽创建的是区域型标注（矩形框选）。
    var createsRectAnnotation: Bool {
        switch self {
        case .rectangle, .ellipse, .mosaic, .blur: return true
        default: return false
        }
    }
}

/// 编辑器文档：原始图片 + 标注集合 + 裁剪状态 + 工具状态 + 撤销重做栈。
/// 原始图片永不修改（非破坏性，plan.md §2.4.3）：裁剪只是记录 cropRect，
/// 显示与导出统一使用 effectiveImage（baseImage 按 cropRect 裁剪的缓存）。
@MainActor
final class EditorDocument: ObservableObject {
    let baseImage: CGImage
    let createdAt = Date()

    @Published private(set) var annotations: [Annotation] = []
    @Published var selectedAnnotationID: UUID?
    @Published var activeTool: EditorTool = .arrow
    /// 当前工具样式（新标注使用；Inspector 修改目标）
    @Published var toolStyle: AnnotationStyle = .default

    /// 裁剪区（原始图像坐标；nil = 未裁剪）
    @Published private(set) var cropRect: CGRect?
    /// 裁剪比例约束（nil = 自由；由 Inspector 设置）
    @Published var cropAspect: CGFloat?
    /// 裁剪交互中的草稿框（当前 effective 坐标系；由画布写入，不入撤销栈）
    @Published var cropDraft: CGRect?

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// 自上次导出（复制/保存）后是否有未导出的修改
    @Published private(set) var hasUnexportedChanges = false

    private var undoStack: [EditorCommand] = []
    private var redoStack: [EditorCommand] = []

    /// Inspector 实时编辑的样式基准（slider 拖动结束才入栈）
    private var liveStyleEditBase: AnnotationStyle?

    /// 裁剪后的有效图像（缓存；cropRect 变化时重算）
    private(set) var effectiveImage: CGImage

    init(baseImage: CGImage) {
        self.baseImage = baseImage
        self.effectiveImage = baseImage
    }

    var selectedAnnotation: Annotation? {
        annotations.first { $0.id == selectedAnnotationID }
    }

    /// Inspector 展示样式：选中标注 → 其样式；否则工具样式。
    var displayStyle: AnnotationStyle {
        selectedAnnotation?.style ?? toolStyle
    }

    /// 下一个编号标注的序号（当前最大 + 1）。
    func nextMarkerNumber() -> Int {
        let numbers = annotations.compactMap { annotation -> Int? in
            if case .numberedMarker(_, let number) = annotation.geometry {
                return number
            }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: - 裁剪

    /// 应用裁剪（rect 为当前 effective 坐标系）。
    /// 标注平移到新坐标系；完全落在裁剪区外的标注被剔除。
    func applyCrop(_ rect: CGRect) {
        guard rect.width >= 4, rect.height >= 4 else { return }

        let originalOrigin = cropRect?.origin ?? .zero
        let newCropRect = CGRect(
            x: originalOrigin.x + rect.minX,
            y: originalOrigin.y + rect.minY,
            width: rect.width,
            height: rect.height
        )
        let newBounds = CGRect(origin: .zero, size: rect.size)
        let newAnnotations = annotations.map { annotation -> Annotation in
            var moved = annotation
            moved.geometry = annotation.geometry.translated(dx: -rect.minX, dy: -rect.minY)
            return moved
        }.filter { annotation in
            annotation.boundingBox().intersection(newBounds).width > 0
                || annotation.boundingBox().intersection(newBounds).height > 0
        }

        let from = EditorCommand.CropState(cropRect: cropRect, annotations: annotations)
        let to = EditorCommand.CropState(cropRect: newCropRect, annotations: newAnnotations)

        record(.setCrop(from: from, to: to))
        cropRect = newCropRect
        recomputeEffectiveImage()
        selectedAnnotationID = nil
        hasUnexportedChanges = true
    }

    /// 取消裁剪，恢复完整图像（标注回到原始坐标）。
    func resetCrop() {
        guard let current = cropRect else { return }
        let from = EditorCommand.CropState(cropRect: current, annotations: annotations)
        // 逆平移：当前坐标 → 原始坐标
        let restored = annotations.map { annotation -> Annotation in
            var moved = annotation
            moved.geometry = annotation.geometry.translated(dx: current.minX, dy: current.minY)
            return moved
        }
        let to = EditorCommand.CropState(cropRect: nil, annotations: restored)
        record(.setCrop(from: from, to: to))
        cropRect = nil
        recomputeEffectiveImage()
        hasUnexportedChanges = true
    }

    private func recomputeEffectiveImage() {
        guard let crop = cropRect else {
            effectiveImage = baseImage
            return
        }
        let pixelRect = ScreenGeometry.pixelRect(
            logicalRect: crop,
            displayFrame: CGRect(origin: .zero, size: CGSize(width: baseImage.width, height: baseImage.height)),
            imagePixelSize: CGSize(width: baseImage.width, height: baseImage.height)
        )
        if let clamped = ScreenGeometry.clampedPixelRect(pixelRect, in: CGSize(width: baseImage.width, height: baseImage.height)),
           let cropped = baseImage.cropping(to: clamped) {
            effectiveImage = cropped
        } else {
            effectiveImage = baseImage
            self.cropRect = nil
        }
    }

    /// 导出后清除未导出标记。
    func markExported() {
        hasUnexportedChanges = false
    }

    // MARK: - 命令入口

    func add(_ annotation: Annotation) {
        record(.add(annotation))
        selectedAnnotationID = annotation.id
    }

    func update(_ annotation: Annotation) {
        guard let old = annotations.first(where: { $0.id == annotation.id }) else { return }
        record(.update(from: old, to: annotation))
    }

    func remove(id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        record(.remove(annotation))
        if selectedAnnotationID == id { selectedAnnotationID = nil }
    }

    func removeSelected() {
        guard let id = selectedAnnotationID else { return }
        remove(id: id)
    }

    func move(id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        var moved = annotation
        moved.geometry = annotation.geometry.translated(dx: dx, dy: dy)
        record(.update(from: annotation, to: moved))
    }

    func resize(id: UUID, from sourceBox: CGRect, to targetBox: CGRect) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        var resized = annotation
        resized.geometry = annotation.geometry.scaled(from: sourceBox, to: targetBox)
        // 文字字号随包围盒高度等比调整
        if annotation.type == .text, sourceBox.height > 1 {
            resized.style.fontSize = max(9, annotation.style.fontSize * targetBox.height / sourceBox.height)
        }
        record(.update(from: annotation, to: resized))
    }

    // MARK: - 样式（Inspector）

    /// 开始一次实时样式编辑（中间态不入撤销栈）。
    func beginStyleEdit() {
        liveStyleEditBase = displayStyle
    }

    /// 实时修改样式（不入栈；直接驱动渲染）。
    func setStyleLive(_ style: AnnotationStyle) {
        if let id = selectedAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].style = style
        } else {
            toolStyle = style
        }
    }

    /// 结束实时样式编辑（一条命令入栈）。
    func endStyleEdit() {
        defer { liveStyleEditBase = nil }
        guard let base = liveStyleEditBase else { return }
        if let id = selectedAnnotationID,
           let current = annotations.first(where: { $0.id == id }) {
            if current.style != base {
                var restored = current
                restored.style = base
                recordWithoutApply(.update(from: restored, to: current))
            }
        } else if toolStyle != base {
            // 工具样式不入撤销栈（未产生对象变更）
        }
    }

    // MARK: - 撤销 / 重做

    func undo() {
        guard let command = undoStack.popLast() else { return }
        EditorCommand.revert(command, to: &annotations)
        redoStack.append(command)
        syncStackState()

        // 撤销 add → 取消其选中
        if case .add(let a) = command, selectedAnnotationID == a.id {
            selectedAnnotationID = nil
        }
        // 撤销 remove → 恢复选中
        if case .remove(let a) = command {
            selectedAnnotationID = a.id
        }
        // 撤销裁剪 → 恢复裁剪区与有效图像
        if case .setCrop(let from, _) = command {
            cropRect = from.cropRect
            recomputeEffectiveImage()
        }
        hasUnexportedChanges = true
        Log.editor.debug("Undo (\(self.undoStack.count) left)")
    }

    func redo() {
        guard let command = redoStack.popLast() else { return }
        EditorCommand.apply(command, to: &annotations)
        undoStack.append(command)
        syncStackState()
        if case .setCrop(_, let to) = command {
            cropRect = to.cropRect
            recomputeEffectiveImage()
        }
        hasUnexportedChanges = true
        Log.editor.debug("Redo (\(self.redoStack.count) left)")
    }

    // MARK: - 私有

    private func record(_ command: EditorCommand) {
        EditorCommand.apply(command, to: &annotations)
        undoStack.append(command)
        redoStack.removeAll()
        syncStackState()
        hasUnexportedChanges = true
    }

    /// 样式实时编辑已直接应用到数组，只补记命令。
    private func recordWithoutApply(_ command: EditorCommand) {
        undoStack.append(command)
        redoStack.removeAll()
        syncStackState()
        hasUnexportedChanges = true
    }

    private func syncStackState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
