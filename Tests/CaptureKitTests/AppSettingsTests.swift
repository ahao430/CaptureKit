import XCTest

@testable import CaptureKit

@MainActor
final class AppSettingsTests: XCTestCase {
    private func clearStoredSettings() {
        UserDefaults.standard.removeObject(forKey: "com.wanghao.capturekit.settings")
    }

    override func setUp() {
        super.setUp()
        clearStoredSettings()
    }

    override func tearDown() {
        clearStoredSettings()
        super.tearDown()
    }

    func testCodableRoundTrip() throws {
        var settings = AppSettings.default
        settings.general.launchAtLogin = true
        settings.capture.autoCopyToClipboard = false
        settings.hotkeys.regionCapture = HotkeyDescriptor(keyCode: 88, modifiers: [.command, .option])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testDecodingMissingFieldsFallsBackToDefaults() throws {
        // 旧版本配置只有部分字段（模拟升级场景）
        let legacyJSON = #"{"capture":{"autoCopyToClipboard":false}}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.general, AppSettings.GeneralSettings.default)
        XCTAssertEqual(decoded.hotkeys, AppSettings.HotkeySettings.default)
        XCTAssertFalse(decoded.capture.autoCopyToClipboard)
    }

    func testEmptyJSONFallsBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppSettings.default)
    }

    func testSettingsStoreLoadsDefaultsWhenEmpty() {
        let store = SettingsStore()
        XCTAssertEqual(store.settings, AppSettings.default)
    }

    func testSettingsStoreUpdatePersists() {
        let store = SettingsStore()
        store.update { $0.capture.autoCopyToClipboard = false }

        // 新实例从 UserDefaults 读取 → 验证持久化
        let reloaded = SettingsStore()
        XCTAssertFalse(reloaded.settings.capture.autoCopyToClipboard)
    }

    func testSettingsStoreNoChangeDoesNotPersist() {
        let store = SettingsStore()
        store.update { $0.capture.autoCopyToClipboard = true } // 默认已是 true
        // 无变化不应崩溃/写入；值保持
        XCTAssertTrue(store.settings.capture.autoCopyToClipboard)
    }

    func testResetHotkeys() {
        let store = SettingsStore()
        store.update {
            $0.hotkeys.regionCapture = HotkeyDescriptor(keyCode: 99, modifiers: [.control])
        }
        store.resetHotkeysToDefault()
        XCTAssertEqual(store.settings.hotkeys, AppSettings.HotkeySettings.default)
    }
}
