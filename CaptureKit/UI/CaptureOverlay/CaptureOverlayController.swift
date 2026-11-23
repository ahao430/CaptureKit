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
            case .region: return "拖拽选择区域 · 单击选中窗口 · 双击捕获窗口"
            case .window: return "单击选中窗口 · 双击捕获窗口"
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
        case windowAt(CGPoint)
        case cancelled
    }

    private var windows: [CaptureOverlayWindow] = []
    private var views: [CaptureOverlayView] = []
    private let model = OverlaySelectionModel()
    private var toolbar: SelectionToolbarPanel?

    /// 展示期间是否允许再次 present（防重入）
    private(set) var isPresented = false

    /// 快照与窗口列表提供者（由 CaptureCoordinator 注入，UI 不直接调用采集 API）
    var snapshotProvider: (() async -> (snapshots: [ScreenSnapshot], windowFrames: [CGRect]))?

    var onFinish: ((Result) -> Void)?

    private var screenChangeObserver: NSObjectProtocol?
    private var snapshotTask: Task<Void, Never>?

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

        let toolbarPanel = SelectionToolbarPanel()
        toolbarPanel.onCopy = { [weak self] in self?.finish(.region(self?.model.selection ?? .zero, action: .copy)) }
        toolbarPanel.onEdit = { [weak self] in self?.finish(.region(self?.model.selection ?? .zero, action: .edit)) }
        toolbarPanel.onSave = { [weak self] in self?.finish(.region(self?.model.selection ?? .zero, action: .save)) }
        toolbarPanel.onReselect = { [weak self] in
            guard let self else { return }
            self.model.selection = nil
            self.overlaySelectionDidChange()
        }
        toolbarPanel.onCancel = { [weak self] in self?.finish(.cancelled) }
        self.toolbar = toolbarPanel

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
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        toolbar?.orderOut(nil)
        toolbar = nil
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
        finish(.region(selection, action: action))
    }

    func overlayRequestsCancel() {
        // 已有选区 → 先清除（回到选择状态）；无选区 → 取消整个 Overlay
        if model.selection != nil {
            model.selection = nil
            model.hoverWindowFrame = nil
            overlaySelectionDidChange()
        } else {
            finish(.cancelled)
        }
    }

    func overlayDidDoubleClick(at globalPoint: CGPoint) {
        finish(.windowAt(globalPoint))
    }

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
