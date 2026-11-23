import AppKit
import SwiftUI

/// History 视图模型（design.md §10：UI 只通过 HistoryService 访问数据）。
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var category: ContentType.Category = .all {
        didSet { Task { await reload() } }
    }
    @Published var searchText: String = "" {
        didSet { scheduleSearchReload() }
    }
    @Published private(set) var items: [ContentItem] = []
    @Published private(set) var isLoading = false

    private let history: HistoryService
    let thumbnails: ThumbnailStore
    private var searchDebounce: Task<Void, Never>?
    private var changeCancellable: Any?

    init(history: HistoryService) {
        self.history = history
        self.thumbnails = ThumbnailStore(fileStore: history.fileStore)
        // 数据变化自动刷新
        changeCancellable = history.$lastChangeAt.sink { [weak self] _ in
            Task { await self?.reload() }
        }
        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        items = await history.items(query: ContentQuery(
            category: category,
            searchText: searchText
        ))
    }

    private func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: - 操作

    func copy(_ item: ContentItem) {
        Task { await history.copyBack(item: item) }
    }

    func togglePin(_ item: ContentItem) {
        Task { await history.setPinned(id: item.id, pinned: !item.isPinned) }
    }

    func delete(_ item: ContentItem) {
        Task { await history.delete(item: item) }
    }

    func revealInFinder(_ item: ContentItem) {
        guard let path = item.storagePath else { return }
        let url = history.fileStore.url(forRelativePath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 异步缩略图（内存缓存；列表滚动不在主线程解码）。
    func thumbnail(for item: ContentItem) async -> NSImage? {
        await thumbnails.image(for: item)
    }
}

/// History 窗口（ui-design.md §9）：左侧分类导航 + 搜索 + 列表/网格切换 + 批量删除。
struct HistoryView: View {
    @EnvironmentObject var viewModel: HistoryViewModel
    @State private var viewMode: ViewMode = .list
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var confirmBatchDelete = false

    enum ViewMode {
        case list, grid

        var toggleIcon: String {
            self == .list ? "square.grid.2x2" : "list.bullet"
        }

        var next: ViewMode { self == .list ? .grid : .list }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(ContentType.Category.allCases, id: \.rawValue) { category in
                    Button {
                        viewModel.category = category
                    } label: {
                        Label(category.displayName, systemImage: category.iconName)
                            .foregroundStyle(viewModel.category == category ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160)

            contentPane
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("CaptureKit 历史")
    }

    private var contentPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if viewModel.items.isEmpty {
                emptyState
            } else {
                switch viewMode {
                case .list: itemList
                case .grid: itemGrid
                }
            }
            if selectionMode {
                batchBar
            }
        }
    }

    /// 批量操作条（Phase 6：批量删除）。
    private var batchBar: some View {
        HStack(spacing: 12) {
            Text("已选 \(selectedIDs.count) 项")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("全选") {
                selectedIDs = Set(viewModel.items.map(\.id))
            }
            .disabled(viewModel.items.isEmpty)
            Spacer()
            Button("删除所选", role: .destructive) {
                confirmBatchDelete = true
            }
            .disabled(selectedIDs.isEmpty)
            Button("完成") {
                selectionMode = false
                selectedIDs.removeAll()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog("删除 \(selectedIDs.count) 项？", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("删除（不可恢复）", role: .destructive) {
                let targets = viewModel.items.filter { selectedIDs.contains($0.id) }
                selectedIDs.removeAll()
                Task {
                    for item in targets {
                        viewModel.delete(item)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("关联文件将同时被删除。")
        }
    }

    /// 行选中态（选择模式）。
    private func toggleSelection(_ item: ContentItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文本与 URL…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { viewMode = viewMode.next }
            } label: {
                Image(systemName: viewMode.toggleIcon)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(viewMode == .list ? "切换到网格视图" : "切换到列表视图")

            Button {
                selectionMode.toggle()
                if !selectionMode { selectedIDs.removeAll() }
            } label: {
                Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(selectionMode ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(selectionMode ? "退出选择模式" : "进入选择模式（批量删除）")
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var itemList: some View {
        List(viewModel.items) { item in
            HistoryRow(item: item, selected: selectionMode && selectedIDs.contains(item.id))
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectionMode {
                        toggleSelection(item)
                    }
                }
                .contextMenu { contextMenu(item) }
        }
        .listStyle(.inset)
    }

    /// 网格视图（ui-design.md §9.4：默认网格可选——本实现列表默认，网格切换）。
    private var itemGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(viewModel.items) { item in
                    HistoryGridCard(item: item, selected: selectionMode && selectedIDs.contains(item.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectionMode {
                                toggleSelection(item)
                            } else {
                                viewModel.copy(item)
                            }
                        }
                        .contextMenu { contextMenu(item) }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func contextMenu(_ item: ContentItem) -> some View {
        Button("复制") { viewModel.copy(item) }
        Button(item.isPinned ? "取消固定" : "固定") { viewModel.togglePin(item) }
        if item.storagePath != nil {
            Button("在 Finder 中显示") { viewModel.revealInFinder(item) }
        }
        Divider()
        Button("删除", role: .destructive) { viewModel.delete(item) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(viewModel.searchText.isEmpty ? "暂无内容" : "没有匹配的结果")
                .font(.system(size: 15, weight: .medium))
            Text(viewModel.searchText.isEmpty
                 ? "截图、录制或复制内容后会显示在这里"
                 : "尝试其它关键词或切换分类")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 网格卡片（ui-design.md §9.5）。
private struct HistoryGridCard: View {
    @EnvironmentObject var viewModel: HistoryViewModel
    let item: ContentItem
    var selected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncThumbnailView(item: item, cornerRadius: 6)
                .frame(height: 96)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.18))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            .overlay(alignment: .topLeading) {
                if item.isPinned {
                    Image(systemName: "pin.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(4)
                }
            }

            Text(item.type.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(item.type.badgeColor)
            Text(cardSummary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    private var cardSummary: String {
        switch item.type {
        case .text, .url: return item.textContent ?? ""
        case .file: return (item.textContent ?? "").split(separator: "\n").prefix(1).joined()
        case .screenshot, .scrollingScreenshot: return HistoryRow.relativeTimeString(item.createdAt)
        case .image: return HistoryRow.relativeTimeString(item.createdAt)
        case .gif, .video: return HistoryRow.relativeTimeString(item.createdAt)
        }
    }
}

/// 单行内容（ui-design.md §9.5 内容卡片：缩略图/摘要 + 类型 + 时间）。
private struct HistoryRow: View {
    @EnvironmentObject var viewModel: HistoryViewModel
    let item: ContentItem
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            AsyncThumbnailView(item: item)
                .frame(width: 52, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    badge
                    Text(relativeTime)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let source = sourceApp {
                        Text(source)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.1) : .clear)
        )
    }

    private var badge: some View {
        Text(item.type.displayName)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(item.type.badgeColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(item.type.badgeColor)
    }

    private var summary: String {
        switch item.type {
        case .text, .url:
            return item.textContent ?? ""
        case .file:
            return (item.textContent ?? "")
                .split(separator: "\n")
                .compactMap { ($0 as NSString).lastPathComponent.isEmpty ? nil : ($0 as NSString).lastPathComponent }
                .prefix(3)
                .joined(separator: "、")
        case .screenshot, .scrollingScreenshot:
            if case .screenshot(let meta) = item.metadata {
                return "\(meta.pixelWidth) × \(meta.pixelHeight)"
            }
            return "截图"
        case .gif, .video:
            if case .recording(let meta) = item.metadata {
                let duration = Int(meta.duration)
                return "\(duration / 60)m \(duration % 60)s · \(meta.fps)fps"
            }
            return item.type.displayName
        case .image:
            return "图片"
        }
    }

    private var sourceApp: String? {
        if case .clipboard(let meta) = item.metadata {
            return meta.sourceBundleID?.components(separatedBy: ".").last
        }
        return nil
    }

    private var relativeTime: String {
        Self.relativeTimeString(item.createdAt)
    }

    static func relativeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 86_400 * 7 { return "\(Int(interval / 86_400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension ContentType.Category {
    var iconName: String {
        switch self {
        case .all: return "tray.2"
        case .clipboard: return "doc.on.doc"
        case .screenshot: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .pinned: return "pin"
        }
    }
}

extension ContentType {
    var iconName: String {
        switch self {
        case .screenshot, .scrollingScreenshot: return "photo"
        case .gif: return "gift"
        case .video: return "video"
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var badgeColor: Color {
        switch self {
        case .screenshot, .scrollingScreenshot, .image: return .blue
        case .gif: return .orange
        case .video: return .purple
        case .text: return .gray
        case .url: return .teal
        case .file: return .indigo
        }
    }
}

/// History 窗口控制器。
@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let history: HistoryService
    private var viewModel: HistoryViewModel?

    init(history: HistoryService) {
        self.history = history
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = HistoryViewModel(history: history)
        self.viewModel = viewModel

        let hosting = NSHostingController(rootView: AnyView(HistoryView().environmentObject(viewModel)))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CaptureKit 历史"
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 860, height: 560))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HistoryWindow")
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
