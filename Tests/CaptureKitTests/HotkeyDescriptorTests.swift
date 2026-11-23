import Carbon.HIToolbox
import XCTest

@testable import CaptureKit

final class HotkeyDescriptorTests: XCTestCase {
    func testDefaultRegionCaptureIsCmdShiftA() {
        let descriptor = HotkeyDescriptor.regionCapture()
        XCTAssertEqual(descriptor.keyCode, Int(kVK_ANSI_A))
        XCTAssertEqual(descriptor.modifiers, [.command, .shift])
        // macOS 惯例修饰键顺序：⌃ ⌥ ⇧ ⌘
        XCTAssertEqual(descriptor.displayName, "⇧⌘A")
    }

    func testDefaultQuickAccessHotkeyIsCmdShiftV() {
        XCTAssertEqual(HotkeyDescriptor.quickAccess().displayName, "⇧⌘V")
        XCTAssertEqual(HotkeyAction.quickAccess.stableID, 4)
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.stableID)).count, HotkeyAction.allCases.count)
    }

    func testCarbonModifierFlags() {
        let all = HotkeyDescriptor(keyCode: Int(kVK_ANSI_H), modifiers: [.command, .option, .shift, .control])
        let expected: UInt32 = UInt32(cmdKey | optionKey | shiftKey | controlKey)
        XCTAssertEqual(all.carbonModifiers, expected)

        let none = HotkeyDescriptor(keyCode: 0, modifiers: [])
        XCTAssertEqual(none.carbonModifiers, 0)
    }

    func testConflictDetection() {
        let a1 = HotkeyDescriptor(keyCode: 0, modifiers: [.command, .shift])
        let a2 = HotkeyDescriptor(keyCode: 0, modifiers: [.command, .shift])
        let b = HotkeyDescriptor(keyCode: 0, modifiers: [.command, .option])

        XCTAssertTrue(a1.conflicts(with: a2))
        XCTAssertFalse(a1.conflicts(with: b))
    }

    func testConflictCheckerFindsDuplicates() {
        let mapping: [HotkeyAction: HotkeyDescriptor] = [
            .regionCapture: HotkeyDescriptor(keyCode: 0, modifiers: [.command, .shift]),
            .history: HotkeyDescriptor(keyCode: 0, modifiers: [.command, .shift]), // 与 regionCapture 冲突
        ]
        let conflicts = HotkeyConflictChecker.conflicts(in: mapping)
        XCTAssertEqual(conflicts.count, 2)
    }

    func testConflictCheckerPassesDistinctKeys() {
        let mapping: [HotkeyAction: HotkeyDescriptor] = [
            .regionCapture: .regionCapture(),
            .history: .history(),
        ]
        XCTAssertTrue(HotkeyConflictChecker.conflicts(in: mapping).isEmpty)
    }

    func testCodableRoundTrip() throws {
        let original = HotkeyDescriptor(keyCode: Int(kVK_ANSI_R), modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyDescriptor.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStableIDsAreUnique() {
        let ids = Set(HotkeyAction.allCases.map(\.stableID))
        XCTAssertEqual(ids.count, HotkeyAction.allCases.count)
    }

    // MARK: - NSEvent 转换

    func testFromEventWithModifiers() {
        // ⌘⇧S
        let descriptor = HotkeyDescriptor.fromEvent(
            keyCode: Int(kVK_ANSI_S),
            flags: [.command, .shift]
        )
        XCTAssertEqual(descriptor, HotkeyDescriptor(keyCode: Int(kVK_ANSI_S), modifiers: [.command, .shift]))
    }

    func testFromEventIgnoresNonShortcutModifiers() {
        // 含功能键等无关 flag，仅提取四类修饰键
        let descriptor = HotkeyDescriptor.fromEvent(
            keyCode: Int(kVK_ANSI_J),
            flags: [.option, .function, .numericPad]
        )
        XCTAssertEqual(descriptor, HotkeyDescriptor(keyCode: Int(kVK_ANSI_J), modifiers: [.option]))
    }

    func testFromEventRejectsMissingModifiers() {
        // 无修饰键 → nil（快捷键必须含修饰键）
        XCTAssertNil(HotkeyDescriptor.fromEvent(keyCode: Int(kVK_ANSI_A), flags: []))
        XCTAssertNil(HotkeyDescriptor.fromEvent(keyCode: Int(kVK_ANSI_A), flags: [.function]))
    }
}
