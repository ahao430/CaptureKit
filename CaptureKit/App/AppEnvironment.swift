import AppKit
import Combine
import Foundation

/// 依赖容器与模块装配（design.md §2 Application Layer）。
/// 显式依赖注入，不引入 DI 框架。
@MainActor
final class AppEnvironment {
    let settings: SettingsStore
    let engine: ScreenCaptureEngine
    let captureCoordinator: CaptureCoordinator
    let recordingCoordinator: RecordingCoordinator
    let scrollCoordinator: ScrollCoordinator
    let editorCoordinator: EditorCoordinator
    let recordingEditorWindow: RecordingEditorWindowController
    let historyService: HistoryService?
    let clipboardMonitor: ClipboardMonitor
    let historyWindow: HistoryWindowController?
    let menuBar: MenuBarManager
    let settingsWindow: SettingsWindowController
    var updateCoordinator: UpdateCoordinator?

    private var cancellables = Set<AnyCancellable>()
    private var registeredHotkeyActions = Set<HotkeyAction>()
    private var cleanupTimer: Timer?

    init() {
        let settings = SettingsStore()
        let engine = ScreenCaptureEngine()
        let capture = CaptureCoordinator(engine: engine, settings: settings)
        let recording = RecordingCoordinator(engine: engine, settings: settings)
        let scroll = ScrollCoordinator(engine: engine, settings: settings)
        let editor = EditorCoordinator()
        let recordingEditor = RecordingEditorWindowController()

        // History 数据层（磁盘故障降级：无历史功能但不崩溃，plan.md §11 稳定性）
        var history: HistoryService?
        do {
            history = try HistoryService.makeDefault(settings: settings)
        } catch {
            Log.storage.error("History service unavailable: \(error.localizedDescription)")
        }
        let monitor = ClipboardMonitor(settings: settings)
        if let history {
            monitor.attach(history: history)
            QuickAccessPanelController.shared.attach(history: history)
        }
        let historyWindow = history.map { HistoryWindowController(history: $0) }

        let menuBar = MenuBarManager()
        let settingsWindow = SettingsWindowController(store: settings, history: history)

        self.settings = settings
        self.engine = engine
        self.captureCoordinator = capture
        self.recordingCoordinator = recording
        self.scrollCoordinator = scroll
        self.editorCoordinator = editor
        self.recordingEditorWindow = recordingEditor
        self.historyService = history
        self.clipboardMonitor = monitor
        self.historyWindow = historyWindow
        self.menuBar = menuBar
        self.settingsWindow = settingsWindow

        wireModules()
    }

    /// 应用启动完成后调用（测试环境跳过 UI 相关初始化）。
    func start() {
        guard !isRunningTests else {
            Log.app.info("Tests detected, skip UI startup")
            return
        }

        // 演示自截图模式：接管生命周期，截完即退（不需要 TCC）
        if DemoSelfCapture.runIfRequested() {
            Log.app.info("Demo self-capture mode")
        }

        menuBar.setup()
        AppDockIconService.apply(showDockIcon: settings.settings.general.showDockIcon)
        // Translocation/quarantine 引导（ADR-030）：临时路径运行会让 TCC 授权反复失效
        TranslocationChecker.checkAndGuideIfNeeded()
        registerHotkeys()
        warnExternalHotkeyConflictIfNeeded()
        clipboardMonitor.applySettings()
        startAutoClean()
        startUpdater()

        Log.app.info("CaptureKit started (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")

        runDemoIfRequested()
    }

    // MARK: - 文档截图演示（--demo-* 启动参数；只开真实窗口供截图，不改变业务行为）

    private var demoHistoryWindow: HistoryWindowController?
    private var demoEditor: EditorWindowController?

    /// 文档截图辅助：把窗口钳制到主屏可见区内并居中（避免跨屏坐标漂移与超屏窗口）。
    private func positionOnPrimaryScreen(_ window: NSWindow?) {
        guard let window else { return }
        let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        guard let visible = main?.visibleFrame else { return }
        var frame = window.frame
        // 超屏窗口按可见区等比缩小（内容视口会随布局重适配）
        let maxWidth = min(visible.width - 80, 1240)
        let maxHeight = min(visible.height - 80, 780)
        if frame.width > maxWidth || frame.height > maxHeight {
            let scale = min(maxWidth / max(frame.width, 1), maxHeight / max(frame.height, 1))
            frame.size = NSSize(width: frame.width * scale, height: frame.height * scale)
            window.setContentSize(frame.size)
        }
        window.setFrame(frame, display: true)
        var centered = window.frame
        centered.origin = CGPoint(
            x: visible.midX - centered.width / 2,
            y: visible.midY - centered.height / 2
        )
        window.setFrame(centered, display: true)
    }

    private func runDemoIfRequested() {
        let args = Set(ProcessInfo.processInfo.arguments)
        if args.contains("--demo-settings") {
            settingsWindow.show()
            positionOnPrimaryScreen(settingsWindow.windowRef)
        }
        if args.contains("--demo-settings-snap") {
            settingsWindow.show()
            positionOnPrimaryScreen(settingsWindow.windowRef)
        }
        if args.contains("--demo-popover") {
            menuBar.showPopoverForDemo()
        }
        if args.contains("--demo-overlay") {
            captureCoordinator.startRegionCapture()
        }
        if args.contains("--demo-history") || args.contains("--demo-quick") {
            Task { await runHistoryDemo(showWindow: args.contains("--demo-history")) }
        }
        if args.contains("--demo-editor") {
            runEditorDemo()
        }
    }

    /// 临时数据库历史演示（不污染真实历史）。
    private func runHistoryDemo(showWindow: Bool) async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureKitDemo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let repository = try? ContentRepository.temporary() else { return }
        let service = HistoryService(
            repository: repository,
            fileStore: ContentFileStore(rootURL: root),
            databaseURL: root.appendingPathComponent("demo.sqlite")
        )

        await service.recordScreenshot(image: DemoContent.mockWebPage(), source: "capture")
        _ = await service.recordClipboard(reading: ClipboardReading(
            text: "Capture. Organize. Reuse.",
            imageIsPNG: false, fileURLs: [],
            sourceBundleID: "com.apple.Safari",
            representations: ["public.utf8-plain-text"]
        ))
        _ = await service.recordClipboard(reading: ClipboardReading(
            text: "https://github.com/ahao430/CaptureKit",
            imageIsPNG: false, fileURLs: [],
            sourceBundleID: "com.apple.Safari",
            representations: ["public.utf8-plain-text", "public.url"]
        ))
        _ = await service.recordClipboard(reading: ClipboardReading(
            text: "xattr -dr com.apple.quarantine /Applications/CaptureKit.app",
            imageIsPNG: false, fileURLs: [],
            sourceBundleID: "com.apple.Terminal",
            representations: ["public.utf8-plain-text"]
        ))

        if showWindow {
            let window = HistoryWindowController(history: service)
            demoHistoryWindow = window
            window.show()
            positionOnPrimaryScreen(window.windowRef)
        } else {
            QuickAccessPanelController.shared.attach(history: service)
            QuickAccessPanelController.shared.toggle()
        }
    }

    /// 编辑器演示：合成底图 + 程序化标注。
    private func runEditorDemo() {
        let controller = EditorWindowController()
        demoEditor = controller
        controller.show(image: DemoContent.mockWebPage())
        positionOnPrimaryScreen(controller.windowRef)

        let red = AnnotationStyle(color: .red, lineWidth: 6, isFilled: false, fontSize: 44)
        let blue = AnnotationStyle(color: .blue, lineWidth: 5, isFilled: false, fontSize: 20)

        // 画布标注坐标为 y 向上（图像底为 0）：换算自上而下坐标
        func top(_ yTop: CGFloat) -> CGFloat { CGFloat(DemoContent.pageHeight) - yTop }
        let document = controller.document
        document?.add(Annotation(
            type: .rectangle,
            geometry: .rect(CGRect(x: 372, y: top(620), width: 646, height: 256)),
            style: blue
        ))
        document?.add(Annotation(
            type: .arrow,
            geometry: .arrow(from: CGPoint(x: 1150, y: top(760)), to: CGPoint(x: 1340, y: top(690))),
            style: red
        ))
        document?.add(Annotation(
            type: .text,
            geometry: .text(origin: CGPoint(x: 880, y: top(790)), string: "导出按钮在这里"),
            style: AnnotationStyle(color: .red, lineWidth: 4, isFilled: false, fontSize: 42)
        ))
        document?.add(Annotation(
            type: .mosaic,
            geometry: .mosaic(CGRect(x: 1052, y: top(180), width: 482, height: 34))
        ))
        document?.add(Annotation(
            type: .numberedMarker,
            geometry: .numberedMarker(center: CGPoint(x: 380, y: top(372)), number: 1)
        ))
        document?.add(Annotation(
            type: .numberedMarker,
            geometry: .numberedMarker(center: CGPoint(x: 1040, y: top(520)), number: 2)
        ))
    }

    func shutdown() {
        for action in registeredHotkeyActions {
            CarbonHotkeyCenter.shared.unregister(actionID: action.stableID)
        }
        registeredHotkeyActions.removeAll()
        clipboardMonitor.stop()
        cleanupTimer?.invalidate()
        // 退出时清空剪贴板历史（plan.md §2.7.4，默认关）
        if settings.settings.clipboard.clearOnQuit, let historyService {
            Task {
                await historyService.deleteAll()
                Log.storage.info("Cleared clipboard history on quit")
            }
        }
        menuBar.teardown()
        Log.app.info("CaptureKit shutdown")
    }

    /// 自动清理：启动时一次 + 每小时（plan.md §2.7.4）。
    private func startAutoClean() {
        runAutoClean()
        // 孤儿条目自愈（崩溃恢复：引用文件丢失的条目清理）
        if let historyService {
            Task { await historyService.healOrphans() }
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runAutoClean()
            }
        }
    }

    private func runAutoClean() {
        guard let historyService, settings.settings.clipboard.enabled else { return }
        let clipboard = settings.settings.clipboard
        Task {
            await historyService.autoClean(keepCount: clipboard.keepCount, maxAgeDays: clipboard.autoCleanDays)
        }
    }

    /// Sparkle 更新器（测试环境不启动：避免单测中触发网络检查）。
    private func startUpdater() {
        let coordinator = UpdateCoordinator(settings: settings)
        settingsWindow.attach(updater: coordinator)
        updateCoordinator = coordinator
    }

    // MARK: - 装配

    private func wireModules() {
        menuBar.onRegionCapture = { [weak self] in self?.captureCoordinator.startRegionCapture() }
        menuBar.onFullscreenCapture = { [weak self] in self?.captureCoordinator.captureFullscreen() }
        menuBar.onWindowCapture = { [weak self] in self?.captureCoordinator.startWindowCapture() }
        menuBar.onDelayedCapture = { [weak self] in self?.captureCoordinator.startDelayedCapture() }
        menuBar.onRecordRegion = { [weak self] in self?.recordingCoordinator.startRegionRecording(mode: .video) }
        menuBar.onRecordRegionGIF = { [weak self] in self?.recordingCoordinator.startRegionRecording(mode: .gif) }
        menuBar.onRecordFullscreen = { [weak self] in self?.recordingCoordinator.startFullscreenRecording(mode: .video) }
        menuBar.onRecordWindow = { [weak self] in self?.recordingCoordinator.startWindowRecording(mode: .video) }
        menuBar.onSettings = { [weak self] in self?.settingsWindow.show() }
        menuBar.onCheckForUpdates = { [weak self] in
            self?.updateCoordinator?.checkForUpdates()
        }
        menuBar.onAbout = {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        captureCoordinator.errorHandler = { [weak self] error in
            self?.presentError(error)
        }
        captureCoordinator.onEditImage = { [weak self] image in
            self?.editorCoordinator.edit(image: image)
        }
        captureCoordinator.onRecordScreenshot = { [weak self] image in
            guard let self, let historyService = self.historyService else { return }
            Task { await historyService.recordScreenshot(image: image) }
        }
        captureCoordinator.onRecordRegion = { [weak self] rect, mode in
            self?.recordingCoordinator.startRecordingInRegion(rect, mode: mode)
        }
        captureCoordinator.onScrollRegion = { [weak self] rect in
            self?.scrollCoordinator.startCapturing(in: rect)
        }
        captureCoordinator.onPinImage = { image, rect in
            PinnedImageManager.shared.show(image: image, at: rect)
        }
        recordingCoordinator.errorHandler = { [weak self] error in
            self?.presentError(error)
        }
        menuBar.onScrollCapture = { [weak self] in self?.scrollCoordinator.start() }
        scrollCoordinator.errorHandler = { [weak self] error in
            self?.presentError(error)
        }
        scrollCoordinator.onStitched = { [weak self] image in
            guard let self else { return }
            self.editorCoordinator.edit(image: image)
            if let historyService = self.historyService {
                Task { await historyService.recordScreenshot(image: image, source: "scroll") }
            }
        }

        recordingCoordinator.onRecordingCompleted = { [weak self] url, mode in
            guard let self else { return }
            // 历史入库
            if let historyService = self.historyService {
                let duration = self.recordingCoordinator.lastRecordedDuration ?? 0
                let fps = self.settings.settings.recording.fps
                Task { await historyService.recordRecording(url: url, mode: mode, duration: duration, fps: fps) }
            }
            // 完成入口：预览编辑器（默认）或 Finder 提示
            if self.settings.settings.recording.autoOpenEditor {
                self.recordingEditorWindow.show(url: url)
            } else {
                self.presentRecordingCompletion(url: url, mode: mode)
            }
        }
        editorCoordinator.errorHandler = { [weak self] error in
            self?.presentError(error)
        }

        // 快捷键配置变化 → 重新注册
        settings.$settings
            .map(\.hotkeys)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.registerHotkeys()
            }
            .store(in: &cancellables)

        // 剪贴板设置变化 → 监控启停（design.md §12.2：配置变化经明确接口生效）
        settings.$settings
            .map(\.clipboard.enabled)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.clipboardMonitor.applySettings()
            }
            .store(in: &cancellables)
    }

    // MARK: - 快捷键

    /// 外部快捷键占用提示（ADR-030 补充）：RegisterEventHotKey 对已占用组合静默成功，
    /// 事件归先注册的应用（实测钉钉/微信占 ⇧⌘A 时本 app 无响应），只能提示用户改键。
    /// 「不再提示」记 UserDefaults；用户改键后自然不再命中检测。
    private func warnExternalHotkeyConflictIfNeeded() {
        guard let conflictApp = HotkeyConflictChecker.externalConflictHint(
            runningBundleIDs: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier),
            regionCapture: settings.settings.hotkeys.regionCapture
        ) else { return }

        let defaults = UserDefaults.standard
        let skipKey = "com.wanghao.capturekit.suppressHotkeyConflictGuide"
        guard !defaults.bool(forKey: skipKey) else {
            Log.hotkey.info("External hotkey conflict detected (guide suppressed): \(conflictApp, privacy: .public)")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "区域截图快捷键 ⇧⌘A 可能被 \(conflictApp) 占用"
        alert.informativeText = "实测 macOS 对快捷键冲突不做拦截：同时运行时按键会发给先启动的应用，CaptureKit 可能无响应。可在 \(conflictApp) 设置中关闭其截图快捷键，或在 CaptureKit 设置 → 快捷键中改用其他组合。"
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "不再提示")
        if alert.runModal() == .alertSecondButtonReturn {
            defaults.set(true, forKey: skipKey)
        }
        Log.hotkey.warning("External hotkey conflict guide shown: \(conflictApp, privacy: .public)")
    }

    private func registerHotkeys() {
        let mapping = settings.settings.hotkeys.mapping
        for (action, descriptor) in mapping {
            let succeeded = CarbonHotkeyCenter.shared.register(actionID: action.stableID, descriptor: descriptor) { [weak self] in
                self?.handleHotkey(action)
            }
            if succeeded {
                registeredHotkeyActions.insert(action)
            } else {
                // 注册失败必须明确反馈（plan.md §2.2），不允许静默失效
                Log.hotkey.error("Failed to register hotkey for \(action.displayName, privacy: .public)")
                presentError(.captureFailed(underlying: nil), message: "快捷键 \(descriptor.displayName) 注册失败，可能已被其他应用占用。")
            }
        }
    }

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .regionCapture:
            captureCoordinator.startRegionCapture()
        case .recordRegion:
            recordingCoordinator.startRegionRecording(mode: .video)
        case .history:
            if let historyWindow {
                historyWindow.show()
            } else {
                presentError(.storageFailed(underlying: nil), message: "历史服务不可用（数据库初始化失败）。")
            }
        case .quickAccess:
            QuickAccessPanelController.shared.toggle()
        }
    }

    /// 录制完成提示（批次 2 将接入预览编辑器）。
    private func presentRecordingCompletion(url: URL, mode: RecordingMode) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "录制完成（\(mode.displayName)）"
        alert.informativeText = url.path
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func presentPlaceholder(for action: HotkeyAction) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(action.displayName)尚未实现"
        alert.informativeText = "该功能将在后续 Phase 提供。"
        alert.runModal()
    }

    // MARK: - 错误呈现

    private func presentError(_ error: CaptureKitError, message override: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = override ?? error.userMessage
        alert.alertStyle = .warning

        if case .permissionDenied = error {
            alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中允许 CaptureKit，然后完全退出并重新打开 CaptureKit（新授权需重启应用生效），再触发截图。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                if let url = URL(string: pane) {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 测试检测

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
