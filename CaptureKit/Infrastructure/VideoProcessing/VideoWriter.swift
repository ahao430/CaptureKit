import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// 视频流式写入器（design.md §8.5）：AVAssetWriter + H.264。
/// 暂停时间轴由调用方处理：append 时传入调整后的输出 PTS。
final class VideoWriter {
    enum WriterError: Error {
        case cannotStart(String)
        case cannotAppend(String)
    }

    let outputURL: URL
    private let size: CGSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    /// 帧写入计数（诊断用）。
    private(set) var appendedFrameCount = 0
    private(set) var appendedAudioSampleCount = 0

    init(outputURL: URL, size: CGSize, audioFormatDescription: CMFormatDescription? = nil) throws {
        self.outputURL = outputURL
        self.size = size

        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: Self.bitRate(for: size),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw WriterError.cannotStart("cannot add input")
        }
        writer.add(input)

        // 音频轨必须在 startWriting 前添加；SCK 音频输出格式固定（48kHz Float32 双声道）
        if let audioFormatDescription {
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: 128_000,
                ],
                sourceFormatHint: audioFormatDescription
            )
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
                Log.recording.info("Audio input attached at init (AAC)")
            }
        }
    }

    /// SCK 音频输出的约定格式描述（48kHz / Float32 / 双声道）。
    nonisolated static func makeDefaultAudioFormatDescription() -> CMFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var format: CMFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return format
    }

    /// 开始会话（源起始 PTS）。
    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        sessionStarted = true
    }

    /// 追加帧（输出 PTS 已由上层调整好）。
    /// - Returns: false 表示本帧被丢弃（input 满，背压下自然丢帧）。
    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer, outputPTS: CMTime) -> Bool {
        guard sessionStarted, writer.status == .writing else { return false }
        guard input.isReadyForMoreMediaData else {
            // 背压：丢帧而不是无限缓存（design.md §8.4 明确丢帧策略）
            return false
        }

        // 重写 PTS 为输出时间轴
        var timing = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 600),
                presentationTimeStamp: outputPTS,
                decodeTimeStamp: .invalid
            ),
            count: 1
        )
        var rewritten: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &rewritten
        )
        guard let rewritten else { return false }
        guard input.append(rewritten) else {
            Log.recording.error("AVAssetWriter append failed (status \(self.writer.status.rawValue))")
            return false
        }
        appendedFrameCount += 1
        return true
    }

    /// 追加音频帧（输出 PTS 已调整；音频轨须在 init 时创建）。
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer, outputPTS: CMTime) -> Bool {
        guard sessionStarted, writer.status == .writing else { return false }
        guard let audioInput, audioInput.isReadyForMoreMediaData else {
            // 无音轨（未开启音频）或背压：丢音频块（视频帧优先）
            return false
        }

        var timing = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: outputPTS,
                decodeTimeStamp: .invalid
            ),
            count: 1
        )
        var rewritten: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &rewritten
        )
        guard let rewritten else { return false }
        guard audioInput.append(rewritten) else { return false }
        appendedAudioSampleCount += 1
        return true
    }

    /// 完成写入并落盘。
    /// - Returns: 成功后的文件 URL；失败抛错。
    func finish() async throws -> URL {
        guard sessionStarted else {
            writer.cancelWriting()
            throw WriterError.cannotStart("session not started")
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed {
            Log.recording.info("Video finished: \(self.outputURL.lastPathComponent, privacy: .public) (\(self.appendedFrameCount) frames)")
            return outputURL
        }
        if let error = writer.error {
            throw WriterError.cannotAppend(error.localizedDescription)
        }
        throw WriterError.cannotAppend("unknown writer failure")
    }

    /// 放弃写入（取消录制）。
    func cancel() {
        input.markAsFinished()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private static func bitRate(for size: CGSize) -> Int {
        // 常用估算：~4 bit/px/s 起步，限制在合理区间
        let pixels = size.width * size.height
        return Int(min(max(pixels * 4, 2_000_000), 24_000_000))
    }
}
