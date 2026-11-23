import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 采集引擎（design.md §6.4 CaptureEngine）。
///
/// 封装静态截图：全屏（指定显示器）、窗口、区域（整屏捕获后按像素矩形裁剪）。
/// UI 层不感知具体系统 API；坐标转换统一经由 ScreenGeometry。
///
/// 最低系统要求：macOS 14.0（SCScreenshotManager）。
final class ScreenCaptureEngine {
    struct CaptureOutput {
        let image: CGImage
        /// 实际捕获内容对应的显示器
        let displayID: CGDirectDisplayID
        let capturedAt: Date
    }

    /// 显示器信息快照（逻辑 frame 与 NSScreen/SCDisplay 一致，原点主屏左下）。
    struct DisplaySnapshot {
        let displayID: CGDirectDisplayID
        let frame: CGRect
    }

    struct WindowSnapshot {
        let windowID: CGWindowID
        let frame: CGRect
        let title: String?
        let owningBundleID: String?
    }

    init() {}

    // MARK: - 内容发现

    /// 获取当前可共享内容（排除桌面窗口，仅可见窗口）。
    func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func displaySnapshots(from content: SCShareableContent) -> [DisplaySnapshot] {
        content.displays.map { DisplaySnapshot(displayID: $0.displayID, frame: $0.frame) }
    }

    /// 可用于点击捕获的窗口（排除本应用窗口与全屏大小的桌面级窗口）。
    func windowSnapshots(from content: SCShareableContent, displayFrame: CGRect?) -> [WindowSnapshot] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { (window: SCWindow) -> WindowSnapshot? in
            guard window.owningApplication != nil,
                  window.owningApplication?.processID != ownPID,
                  window.frame.width > 40, window.frame.height > 40
            else { return nil }
            // 超出目标显示器的窗口保留（窗口可跨屏），由命中检测决定
            return WindowSnapshot(
                windowID: window.windowID,
                frame: window.frame,
                title: window.title,
                owningBundleID: window.owningApplication?.bundleIdentifier
            )
        }
    }

    // MARK: - 捕获

    /// 捕获整台显示器。
    /// - Parameters:
    ///   - content: 当前可共享内容（用于解析自身 app 以排除 Overlay 等窗口）。
    ///   - excludeOwnWindows: 排除 CaptureKit 自身窗口。
    func captureDisplay(_ display: SCDisplay, content: SCShareableContent, excludeOwnWindows: Bool) async throws -> CaptureOutput {
        let ownApps: [SCRunningApplication] = excludeOwnWindows
            ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            : []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: []
        )
        let image = try await captureImage(with: filter, logicalSize: display.frame.size, displayID: display.displayID)
        return CaptureOutput(image: image, displayID: display.displayID, capturedAt: Date())
    }

    /// 捕获指定窗口（不含窗口外内容）。
    func captureWindow(_ window: SCWindow) async throws -> CaptureOutput {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // desktopIndependentWindow 输出尺寸跟随窗口 backing；
        // 显式按 frame × 显示器缩放请求，保证 Retina 清晰度。
        let scale = await displayScale(for: window.frame)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB as CFString

        do {
            // macOS 14+ 静态截图 API，返回单张 CGImage
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CaptureOutput(image: image, displayID: 0, capturedAt: Date())
        } catch let error as CaptureKitError {
            throw error
        } catch {
            throw CaptureKitError.captureFailed(underlying: error)
        }
    }

    /// 捕获全局逻辑坐标矩形（区域截图）。
    ///
    /// 策略：选取与矩形相交面积最大的显示器 → 捕获整屏 → 按像素矩形裁剪交集。
    /// 选区完全在某一块屏内时输出与选区等大；跨屏选区裁剪为该屏内交集。
    func captureRegion(
        _ rect: CGRect,
        content: SCShareableContent,
        excludeOwnWindows: Bool
    ) async throws -> CaptureOutput {
        let candidates = displaySnapshots(from: content)
            .map { (displayID: $0.displayID, frame: $0.frame) }
        guard rect.width >= 1, rect.height >= 1 else {
            throw CaptureKitError.invalidSelection
        }
        guard let displayID = ScreenGeometry.bestDisplay(for: rect, candidates: candidates),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw CaptureKitError.invalidSelection
        }

        let output = try await captureDisplay(display, content: content, excludeOwnWindows: excludeOwnWindows)

        let displayFrame = display.frame
        let intersection = rect.intersection(displayFrame)
        guard !intersection.isNull else { throw CaptureKitError.invalidSelection }

        let pixelRect = ScreenGeometry.pixelRect(
            logicalRect: intersection,
            displayFrame: displayFrame,
            imagePixelSize: CGSize(width: output.image.width, height: output.image.height)
        )
        guard let clamped = ScreenGeometry.clampedPixelRect(pixelRect, in: CGSize(width: output.image.width, height: output.image.height)),
              let cropped = output.image.cropping(to: clamped)
        else {
            throw CaptureKitError.invalidSelection
        }
        return CaptureOutput(image: cropped, displayID: displayID, capturedAt: output.capturedAt)
    }

    // MARK: - 私有

    private func captureImage(with filter: SCContentFilter, logicalSize: CGSize, displayID: CGDirectDisplayID) async throws -> CGImage {
        let config = SCStreamConfiguration()
        // 使用显示器物理像素尺寸，保证 Retina 原生分辨率
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            config.width = mode.pixelWidth
            config.height = mode.pixelHeight
        } else {
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
            config.width = max(1, Int(logicalSize.width * scale))
            config.height = max(1, Int(logicalSize.height * scale))
        }
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB as CFString

        do {
            // macOS 14+ 静态截图 API，返回单张 CGImage
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch let error as CaptureKitError {
            throw error
        } catch {
            throw CaptureKitError.captureFailed(underlying: error)
        }
    }

    /// 取窗口中心所在显示器的 backingScaleFactor。
    private func displayScale(for windowFrame: CGRect) async -> CGFloat {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return await MainActor.run {
            let screen = NSScreen.screens.first {
                $0.frame.insetBy(dx: -2, dy: -2).contains(center)
            }
            return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
    }
}
