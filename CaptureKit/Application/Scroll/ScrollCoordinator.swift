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
    private var captureTimer: Timer?
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
        overlay.present(mode: .region)
    }

    private func handleOverlayResult(_ result: CaptureOverlayController.Result) {
        switch result {
        case .region(let rect, _):
            beginCapturing(in: rect)
        case .windowAt, .cancelled:
            state = .cancelled
        }
    }

    // MARK: - 采集

    private func beginCapturing(in rect: CGRect) {
        state = .capturing
        regionRect = rect
        frames = []
        consecutiveStillFrames = 0

        // 自动滚动决策（ADR-027）：设置开 + 辅助功能授权；未授权弹一次引导后降级手动
        autoScroll = false
        if settings.settings.capture.scrollAutoScroll {
            if AutoScroller.isTrusted() {
                autoScroll = true
            } else {
                let alert = NSAlert()
                alert.messageText = "开启自动滚动需要辅助功能权限"
                alert.informativeText = "授权后 CaptureKit 会自动滚动页面（到底自动完成）；不授权也可以手动滚动。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "手动滚动")
                if alert.runModal() == .alertFirstButtonReturn {
                    AutoScroller.openAccessibilitySettings()
                }
            }
        }

        let panel = ScrollCapturePanel()
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        self.panel = panel
        panel.setHint(autoScroll ? "自动滚动中… 也可手动滚动 · 到底自动完成" : "在选区内手动滚动页面")
        panel.show(near: rect)

        captureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureOneFrame()
            }
        }
        captureOneFrame()
        Log.capture.info("Scroll capture started (\(Int(rect.width))×\(Int(rect.height)), auto=\(self.autoScroll))")
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

    /// 未滚动帧处理：自动模式下连续 2 帧 → 判定到底，自动完成。
    private func handleStillFrame() {
        consecutiveStillFrames += 1
        if autoScroll, consecutiveStillFrames >= 2 {
            Log.capture.info("Scroll reached bottom, auto-finishing")
            finish()
        } else {
            panel?.update(frameCount: frames.count)
        }
    }

    // MARK: - 完成 / 取消

    func finish() {
        guard state == .capturing else { return }
        captureTimer?.invalidate()
        captureTimer = nil
        panel?.dismiss()
        panel = nil
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
        panel?.dismiss()
        panel = nil
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
