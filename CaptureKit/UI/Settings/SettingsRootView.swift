import SwiftUI

/// 历史服务环境注入（设置窗口的存储页使用；可能为 nil——数据库初始化失败降级）。
private struct HistoryServiceKey: EnvironmentKey {
    static let defaultValue: HistoryService? = nil
}

extension EnvironmentValues {
    var historyService: HistoryService? {
        get { self[HistoryServiceKey.self] }
        set { self[HistoryServiceKey.self] = newValue }
    }
}

/// 更新协调器环境注入（更新页使用；测试环境为 nil）。
private struct UpdateCoordinatorKey: EnvironmentKey {
    static let defaultValue: UpdateCoordinator? = nil
}

extension EnvironmentValues {
    var updateCoordinator: UpdateCoordinator? {
        get { self[UpdateCoordinatorKey.self] }
        set { self[UpdateCoordinatorKey.self] = newValue }
    }
}

/// 设置根视图（SwiftUI，ui-design.md §11；通用/截图/录制/剪贴板/存储/快捷键/更新）。
struct SettingsRootView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var launchAtLogin: Bool = LaunchAtLoginService.isEnabled

    var body: some View {
        TabView {
            GeneralSettingsView(launchAtLogin: $launchAtLogin)
                .tabItem { Label("通用", systemImage: "gearshape") }
            CaptureSettingsView()
                .tabItem { Label("截图", systemImage: "camera.viewfinder") }
            RecordingSettingsView()
                .tabItem { Label("录制", systemImage: "record.circle") }
            ClipboardSettingsView()
                .tabItem { Label("剪贴板", systemImage: "doc.on.doc") }
            StorageSettingsView()
                .tabItem { Label("存储", systemImage: "internaldrive") }
            HotkeySettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            UpdateSettingsView()
                .tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @Binding var launchAtLogin: Bool

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLoginService.setEnabled(newValue)
                    }
                Toggle("在 Dock 中显示图标", isOn: Binding(
                    get: { store.settings.general.showDockIcon },
                    set: { newValue in
                        store.update { $0.general.showDockIcon = newValue }
                        AppDockIconService.apply(showDockIcon: newValue)
                    }
                ))
            } header: {
                Text("启动")
            } footer: {
                Text("关闭 Dock 图标时，CaptureKit 仅驻留菜单栏。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("图片文字识别（OCR）", isOn: Binding(
                    get: { store.settings.ocr.enabled },
                    set: { newValue in store.update { $0.ocr.enabled = newValue } }
                ))
            } header: {
                Text("文字识别")
            } footer: {
                Text("截图与剪贴板图片入库后，在本地（Vision）识别文字写入搜索索引，可在历史中搜索图片里的文字。不会上传任何内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct CaptureSettingsView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("截图后自动复制到剪贴板", isOn: Binding(
                    get: { store.settings.capture.autoCopyToClipboard },
                    set: { newValue in store.update { $0.capture.autoCopyToClipboard = newValue } }
                ))
                Toggle("捕获时排除 CaptureKit 自身窗口", isOn: Binding(
                    get: { store.settings.capture.excludeOwnWindows },
                    set: { newValue in store.update { $0.capture.excludeOwnWindows = newValue } }
                ))
            } header: {
                Text("截图")
            }

            Section {
                Toggle("截图后自动进入编辑器", isOn: Binding(
                    get: { store.settings.editor.autoOpenEditor },
                    set: { newValue in store.update { $0.editor.autoOpenEditor = newValue } }
                ))
            } header: {
                Text("编辑器")
            } footer: {
                Text("关闭后截图直接复制到剪贴板（可配合下方自动复制）。也可在选区工具栏点「编辑」手动进入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("滚动截图自动滚动", isOn: Binding(
                    get: { store.settings.capture.scrollAutoScroll },
                    set: { newValue in store.update { $0.capture.scrollAutoScroll = newValue } }
                ))
            } header: {
                Text("滚动截图")
            } footer: {
                Text("开启后自动滚动页面并到底自动完成，需要「辅助功能」权限（首次使用时引导授权）；关闭或未授权时手动滚动。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(
                    "延时截图秒数：\(store.settings.capture.delaySeconds) 秒",
                    value: Binding(
                        get: { store.settings.capture.delaySeconds },
                        set: { newValue in store.update { $0.capture.delaySeconds = min(10, max(1, newValue)) } }
                    ),
                    in: 1...10
                )
            } header: {
                Text("延时截图")
            } footer: {
                Text("延时结束后自动进入区域截图，期间可在倒计时面板取消。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct RecordingSettingsView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Stepper(
                    "帧率：\(store.settings.recording.fps) FPS",
                    value: Binding(
                        get: { store.settings.recording.fps },
                        set: { newValue in store.update { $0.recording.fps = min(60, max(5, newValue)) } }
                    ),
                    in: 5...60,
                    step: 5
                )
                Toggle("录制鼠标指针", isOn: Binding(
                    get: { store.settings.recording.showsCursor },
                    set: { newValue in store.update { $0.recording.showsCursor = newValue } }
                ))
                Toggle("录制后自动打开预览编辑器", isOn: Binding(
                    get: { store.settings.recording.autoOpenEditor },
                    set: { newValue in store.update { $0.recording.autoOpenEditor = newValue } }
                ))
                Toggle("录制系统音频", isOn: Binding(
                    get: { store.settings.recording.audioEnabled },
                    set: { newValue in store.update { $0.recording.audioEnabled = newValue } }
                ))
                Toggle("录制麦克风", isOn: Binding(
                    get: { store.settings.recording.microphoneEnabled },
                    set: { newValue in store.update { $0.recording.microphoneEnabled = newValue } }
                ))
                Toggle("鼠标点击高亮效果", isOn: Binding(
                    get: { store.settings.recording.clickEffects },
                    set: { newValue in store.update { $0.recording.clickEffects = newValue } }
                ))
            } header: {
                Text("视频")
            } footer: {
                Text("建议 15–30 FPS。帧率越高文件越大。系统音频仅视频生效（GIF 无音轨）；系统音频不含 CaptureKit 自身的声音。麦克风需 macOS 15+，首次录制请求授权，拒绝后以无麦克风继续。点击效果仅视频生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("GIF 最大宽度", selection: Binding(
                    get: { store.settings.recording.gifMaxPixelWidth },
                    set: { newValue in store.update { $0.recording.gifMaxPixelWidth = newValue } }
                )) {
                    ForEach([480, 720, 1080], id: \.self) { width in
                        Text("\(width)px").tag(width)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("GIF")
            } footer: {
                Text("GIF 帧率与视频共用上方设置；小尺寸可显著减小文件体积。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("录制保存位置") {
                    Text("~/Library/Application Support/CaptureKit/Recordings")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("存储")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// 剪贴板隐私设置（ui-design.md §11.3；默认关闭，plan.md §2.7.3）。
private struct ClipboardSettingsView: View {
    @EnvironmentObject var store: SettingsStore

    @State private var excludeAppsText: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("启用剪贴板历史记录", isOn: Binding(
                    get: { store.settings.clipboard.enabled },
                    set: { newValue in store.update { $0.clipboard.enabled = newValue } }
                ))
                Toggle("暂停监听", isOn: Binding(
                    get: { store.settings.clipboard.paused },
                    set: { newValue in store.update { $0.clipboard.paused = newValue } }
                ))
                .disabled(!store.settings.clipboard.enabled)
            } header: {
                Text("剪贴板")
            } footer: {
                Text("开启后，CaptureKit 会在本地保存你复制的内容（文本/图片/URL/文件引用）。所有数据仅存储在本机，不会上传。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("敏感内容过滤（辅助保护）", isOn: Binding(
                    get: { store.settings.clipboard.sensitiveFilter },
                    set: { newValue in store.update { $0.clipboard.sensitiveFilter = newValue } }
                ))
                TextField("排除应用 bundleID（逗号分隔）", text: $excludeAppsText)
                    .font(.system(size: 12, design: .monospaced))
                    .onAppear {
                        excludeAppsText = store.settings.clipboard.excludeApps.joined(separator: ", ")
                    }
                    .onSubmit {
                        let apps = excludeAppsText
                            .split(whereSeparator: { $0 == "," || $0.isNewline })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        store.update { $0.clipboard.excludeApps = apps }
                    }
            } header: {
                Text("隐私")
            } footer: {
                Text("敏感内容过滤会跳过疑似 API Key / Token / 密码的内容，但不能保证识别所有敏感信息。排除应用按读取时刻的前台应用近似判断。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(
                    "保留数量上限：\(store.settings.clipboard.keepCount == 0 ? "不限" : "\(store.settings.clipboard.keepCount) 条")",
                    value: Binding(
                        get: { store.settings.clipboard.keepCount },
                        set: { newValue in store.update { $0.clipboard.keepCount = max(0, newValue) } }
                    ),
                    in: 0...5000,
                    step: 50
                )
                Stepper(
                    "自动清理：\(store.settings.clipboard.autoCleanDays == 0 ? "关闭" : "\(store.settings.clipboard.autoCleanDays) 天")",
                    value: Binding(
                        get: { store.settings.clipboard.autoCleanDays },
                        set: { newValue in store.update { $0.clipboard.autoCleanDays = max(0, newValue) } }
                    ),
                    in: 0...365,
                    step: 5
                )
            } header: {
                Text("清理")
            } footer: {
                Text("固定（Pin）的内容不会被自动清理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("退出时清空全部历史", isOn: Binding(
                    get: { store.settings.clipboard.clearOnQuit },
                    set: { newValue in store.update { $0.clipboard.clearOnQuit = newValue } }
                ))
            } header: {
                Text("退出")
            } footer: {
                Text("开启后每次退出 CaptureKit 会删除全部历史内容（含截图与录制，固定内容同样删除）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// 存储设置（ui-design.md §11.3：存储路径/已使用空间/清理）。
private struct StorageSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var contentSize: Int64 = 0
    @State private var databaseSize: Int64 = 0
    @State private var itemCount: Int = 0
    @State private var isRefreshing = false

    /// 注入的历史服务（由 SettingsWindowController 传入环境）。
    @Environment(\.historyService) private var history

    var body: some View {
        Form {
            Section {
                LabeledContent("内容存储") {
                    Text(StorageFormat.bytes(contentSize))
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("索引数据库") {
                    Text(StorageFormat.bytes(databaseSize))
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("内容条目") {
                    Text("\(itemCount) 条")
                }
                Button("刷新") {
                    Task { await refresh() }
                }
                Button("打开存储目录") {
                    openDirectory()
                }
            } header: {
                Text("已使用空间")
            } footer: {
                Text("路径：~/Library/Application Support/CaptureKit/")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                Button("清空全部历史", role: .destructive) {
                    confirmClear()
                }
            } footer: {
                Text("删除全部内容条目与关联文件（含截图与录制），不可恢复。固定内容同样会被删除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { Task { await refresh() } }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = base.appendingPathComponent("CaptureKit", isDirectory: true)
        contentSize = Self.directorySize(root.appendingPathComponent("Content"))
        let dbURL = root.appendingPathComponent("Database/capturekit.sqlite")
        var dbSize: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            dbSize += (try? FileManager.default.attributesOfItem(atPath: dbURL.path + suffix)[.size] as? Int64) ?? 0
        }
        databaseSize = dbSize
        if let history {
            itemCount = await history.itemCount()
        }
    }

    private func openDirectory() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("CaptureKit", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    private func confirmClear() {
        guard let history else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清空全部历史？"
        alert.informativeText = "将删除 \(itemCount) 条内容及其关联文件，不可恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await history.deleteAll()
                await refresh()
            }
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               size.isRegularFile == true {
                total += Int64(size.fileSize ?? 0)
            }
        }
        return total
    }
}

enum StorageFormat {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

/// 更新设置（发布策略：Sparkle + GitHub Releases；默认自动检查，安装由用户确认）。
private struct UpdateSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @Environment(\.updateCoordinator) private var updater

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本") {
                    Text(UpdateCoordinator.currentVersion)
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("自动检查更新", isOn: Binding(
                    get: { store.settings.update.autoCheck },
                    set: { newValue in store.update { $0.update.autoCheck = newValue } }
                ))
                Button("立即检查…") {
                    updater?.checkForUpdates()
                }
                .disabled(updater == nil)
            } header: {
                Text("软件更新")
            } footer: {
                Text("每 24 小时通过 GitHub Releases 检查一次新版本；发现更新时展示版本说明，由你确认后下载安装并重启。更新包经 EdDSA 签名验证。关闭后仍可手动检查。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct HotkeySettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var conflictMessage: String?

    var body: some View {
        Form {
            Section {
                HotkeyRow(title: HotkeyAction.regionCapture.displayName,
                          descriptor: store.settings.hotkeys.regionCapture) { recorded in
                    store.update { $0.hotkeys.regionCapture = recorded }
                }
                HotkeyRow(title: HotkeyAction.recordRegion.displayName,
                          descriptor: store.settings.hotkeys.recordRegion) { recorded in
                    store.update { $0.hotkeys.recordRegion = recorded }
                }
                HotkeyRow(title: HotkeyAction.history.displayName,
                          descriptor: store.settings.hotkeys.history) { recorded in
                    store.update { $0.hotkeys.history = recorded }
                }
                HotkeyRow(title: HotkeyAction.quickAccess.displayName,
                          descriptor: store.settings.hotkeys.quickAccess) { recorded in
                    store.update { $0.hotkeys.quickAccess = recorded }
                }
            } header: {
                Text("全局快捷键")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let conflictMessage {
                        Label(conflictMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("点击右侧快捷键进行录制（须包含修饰键，Esc 取消）。修改后立即生效。")
                    HStack {
                        Button("恢复默认") {
                            store.resetHotkeysToDefault()
                        }
                        Spacer()
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { checkConflicts() }
        .onChange(of: store.settings.hotkeys) { checkConflicts() }
    }

    private func checkConflicts() {
        let conflicts = HotkeyConflictChecker.conflicts(in: store.settings.hotkeys.mapping)
        if conflicts.isEmpty {
            conflictMessage = nil
        } else {
            let names = conflicts.map(\.0.displayName).joined(separator: "、")
            conflictMessage = "快捷键冲突：\(names)，请修改其中之一"
        }
    }
}
