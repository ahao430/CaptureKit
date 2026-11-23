import AppKit
import Foundation

/// 异步缩略图加载 + 内存缓存（plan.md §11 性能：缩略图异步生成、历史列表按需加载）。
/// 列表滚动不再在主线程同步解码 PNG。
@MainActor
final class ThumbnailStore {
    private let cache = NSCache<NSString, NSImage>()
    private let fileStore: ContentFileStore

    init(fileStore: ContentFileStore, countLimit: Int = 300) {
        self.fileStore = fileStore
        cache.countLimit = countLimit
    }

    /// 取条目缩略图：命中缓存直接返回；未命中后台解码后入缓存。
    func image(for item: ContentItem) async -> NSImage? {
        guard let path = item.thumbnailPath else { return nil }
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        let url = fileStore.url(forRelativePath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoded = await Task.detached(priority: .utility) {
            NSImage(data: data)
        }.value
        if let decoded {
            cache.setObject(decoded, forKey: path as NSString)
        }
        return decoded
    }

    /// 测试辅助：清空缓存。
    func clearForTesting() {
        cache.removeAllObjects()
    }
}
