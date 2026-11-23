import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// 录制业务协调器（design.md §8.3）。
///
/// 流程：权限 → Overlay 选区（或全屏）→ SCStream 启动 → 帧管线（暂停过滤 + PTS 调整）
/// → VideoWriter/GIFEncoder 流式写入 → 停止 → 完成（HUD 全程排除在录制外）。
@MainActor
final class RecordingCoordinator {
    private let engine: ScreenCaptureEngine
    private let settings: SettingsStore
    private let overlay: CaptureOverlayController

    private let hud = RecordingHUDPanel()

    private var recorder: ScreenRecorder?
    private var videoWriter: VideoWriter?
    private var gifEncoder: GIFEncoder?
    private var session: RecordingSession?
    private var pauseTimeline = PauseTimeline()
    /// 首帧原始 PTS（秒），输出时间轴原点
    private var timelineOrigin: Double?
    /// GIF 帧率节流：上次写入帧的原始 PTS
    private var lastGIFFramePTS: Double?
    private var hudTimer: Timer?
    /// 区域录制上下文（整屏流 + 逐帧裁剪）
    private var activeDisplayFrame: CGRect?
    private var activeRegionRect: CGRect?
    /// 点击高亮（Phase 6）
    private let clickHighlighter = ClickHighlighter()
    /// 音频写入的最近输出 PTS（系统音频 + 麦克风共用一个音轨，乱序丢弃保单调）
    private var lastAudioPTS: Double = -1

    var errorHandler: ((CaptureKitError) -> Void)?
    /// 录制完成回调（预览编辑器入口，Phase 4 批次 2 接入）
    var onRecordingCompleted: ((URL, RecordingMode) -> Void)?

    /// 最近一次录制的有效时长（秒，已扣除暂停段）——历史记录用。
    private(set) var lastRecordedDuration: Double?

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
        hud.onPauseToggle = { [weak self] in self?.togglePause() }
        hud.onStop = { [weak self] in self?.stop() }
        hud.onCancel = { [weak self] in self?.confirmCancel() }
    }

    // MARK: - 入口

    /// 区域录制：Overlay 选区 → Enter 开始。
    func startRegionRecording(mode: RecordingMode) {
        guard ensurePermission() else { return }
        guard session?.state != .recording, session?.state != .paused else { return }
        pendingMode = mode
        overlay.present(mode: .recordRegion)
    }

    /// 全屏录制（鼠标所在显示器）。
    func startFullscreenRecording(mode: RecordingMode) {
        guard ensurePermission() else { return }
        guard session?.state != .recording, session?.state != .paused else { return }
        beginRecording(regionRect: nil, mode: mode)
    }

    /// 窗口录制：Overlay 双击选择窗口 → 开始录制该窗口（Phase 4 批次 2）。
    func startWindowRecording(mode: RecordingMode) {
        guard ensurePermission() else { return }
        guard session?.state != .recording, session?.state != .paused else { return }
        pendingMode = mode
        overlay.present(mode: .recordWindow)
    }

    // MARK: - 控制

    func togglePause() {
        guard let session else { return }
        switch session.state {
        case .recording:
            pauseTimeline.pause(at: nowOnTimeline())
            self.session?.state = .paused
            refreshHUD()
        case .paused:
            pauseTimeline.resume(at: nowOnTimeline())
            self.session?.state = .recording
            lastGIFFramePTS = nil // 恢复后立即写入一帧
            refreshHUD()
        default:
            break
        }
    }

    func stop() {
        guard let session, session.state == .recording || session.state == .paused else { return }
        if session.state == .paused {
            // 结束未闭合的暂停段
            pauseTimeline.resume(at: nowOnTimeline())
        }
        self.session?.state = .stopping
        refreshHUD()

        Task { [weak self] in
            await self?.finishRecording(cancelled: false)
        }
    }

    /// 取消录制（plan.md §2.6.3：需确认）。
    func confirmCancel() {
        guard let session, session.state == .recording || session.state == .paused else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "取消录制？"
        alert.informativeText = "已录制的内容将被丢弃。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消录制")
        alert.addButton(withTitle: "继续录制")
        if alert.runModal() == .alertFirstButtonReturn {
            self.session?.state = .stopping
            Task { [weak self] in
                await self?.finishRecording(cancelled: true)
            }
        }
    }

    // MARK: - Overlay 结果

    private func handleOverlayResult(_ result: CaptureOverlayController.Result) {
        switch result {
        case .region(let rect, _):
            beginRecording(regionRect: rect, mode: currentMode)
        case .windowAt(let point):
            // 窗口录制：解析双击命中的窗口
            Task { [weak self] in
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
                    self.beginWindowRecording(window: window, mode: self.currentMode)
                } catch {
                    self.errorHandler?((error as? CaptureKitError) ?? .captureFailed(underlying: error))
                }
            }
        case .cancelled:
            break
        }
    }

    private var currentMode: RecordingMode {
        // 入口决定模式；通过暂存传递
        pendingMode ?? .video
    }

    private var pendingMode: RecordingMode?

    // MARK: - 启动

    private func beginRecording(regionRect: CGRect?, mode: RecordingMode) {
        let recordingSettings = settings.settings.recording
        var session = RecordingSession(
            mode: mode,
            settings: RecordingSettings(
                fps: recordingSettings.fps,
                gifMaxPixelWidth: recordingSettings.gifMaxPixelWidth,
                showsCursor: recordingSettings.showsCursor
            ),
            regionRect: regionRect
        )
        session.state = .starting
        self.session = session
        pendingMode = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await self.engine.shareableContent()
                let candidates = content.displays.map { (displayID: $0.displayID, frame: $0.frame) }

                let display: SCDisplay
                if let rect = regionRect {
                    guard let displayID = ScreenGeometry.bestDisplay(for: rect, candidates: candidates),
                          let d = content.displays.first(where: { $0.displayID == displayID })
                    else {
                        throw CaptureKitError.invalidSelection
                    }
                    display = d
                } else {
                    let mouse = await MainActor.run { NSEvent.mouseLocation }
                    guard let d = content.displays.first(where: { $0.frame.contains(mouse) })
                        ?? content.displays.first
                    else {
                        throw CaptureKitError.captureFailed(underlying: nil)
                    }
                    display = d
                }

                // 整屏像素流（区域在帧管线裁剪；SCStream 输出物理像素）
                let scale = await self.displayScale(for: display.displayID)
                let displayPixelWidth: Int
                let displayPixelHeight: Int
                if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                    displayPixelWidth = mode.pixelWidth
                    displayPixelHeight = mode.pixelHeight
                } else {
                    displayPixelWidth = max(2, Int(display.frame.width * scale))
                    displayPixelHeight = max(2, Int(display.frame.height * scale))
                }

                // 输出尺寸：区域 = 区域像素；全屏 = 整屏像素
                let outputWidth: Int
                let outputHeight: Int
                if let rect = regionRect {
                    outputWidth = max(2, Int(rect.width * scale))
                    outputHeight = max(2, Int(rect.height * scale))
                } else {
                    outputWidth = displayPixelWidth
                    outputHeight = displayPixelHeight
                }

                // 排除自身 app（Overlay/HUD/Toast 不入镜）
                let ownApps: [SCRunningApplication] = content.applications.filter {
                    $0.processID == ProcessInfo.processInfo.processIdentifier
                }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

                // 输出文件
                let outputURL = try Self.makeOutputURL(mode: mode)

                if mode == .video {
                    let writer = try VideoWriter(
                        outputURL: outputURL,
                        size: CGSize(width: outputWidth, height: outputHeight),
                        audioFormatDescription: recordingSettings.audioEnabled
                            ? VideoWriter.makeDefaultAudioFormatDescription()
                            : nil
                    )
                    writer.start()
                    self.videoWriter = writer
                } else {
                    let encoder = try GIFEncoder(
                        outputURL: outputURL,
                        fps: session.settings.resolvedFPS(for: mode),
                        maxPixelWidth: session.settings.gifMaxPixelWidth
                    )
                    self.gifEncoder = encoder
                }

                // 启动整屏流
                var microphoneEnabled = false
                if mode == .video, recordingSettings.microphoneEnabled {
                    microphoneEnabled = await MicrophonePermission.ensureAuthorized()
                    if !microphoneEnabled {
                        Log.recording.info("Microphone denied, recording without mic audio")
                    }
                }
                let recorder = ScreenRecorder()
                self.configureFramePipeline(recorder: recorder, mode: mode)
                try await recorder.start(
                    filter: filter,
                    pixelSize: CGSize(width: displayPixelWidth, height: displayPixelHeight),
                    fps: session.settings.resolvedFPS(for: mode),
                    showsCursor: session.settings.showsCursor,
                    capturesAudio: mode == .video && recordingSettings.audioEnabled,
                    capturesMicrophone: microphoneEnabled
                )
                self.recorder = recorder
                self.activeDisplayFrame = display.frame
                self.activeRegionRect = regionRect

                // 会话正式开始
                self.session?.state = .recording
                self.session?.startedAt = Date()
                self.session?.outputURL = outputURL
                self.timelineOrigin = nil
                self.lastGIFFramePTS = nil
                self.lastAudioPTS = -1
                if mode == .video, recordingSettings.clickEffects {
                    self.clickHighlighter.start()
                }
                self.showHUD()
                Log.recording.info("Recording started (\(mode.displayName, privacy: .public), output \(outputWidth)×\(outputHeight))")
            } catch {
                self.session?.state = .failed(error.localizedDescription)
                self.cleanup()
                let captureError = (error as? CaptureKitError) ?? .recordingFailed(underlying: error)
                self.errorHandler?(captureError)
            }
        }
    }

    /// 窗口录制启动（desktopIndependentWindow filter，无裁剪；Phase 4 批次 2）。
    private func beginWindowRecording(window: SCWindow, mode: RecordingMode) {
        let recordingSettings = settings.settings.recording
        var session = RecordingSession(
            mode: mode,
            settings: RecordingSettings(
                fps: recordingSettings.fps,
                gifMaxPixelWidth: recordingSettings.gifMaxPixelWidth,
                showsCursor: recordingSettings.showsCursor
            ),
            regionRect: window.frame
        )
        session.state = .starting
        self.session = session
        pendingMode = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let scale = await self.displayScale(forWindowFrame: window.frame)
                let pixelWidth = max(2, Int(window.frame.width * scale))
                let pixelHeight = max(2, Int(window.frame.height * scale))

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let outputURL = try Self.makeOutputURL(mode: mode)

                if mode == .video {
                    let writer = try VideoWriter(
                        outputURL: outputURL,
                        size: CGSize(width: pixelWidth, height: pixelHeight),
                        audioFormatDescription: recordingSettings.audioEnabled
                            ? VideoWriter.makeDefaultAudioFormatDescription()
                            : nil
                    )
                    writer.start()
                    self.videoWriter = writer
                } else {
                    let encoder = try GIFEncoder(
                        outputURL: outputURL,
                        fps: session.settings.resolvedFPS(for: mode),
                        maxPixelWidth: session.settings.gifMaxPixelWidth
                    )
                    self.gifEncoder = encoder
                }

                let recorder = ScreenRecorder()
                self.configureFramePipeline(recorder: recorder, mode: mode)
                var microphoneEnabled = false
                if mode == .video, recordingSettings.microphoneEnabled {
                    microphoneEnabled = await MicrophonePermission.ensureAuthorized()
                    if !microphoneEnabled {
                        Log.recording.info("Microphone denied, recording without mic audio")
                    }
                }
                try await recorder.start(
                    filter: filter,
                    pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                    fps: session.settings.resolvedFPS(for: mode),
                    showsCursor: session.settings.showsCursor,
                    capturesAudio: mode == .video && recordingSettings.audioEnabled,
                    capturesMicrophone: microphoneEnabled
                )
                self.recorder = recorder
                self.activeDisplayFrame = nil
                self.activeRegionRect = nil

                self.session?.state = .recording
                self.session?.startedAt = Date()
                self.session?.outputURL = outputURL
                self.timelineOrigin = nil
                self.lastGIFFramePTS = nil
                if mode == .video, recordingSettings.clickEffects {
                    self.clickHighlighter.start()
                }
                self.showHUD()
                Log.recording.info("Window recording started (\(mode.rawValue, privacy: .public), \(pixelWidth)×\(pixelHeight))")
            } catch {
                self.session?.state = .failed(error.localizedDescription)
                self.cleanup()
                self.errorHandler?((error as? CaptureKitError) ?? .recordingFailed(underlying: error))
            }
        }
    }

    private func displayScale(forWindowFrame frame: CGRect) async -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return await MainActor.run {
            let screen = NSScreen.screens.first {
                $0.frame.insetBy(dx: -4, dy: -4).contains(center)
            }
            return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
    }

    // MARK: - 帧管线

    private func configureFramePipeline(recorder: ScreenRecorder, mode: RecordingMode) {
        let fps = session?.settings.resolvedFPS(for: mode) ?? 30
        let gifInterval = 1.0 / Double(fps)

        recorder.onFrame = { [weak self] buffer in
            let rawPTS = CMTimeGetSeconds(buffer.presentationTimeStamp)
            guard rawPTS.isFinite, rawPTS >= 0 else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
            let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

            Task { @MainActor [weak self] in
                guard let self, self.session?.state == .recording || self.session?.state == .paused else { return }
                // 原点：首帧
                if self.timelineOrigin == nil {
                    self.timelineOrigin = rawPTS
                }
                let timeline = rawPTS - (self.timelineOrigin ?? rawPTS)
                guard timeline >= 0 else { return }

                // 暂停期间丢帧
                guard !self.pauseTimeline.shouldDropFrame(at: timeline) else { return }
                let outputPTS = self.pauseTimeline.adjustedPTS(timeline)

                // 区域裁剪 rect（帧像素坐标，左上原点；全屏为 nil）
                var cropRect: CGRect?
                if let region = self.activeRegionRect, let displayFrame = self.activeDisplayFrame {
                    cropRect = PixelBufferCropper.pixelRect(
                        forRegion: region,
                        displayFrame: displayFrame,
                        framePixelSize: frameSize
                    )
                }

                switch mode {
                case .video:
                    if let crop = cropRect {
                        guard let cropped = PixelBufferCropper.crop(pixelBuffer, toPixelRect: crop) else { return }
                        self.drawClickEffectsIfEnabled(
                            on: cropped,
                            contentOrigin: self.activeRegionRect?.origin,
                            contentLogicalSize: self.activeRegionRect?.size
                        )
                        guard let sample = PixelBufferCropper.sampleBuffer(from: cropped, pts: buffer.presentationTimeStamp) else { return }
                        self.videoWriter?.append(sample, outputPTS: CMTime(seconds: outputPTS, preferredTimescale: 600))
                    } else {
                        self.drawClickEffectsIfEnabled(
                            on: pixelBuffer,
                            contentOrigin: self.activeRegionRect?.origin ?? self.activeDisplayFrame?.origin,
                            contentLogicalSize: self.activeRegionRect?.size ?? self.activeDisplayFrame.map { $0.size }
                        )
                        self.videoWriter?.append(buffer, outputPTS: CMTime(seconds: outputPTS, preferredTimescale: 600))
                    }

                case .gif:
                    // 帧率节流
                    if let last = self.lastGIFFramePTS, timeline - last < gifInterval * 0.9 {
                        return
                    }
                    self.lastGIFFramePTS = timeline
                    var image = PixelBufferCropper.cgImage(from: pixelBuffer)
                    if let crop = cropRect {
                        let clamped = crop.integral.intersection(CGRect(x: 0, y: 0, width: image?.width ?? 0, height: image?.height ?? 0))
                        if !clamped.isNull, clamped.width >= 2, clamped.height >= 2 {
                            image = image?.cropping(to: clamped)
                        }
                    }
                    guard let image else { return }
                    try? self.gifEncoder?.append(image)
                }
            }
        }

        recorder.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.session?.state == .recording || self.session?.state == .paused else { return }
                self.session?.state = .failed(error.localizedDescription)
                Log.recording.error("Stream error mid-recording: \(error.localizedDescription)")
                // 尽力保存已写入内容
                await self.finishRecording(cancelled: false)
            }
        }

        // 音频帧（系统音频 + 麦克风共用同一音轨与时间轴；暂停过滤 + PTS 调整 + 单调保护）
        recorder.onAudioFrame = { [weak self] buffer in
            self?.enqueueAudio(buffer)
        }
        recorder.onMicrophoneFrame = { [weak self] buffer in
            self?.enqueueAudio(buffer)
        }
    }

    /// 音频块入队（主线程）：暂停过滤 → PTS 调整 → 单调检查 → 写入。
    private func enqueueAudio(_ buffer: CMSampleBuffer) {
        let rawPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        guard rawPTS.isFinite, rawPTS >= 0 else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.session?.state == .recording || self.session?.state == .paused,
                  let origin = self.timelineOrigin
            else { return }
            let timeline = rawPTS - origin
            guard timeline >= 0, !self.pauseTimeline.shouldDropFrame(at: timeline) else { return }
            let outputPTS = self.pauseTimeline.adjustedPTS(timeline)
            // 双来源共用音轨：输出 PTS 必须非递减，迟到块丢弃
            guard outputPTS >= self.lastAudioPTS else {
                Log.recording.debug("Dropped out-of-order audio block (\(outputPTS) < \(self.lastAudioPTS))")
                return
            }
            if self.videoWriter?.appendAudio(buffer, outputPTS: CMTime(seconds: outputPTS, preferredTimescale: 600)) == true {
                self.lastAudioPTS = outputPTS
            }
        }
    }

    /// 点击高亮：开启时在输出帧上绘制活跃效果（就地修改像素）。
    private func drawClickEffectsIfEnabled(on buffer: CVPixelBuffer,
                                            contentOrigin: CGPoint?,
                                            contentLogicalSize: CGSize?) {
        guard settings.settings.recording.clickEffects,
              clickHighlighter.isRunning,
              let origin = contentOrigin,
              let logicalSize = contentLogicalSize
        else { return }
        let outputSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let effects = clickHighlighter.activeEffects().compactMap { effect -> (point: CGPoint, progress: Double)? in
            guard let pixel = ClickEffectRenderer.pixelPoint(
                global: effect.globalPoint,
                contentOrigin: origin,
                contentLogicalSize: logicalSize,
                outputPixelSize: outputSize
            ) else { return nil }
            return (pixel, effect.progress)
        }
        ClickEffectRenderer.drawEffects(on: buffer, effects: effects)
    }

    // MARK: - 完成

    private func finishRecording(cancelled: Bool) async {
        let recorder = recorder
        let videoWriter = videoWriter
        let gifEncoder = gifEncoder

        // 记录有效时长（扣除暂停）
        if let startedAt = session?.startedAt {
            lastRecordedDuration = max(0, Date().timeIntervalSince(startedAt) - pauseTimeline.totalPausedDuration)
        }

        hudTimer?.invalidate()
        hudTimer = nil
        hud.dismiss()

        await recorder?.stop()

        do {
            if cancelled {
                videoWriter?.cancel()
                gifEncoder?.cancel()
                session?.state = .cancelled
                Log.recording.info("Recording cancelled")
            } else if let writer = videoWriter {
                let url = try await writer.finish()
                session?.state = .completed
                notifyCompletion(url: url, mode: .video)
            } else if let encoder = gifEncoder {
                try encoder.finish()
                session?.state = .completed
                notifyCompletion(url: encoder.outputURL, mode: .gif)
            } else {
                session?.state = .failed("no encoder")
            }
        } catch {
            session?.state = .failed(error.localizedDescription)
            errorHandler?(.recordingFailed(underlying: error))
        }

        cleanup()
    }

    private func notifyCompletion(url: URL, mode: RecordingMode) {
        Log.recording.info("Recording completed: \(url.lastPathComponent, privacy: .public)")
        onRecordingCompleted?(url, mode)
    }

    private func cleanup() {
        recorder = nil
        videoWriter = nil
        gifEncoder = nil
        pauseTimeline = PauseTimeline()
        timelineOrigin = nil
        lastGIFFramePTS = nil
        lastAudioPTS = -1
        activeDisplayFrame = nil
        activeRegionRect = nil
        clickHighlighter.stop()
        hudTimer?.invalidate()
        hudTimer = nil
    }

    // MARK: - HUD

    private func showHUD() {
        hud.show()
        refreshHUD()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshHUD()
            }
        }
    }

    private func refreshHUD() {
        guard let session else { return }
        let paused = pauseTimeline.totalPausedDuration
        guard let startedAt = session.startedAt else { return }
        switch session.state {
        case .recording:
            hud.update(state: .recording(startedAt: startedAt, pausedDuration: paused))
        case .paused:
            hud.update(state: .paused(startedAt: startedAt, pausedDuration: paused))
        default:
            break
        }
    }

    /// 当前时间在原始时间轴上的位置（秒）。
    private func nowOnTimeline() -> Double {
        guard let startedAt = session?.startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
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

    // MARK: - 工具

    private func displayScale(for displayID: CGDirectDisplayID) async -> CGFloat {
        await MainActor.run {
            let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID }
            return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
    }

    /// 录制输出目录：Application Support/CaptureKit/Recordings/。
    static func recordingsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("CaptureKit/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeOutputURL(mode: RecordingMode) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Recording \(formatter.string(from: Date())).\(mode == .video ? "mp4" : "gif")"
        return try recordingsDirectory().appendingPathComponent(name)
    }
}
