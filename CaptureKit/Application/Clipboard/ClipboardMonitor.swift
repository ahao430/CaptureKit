import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 统一历史服务（design.md §10）：三个采集来源 → 文件存储 + 索引 + 查询/删除。
/// UI（History 窗口 / QuickAccess）只通过本服务访问数据，不直接触碰数据库与文件。
@MainActor
final class HistoryService: ObservableObject {
    let repository: ContentRepository
    let fileStore: ContentFileStore
    private let settings: SettingsStore?

    /// 数据变化时间戳（列表刷新信号）
    @Published private(set) var lastChangeAt: Date?

    private let databaseURL: URL

    init(repository: ContentRepository, fileStore: ContentFileStore, databaseURL: URL, settings: SettingsStore? = nil) {
        self.repository = repository
        self.fileStore = fileStore
        self.databaseURL = databaseURL
        self.settings = settings
    }

    /// 默认实例：Application Support/CaptureKit/Database/capturekit.sqlite。
    static func makeDefault(settings: SettingsStore? = nil) throws -> HistoryService {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("CaptureKit/Database", isDirectory: true)
        let database = try SQLiteDatabase(url: directory.appendingPathComponent("capturekit.sqlite"))
        let repository = try ContentRepository(database: database)
        return HistoryService(
            repository: repository,
            fileStore: ContentFileStore(),
            databaseURL: directory.appendingPathComponent("capturekit.sqlite"),
            settings: settings
        )
    }

    // MARK: - 记录：截图

    /// 截图（含编辑合成图导出）。
    func recordScreenshot(image: CGImage, source: String = "capture") async {
        guard let pngData = ClipboardWriter.pngData(from: image) else { return }
        let hash = ContentHasher.hash(data: pngData)

        // 去重：同一图像已存在（如编辑后再复制）→ bump
        if let existing = try? await repository.findByHashAsync(hash) {
            try? await repository.touchAsync(id: existing.id)
            bump()
            return
        }

        let storagePath = (try? fileStore.save(data: pngData, kind: .image, fileExtension: "png"))
        let thumbnailPath = (try? await generateThumbnail(pngData: pngData)) ?? storagePath
        let item = ContentItem(
            type: .screenshot,
            storagePath: storagePath,
            thumbnailPath: thumbnailPath,
            metadata: .screenshot(.init(pixelWidth: image.width, pixelHeight: image.height)),
            contentHash: hash
        )
        try? await repository.insertAsync(item)
        Log.storage.info("Screenshot recorded (\(image.width)×\(image.height))")
        bump()

        // 后台 OCR → 文字入索引可搜索（plan.md Phase 6：OCR 搜索）
        await runBackgroundOCR(item: item, image: image)
    }

    /// 图片/截图入库后异步识别文字并写入 textContent（失败静默——不影响主流程）。
    private func runBackgroundOCR(item: ContentItem, image: CGImage) async {
        guard settings?.settings.ocr.enabled ?? true else { return }
        Task.detached(priority: .utility) { [repository] in
            guard let text = try? await OCRService.recognizeText(in: image),
                  !text.isEmpty
            else { return }
            var updated = item
            updated.textContent = text
            try? await repository.updateAsync(updated)
            await MainActor.run {
                Log.storage.info("OCR indexed (\(text.count) chars)")
            }
        }
    }

    // MARK: - 记录：录制

    func recordRecording(url: URL, mode: RecordingMode, duration: Double, fps: Int) async {
        let kind: ContentFileStore.Kind = mode == .video ? .video : .gif
        // 录制产物已在 Recordings 目录；复制进 Content 统一管理
        guard let data = try? Data(contentsOf: url) else {
            Log.storage.error("Recording file unreadable, not recorded: \(url.path, privacy: .public)")
            return
        }
        let hash = ContentHasher.hash(data: data)
        if let existing = try? await repository.findByHashAsync(hash) {
            try? await repository.touchAsync(id: existing.id)
            bump()
            return
        }

        let storagePath = try? fileStore.save(data: data, kind: kind, fileExtension: mode == .video ? "mp4" : "gif")
        let thumbnailData = await ThumbnailService.videoThumbnail(videoURL: url)
        let thumbnailPath = try? thumbnailData.flatMap { try fileStore.save(data: $0, kind: .clipboard, fileExtension: "png") }

        let item = ContentItem(
            type: mode == .video ? .video : .gif,
            storagePath: storagePath,
            thumbnailPath: thumbnailPath,
            metadata: .recording(.init(mode: mode.rawValue, duration: duration, fps: fps)),
            contentHash: hash
        )
        try? await repository.insertAsync(item)
        Log.storage.info("Recording recorded (\(mode.rawValue))")
        bump()
    }

    // MARK: - 记录：剪贴板

    /// 处理一次剪贴板读取：分类 → 过滤由 Monitor 完成，这里做去重与落库。
    /// - Returns: false = 重复内容（已 bump 既有记录）。
    @discardableResult
    func recordClipboard(reading: ClipboardReading) async -> Bool {
        let classification = ClipboardClassifier.classify(reading)

        // 去重哈希
        let hash: String
        switch classification {
        case .image:
            guard let imageData = reading.imageData else { return false }
            hash = ContentHasher.hash(data: imageData)
        case .url(let url):
            hash = ContentHasher.hash(text: url.absoluteString)
        case .richText, .plainText:
            guard let text = reading.text, !text.isEmpty else { return false }
            hash = ContentHasher.hash(text: text)
        case .file(let paths):
            hash = ContentHasher.hash(text: "files:" + paths.joined(separator: "\n"))
        }

        if let existing = try? await repository.findByHashAsync(hash) {
            try? await repository.touchAsync(id: existing.id)
            Log.clipboard.debug("Duplicate clipboard content bumped")
            bump()
            return false
        }

        switch classification {
        case .image:
            guard let imageData = reading.imageData else { return false }
            let storagePath = try? fileStore.save(data: imageData, kind: .clipboard, fileExtension: "png")
            let thumbnailPath = (try? await generateThumbnail(pngData: imageData)) ?? storagePath
            let item = ContentItem(
                type: .image,
                storagePath: storagePath,
                thumbnailPath: thumbnailPath,
                metadata: .clipboard(.init(sourceBundleID: reading.sourceBundleID, representations: reading.representations)),
                contentHash: hash
            )
            try? await repository.insertAsync(item)
            // 后台 OCR：图片文字入搜索索引
            if let source = CGImageSourceCreateWithData(imageData as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                await runBackgroundOCR(item: item, image: image)
            }

        case .url(let url):
            let item = ContentItem(
                type: .url,
                textContent: url.absoluteString,
                metadata: .clipboard(.init(sourceBundleID: reading.sourceBundleID, representations: reading.representations)),
                contentHash: hash
            )
            try? await repository.insertAsync(item)

        case .richText, .plainText:
            let item = ContentItem(
                type: .text,
                textContent: reading.text,
                metadata: .clipboard(.init(sourceBundleID: reading.sourceBundleID, representations: reading.representations)),
                contentHash: hash
            )
            try? await repository.insertAsync(item)

        case .file(let paths):
            let item = ContentItem(
                type: .file,
                textContent: paths.joined(separator: "\n"),
                metadata: .clipboard(.init(sourceBundleID: reading.sourceBundleID, representations: reading.representations)),
                contentHash: hash
            )
            try? await repository.insertAsync(item)
        }

        Log.clipboard.info("Clipboard recorded (\(classification.contentType.rawValue, privacy: .public))")
        bump()
        return true
    }

    // MARK: - 查询与操作

    func items(query: ContentQuery) async -> [ContentItem] {
        (try? await repository.fetchAsync(query: query)) ?? []
    }

    func itemCount() async -> Int {
        (try? await repository.countAsync()) ?? 0
    }

    func delete(item: ContentItem) async {
        let deleted = await repository.deleteAsync(id: item.id)
        if let deleted {
            for path in [deleted.storagePath, deleted.thumbnailPath].compactMap({ $0 }) {
                fileStore.delete(relativePath: path)
            }
        }
        bump()
    }

    func setPinned(id: UUID, pinned: Bool) async {
        try? await repository.setPinnedAsync(id: id, pinned: pinned)
        bump()
    }

    /// 复制回剪贴板（恢复）。
    func copyBack(item: ContentItem) async {
        switch item.type {
        case .text, .url:
            if let text = item.textContent {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        case .image, .screenshot, .scrollingScreenshot:
            if let path = item.storagePath,
               let data = try? Data(contentsOf: fileStore.url(forRelativePath: path)),
               let image = NSImage(data: data) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
            }
        case .file:
            if let text = item.textContent {
                let urls = text.split(separator: "\n").compactMap { URL(fileURLWithPath: String($0)) }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
            }
        case .gif, .video:
            // GIF/视频恢复：写文件 URL（接收方按引用处理）
            if let path = item.storagePath {
                let url = fileStore.url(forRelativePath: path)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
            }
        }
        Log.clipboard.info("Copied back to clipboard (type \(item.type.rawValue, privacy: .public))")
    }

    /// 自动清理：超龄 + 超量（pin 不清理）。
    func autoClean(keepCount: Int, maxAgeDays: Int) async {
        var removed: [ContentItem] = []
        if maxAgeDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
            removed += (try? await repository.purgeAsync(olderThan: cutoff)) ?? []
        }
        if keepCount > 0 {
            removed += (try? await repository.enforceLimitAsync(keepCount: keepCount)) ?? []
        }
        for item in removed {
            for path in [item.storagePath, item.thumbnailPath].compactMap({ $0 }) {
                fileStore.delete(relativePath: path)
            }
        }
        if !removed.isEmpty {
            Log.storage.info("Auto-clean removed \(removed.count) item(s)")
            bump()
        }
    }

    /// 孤儿条目自愈（Phase 6 崩溃恢复）：引用文件已丢失的条目直接删除，
    /// 避免历史列表出现无法预览/恢复的死条目。pin 条目同样处理（文件已丢则无保留价值）。
    /// - Returns: 清理的条目数。
    @discardableResult
    func healOrphans() async -> Int {
        let all = await items(query: ContentQuery(category: .all, limit: 10_000))
        var removed = 0
        for item in all {
            guard let path = item.storagePath else { continue } // 纯文本无文件
            if !FileManager.default.fileExists(atPath: fileStore.url(forRelativePath: path).path) {
                await delete(item: item)
                removed += 1
            }
        }
        if removed > 0 {
            Log.storage.info("Healed \(removed) orphan item(s)")
        }
        return removed
    }

    /// 清空全部（清空历史，plan.md §2.7.4）。
    func deleteAll() async {
        let removed = (try? await repository.deleteAllAsync()) ?? []
        for item in removed {
            for path in [item.storagePath, item.thumbnailPath].compactMap({ $0 }) {
                fileStore.delete(relativePath: path)
            }
        }
        bump()
    }

    // MARK: - 私有

    private func generateThumbnail(pngData: Data) async throws -> String? {
        guard let thumbnailData = ThumbnailService.thumbnailData(from: pngData) else { return nil }
        return try fileStore.save(data: thumbnailData, kind: .clipboard, fileExtension: "png")
    }

    private func bump() {
        lastChangeAt = Date()
    }
}

/// 剪贴板监控（design.md §9.2）：changeCount 轮询，可控启停。
/// 隐私：默认不启动；用户在设置开启后才 start（plan.md §2.7.3）。
@MainActor
final class ClipboardMonitor: ObservableObject {
    private let settings: SettingsStore
    private weak var history: HistoryService?

    private var timer: Timer?
    private var lastChangeCount: Int
    /// 用户手动暂停（设置）
    @Published private(set) var isRunning = false

    init(settings: SettingsStore) {
        self.settings = settings
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func attach(history: HistoryService) {
        self.history = history
    }

    func start() {
        guard !isRunning else { return }
        lastChangeCount = NSPasteboard.general.changeCount // 启动时刻之前的内容不采集
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        isRunning = true
        Log.clipboard.info("Clipboard monitor started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        Log.clipboard.info("Clipboard monitor stopped")
    }

    func applySettings() {
        let clipboard = settings.settings.clipboard
        if clipboard.enabled {
            if !isRunning { start() }
        } else if isRunning {
            stop()
        }
    }

    private func poll() {
        guard settings.settings.clipboard.enabled,
              !settings.settings.clipboard.paused,
              history != nil
        else { return }

        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let reading = ClipboardReader.read(from: pasteboard) else { return }
        process(reading)
    }

    /// 采集处理链（design.md §9.1）：读取 → 分类 → 过滤 → 去重 → 存储。
    private func process(_ reading: ClipboardReading) {
        let clipboard = settings.settings.clipboard

        // 应用排除（近似来源）
        if let source = reading.sourceBundleID,
           clipboard.excludeApps.contains(source) {
            Log.clipboard.debug("Skipped: excluded app")
            return
        }

        // 敏感内容过滤（辅助保护，plan.md §2.7.4）
        if clipboard.sensitiveFilter, let text = reading.text {
            if SensitiveContentDetector.isSensitive(text) {
                Log.clipboard.info("Skipped: sensitive content detected")
                return
            }
        }

        // 空内容
        if reading.text == nil && reading.imageData == nil && reading.fileURLs.isEmpty {
            return
        }
        if let text = reading.text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           reading.imageData == nil, reading.fileURLs.isEmpty {
            return
        }

        Task { [weak self] in
            await self?.history?.recordClipboard(reading: reading)
        }
    }
}
