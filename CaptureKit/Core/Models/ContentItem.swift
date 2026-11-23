import CoreGraphics
import Foundation

/// 内容类型（plan.md §5.1）。
enum ContentType: String, Codable, CaseIterable {
    case screenshot
    case scrollingScreenshot
    case gif
    case video
    case text
    case url
    case image
    case file

    var displayName: String {
        switch self {
        case .screenshot: return "截图"
        case .scrollingScreenshot: return "长截图"
        case .gif: return "GIF"
        case .video: return "视频"
        case .text: return "文本"
        case .url: return "URL"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    /// History 左侧分类（ui-design.md §9.3）。
    enum Category: String, CaseIterable {
        case all
        case clipboard
        case screenshot
        case recording
        case pinned

        var displayName: String {
            switch self {
            case .all: return "全部"
            case .clipboard: return "剪贴板"
            case .screenshot: return "截图"
            case .recording: return "录制"
            case .pinned: return "已固定"
            }
        }

        /// 分类 → 类型集合（clipboard 分类含 text/url/image/file 剪贴板来源）。
        var includesClipboards: Bool {
            switch self {
            case .all, .clipboard, .pinned: return true
            case .screenshot, .recording: return false
            }
        }
    }
}

/// 类型化内容元数据（design.md §10.2：禁止把所有属性塞进 [String: String]）。
enum ContentMetadata: Equatable, Codable {
    case none
    case screenshot(ScreenshotMetadata)
    case recording(RecordingMetadata)
    case clipboard(ClipboardMetadata)

    struct ScreenshotMetadata: Equatable, Codable {
        var pixelWidth: Int
        var pixelHeight: Int
    }

    struct RecordingMetadata: Equatable, Codable {
        var mode: String  // "video" / "gif"
        var duration: Double
        var fps: Int
    }

    struct ClipboardMetadata: Equatable, Codable {
        /// 疑似来源应用 bundleID（读取时刻前台应用，近似值）
        var sourceBundleID: String?
        /// 原始 representation 类型（png/tiff/string/fileURL/rtf/html）
        var representations: [String]
    }
}

/// 统一内容条目（plan.md §5.1）。
struct ContentItem: Identifiable, Codable, Equatable {
    let id: UUID
    var type: ContentType
    var createdAt: Date
    var updatedAt: Date
    /// 相对 Content 目录的路径（nil = 纯文本等无文件内容）
    var storagePath: String?
    var thumbnailPath: String?
    /// 文本/URL 内容（检索用）
    var textContent: String?
    var metadata: ContentMetadata
    var isPinned: Bool
    /// 内容哈希（去重；plan.md §2.8）
    var contentHash: String?

    init(id: UUID = UUID(),
         type: ContentType,
         createdAt: Date = Date(),
         updatedAt: Date? = nil,
         storagePath: String? = nil,
         thumbnailPath: String? = nil,
         textContent: String? = nil,
         metadata: ContentMetadata = .none,
         isPinned: Bool = false,
         contentHash: String? = nil) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.storagePath = storagePath
        self.thumbnailPath = thumbnailPath
        self.textContent = textContent
        self.metadata = metadata
        self.isPinned = isPinned
        self.contentHash = contentHash
    }
}

/// 内容查询（design.md §10.4）。
struct ContentQuery {
    var category: ContentType.Category = .all
    /// 全文搜索（textContent LIKE）
    var searchText: String = ""
    var limit: Int = 200
    var offset: Int = 0

    init(category: ContentType.Category = .all, searchText: String = "", limit: Int = 200, offset: Int = 0) {
        self.category = category
        self.searchText = searchText
        self.limit = limit
        self.offset = offset
    }
}
