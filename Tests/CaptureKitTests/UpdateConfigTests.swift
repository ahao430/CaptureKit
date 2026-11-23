import XCTest

@testable import CaptureKit

/// 发布配置自检（ADR-028/029）：宿主 App 的 Info.plist 更新配置存在且合法。
/// （TEST_HOST 模式下 Bundle.main 即 CaptureKit.app）
final class UpdateConfigTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func testFeedURLPointsToLatestReleaseAppcast() {
        // feed 固定指向最新 Release 附件：资产名不变则链接永不失效
        let url = info["SUFeedURL"] as? String
        XCTAssertEqual(url, "https://github.com/ahao430/CaptureKit/releases/latest/download/appcast.xml")
    }

    func testPublicEDKeyIs32ByteEd25519() throws {
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String, "缺少 SUPublicEDKey")
        let data = try XCTUnwrap(Data(base64Encoded: key), "公钥应为合法 base64")
        XCTAssertEqual(data.count, 32, "Ed25519 公钥应为 32 字节")
    }

    func testCheckIntervalIsDaily() {
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86_400)
    }

    func testAutomaticChecksEnabledOnFirstLaunch() {
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testUpdateInstallRequiresUserConfirmation() {
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
    }

    /// 隐私优先：检查更新不向服务器发送系统剖析信息
    func testSystemProfilingDisabled() {
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }

    func testUpdateSettingsDefaultOn() {
        XCTAssertEqual(AppSettings.UpdateSettingsBox().autoCheck, true)
        XCTAssertEqual(AppSettings.default.update.autoCheck, true)
        XCTAssertEqual(UpdateCoordinator.checkInterval, 86_400, accuracy: 0.5)
    }

    func testUpdateSettingsDecodeMissingFallsBackToDefault() throws {
        // 旧版本配置（无 update 字段）回退默认开启
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.update.autoCheck, true)
    }
}
