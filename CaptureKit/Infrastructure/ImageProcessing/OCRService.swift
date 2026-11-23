import AppKit
import CoreGraphics
import Foundation
import Vision

/// OCR 文字识别（plan.md Phase 6：Vision；本地处理，不上传）。
enum OCRService {
    enum OCRError: Error {
        case requestFailed(String?)
        case imageNotSupported
    }

    /// 识别图像中的文字（简中 + 英文，accurate 级别）。
    /// - Returns: 按行拼接的全文（空图像返回空字符串）。
    static func recognizeText(in image: CGImage) async throws -> String {
        // Vision 在后台线程执行
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw OCRError.requestFailed(error.localizedDescription)
            }

            let observations = request.results ?? []
            let lines = observations.compactMap { observation -> String? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return candidate.string
            }
            return lines.joined(separator: "\n")
        }.value
    }

    /// 从图像数据（PNG 等）识别。
    static func recognizeText(in imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OCRError.imageNotSupported
        }
        return try await recognizeText(in: image)
    }
}
