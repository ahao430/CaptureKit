import AppKit
import CoreGraphics
import Foundation

/// 剪贴板读取结果：保留可恢复的原始 representation（design.md §9.3）。
struct ClipboardReading: Equatable {
    /// 纯文本（含 URL/文件路径字符串；最小公约 representation）
    var text: String?
    /// 图像原始数据（PNG 优先，TIFF 兜底）
    var imageData: Data?
    var imageIsPNG: Bool
    /// 文件引用（多选）
    var fileURLs: [URL]
    /// 疑似来源应用（读取时刻前台应用；macOS 无直接来源 API，近似值）
    var sourceBundleID: String?
    /// 存在的 representation 类型名（记录到 metadata）
    var representations: [String]
}

/// 剪贴板读取器（design.md §9.3：多 Item、保留可恢复类型）。
enum ClipboardReader {
    /// 读取系统剪贴板（MainActor：NSPasteboard 必须主线程）。
    @MainActor
    static func read(from pasteboard: NSPasteboard = .general) -> ClipboardReading? {
        let types = Set(pasteboard.types ?? [])

        var representations: [String] = []
        var text: String?
        var imageData: Data?
        var imageIsPNG = false
        var fileURLs: [URL] = []

        // 1. 文件引用（优先级最高，design.md §9.4）
        if types.contains(.fileURL) {
            fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true,
            ]) as? [URL] ?? []
            if !fileURLs.isEmpty {
                representations.append("fileURL")
            }
        }

        // 2. 图像（PNG 无损优先，TIFF 兜底）
        if types.contains(.png) {
            imageData = pasteboard.data(forType: .png)
            imageIsPNG = true
        }
        if imageData == nil, types.contains(.tiff) {
            // TIFF → 转 PNG 保存（统一存储格式；原始 TIFF 语义在 metadata 记录）
            if let tiffData = pasteboard.data(forType: .tiff) {
                imageData = pngFromTIFF(tiffData)
                imageIsPNG = true
            }
        }
        if imageData != nil {
            representations.append("image")
        }

        // 3. 字符串（string 是纯文本/URL 的最小公约）
        if types.contains(.string) {
            text = pasteboard.string(forType: .string)
            if text != nil {
                representations.append("string")
            }
        }

        // 富文本 representation 语义保留（导出时优先 string，rft/html 标记存在）
        if types.contains(.rtf) { representations.append("rtf") }
        if types.contains(.html) { representations.append("html") }
        if types.contains(.URL) { representations.append("url") }

        guard !representations.isEmpty else { return nil }
        guard text != nil || imageData != nil || !fileURLs.isEmpty else { return nil }

        // 疑似来源（近似：读取时刻前台应用）
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        return ClipboardReading(
            text: text,
            imageData: imageData,
            imageIsPNG: imageIsPNG,
            fileURLs: fileURLs,
            sourceBundleID: source,
            representations: representations
        )
    }

    private static func pngFromTIFF(_ tiffData: Data) -> Data? {
        guard let image = NSBitmapImageRep(data: tiffData)?.cgImage else { return nil }
        return ClipboardWriter.pngData(from: image)
    }
}

/// 分类结果（design.md §9.4 优先级：文件 > 图片 > URL > 富文本 > 纯文本）。
enum ClipboardClassification: Equatable {
    case file(paths: [String])
    case image
    case url(URL)
    case richText
    case plainText

    var contentType: ContentType {
        switch self {
        case .file: return .file
        case .image: return .image
        case .url: return .url
        case .richText: return .text
        case .plainText: return .text
        }
    }
}

/// 类型分类器。
enum ClipboardClassifier {
    static func classify(_ reading: ClipboardReading) -> ClipboardClassification {
        if !reading.fileURLs.isEmpty {
            return .file(paths: reading.fileURLs.map(\.path))
        }
        if reading.imageData != nil {
            return .image
        }
        if let text = reading.text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // URL：单行且带 scheme
            if !trimmed.contains(where: { $0.isNewline }),
               let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) {
                return .url(url)
            }
            if reading.representations.contains("rtf") || reading.representations.contains("html") {
                return .richText
            }
            return .plainText
        }
        return .plainText
    }

    /// 是否为 URL 文本（供 QuickAccess 徽标）。
    static func isURLText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isNewline }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https"].contains(scheme)
    }
}

/// 敏感内容检测（design.md §9.5：辅助保护，非安全边界）。
enum SensitiveContentDetector {
    /// 检测疑似敏感内容（API Key / Token / 密码 / 高熵密钥串）。
    /// - Returns: true 表示应按策略跳过或警示。
    static func isSensitive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 10_000 else { return false }

        // 常见凭证模式
        let patterns: [(pattern: String, isRegex: Bool)] = [
            // AWS Access Key
            ("AKIA[0-9A-Z]{16}", true),
            // GitHub / 通用 token 前缀
            ("gh[pousr]_[A-Za-z0-9]{20,}", true),
            // sk- 开头（OpenAI 风格）
            ("sk-[A-Za-z0-9]{20,}", true),
            // Bearer 令牌
            ("(?i)bearer\\s+[a-z0-9._\\-]{20,}", true),
            // key/token/password = value 形式
            ("(?i)^(api[_-]?key|secret|token|password|passwd|pwd)\\s*[:=]\\s*\\S{8,}$", true),
            // 私钥头
            ("-----BEGIN [A-Z ]*PRIVATE KEY-----", true),
            // 疑似密码粘贴（密码管理器格式 "password: xxx"）
            ("(?i)password[:：]\\s*\\S{6,}", true),
        ]

        for entry in patterns {
            if entry.isRegex,
               let regex = try? NSRegularExpression(pattern: entry.pattern),
               regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return true
            }
        }

        // 高熵长串（连续 base64/hex ≥ 40 字符，单独成段）
        if isHighEntropySecret(trimmed) { return true }

        return false
    }

    /// 高熵检测：无空格、长度 ≥40、base64/hex 字符集。
    static func isHighEntropySecret(_ text: String) -> Bool {
        guard text.count >= 40, !text.contains(" ") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/-_=")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // 字符多样性：不同字符 ≥ 30% 长度
        let unique = Set(text)
        return Double(unique.count) / Double(text.count) >= 0.3
    }
}
