import AppKit
import CoreGraphics
import Foundation

/// 滚动截图会话状态。
enum ScrollCaptureState: Equatable {
    case idle
    case selecting
    case capturing
    case stitching
    case completed
    case cancelled
    case failed(String?)
}

/// 滚动截图协调器（plan.md §2.5 基础版）。
///
/// 流程：区域选择（复用 Overlay）→ 采集循环（定时抓帧，重复帧自动跳过）
/// → 用户点「完成」→ 帧间位移匹配 + 拼接 → 交付编辑器 + 历史入库。
/// 手动滚动方案：不注入滚动事件（免辅助功能权限，ADR-026），由用户在目标窗口自行滚动。
@MainActor
final class ScrollCoordinator {
    private let engine: ScreenCaptureEngine
    private let settings: SettingsStore
    private let overlay: CaptureOverlayController

    private var panel: ScrollCapturePanel?
    /// 选区边框（蓝色，提示滚动范围；不挡鼠标）
    private var regionBorder: RecordingRegionBorderPanel?
    private var captureTimer: Timer?
    /// 鼠标驱动滚动定时器（鼠标靠近选区下/上边缘时注入滚动事件）
    private var edgeScrollTimer: Timer?
    private var frames: [CGImage] = []
    private var regionRect: CGRect?
    private(set) var state: ScrollCaptureState = .idle
    /// 采集周期（秒）
    private let interval: TimeInterval = 0.35
    private let maxFrames = 120
    /// 本会话是否注入自动滚动（设置开 + 辅助功能已授权）
    private var autoScroll = false
    /// 连续未滚动帧数（自动模式下连续 2 帧 → 判定到底自动完成）
    private var consecutiveStillFrames = 0

    var errorHandler: ((CaptureKitError) -> Void)?
    /// 拼接结果交付（编辑器 + 历史由 AppEnvironment 注入）
    var onStitched: ((CGImage) -> Void)?

    init(engine: ScreenCaptureEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
        self.overlay = CaptureOverlayController()
        overlay.snapshotProvider = { [weak self] in
            guard let self else { return ([], []) }
            do {
                let content = try await self.engine.shareableContent()
                var snapshots: [ScreenSnapshot] = []
                for display in content.displays {
                    let output = try await self.engine.captureDisplay(display, content: content, excludeOwnWindows: true)
                    snapshots.append(ScreenSnapshot(displayID: display.displayID, frame: display.frame, image: output.image))
                }
                let frames = self.engine.windowSnapshots(from: content, displayFrame: nil).map(\.frame)
                return (snapshots, frames)
            } catch {
                return ([], [])
            }
        }
        overlay.onFinish = { [weak self] result in
            self?.handleOverlayResult(result)
        }
    }

    // MARK: - 入口

    func start() {
        guard state == .idle || state == .completed || state == .cancelled || state == .failed(nil) else { return }
        guard ensurePermission() else { return }
        state = .selecting
        overlay.autoScrollPending = true
        overlay.present(mode: .region)
    }

    private func handleOverlayResult(_ result: CaptureOverlayController.Result) {
        switch result {
        case .region(let rect, _), .scrollRegion(let rect):
            // 选区中央 ▶ 点击后进入
            beginCapturing(in: rect)
        case .windowAt, .regionAnnotated, .recognizeRegion, .recordRegion, .pinRegion, .cancelled:
            state = .cancelled
        }
    }

    /// 在已选区域上直接开始滚动采集（截图 Overlay 工具栏 / 右键菜单入口）。
    func startCapturing(in rect: CGRect) {
        guard state == .idle || state == .completed || state == .cancelled || state == .failed(nil) else {
            Log.capture.warning("Scroll capture already active, ignore request from capture overlay")
            return
        }
        guard ensurePermission() else { return }
        beginCapturing(in: rect)
    }

    // MARK: - 采集

    private func beginCapturing(in rect: CGRect) {
        state = .capturing
        regionRect = rect
        frames = []
        consecutiveStillFrames = 0

        // 自动滚动 / 鼠标滚动决策（ADR-002/027）：依赖辅助功能权限。
        // 不再弹模态授权框打断流程；无权限时禁用开关并在控制条提示，手动滚动始终可用。
        let accessibilityAvailable = AutoScroller.isTrusted()
        autoScroll = accessibilityAvailable && settings.settings.capture.scrollAutoScroll

        let panel = ScrollCapturePanel()
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onAutoScrollToggle = { [weak self] on in self?.setAutoScroll(on) }
        panel.setAutoScrollAvailable(accessibilityAvailable)
        panel.setAutoScroll(autoScroll)
        self.panel = panel
        if accessibilityAvailable {
            panel.setHint(autoScroll
                ? "自动滚动中… 也可手动滚动 · 完成后点「结束并保存」"
                : "在选区内手动滚动，或把鼠标移到选区下边缘滚动")
        } else {
            panel.setHint("手动滚动中 · 自动/鼠标滚动需「辅助功能」权限（点「自动滚动」授权）")
        }
        panel.update(frameCount: 0)
        panel.show(near: rect)

        // 选区蓝色边框：提示滚动范围
        let border = RecordingRegionBorderPanel(region: rect, color: .systemBlue)
        border.show()
        regionBorder = border

        captureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureOneFrame()
            }
        }
        // 鼠标驱动滚动：高频检测鼠标相对选区边缘的位置
        edgeScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.driveEdgeScroll()
            }
        }
        captureOneFrame()
        Log.capture.info("Scroll capture started (\(Int(rect.width))×\(Int(rect.height)), auto=\(self.autoScroll))")
    }

    /// 自动滚动开关：无辅助功能权限时引导授权并回退为手动。
    private func setAutoScroll(_ on: Bool) {
        guard on else {
            autoScroll = false
            panel?.setAutoScroll(false)
            if AutoScroller.isTrusted() {
                panel?.setHint("在选区内手动滚动，或把鼠标移到选区下边缘滚动")
            }
            return
        }
        guard AutoScroller.isTrusted() else {
            panel?.setAutoScroll(false)
            panel?.setHint("自动/鼠标滚动需「辅助功能」权限：已打开系统设置，授权后重新勾选")
            AutoScroller.openAccessibilitySettings()
            return
        }
        autoScroll = true
        panel?.setAutoScroll(true)
        panel?.setHint("自动滚动中… 也可手动滚动 · 完成后点「结束并保存」")
    }

    /// 鼠标驱动滚动（需辅助功能权限）：鼠标在选区内靠近下边缘 → 向下滚；上边缘 → 向上滚。
    private func driveEdgeScroll() {
        guard state == .capturing, let rect = regionRect else { return }
        // 自动滚动已接管时不叠加鼠标滚动
        guard !autoScroll, AutoScroller.isTrusted() else { return }
        let plan = ScrollEdgeDriver.plan(mouse: NSEvent.mouseLocation, region: rect)
        guard plan.pixels.magnitude >= 1 else { return }
        AutoScroller.postScrollDown(pixels: plan.pixels, atAppKitPoint: plan.location)
    }

    private func captureOneFrame() {
        guard state == .capturing, let rect = regionRect else { return }
        guard frames.count < maxFrames else {
            Log.capture.info("Scroll capture hit frame cap, auto-finishing")
            finish()
            return
        }
        // 自动滚动：注入滚轮事件（路由到选区中心下的窗口）
        if autoScroll {
            AutoScroller.postScrollDown(pixels: AutoScroller.stepPixels, atAppKitPoint: CGPoint(x: rect.midX, y: rect.midY))
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await self.engine.shareableContent()
                let output = try await self.engine.captureRegion(
                    rect,
                    content: content,
                    excludeOwnWindows: true
                )
                // 重复帧（未滚动/到底）：跳过追加，并喂给到底检测
                if let previous = self.frames.last,
                   previous.width == output.image.width,
                   previous.height == output.image.height {
                    let shift = ScrollFrameMatcher.estimateShift(previous: previous, current: output.image)
                    if shift.shift == 0 && shift.confidence > 0.9 {
                        self.handleStillFrame()
                        return
                    }
                }
                self.consecutiveStillFrames = 0
                self.frames.append(output.image)
                self.panel?.update(frameCount: self.frames.count)
            } catch {
                Log.capture.error("Scroll frame failed: \(String(describing: error))")
                // 单帧失败不中断采集
            }
        }
    }

    /// 未滚动帧处理：跳过（钉钉行为：是否到底由用户判断，手动「结束并保存」）。
    private func handleStillFrame() {
        consecutiveStillFrames += 1
        panel?.update(frameCount: frames.count)
    }

    // MARK: - 完成 / 取消

    func finish() {
        guard state == .capturing else { return }
        captureTimer?.invalidate()
        captureTimer = nil
        edgeScrollTimer?.invalidate()
        edgeScrollTimer = nil
        panel?.dismiss()
        panel = nil
        regionBorder?.hide()
        regionBorder = nil
        state = .stitching

        let captured = frames
        Task { [weak self] in
            guard let self else { return }
            // 拼接在后台执行
            let result = await Task.detached(priority: .userInitiated) {
                ScrollImageStitcher.stitch(frames: captured)
            }.value

            await MainActor.run {
                self.state = .completed
                if let image = result.image {
                    if result.lowConfidenceSegments > 0 {
                        Log.capture.warning("Scroll stitch had \(result.lowConfidenceSegments) low-confidence segment(s)")
                    }
                    Log.capture.info("Scroll stitched (\(result.skippedDuplicates) duplicate frame(s) skipped)")
                    self.onStitched?(image)
                } else {
                    self.errorHandler?(.captureFailed(underlying: nil))
                }
            }
        }
    }

    func cancel() {
        captureTimer?.invalidate()
        captureTimer = nil
        edgeScrollTimer?.invalidate()
        edgeScrollTimer = nil
        panel?.dismiss()
        panel = nil
        regionBorder?.hide()
        regionBorder = nil
        frames = []
        regionRect = nil
        state = .cancelled
        Log.capture.info("Scroll capture cancelled")
    }

    // MARK: - 权限

    private func ensurePermission() -> Bool {
        guard let authorized = ScreenCapturePermission.isAuthorized() else {
            Task {
                if await !ScreenCapturePermission.request() {
                    errorHandler?(.permissionDenied)
                }
            }
            return false
        }
        if authorized { return true }
        Task {
            if await !ScreenCapturePermission.request() {
                errorHandler?(.permissionDenied)
            }
        }
        return false
    }
}
