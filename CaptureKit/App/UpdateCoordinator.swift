import Combine
import Foundation
import Sparkle

/// 自动更新装配（ADR-029：Sparkle 2 + EdDSA，feed 固定指向 GitHub Releases 附件）。
/// 设置中的开关是唯一事实来源：启动与变更时推送给 Sparkle，避免双写漂移。
@MainActor
final class UpdateCoordinator {
    private let controller: SPUStandardUpdaterController
    private let settings: SettingsStore

    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // 应用侧配置 → Sparkle（Info.plist 的 SUEnableAutomaticChecks/SUScheduledCheckInterval 为首启默认）
        applyAutoCheck(settings.settings.update.autoCheck)

        settings.$settings
            .map(\.update.autoCheck)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                self?.applyAutoCheck(enabled)
            }
            .store(in: &cancellables)
    }

    var updater: SPUUpdater {
        controller.updater
    }

    /// 当前应用版本（CFBundleShortVersionString，展示用）。
    static var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "0"
    }

    /// 手动检查更新（菜单「检查更新…」/ 设置页「立即检查」）。
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    func applyAutoCheck(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        if enabled {
            updater.updateCheckInterval = Self.checkInterval
        }
        Log.app.info("Auto update check set to \(enabled)")
    }

    /// 检查周期：24 小时（发布策略：启动后延迟检查 + 每日一次）。
    static let checkInterval: TimeInterval = 86_400
}
