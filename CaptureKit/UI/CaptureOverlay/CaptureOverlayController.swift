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
final class CaptureOverlayController: NSObject, CaptureOverlayViewDelegate, NSTextFieldDelegate {
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
    private var modePanel: OverlayModePanel?

    /// 是否展示顶部模式胶囊（截图/滚动/录屏/文字识别）。
    /// 仅 CaptureCoordinator 的区域截图流程开启；复用 Overlay 的其他协调器保持原流程。
    var showsModePanel = false

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
        // 激活 App：热键触发时 App 可能未激活，key window 收不到键盘（Enter/Esc/取色全失效）
        NSApp.activate(ignoringOtherApps: true)
        model.selection = nil
        model.interaction = .none
        model.hint = mode.hint
        model.hoverWindowFrame = nil
        model.snapshots = []
        model.windowFrames = []
        resetAnnotateState()

        let toolbarPanel = SelectionToolbarPanel()
        toolbarPanel.onToolChange = { [weak self] tool in
            guard let self else { return }
            // 再点当前工具 = 取消，回到选择
            if self.model.activeTool == tool {
                self.model.activeTool = nil
                self.model.draftAnnotation = nil
                self.model.annotateDragStart = nil
            } else {
                self.model.activeTool = tool
                self.model.selectedAnnotationID = nil
            }
            self.overlaySelectionDidChange()
        }
        toolbarPanel.onColorChange = { [weak self] color in
            guard let self else { return }
            self.model.annotateStyle.color = color
            // 选中标注时同步改色（钉钉行为）
            if let id = self.model.selectedAnnotationID,
               let index = self.model.annotations.firstIndex(where: { $0.id == id }) {
                self.model.annotations[index].style.color = color
            }
            self.overlaySelectionDidChange()
        }
        toolbarPanel.onWidthChange = { [weak self] width in
            guard let self else { return }
            self.model.annotateStyle.lineWidth = width.value
            if let id = self.model.selectedAnnotationID,
               let index = self.model.annotations.firstIndex(where: { $0.id == id }) {
                self.model.annotations[index].style.lineWidth = width.value
            }
            self.overlaySelectionDidChange()
        }
        toolbarPanel.onUndo = { [weak self] in
            guard let self else { return }
            if let id = self.model.selectedAnnotationID {
                self.model.annotations.removeAll { $0.id == id }
                self.model.selectedAnnotationID = nil
            } else if !self.model.annotations.isEmpty {
                self.model.annotations.removeLast()
            }
            self.overlaySelectionDidChange()
        }
        toolbarPanel.onPin = { [weak self] in
            guard let selection = self?.model.selection else { return }
            self?.finish(.pinRegion(selection))
        }
        toolbarPanel.onSave = { [weak self] in self?.finish(.region(self?.model.selection ?? .zero, action: .save)) }
        toolbarPanel.onCancel = { [weak self] in self?.finish(.cancelled) }
        toolbarPanel.onFinish = { [weak self] in self?.finishByIntent() }
        self.toolbar = toolbarPanel

        // 顶部模式胶囊（截图/滚动/录屏/文字识别）
        let mode = OverlayModePanel()
        mode.onIntentChange = { [weak self] intent in
            guard let self else { return }
            self.model.captureIntent = intent
            // 已有选区时切换意图 → 立即按新意图执行
            if intent != .screenshot, self.model.selection != nil, !self.model.isInteracting {
                self.finishByIntent()
            }
        }
        self.modePanel = mode

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

        // 顶部模式胶囊：截图流程且当前无选区时展示
        if showsModePanel, presentedMode == .region {
            let mouseScreen = NSScreen.screens.first {
                $0.frame.contains(NSEvent.mouseLocation)
            } ?? NSScreen.main
            if let mouseScreen {
                modePanel?.showBelowMenuBar(in: mouseScreen, intent: model.captureIntent)
            }
        }

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
        // 文字编辑中：直接丢弃（不提交），移除输入框
        if let editing = activeTextField {
            activeTextField = nil
            editing.field.removeFromSuperview()
        }
        toolbar?.orderOut(nil)
        toolbar = nil
        modePanel?.orderOut(nil)
        modePanel = nil
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

        // 非截图意图（滚动/录屏/文字识别）：选区确定后立即执行
        if showsModePanel,
           model.captureIntent != .screenshot,
           model.selection != nil,
           !model.isInteracting, !model.isAnnotateDrafting {
            finishByIntent()
        }
    }

    func overlayRequestsConfirm(action: CaptureDeliveryAction) {
        guard model.selection != nil else { return }
        finishByIntent()
    }

    func overlayRequestsCancel() {
        // ESC 直接取消截图（钉钉行为；回到选择态走右键菜单「重选」）
        finish(.cancelled)
    }

    func overlayDidDoubleClick(at globalPoint: CGPoint) {
        finish(.windowAt(globalPoint))
    }

    // MARK: - 一体化标注（DingTalk 式）

    /// 标注状态复位（选区重建 / Overlay 收起时）。
    private func resetAnnotateState() {
        model.activeTool = nil
        model.captureIntent = .screenshot
        model.annotations = []
        model.draftAnnotation = nil
        model.annotateDragStart = nil
        model.selectedAnnotationID = nil
        model.annotationDrag = nil
        model.selectionBaseImage = nil
        model.selectionBaseImageForRect = nil
    }

    /// 清除选区（连同已画标注一并丢弃；模式胶囊重新出现）。
    private func clearSelection() {
        model.selection = nil
        model.hoverWindowFrame = nil
        resetAnnotateState()
        overlaySelectionDidChange()
    }

    /// 完成交付：按当前意图路由（截图 = 有标注走合成导出，无标注普通复制）。
    private func finishByIntent() {
        guard let selection = model.selection,
              let result = OverlayFinishRouter.result(
                intent: model.captureIntent,
                selection: selection,
                annotations: model.annotations
              ) else { return }
        finish(result)
    }

    /// 完成截图意图交付（复制含标注）。
    private func finishAnnotated() {
        finishByIntent()
    }

    // MARK: - 选区内文字输入（内嵌 NSTextField，复用 Overlay 窗口已验证的键盘链路）

    /// 当前编辑中的文字输入框（挂在鼠标所在屏的 Overlay 视图上）
    private var activeTextField: (field: NSTextField, view: CaptureOverlayView, localPoint: CGPoint)?

    /// 是否有正在编辑的文字输入框。
    func overlayTextEditingIsActive() -> Bool {
        activeTextField != nil
    }

    /// 视图请求结束文字编辑（点击其他区域时；非空提交）。
    func overlayRequestsCommitTextEditing() {
        endTextEditing(commit: true)
    }

    func overlayRequestsTextAnnotation(at globalPoint: CGPoint) {
        guard let selection = model.selection else { return }
        // 已在编辑 → 先提交旧的
        if activeTextField != nil {
            endTextEditing(commit: true)
        }
        guard let view = views.first(where: { $0.screenFrame.contains(globalPoint) }) else { return }
        let local = CGPoint(
            x: globalPoint.x - view.screenFrame.minX,
            y: globalPoint.y - view.screenFrame.minY
        )
        let selectionLocal = CGPoint(
            x: globalPoint.x - selection.minX,
            y: globalPoint.y - selection.minY
        )
        let style = model.annotateStyle

        let field = NSTextField(frame: NSRect(
            x: local.x,
            y: local.y,
            width: 240,
            height: style.fontSize + 14
        ))
        field.font = .systemFont(ofSize: style.fontSize, weight: .semibold)
        field.textColor = style.color.nsColor
        field.placeholderString = "输入文字，Enter 确认 · Esc 取消"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        field.layer?.cornerRadius = 6
        field.delegate = self
        view.addSubview(field)
        activeTextField = (field, view, selectionLocal)

        // Overlay 窗口已是 key（键盘链路已被 Enter/Esc/取色验证），直接接管 first responder
        if let window = view.window {
            window.makeFirstResponder(field)
        }
    }

    /// 结束文字编辑（Enter = 提交非空文本；Esc / 点击其他处 = 非空提交、空丢弃）。
    private func endTextEditing(commit: Bool) {
        guard let editing = activeTextField else { return }
        activeTextField = nil
        let text = editing.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editing.field.removeFromSuperview()
        editing.view.window?.makeFirstResponder(nil)

        if commit, !text.isEmpty, let selection = model.selection {
            model.annotations.append(Annotation(
                type: .text,
                geometry: .text(origin: editing.localPoint, string: text),
                style: model.annotateStyle
            ))
        }
        overlaySelectionDidChange()
    }

    // MARK: - NSTextFieldDelegate（文字内嵌输入）

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endTextEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endTextEditing(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // 失焦（点击其他位置）统一走提交
        guard activeTextField != nil else { return }
        endTextEditing(commit: true)
    }

    func overlayDidRequestCopyColor(at globalPoint: CGPoint) {
        guard let color = PixelColorReader.color(at: globalPoint, snapshots: model.snapshots) else { return }
        // 按当前格式复制（Shift 切换 HEX/RGB）
        let value = model.colorFormat == .hex ? color.hex : color.rgbText
        ClipboardWriter.copyText(value)
        model.colorCopyFeedback = "已复制 \(value)"
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

        // 标注相关（有已画标注时可用）
        if model.hasAnnotations {
            menu.addItem(item("撤销上一条标注 ⌘Z", action: #selector(menuUndoAnnotation)))
        }
        if model.selectedAnnotationID != nil {
            menu.addItem(item("删除选中标注 ⌫", action: #selector(menuDeleteSelectedAnnotation)))
        }

        menu.addItem(item("复制 ⏎（含标注）", action: #selector(menuCopy)))
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

    @objc private func menuCopy() { finishAnnotated() }
    @objc private func menuUndoAnnotation() {
        guard !model.annotations.isEmpty else { return }
        model.annotations.removeLast()
        model.selectedAnnotationID = nil
        overlaySelectionDidChange()
    }
    @objc private func menuDeleteSelectedAnnotation() {
        guard let id = model.selectedAnnotationID else { return }
        model.annotations.removeAll { $0.id == id }
        model.selectedAnnotationID = nil
        overlaySelectionDidChange()
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
        // 顶部模式胶囊：无选区时展示（选区出现后隐藏，截图流程专属）
        if showsModePanel, presentedMode == .region {
            if model.selection == nil {
                if let modePanel, !modePanel.isVisible {
                    let mouseScreen = NSScreen.screens.first {
                        $0.frame.contains(NSEvent.mouseLocation)
                    } ?? NSScreen.main
                    if let mouseScreen {
                        modePanel.showBelowMenuBar(in: mouseScreen, intent: model.captureIntent)
                    }
                }
            } else {
                modePanel?.orderOut(nil)
            }
        }

        guard let toolbar else { return }

        // 一体化标注工具栏：有选区且不在交互/绘制草稿中时显示（贴选区上方）
        guard presentedMode.showsToolbar,
              model.captureIntent == .screenshot,
              let selection = model.selection,
              !model.isInteracting, !model.isAnnotateDrafting, model.annotationDrag == nil else {
            toolbar.orderOut(nil)
            return
        }
        // 找到选区中心所在屏幕
        let center = CGPoint(x: selection.midX, y: selection.midY)
        let screen = NSScreen.screens.first {
            $0.frame.insetBy(dx: -2, dy: -2).contains(center)
        } ?? NSScreen.main
        guard let screen else { return }

        toolbar.reflect(tool: model.activeTool, style: model.annotateStyle)
        toolbar.position(above: selection, in: screen)
        if !toolbar.isVisible {
            toolbar.orderFrontRegardless()
        }
    }
}

/// 意图 → 交付结果路由（纯函数，可单测）。
enum OverlayFinishRouter {
    /// 截图：有标注 = 合成导出，无标注 = 普通复制；其他意图 = 对应区域动作。
    static func result(
        intent: OverlaySelectionModel.CaptureIntent,
        selection: CGRect,
        annotations: [Annotation]
    ) -> CaptureOverlayController.Result? {
        switch intent {
        case .screenshot:
            if annotations.isEmpty {
                return .region(selection, action: .copy)
            }
            return .regionAnnotated(selection, annotations)
        case .scroll:
            return .scrollRegion(selection)
        case .record:
            return .recordRegion(selection, mode: .video)
        case .ocr:
            return .recognizeRegion(selection)
        }
    }
}
