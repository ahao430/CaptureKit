import Combine
import Foundation

/// 应用配置（design.md §12.1）。
/// 第一版只包含已实现功能对应的配置项，随 Phase 推进逐步扩展。
struct AppSettings: Codable, Equatable {
    var general: GeneralSettings
    var capture: CaptureSettings
    var editor: EditorSettings
    var recording: RecordingSettingsBox
    var clipboard: ClipboardSettingsBox
    var ocr: OCRSettingsBox
    var hotkeys: HotkeySettings
    var update: UpdateSettingsBox

    struct EditorSettings: Codable, Equatable {
        /// 截图完成后自动进入编辑器（plan.md §2.4，默认开）
        var autoOpenEditor: Bool

        static let `default` = EditorSettings(autoOpenEditor: true)

        enum CodingKeys: String, CodingKey {
            case autoOpenEditor
        }

        init(autoOpenEditor: Bool) {
            self.autoOpenEditor = autoOpenEditor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autoOpenEditor = try container.decodeIfPresent(Bool.self, forKey: .autoOpenEditor) ?? true
        }
    }

    struct GeneralSettings: Codable, Equatable {
        /// 登录时启动
        var launchAtLogin: Bool
        /// 在 Dock 显示图标（false = 纯菜单栏应用）
        var showDockIcon: Bool

        static let `default` = GeneralSettings(launchAtLogin: false, showDockIcon: false)

        enum CodingKeys: String, CodingKey {
            case launchAtLogin, showDockIcon
        }

        init(launchAtLogin: Bool, showDockIcon: Bool) {
            self.launchAtLogin = launchAtLogin
            self.showDockIcon = showDockIcon
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
            showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        }
    }

    struct CaptureSettings: Codable, Equatable {
        /// 截图完成后自动复制到剪贴板
        var autoCopyToClipboard: Bool
        /// 截图时排除 CaptureKit 自身窗口
        var excludeOwnWindows: Bool
        /// 延时截图秒数（1–10）
        var delaySeconds: Int
        /// 滚动截图自动滚动（需辅助功能权限；未授权降级手动）
        var scrollAutoScroll: Bool

        static let `default` = CaptureSettings(autoCopyToClipboard: true, excludeOwnWindows: true, delaySeconds: 3, scrollAutoScroll: true)

        enum CodingKeys: String, CodingKey {
            case autoCopyToClipboard, excludeOwnWindows, delaySeconds, scrollAutoScroll
        }

        init(autoCopyToClipboard: Bool, excludeOwnWindows: Bool, delaySeconds: Int, scrollAutoScroll: Bool = true) {
            self.autoCopyToClipboard = autoCopyToClipboard
            self.excludeOwnWindows = excludeOwnWindows
            self.delaySeconds = delaySeconds
            self.scrollAutoScroll = scrollAutoScroll
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autoCopyToClipboard = try container.decodeIfPresent(Bool.self, forKey: .autoCopyToClipboard) ?? true
            excludeOwnWindows = try container.decodeIfPresent(Bool.self, forKey: .excludeOwnWindows) ?? true
            delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 3
            scrollAutoScroll = try container.decodeIfPresent(Bool.self, forKey: .scrollAutoScroll) ?? true
        }
    }

    struct HotkeySettings: Codable, Equatable {
        var regionCapture: HotkeyDescriptor
        var recordRegion: HotkeyDescriptor
        var history: HotkeyDescriptor
        var quickAccess: HotkeyDescriptor

        var mapping: [HotkeyAction: HotkeyDescriptor] {
            [
                .regionCapture: regionCapture,
                .recordRegion: recordRegion,
                .history: history,
                .quickAccess: quickAccess,
            ]
        }

        static let `default` = HotkeySettings(
            regionCapture: .regionCapture(),
            recordRegion: .recordRegion(),
            history: .history(),
            quickAccess: .quickAccess()
        )

        init(regionCapture: HotkeyDescriptor, recordRegion: HotkeyDescriptor,
             history: HotkeyDescriptor, quickAccess: HotkeyDescriptor) {
            self.regionCapture = regionCapture
            self.recordRegion = recordRegion
            self.history = history
            self.quickAccess = quickAccess
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            regionCapture = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .regionCapture) ?? .regionCapture()
            recordRegion = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .recordRegion) ?? .recordRegion()
            history = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .history) ?? .history()
            quickAccess = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .quickAccess) ?? .quickAccess()
        }

        static func == (lhs: HotkeySettings, rhs: HotkeySettings) -> Bool {
            lhs.regionCapture == rhs.regionCapture
                && lhs.recordRegion == rhs.recordRegion
                && lhs.history == rhs.history
                && lhs.quickAccess == rhs.quickAccess
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(regionCapture, forKey: .regionCapture)
            try container.encode(recordRegion, forKey: .recordRegion)
            try container.encode(history, forKey: .history)
            try container.encode(quickAccess, forKey: .quickAccess)
        }

        private enum CodingKeys: String, CodingKey {
            case regionCapture, recordRegion, history, quickAccess
        }
    }

    struct RecordingSettingsBox: Codable, Equatable {
        var fps: Int
        var gifMaxPixelWidth: Int
        var showsCursor: Bool
        /// 录制完成后自动打开预览编辑器（plan.md §2.6.6）
        var autoOpenEditor: Bool
        /// 捕获系统音频（plan.md §2.6.5；默认关闭避免意外录入）
        var audioEnabled: Bool
        /// 鼠标点击高亮效果（plan.md §2.6.5；默认关）
        var clickEffects: Bool
        /// 采集麦克风（Phase 6；默认关，需 TCC 麦克风授权）
        var microphoneEnabled: Bool

        static let `default` = RecordingSettingsBox(
            fps: 30, gifMaxPixelWidth: 720, showsCursor: true,
            autoOpenEditor: true, audioEnabled: false, clickEffects: false, microphoneEnabled: false
        )

        enum CodingKeys: String, CodingKey {
            case fps, gifMaxPixelWidth, showsCursor, autoOpenEditor, audioEnabled, clickEffects, microphoneEnabled
        }

        init(fps: Int, gifMaxPixelWidth: Int = 720, showsCursor: Bool = true,
             autoOpenEditor: Bool = true, audioEnabled: Bool = false, clickEffects: Bool = false,
             microphoneEnabled: Bool = false) {
            self.fps = fps
            self.gifMaxPixelWidth = gifMaxPixelWidth
            self.showsCursor = showsCursor
            self.autoOpenEditor = autoOpenEditor
            self.audioEnabled = audioEnabled
            self.clickEffects = clickEffects
            self.microphoneEnabled = microphoneEnabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fps = try container.decodeIfPresent(Int.self, forKey: .fps) ?? 30
            gifMaxPixelWidth = try container.decodeIfPresent(Int.self, forKey: .gifMaxPixelWidth) ?? 720
            showsCursor = try container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true
            autoOpenEditor = try container.decodeIfPresent(Bool.self, forKey: .autoOpenEditor) ?? true
            audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? false
            clickEffects = try container.decodeIfPresent(Bool.self, forKey: .clickEffects) ?? false
            microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? false
        }
    }

    /// 剪贴板设置（plan.md §2.7.3：默认关闭，隐私优先）。
    struct ClipboardSettingsBox: Codable, Equatable {
        /// 是否启用历史记录（默认关）
        var enabled: Bool
        /// 手动暂停监听
        var paused: Bool
        /// 保留数量上限（0 = 不限）
        var keepCount: Int
        /// 自动清理天数（0 = 不清理）
        var autoCleanDays: Int
        /// 排除应用 bundleID 列表
        var excludeApps: [String]
        /// 敏感内容过滤（辅助保护，非安全边界）
        var sensitiveFilter: Bool
        /// 退出时清空全部历史（plan.md §2.7.4）
        var clearOnQuit: Bool

        static let `default` = ClipboardSettingsBox(
            enabled: false, paused: false, keepCount: 500,
            autoCleanDays: 30, excludeApps: [], sensitiveFilter: true, clearOnQuit: false
        )

        enum CodingKeys: String, CodingKey {
            case enabled, paused, keepCount, autoCleanDays, excludeApps, sensitiveFilter, clearOnQuit
        }

        init(enabled: Bool = false, paused: Bool = false, keepCount: Int = 500,
             autoCleanDays: Int = 30, excludeApps: [String] = [], sensitiveFilter: Bool = true,
             clearOnQuit: Bool = false) {
            self.enabled = enabled
            self.paused = paused
            self.keepCount = keepCount
            self.autoCleanDays = autoCleanDays
            self.excludeApps = excludeApps
            self.sensitiveFilter = sensitiveFilter
            self.clearOnQuit = clearOnQuit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            keepCount = try container.decodeIfPresent(Int.self, forKey: .keepCount) ?? 500
            autoCleanDays = try container.decodeIfPresent(Int.self, forKey: .autoCleanDays) ?? 30
            excludeApps = try container.decodeIfPresent([String].self, forKey: .excludeApps) ?? []
            sensitiveFilter = try container.decodeIfPresent(Bool.self, forKey: .sensitiveFilter) ?? true
            clearOnQuit = try container.decodeIfPresent(Bool.self, forKey: .clearOnQuit) ?? false
        }
    }

    /// OCR 设置（plan.md Phase 6：图片文字识别；本地 Vision 处理）。
    struct OCRSettingsBox: Codable, Equatable {
        var enabled: Bool
        static let `default` = OCRSettingsBox(enabled: true)

        enum CodingKeys: String, CodingKey {
            case enabled
        }

        init(enabled: Bool = true) {
            self.enabled = enabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    /// 更新设置（发布策略：默认自动检查，更新由用户确认后安装）。
    struct UpdateSettingsBox: Codable, Equatable {
        /// 启动后延迟检查 + 每 24 小时一次
        var autoCheck: Bool

        static let `default` = UpdateSettingsBox(autoCheck: true)

        enum CodingKeys: String, CodingKey {
            case autoCheck
        }

        init(autoCheck: Bool = true) {
            self.autoCheck = autoCheck
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autoCheck = try container.decodeIfPresent(Bool.self, forKey: .autoCheck) ?? true
        }
    }

    static let `default` = AppSettings(
        general: .default,
        capture: .default,
        editor: .default,
        recording: .default,
        clipboard: .default,
        ocr: .default,
        hotkeys: .default,
        update: .default
    )

    // MARK: - 向后兼容解码

    private enum CodingKeys: String, CodingKey {
        case general, capture, editor, recording, clipboard, ocr, hotkeys, update
    }

    init(general: GeneralSettings, capture: CaptureSettings, editor: EditorSettings,
         recording: RecordingSettingsBox, clipboard: ClipboardSettingsBox,
         ocr: OCRSettingsBox, hotkeys: HotkeySettings,
         update: UpdateSettingsBox = .default) {
        self.general = general
        self.capture = capture
        self.editor = editor
        self.recording = recording
        self.clipboard = clipboard
        self.ocr = ocr
        self.hotkeys = hotkeys
        self.update = update
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 缺失字段回退默认值，保证旧版本配置文件可解析
        general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .default
        capture = try container.decodeIfPresent(CaptureSettings.self, forKey: .capture) ?? .default
        editor = try container.decodeIfPresent(EditorSettings.self, forKey: .editor) ?? .default
        recording = try container.decodeIfPresent(RecordingSettingsBox.self, forKey: .recording) ?? .default
        clipboard = try container.decodeIfPresent(ClipboardSettingsBox.self, forKey: .clipboard) ?? .default
        ocr = try container.decodeIfPresent(OCRSettingsBox.self, forKey: .ocr) ?? .default
        hotkeys = try container.decodeIfPresent(HotkeySettings.self, forKey: .hotkeys) ?? .default
        update = try container.decodeIfPresent(UpdateSettingsBox.self, forKey: .update) ?? .default
    }
}

/// 配置存储：UserDefaults + JSON Codable。
/// 通过 onChange 回调通知相关模块，禁止各 View 全局散读 UserDefaults（design.md §12.2）。
@MainActor
final class SettingsStore: ObservableObject {
    private static let storageKey = "com.wanghao.capturekit.settings"

    @Published private(set) var settings: AppSettings

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
            Log.settings.info("Settings loaded")
        } else {
            settings = .default
            Log.settings.info("Settings initialized with defaults")
        }
    }

    /// 更新并持久化配置。
    func update(_ transform: (inout AppSettings) -> Void) {
        var next = settings
        transform(&next)
        guard next != settings else { return }
        settings = next
        persist()
    }

    /// 恢复默认快捷键。
    func resetHotkeysToDefault() {
        update { $0.hotkeys = .default }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            Log.settings.debug("Settings persisted")
        } catch {
            Log.settings.error("Failed to persist settings: \(error.localizedDescription)")
        }
    }
}
