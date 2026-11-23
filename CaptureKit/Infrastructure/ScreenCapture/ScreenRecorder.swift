import CoreMedia
import Foundation
import ScreenCaptureKit

/// SCStream 录制封装（design.md §8.1 CaptureEngine 的流式版本）。
///
/// 职责：
/// - 配置并启动 SCStream（帧率、clipBounds 区域、排除自身 app）。
/// - 帧回调分发（不阻塞 SCStream 回调线程；上层自行决定处理方式）。
/// - 停止并释放资源。
///
/// 暂停/恢复不在本层实现（由 RecordingCoordinator 用 PauseTimeline 处理帧过滤与时间轴）。
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 帧回调（SCStream 回调线程；不得执行耗时工作）。
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// 音频帧回调（capturesAudio 开启时）。
    var onAudioFrame: ((CMSampleBuffer) -> Void)?
    /// 麦克风帧回调（capturesMicrophone 开启时）。
    var onMicrophoneFrame: ((CMSampleBuffer) -> Void)?
    /// 流异常终止回调。
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private var running = false

    /// 启动录制流。
    /// - Parameters:
    ///   - filter: 内容过滤器（已排除自身窗口的整屏/单窗口 filter）。
    ///   - pixelSize: 输出像素尺寸。
    ///   - fps: 帧率。
    ///   - capturesAudio: 捕获系统音频（plan.md §2.6.5 音频）。
    ///   - capturesMicrophone: 捕获麦克风（需已获 TCC 麦克风授权，Phase 6）。
    func start(filter: SCContentFilter, pixelSize: CGSize, fps: Int, showsCursor: Bool,
               capturesAudio: Bool = false, capturesMicrophone: Bool = false) async throws {
        guard !running else { throw CaptureKitError.captureFailed(underlying: nil) }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, fps)))
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if capturesAudio {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
        }
        if #available(macOS 15.0, *) {
            if capturesMicrophone {
                configuration.captureMicrophone = true
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream

        do {
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.wanghao.capturekit.recorder.frames", qos: .userInitiated)
            )
            if capturesAudio {
                try stream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: DispatchQueue(label: "com.wanghao.capturekit.recorder.audio", qos: .userInitiated)
                )
            }
            if #available(macOS 15.0, *) {
                if capturesMicrophone {
                    try stream.addStreamOutput(
                        self,
                        type: .microphone,
                        sampleHandlerQueue: DispatchQueue(label: "com.wanghao.capturekit.recorder.mic", qos: .userInitiated)
                    )
                }
            }
            try await stream.startCapture()
            running = true
            Log.recording.info("SCStream started (\(Int(pixelSize.width))×\(Int(pixelSize.height)) @ \(fps)fps, audio=\(capturesAudio), mic=\(capturesMicrophone))")
        } catch {
            self.stream = nil
            throw CaptureKitError.captureFailed(underlying: error)
        }
    }

    /// 停止并释放。
    func stop() async {
        guard running else { return }
        running = false
        onFrame = nil
        onAudioFrame = nil
        onMicrophoneFrame = nil
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
            if #available(macOS 15.0, *) {
                try? stream.removeStreamOutput(self, type: .microphone)
            }
        }
        stream = nil
        Log.recording.info("SCStream stopped")
    }

    var isRunning: Bool { running }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard running, sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue
            else { return }
            onFrame?(sampleBuffer)
        case .audio:
            onAudioFrame?(sampleBuffer)
        case .microphone:
            onMicrophoneFrame?(sampleBuffer)
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard running else { return }
        Log.recording.error("SCStream stopped with error: \(error.localizedDescription)")
        onError?(error)
    }
}
