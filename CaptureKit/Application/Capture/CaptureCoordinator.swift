import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 截图业务协调器（design.md §6.3）。
///
/// 流程：权限检查 → Overlay 选区 → ScreenCaptureKit 捕获 → 复制/保存 → 结果反馈。
/// 不阻塞主线程等待捕获；错误统一交给 errorHandler 呈现。
@MainActor
final class CaptureCoordinator {
    private let engine: ScreenCaptureEngine
    private let overlay: CaptureOverlayController
    private let settings: SettingsStore

    /// UI 层注入的错误呈现（Alert、权限引导等）
    var errorHandler: ((CaptureKitError) -> Void)?
    /// 编辑器入口（AppEnvironment 注入，避免模块互相持有）
    var onEditImage: ((CGImage) -> Void)?
    /// 历史记录入口（截图写入统一历史）
    var onRecordScreenshot: ((CGImage) -> Void)?
    /// 选区直录入口（工具栏/右键菜单 → RecordingCoordinator）
    var onRecordRegion: ((CGRect, RecordingMode) -> Void)?
    /// 选区长截图入口（工具栏/右键菜单 → ScrollCoordinator）
    var onScrollRegion: ((CGRect) -> Void)?
    /// 选区贴图入口（工具栏/右键菜单 → PinnedImageManager）
    var onPinImage: ((CGImage, CGRect) -> Void)?

    private var isCapturing = false
    private var countdownPanel: DelayedCapturePanel?

    init(engine: ScreenCaptureEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
        self.overlay = CaptureOverlayController()
        // 截图流程展示顶部模式胶囊（截图/滚动/录屏/文字识别）
        overlay.showsModePanel = true
        // 内联 OCR：截图保持打开，识别结果以独立窗口展示（钉钉行为）
        overlay.onInlineOCR = { [weak self] rect in
            self?.runInlineOCR(rect: rect)
        }
        overlay.onFinish = { [weak self] result in
            self?.handleOverlayResult(result)
        }
        // 快照与窗口列表提供者：Overlay 放大镜 / 悬停高亮 / 吸附数据源。
        // 捕获时排除自身窗口，快照不包含 Overlay 本身。
        overlay.snapshotProvider = { [weak self] in
            guard let self else { return ([], []) }
            do {
                let content = try await self.engine.shareableContent()
                var snapshots: [ScreenSnapshot] = []
                for display in content.displays {
                    let output = try await self.engine.captureDisplay(
                        display,
                        content: content,
                        excludeOwnWindows: true
                    )
                    snapshots.append(ScreenSnapshot(displayID: display.displayID, frame: display.frame, image: output.image))
                }
                let frames = self.engine.windowSnapshots(from: content, displayFrame: nil).map(\.frame)
                return (snapshots, frames)
            } catch {
                Log.overlay.error("Snapshot provider failed: \(String(describing: error))")
                return ([], [])
            }
        }
    }

    // MARK: - 入口

    func startRegionCapture() {
        cancelCountdown()
        guard ensurePermission() else { return }
        overlay.present(mode: .region)
    }

    func startWindowCapture() {
        cancelCountdown()
        guard ensurePermission() else { return }
        overlay.present(mode: .window)
    }

    /// 延时截图：倒计时（设置项 delaySeconds）后自动进入区域截图。
    func startDelayedCapture() {
        cancelCountdown()
        guard ensurePermission() else { return }
        let seconds = min(10, max(1, settings.settings.capture.delaySeconds))

        let panel = DelayedCapturePanel()
        panel.onCancel = { [weak self] in self?.cancelCountdown() }
        countdownPanel = panel
        panel.show(seconds: seconds) { [weak self] in
            self?.countdownPanel = nil
            self?.startRegionCapture()
        }
    }

    private func cancelCountdown() {
        // 先置 nil 再 cancel，避免 onCancel 回调重入
        guard let panel = countdownPanel else { return }
        countdownPanel = nil
        panel.cancel()
    }

    /// 全屏捕获当前鼠标所在显示器。
    func captureFullscreen() {
        guard ensurePermission() else { return }
        let mouseLocation = NSEvent.mouseLocation

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await self.engine.shareableContent()
                guard let display = content.displays.first(where: { $0.frame.contains(mouseLocation) })
                    ?? content.displays.first
                else {
                    throw CaptureKitError.captureFailed(underlying: nil)
                }
                let output = try await self.engine.captureDisplay(
                    display,
                    content: content,
                    excludeOwnWindows: self.settings.settings.capture.excludeOwnWindows
                )
                self.deliver(output: output, action: .copy, anchorRect: display.frame)
            } catch {
                self.report(error)
            }
        }
    }

    // MARK: - Overlay 结果

    private func handleOverlayResult(_ result: CaptureOverlayController.Result) {
        switch result {
        case .cancelled:
            break

        case .region(let rect, let action):
            guard !isCapturing else { return }
            isCapturing = true
            Task { [weak self] in
                defer { self?.isCapturing = false }
                guard let self else { return }
                do {
                    let content = try await self.engine.shareableContent()
                    let output = try await self.engine.captureRegion(
                        rect,
                        content: content,
                        excludeOwnWindows: self.settings.settings.capture.excludeOwnWindows
                    )
                    self.deliver(output: output, action: action, anchorRect: rect)
                } catch {
                    self.report(error)
                }
            }

        case .windowAt(let point):
            guard !isCapturing else { return }
            isCapturing = true
            Task { [weak self] in
                defer { self?.isCapturing = false }
                guard let self else { return }
                do {
                    let content = try await self.engine.shareableContent()
                    let candidates = self.engine.windowSnapshots(from: content, displayFrame: nil)
                        .map { (windowID: $0.windowID, frame: $0.frame) }
                    guard let windowID = ScreenGeometry.window(at: point, candidates: candidates),
                          let window = content.windows.first(where: { $0.windowID == windowID })
                    else {
                        throw CaptureKitError.invalidSelection
                    }
                    let output = try await self.engine.captureWindow(window)
                    self.deliver(output: output, action: .copy, anchorRect: window.frame)
                } catch {
                    self.report(error)
                }
            }

        case .recognizeRegion(let rect):
            // 选区 OCR：捕获 → Vision 识别 → 结果窗口展示（不自动关闭，钉钉行为）
            runInlineOCR(rect: rect)

        case .regionAnnotated(let rect, let annotations):
            // 选区内直接标注：捕获 → 标注缩放到像素坐标 → 统一管线合成 → 复制
            guard !isCapturing else { return }
            isCapturing = true
            Task { [weak self] in
                defer { self?.isCapturing = false }
                guard let self else { return }
                do {
                    let content = try await self.engine.shareableContent()
                    let output = try await self.engine.captureRegion(
                        rect,
                        content: content,
                        excludeOwnWindows: self.settings.settings.capture.excludeOwnWindows
                    )
                    let scaled = OverlayAnnotationExporter.scale(
                        annotations: annotations,
                        selectionSize: rect.size,
                        imageSize: CGSize(width: output.image.width, height: output.image.height)
                    )
                    if let composite = AnnotationRenderer.compose(baseImage: output.image, annotations: scaled) {
                        self.onRecordScreenshot?(composite)
                        do {
                            try ClipboardWriter.copy(composite)
                            CaptureResultToast.show(image: composite, message: "已复制（含标注）", anchorRect: rect)
                        } catch {
                            self.report(error)
                        }
                    } else {
                        // 合成失败兜底：按普通复制交付原始截图
                        self.deliver(output: output, action: .copy, anchorRect: rect)
                    }
                } catch {
                    self.report(error)
                }
            }

        case .recordRegion(let rect, let mode):
            onRecordRegion?(rect, mode)

        case .scrollRegion(let rect):
            onScrollRegion?(rect)

        case .pinRegion(let rect):
            // 贴图：捕获选区 → 钉在原位的置顶浮窗（截图同时入历史）
            guard !isCapturing else { return }
            isCapturing = true
            Task { [weak self] in
                defer { self?.isCapturing = false }
                guard let self else { return }
                do {
                    let content = try await self.engine.shareableContent()
                    let output = try await self.engine.captureRegion(
                        rect,
                        content: content,
                        excludeOwnWindows: self.settings.settings.capture.excludeOwnWindows
                    )
                    self.onRecordScreenshot?(output.image)
                    self.onPinImage?(output.image, rect)
                } catch {
                    self.report(error)
                }
            }
        }
    }

    // MARK: - 结果分发

    private func deliver(output: ScreenCaptureEngine.CaptureOutput, action: CaptureDeliveryAction, anchorRect: CGRect) {
        // 统一历史：所有交付路径记录原始截图（合成图导出由编辑器另行记录，哈希去重）
        onRecordScreenshot?(output.image)

        switch action {
        case .copy:
            // ✓/Enter = 直接写剪贴板（钉钉语义：选区内标注已就绪，不再自动打开编辑器）
            do {
                try ClipboardWriter.copy(output.image)
                CaptureResultToast.show(image: output.image, message: "已复制到剪贴板", anchorRect: anchorRect)
            } catch {
                report(error)
            }

        case .save:
            SavePanelPresenter.presentPNGPanel(for: output.image)

        case .edit:
            onEditImage?(output.image)
        }
        Log.capture.info("Capture delivered (\(output.image.width)×\(output.image.height), action=\(action, privacy: .public))")
    }

    // MARK: - 内联 OCR（截图保持打开）

    /// 选区文字识别：不关闭截图，结果以独立窗口展示（钉钉行为）。
    private func runInlineOCR(rect: CGRect) {
        guard !isCapturing else { return }
        isCapturing = true
        Task { [weak self] in
            defer { self?.isCapturing = false }
            guard let self else { return }
            do {
                let content = try await self.engine.shareableContent()
                let output = try await self.engine.captureRegion(
                    rect,
                    content: content,
                    excludeOwnWindows: self.settings.settings.capture.excludeOwnWindows
                )
                let text = try await OCRService.recognizeText(in: output.image)
                OCRResultPanelController.shared.show(text: text, anchorRect: rect)
            } catch {
                self.report(error)
            }
        }
    }

    // MARK: - 权限与错误

    private func ensurePermission() -> Bool {
        guard let authorized = ScreenCapturePermission.isAuthorized() else {
            // 无法判断时按未授权处理并请求
            Task {
                if await !ScreenCapturePermission.request() {
                    self.errorHandler?(.permissionDenied)
                }
            }
            return false
        }
        if authorized { return true }

        Task {
            // CGRequestScreenCaptureAccess 仅首次弹系统对话框
            if await !ScreenCapturePermission.request() {
                self.errorHandler?(.permissionDenied)
            }
        }
        return false
    }

    private func report(_ error: Error) {
        if let error = error as? CaptureKitError {
            errorHandler?(error)
        } else {
            errorHandler?(CaptureKitError.captureFailed(underlying: error))
        }
        Log.capture.error("Capture failed: \(String(describing: error))")
    }
}

/// NSSavePanel 展示（保存 PNG 到用户指定位置）。
@MainActor
enum SavePanelPresenter {
    static func presentPNGPanel(for image: CGImage, onSaved: (() -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try writePNG(image, to: url)
                Log.capture.info("Saved to \(url.lastPathComponent, privacy: .public)")
                onSaved?()
            } catch {
                Log.capture.error("Save failed: \(error.localizedDescription)")
            }
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = ClipboardWriter.pngData(from: image) else {
            throw CaptureKitError.exportFailed(underlying: nil)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureKitError.exportFailed(underlying: error)
        }
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date())).png"
    }
}
