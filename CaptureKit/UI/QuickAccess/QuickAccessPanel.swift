import AppKit
import SwiftUI

/// QuickAccess 视图模型（ui-design.md §10：快速，不承担完整管理职责）。
@MainActor
final class QuickAccessViewModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet { scheduleReload() }
    }
    @Published private(set) var items: [ContentItem] = []
    @Published var selectedIndex: Int = 0

    private let history: HistoryService
    let thumbnails: ThumbnailStore
    private var reloadTask: Task<Void, Never>?

    /// 一次会话的条目快照（面板打开时加载，避免与 History 窗口实时联动跳动）。
    init(history: HistoryService) {
        self.history = history
        self.thumbnails = ThumbnailStore(fileStore: history.fileStore)
    }

    func reload() async {
        let query = ContentQuery(category: .all, searchText: searchText, limit: 30)
        let loaded = await history.items(query: query)
        items = loaded
        if selectedIndex >= loaded.count { selectedIndex = 0 }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: - 键盘导航

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), items.count - 1)
    }

    /// Enter：复制并回调关闭。
    func confirmSelection() -> ContentItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func copy(_ item: ContentItem, completion: @escaping () -> Void) {
        Task {
            await history.copyBack(item: item)
            completion()
        }
    }

    func thumbnail(for item: ContentItem) async -> NSImage? {
        await thumbnails.image(for: item)
    }
}

/// QuickAccess 面板内容（ui-design.md §10.2/10.3）。
struct QuickAccessView: View {
    @EnvironmentObject var viewModel: QuickAccessViewModel
    let onConfirm: (ContentItem) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if viewModel.items.isEmpty {
                emptyState
            } else {
                list
            }
            footer
        }
        .frame(width: 420, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true }
        .onKeyPress(.downArrow) { viewModel.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { viewModel.moveSelection(-1); return .handled }
        .onKeyPress(.return) {
            if let item = viewModel.confirmSelection() {
                onConfirm(item)
            }
            return .handled
        }
        .onKeyPress(.escape) { QuickAccessPanelController.shared.dismiss(); return .handled }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索最近复制的内容…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 14))
            Text("⇧⌘V")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.items.indices, id: \.self) { index in
                        row(for: index)
                            .id(index)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: viewModel.selectedIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onChange(of: viewModel.items.count) { _, _ in
                proxy.scrollTo(0, anchor: .top)
            }
        }
    }

    private func row(for index: Int) -> some View {
        let item = viewModel.items[index]
        return QuickAccessRow(item: item, isSelected: index == viewModel.selectedIndex)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                viewModel.selectedIndex = index
                onConfirm(item)
            }
            .onTapGesture(count: 1) {
                viewModel.selectedIndex = index
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(viewModel.searchText.isEmpty ? "暂无内容" : "没有匹配的结果")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("⏎ 复制选中 · ↑↓ 选择 · ⎋ 关闭")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

/// 单行（类型图标 + 摘要 + 时间 + Pin）。
private struct QuickAccessRow: View {
    @EnvironmentObject var viewModel: QuickAccessViewModel
    let item: ContentItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            AsyncThumbnailView(item: item)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(item.type.displayName) · \(Self.relativeTime(item.createdAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
    }

    private var summary: String {
        switch item.type {
        case .text, .url:
            return item.textContent ?? ""
        case .file:
            return (item.textContent ?? "").split(separator: "\n").prefix(1).joined()
        case .screenshot, .scrollingScreenshot, .image:
            return "图片"
        case .gif, .video:
            return item.type.displayName
        }
    }

    static func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86_400)) 天前"
    }
}

/// QuickAccess 面板控制器（ui-design.md §10.4：屏幕中央附近，失焦关闭）。
@MainActor
final class QuickAccessPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickAccessPanelController()

    private var panel: NSPanel?
    private weak var historyService: HistoryService?

    func attach(history: HistoryService) {
        historyService = history
    }

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    private func show() {
        guard let historyService else { return }

        if panel == nil {
            let viewModel = QuickAccessViewModel(history: historyService)
            let view = QuickAccessView { [weak self] item in
                viewModel.copy(item) {
                    self?.dismiss()
                }
            }
            .environmentObject(viewModel)

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "快速剪贴板"
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentViewController = NSHostingController(rootView: AnyView(view))
            self.panel = panel
            self.viewModel = viewModel
        }

        // 每次打开重新加载
        if let viewModel {
            Task { await viewModel.reload() }
        }
        positionCenter()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private var viewModel: QuickAccessViewModel?

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func positionCenter() {
        guard let panel else { return }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2 + visible.height * 0.1
        ))
    }

    // MARK: - NSWindowDelegate（失焦关闭）

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            dismiss()
        }
    }
}
