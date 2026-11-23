import AppKit

/// Overlay 总控（design.md §6.6 CaptureOverlayController）。
///
/// 职责：
/// - 为每个显示器创建透明全屏窗口。
/// - 汇总各屏视图事件，维护共享选区模型。
/// - 异步加载屏幕快照与窗口列表（放大镜 / 悬停高亮 / 吸附）。
/// - 管理选区工具栏的位置与显隐。
/// - 监听显示器配置变化，自动取消。
/// - 通过 onFinish 一次性向 CaptureCoordinator 报告结果。
@MainActor
final class CaptureOverlayController: CaptureOverlayViewDelegate {
    enum Mode {
        case region
        case window
        /// 录制区域选择（Phase 4）：Enter 直接开始录制，不显示截图工具栏。
        case recordRegion
        /// 录制窗口选择（Phase 4 批次 2）：双击窗口开始录制。
        case recordWindow

        var hint: String {
            switch self {
            case .region: return "拖拽选择区域 · 单击选中窗口 · 双击捕获窗口 · 右键更多"
            case .window: return "单击选中窗口 · 双击捕获窗口 · 右键更多"
            case .recordRegion: return "拖拽选择录制区域 · ⏎ 开始录制 · ⎋ 取消"
            case .recordWindow: return "双击要录制的窗口 · ⎋ 取消"
            }
        }

        /// 选区完成后是否显示截图工具栏。
        var showsToolbar: Bool {
            switch self {
            case .region, .window: return true
            case .recordRegion, .recordWindow: return false
            }
        }
    }

    /// 当前展示模式（present 时记录）。
    private var presentedMode: Mode = .region

    enum Result {
        case region(CGRect, action: CaptureDeliveryAction)
        /// 选区 + 选区内直接标注 → 合成导出（批次 2，不打开编辑器）
        case regionAnnotated(CGRect, [Annotation])
        case windowAt(CGPoint)
        /// 选区 OCR 文字识别（工具栏 / 右键菜单）
        case recognizeRegion(CGRect)
        /// 在已选区域上直接开始录制（工具栏 / 右键菜单）
        case recordRegion(CGRect, mode: RecordingMode)
        /// 在已选区域上开始长截图（滚动拼接）
        case scrollRegion(CGRect)
        /// 选区贴图（钉在屏幕上，批次 3）
        case pinRegion(CGRect)
        case cancelled
    }

    private var windows: [CaptureOverlayWindow] = []
    private var views: [CaptureOverlayView] = []
    private let model = OverlaySelectionModel()
    private var toolbar: SelectionToolbarPanel?
    private var annotatePanel: AnnotateToolPanel?
    private var textEntryPanel: OverlayTextEntryPanel?

    /// 展示期间是否允许再次 present（防重入）
    private(set) var isPresented = false

    /// 快照与窗口列表提供者（由 CaptureCoordinator 注入，UI 不直接调用采集 API）
    var snapshotProvider: (() async -> (snapshots: [ScreenSnapshot], windowFrames: [CGRect]))?

    var onFinish: ((Result) -> Void)?

    private var screenChangeObserver: NSObjectProtocol?
    private var snapshotTask: Task<Void, Never>?
    /// 取色复制反馈的自动清除任务
    private var colorFeedbackTask: Task<Void, Never>?

    // MARK: - 展示 / 收起

    func present(mode: Mode) {
        guard !isPresented else { return }
        isPresented = true
        presentedMode = mode
        model.selection = nil
        model.interaction = .none
        model.hint = mode.hint
        model.hoverWindowFrame = nil
        model.snapshots = []
        model.windowFrames = []
        resetAnnotateState()

        let toolbarPanel = SelectionToolbarPanel()
        toolbarPanel.onCopy = { [weak self] in self?.finish(.region(self?.model.selection ?? .zero, action: .copy)) }
        // 编辑 = 进入选区内直接标注（批次 2；完整编辑器走右键菜单）
        toolbarPanel.onEdit = { [weak self] in self?.enterAnnotateMode() }
        toolbarPanel.onSave = { [weak self] in self?.finish(.region(self?.model.selection ?? .zero, action: .save)) }
        toolbarPanel.onRecognizeText = { [weak self] in
            guard let selection = self?.model.selection else { return }
            self?.finish(.recognizeRegion(selection))
        }
        toolbarPanel.onRecordVideo = { [weak self] in
            guard let selection = self?.model.selection else { return }
            self?.finish(.recordRegion(selection, mode: .video))
        }
        toolbarPanel.onScrollCapture = { [weak self] in
            guard let selection = self?.model.selection else { return }
            self?.finish(.scrollRegion(selection))
        }
        toolbarPanel.onPin = { [weak self] in
            guard let selection = self?.model.selection else { return }
            self?.finish(.pinRegion(selection))
        }
        toolbarPanel.onCancel = { [weak self] in self?.finish(.cancelled) }
        self.toolbar = toolbarPanel

        // 标注模式工具面板（进入标注模式时显示）
        let annotate = AnnotateToolPanel()
        annotate.onToolChange = { [weak self] tool in
            self?.model.annotateTool = tool
        }
        annotate.onColorChange = { [weak self] color in
            guard let self else { return }
            self.model.annotateStyle.color = color
        }
        annotate.onUndo = { [weak self] in
            guard let self, !self.model.annotations.isEmpty else { return }
            self.model.annotations.removeLast()
            self.overlaySelectionDidChange()
        }
        annotate.onFinish = { [weak self] in self?.finishAnnotated() }
        annotate.onExit = { [weak self] in self?.exitAnnotateMode() }
        self.annotatePanel = annotate

        for screen in NSScreen.screens {
            let view = CaptureOverlayView(model: model, screenFrame: screen.frame)
            view.delegate = self

            let window = CaptureOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = view
            window.orderFrontRegardless()

            windows.append(window)
            views.append(view)
        }
        // 让包含鼠标的屏幕窗口成为 key，接收键盘
        let mouseLocation = NSEvent.mouseLocation
        if let index = views.firstIndex(where: { $0.screenFrame.contains(mouseLocation) }) {
            windows[index].makeKey()
        } else {
            windows.first?.makeKey()
        }

        observeScreenChanges()
        loadSnapshots()

        Log.overlay.debug("Overlay presented with \(self.views.count) screen(s)")
    }

    func dismiss() {
        snapshotTask?.cancel()
        snapshotTask = nil
        colorFeedbackTask?.cancel()
        colorFeedbackTask = nil
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        toolbar?.orderOut(nil)
        toolbar = nil
        annotatePanel?.orderOut(nil)
        annotatePanel = nil
        textEntryPanel?.orderOut(nil)
        textEntryPanel = nil
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        model.selection = nil
        model.interaction = .none
        model.snapshots = []
        model.windowFrames = []
        resetAnnotateState()
        isPresented = false
        Log.overlay.debug("Overlay dismissed")
    }

    // MARK: - CaptureOverlayViewDelegate

    func overlaySelectionDidChange() {
        for view in views { view.needsDisplay = true }
        updateToolbar()
    }

    func overlayRequestsConfirm(action: CaptureDeliveryAction) {
        guard let selection = model.selection else { return }
        // 标注模式下 Enter = 完成并复制（含标注）
        if model.annotateMode {
            finishAnnotated()
            return
        }
        finish(.region(selection, action: action))
    }

    func overlayRequestsCancel() {
        // 标注模式 → 先退出标注（保留已画内容）；已有选区 → 清除（回到选择状态）；无选区 → 取消整个 Overlay
        if model.annotateMode {
            exitAnnotateMode()
            return
        }
        if model.selection != nil {
            clearSelection()
        } else {
            finish(.cancelled)
        }
    }

    func overlayDidDoubleClick(at globalPoint: CGPoint) {
        finish(.windowAt(globalPoint))
    }

    // MARK: - 选区内直接标注（批次 2）

    /// 进入标注模式：准备选区像素快照（马赛克/模糊预览数据源）并切换工具面板。
    private func enterAnnotateMode() {
        guard model.selection != nil else { return }
        model.annotateMode = true
        refreshSelectionBaseImage()
        overlaySelectionDidChange()
    }

    /// 退出标注模式（保留已画标注，返回选区工具栏）。
    private func exitAnnotateMode() {
        model.annotateMode = false
        model.draftAnnotation = nil
        model.annotateDragStart = nil
        textEntryPanel?.orderOut(nil)
        overlaySelectionDidChange()
    }

    /// 标注状态复位（选区重建 / Overlay 收起时）。
    private func resetAnnotateState() {
        model.annotateMode = false
        model.annotations = []
        model.draftAnnotation = nil
        model.annotateDragStart = nil
        model.selectionBaseImage = nil
    }

    /// 清除选区（连同已画标注一并丢弃）。
    private func clearSelection() {
        model.selection = nil
        model.hoverWindowFrame = nil
        resetAnnotateState()
        overlaySelectionDidChange()
    }

    /// 完成标注：有标注走合成导出，无标注退化为普通复制。
    private func finishAnnotated() {
        guard let selection = model.selection else { return }
        if model.annotations.isEmpty {
            finish(.region(selection, action: .copy))
        } else {
            finish(.regionAnnotated(selection, model.annotations))
        }
    }

    /// 从屏幕快照裁剪选区内容（标注效果实时预览数据源；选区变化时重算）。
    private func refreshSelectionBaseImage() {
        guard let selection = model.selection, !model.snapshots.isEmpty else {
            model.selectionBaseImage = nil
            return
        }
        // 取与选区相交面积最大的显示器快照
        guard let snapshot = model.snapshots.max(by: { a, b in
            a.frame.intersection(selection).width * a.frame.intersection(selection).height
                < b.frame.intersection(selection).width * b.frame.intersection(selection).height
        }) else {
            model.selectionBaseImage = nil
            return
        }
        let intersection = snapshot.frame.intersection(selection)
        guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else {
            model.selectionBaseImage = nil
            return
        }
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixelRect = ScreenGeometry.pixelRect(
            logicalRect: intersection,
            displayFrame: snapshot.frame,
            imagePixelSize: imageSize
        )
        if let clamped = ScreenGeometry.clampedPixelRect(pixelRect, in: imageSize) {
            model.selectionBaseImage = snapshot.image.cropping(to: clamped)
        } else {
            model.selectionBaseImage = nil
        }
    }

    func overlayRequestsTextAnnotation(at globalPoint: CGPoint) {
        guard let selection = model.selection else { return }
        let local = CGPoint(
            x: globalPoint.x - selection.minX,
            y: globalPoint.y - selection.minY
        )
        let style = model.annotateStyle

        let panel: OverlayTextEntryPanel
        if let existing = textEntryPanel {
            panel = existing
        } else {
            let created = OverlayTextEntryPanel()
            textEntryPanel = created
            panel = created
        }
        panel.onCommit = { [weak self] text in
            guard let self, self.isPresented else { return }
            self.model.annotations.append(Annotation(
                type: .text,
                geometry: .text(origin: local, string: text),
                style: style
            ))
            self.restoreOverlayKeyWindow()
            self.overlaySelectionDidChange()
        }
        panel.onCancel = { [weak self] in
            self?.restoreOverlayKeyWindow()
        }
        panel.show(
            at: CGPoint(x: globalPoint.x, y: globalPoint.y + 4),
            fontSize: style.fontSize,
            color: style.color
        )
    }

    /// 文字输入面板收起后，把键盘焦点还给鼠标所在屏的 Overlay 窗口。
    private func restoreOverlayKeyWindow() {
        let mouseLocation = NSEvent.mouseLocation
        if let index = views.firstIndex(where: { $0.screenFrame.contains(mouseLocation) }) {
            windows[index].makeKey()
        } else {
            windows.first?.makeKey()
        }
    }

    func overlayDidRequestCopyColor(at globalPoint: CGPoint) {
        guard let color = PixelColorReader.color(at: globalPoint, snapshots: model.snapshots) else { return }
        ClipboardWriter.copyText(color.hex)
        model.colorCopyFeedback = "已复制 \(color.hex)"
        overlaySelectionDidChange()

        colorFeedbackTask?.cancel()
        colorFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.isPresented else { return }
            self.model.colorCopyFeedback = nil
            self.overlaySelectionDidChange()
        }
        Log.overlay.debug("Color copied at overlay: \(color.hex, privacy: .public)")
    }

    func overlayRequestsContextMenu(at globalPoint: CGPoint) {
        guard let selection = model.selection else { return }
        let menu = NSMenu()

        func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.target = self
            return menuItem
        }

        // 标注模式：专属菜单（复制含标注 / 撤销 / 退出标注）
        if model.annotateMode {
            menu.addItem(item("复制（含标注）⏎", action: #selector(menuCopy)))
            menu.addItem(item("撤销上一条 ⌘Z", action: #selector(menuUndoAnnotation)))
            menu.addItem(item("退出标注 ✕", action: #selector(menuExitAnnotate)))
            menu.addItem(.separator())
            menu.addItem(item("取消 ⎋", action: #selector(menuCancel)))
            popUp(menu, at: globalPoint)
            return
        }

        menu.addItem(item("复制 ⏎", action: #selector(menuCopy)))
        menu.addItem(item("标注（画框/箭头/文字）", action: #selector(menuAnnotate)))
        menu.addItem(item("在编辑器中打开", action: #selector(menuEdit)))
        menu.addItem(item("保存", action: #selector(menuSave)))
        menu.addItem(item("识别文字（OCR）", action: #selector(menuRecognize)))
        menu.addItem(item("录制视频", action: #selector(menuRecordVideo)))
        menu.addItem(item("录制 GIF", action: #selector(menuRecordGIF)))
        menu.addItem(item("长截图", action: #selector(menuScroll)))
        menu.addItem(item("贴图", action: #selector(menuPin)))
        menu.addItem(.separator())
        menu.addItem(item("重选", action: #selector(menuReselect)))
        menu.addItem(item("取消 ⎋", action: #selector(menuCancel)))

        // 在包含该点的屏幕视图中弹出（右键位置，本地坐标）
        popUp(menu, at: globalPoint)
    }

    private func popUp(_ menu: NSMenu, at globalPoint: CGPoint) {
        guard let view = views.first(where: { $0.screenFrame.contains(globalPoint) }) else { return }
        let local = NSPoint(
            x: globalPoint.x - view.screenFrame.minX,
            y: globalPoint.y - view.screenFrame.minY
        )
        menu.popUp(positioning: nil, at: local, in: view)
    }

    // MARK: - 右键菜单动作

    @objc private func menuCopy() {
        // 标注模式下复制 = 合成含标注的截图
        if model.annotateMode {
            finishAnnotated()
            return
        }
        finish(.region(model.selection ?? .zero, action: .copy))
    }
    @objc private func menuUndoAnnotation() {
        guard !model.annotations.isEmpty else { return }
        model.annotations.removeLast()
        overlaySelectionDidChange()
    }
    @objc private func menuExitAnnotate() { exitAnnotateMode() }
    @objc private func menuAnnotate() {
        guard !model.annotateMode else { return }
        enterAnnotateMode()
    }
    @objc private func menuEdit() { finish(.region(model.selection ?? .zero, action: .edit)) }
    @objc private func menuSave() { finish(.region(model.selection ?? .zero, action: .save)) }
    @objc private func menuRecognize() {
        guard let selection = model.selection else { return }
        finish(.recognizeRegion(selection))
    }
    @objc private func menuRecordVideo() {
        guard let selection = model.selection else { return }
        finish(.recordRegion(selection, mode: .video))
    }
    @objc private func menuRecordGIF() {
        guard let selection = model.selection else { return }
        finish(.recordRegion(selection, mode: .gif))
    }
    @objc private func menuScroll() {
        guard let selection = model.selection else { return }
        finish(.scrollRegion(selection))
    }
    @objc private func menuPin() {
        guard let selection = model.selection else { return }
        finish(.pinRegion(selection))
    }
    @objc private func menuReselect() { clearSelection() }
    @objc private func menuCancel() { finish(.cancelled) }

    // MARK: - 快照与窗口列表

    private func loadSnapshots() {
        guard let provider = snapshotProvider else { return }
        snapshotTask = Task { [weak self] in
            let (snapshots, windowFrames) = await provider()
            guard let self, self.isPresented, !Task.isCancelled else { return }
            self.model.snapshots = snapshots
            self.model.windowFrames = windowFrames
            for view in self.views { view.needsDisplay = true }
            Log.overlay.debug("Snapshots ready: \(snapshots.count) display(s), \(windowFrames.count) window(s)")
        }
    }

    // MARK: - 显示器配置变化

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                Log.overlay.info("Screen configuration changed, cancelling overlay")
                self.finish(.cancelled)
            }
        }
    }

    // MARK: - 私有

    private func finish(_ result: Result) {
        guard isPresented else { return }
        dismiss()
        onFinish?(result)
    }

    private func updateToolbar() {
        guard let toolbar else { return }

        // 标注模式：显示标注工具面板（绘制草稿时避让）
        if model.annotateMode {
            toolbar.orderOut(nil)
            guard let annotatePanel,
                  let selection = model.selection, !model.isAnnotateDrafting else {
                annotatePanel?.orderOut(nil)
                return
            }
            let center = CGPoint(x: selection.midX, y: selection.midY)
            let screen = NSScreen.screens.first {
                $0.frame.insetBy(dx: -2, dy: -2).contains(center)
            } ?? NSScreen.main
            guard let screen else { return }
            annotatePanel.position(below: selection, in: screen)
            if !annotatePanel.isVisible {
                annotatePanel.orderFrontRegardless()
            }
            return
        }

        annotatePanel?.orderOut(nil)
        guard presentedMode.showsToolbar,
              let selection = model.selection, !model.isInteracting else {
            toolbar.orderOut(nil)
            return
        }
        // 找到选区中心所在屏幕
        let center = CGPoint(x: selection.midX, y: selection.midY)
        let screen = NSScreen.screens.first {
            $0.frame.insetBy(dx: -2, dy: -2).contains(center)
        } ?? NSScreen.main
        guard let screen else { return }

        toolbar.position(below: selection, in: screen)
        if !toolbar.isVisible {
            toolbar.orderFrontRegardless()
        }
    }
}
