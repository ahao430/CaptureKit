import Accelerate
import CoreGraphics
import Foundation

/// 滚动截图帧匹配与拼接（plan.md §2.5 基础拼接；纯函数，可单测）。
///
/// 算法：帧灰度降采样 → 逐候选位移 d 计算 A[d..H) 与 B[0..H-d) 的重叠区平均绝对差
/// → 最小差为滚动位移。d=0 表示未滚动（重复帧）。
enum ScrollFrameMatcher {
    struct MatchResult: Equatable {
        /// 帧间垂直位移（像素，0 = 无滚动）
        let shift: Int
        /// 匹配置信度 0–1（1 - 归一化差值）
        let confidence: Double
    }

    /// 估计 B 相对 A 的滚动位移（B 在 A 之后捕获；向下滚动为正）。
    /// - Parameters:
    ///   - maxShiftRatio: 最大搜索位移占帧高比例（防过度匹配）。
    static func estimateShift(previous: CGImage, current: CGImage, maxShiftRatio: Double = 0.85) -> MatchResult {
        let width = min(previous.width, current.width)
        guard width >= 8, previous.height >= 8, current.height >= 8 else {
            return MatchResult(shift: 0, confidence: 0)
        }

        let sampleWidth = 128
        let sampleHeight = min(256, min(previous.height, current.height))
        let a = grayscaleSamples(previous, width: sampleWidth, height: sampleHeight)
        let b = grayscaleSamples(current, width: sampleWidth, height: sampleHeight)

        let rowStride = max(1, sampleHeight / 24)
        let columnStride = 4
        let maxShift = Int(Double(sampleHeight) * maxShiftRatio)

        var bestShift = 0
        var bestScore = Double.greatestFiniteMagnitude
        for d in 0...max(maxShift, 0) {
            let overlapHeight = sampleHeight - d
            guard overlapHeight >= rowStride * 2 else { break }
            var total: Double = 0
            var count: Double = 0
            var row = 0
            while row < overlapHeight {
                let aRow = (d + row) * sampleWidth
                let bRow = row * sampleWidth
                var column = 0
                while column < sampleWidth {
                    total += abs(Double(a[aRow + column]) - Double(b[bRow + column]))
                    count += 1
                    column += columnStride
                }
                row += rowStride
            }
            guard count > 0 else { continue }
            let score = total / count
            if score < bestScore {
                bestScore = score
                bestShift = d
            }
        }

        // 置信度：差值归一化（≤8/255 视为高置信）
        let confidence = max(0, min(1, 1 - bestScore / 32))
        // 位移还原到原始分辨率
        let scale = Double(previous.height) / Double(sampleHeight)
        let shift = Int((Double(bestShift) * scale).rounded())
        return MatchResult(shift: shift, confidence: confidence)
    }

    /// 灰度降采样（最近邻，UInt8）。
    static func grayscaleSamples(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }
}

/// 帧拼接器：按帧间位移纵向拼接（plan.md §2.5）。
enum ScrollImageStitcher {
    struct StitchResult {
        let image: CGImage?
        /// 低于置信阈值的段数（动态内容提示用）
        let lowConfidenceSegments: Int
        /// 被跳过的重复帧数
        let skippedDuplicates: Int
    }

    /// 拼接帧序列。
    /// - Parameters:
    ///   - confidenceThreshold: 低于此置信度的位移按 0 处理并计入 lowConfidenceSegments。
    static func stitch(frames: [CGImage], confidenceThreshold: Double = 0.25) -> StitchResult {
        guard let first = frames.first else {
            return StitchResult(image: nil, lowConfidenceSegments: 0, skippedDuplicates: 0)
        }
        guard frames.count > 1 else {
            return StitchResult(image: first, lowConfidenceSegments: 0, skippedDuplicates: 0)
        }

        let width = frames.map(\.width).min() ?? first.width
        var shifts: [Int] = []
        var lowConfidence = 0
        var duplicates = 0

        for index in 1..<frames.count {
            let match = ScrollFrameMatcher.estimateShift(previous: frames[index - 1], current: frames[index])
            var shift = match.shift
            if match.confidence < confidenceThreshold {
                // 匹配不可信（动态内容/加载中）：保守取整帧追加，避免内容丢失
                shift = frames[index].height
                lowConfidence += 1
            }
            if shift <= 0 {
                duplicates += 1
                shift = 0
            }
            shifts.append(shift)
        }

        // 总高度：每帧的顶部偏移 = 前帧偏移 + 新增位移；输出高度 = max(帧偏移 + 帧高)
        // 上限 16000px（位图格式限制保护）
        var offsets: [Int] = [0]
        var totalHeight = frames[0].height
        for (index, shift) in shifts.enumerated() {
            let nextFrame = frames[index + 1]
            let offset = min(offsets[index] + max(0, shift), 16_000 - nextFrame.height)
            offsets.append(max(offset, offsets[index]))
            totalHeight = max(totalHeight, offset + nextFrame.height)
        }
        totalHeight = min(totalHeight, 16_000)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return StitchResult(image: nil, lowConfidenceSegments: lowConfidence, skippedDuplicates: duplicates)
        }
        context.interpolationQuality = .medium

        for (index, frame) in frames.enumerated() where offsets[index] < totalHeight {
            let drawHeight = min(frame.height, totalHeight - offsets[index])
            guard drawHeight > 0 else { break }
            // 位图上下文原点在左下：像素坐标（顶部对齐）需翻转 y
            let y = totalHeight - offsets[index] - drawHeight
            context.draw(frame, in: CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: CGFloat(drawHeight)))
        }

        return StitchResult(
            image: context.makeImage(),
            lowConfidenceSegments: lowConfidence,
            skippedDuplicates: duplicates
        )
    }
}
