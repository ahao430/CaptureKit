import Carbon.HIToolbox
import XCTest

@testable import CaptureKit

/// 外部快捷键占用检测（ADR-030 补充实证：RegisterEventHotKey 对已占用组合静默成功）。
final class ExternalHotkeyConflictTests: XCTestCase {
    func testDingTalkRunningWithDefaultKeyTriggersHint() {
        let hint = HotkeyConflictChecker.externalConflictHint(
            runningBundleIDs: ["com.alibaba.DingTalk", "com.apple.Safari"],
            regionCapture: .regionCapture()
        )
        XCTAssertEqual(hint, "钉钉")
    }

    func testWeChatRunningWithDefaultKeyTriggersHint() {
        let hint = HotkeyConflictChecker.externalConflictHint(
            runningBundleIDs: ["com.tencent.xinWeChat"],
            regionCapture: .regionCapture()
        )
        XCTAssertEqual(hint, "微信")
    }

    func testNoKnownAppsRunningReturnsNil() {
        let hint = HotkeyConflictChecker.externalConflictHint(
            runningBundleIDs: ["com.apple.Safari", "com.apple.finder"],
            regionCapture: .regionCapture()
        )
        XCTAssertNil(hint)
    }

    func testCustomKeyNeverTriggersHint() {
        // 用户已改键 → 即使钉钉在运行也不提示
        var custom = HotkeyDescriptor.regionCapture()
        custom.keyCode = Int(kVK_ANSI_X)
        let hint = HotkeyConflictChecker.externalConflictHint(
            runningBundleIDs: ["com.alibaba.DingTalk"],
            regionCapture: custom
        )
        XCTAssertNil(hint)
    }

    func testBundlePrefixMatching() {
        // 前缀匹配：子 bundle（如 DingTalk 的 helper）也命中
        let hint = HotkeyConflictChecker.externalConflictHint(
            runningBundleIDs: ["com.alibaba.DingTalk.helper"],
            regionCapture: .regionCapture()
        )
        XCTAssertEqual(hint, "钉钉")
    }

    func testKnownScreenshotAppsCatalog() {
        // 目录自检：bundle 前缀非空、显示名非空
        for app in HotkeyConflictChecker.knownScreenshotApps {
            XCTAssertFalse(app.bundlePrefix.isEmpty)
            XCTAssertFalse(app.name.isEmpty)
        }
    }
}
