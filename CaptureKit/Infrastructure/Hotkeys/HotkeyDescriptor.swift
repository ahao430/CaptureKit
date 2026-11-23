import AppKit
import Carbon.HIToolbox
import Foundation

/// 快捷键修饰键（独立于 Carbon / NSEvent 的中性模型）。
enum HotkeyModifier: String, Codable, CaseIterable, Hashable {
    case command
    case option
    case shift
    case control

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .control: return "⌃"
        }
    }
}

/// 快捷键描述：Carbon 虚拟键码 + 修饰键集合。
/// Codable，用于持久化到 AppSettings.hotkeys。
struct HotkeyDescriptor: Codable, Hashable {
    /// Carbon 虚拟键码（kVK_ANSI_*，例如 A = 0）。
    var keyCode: Int
    var modifiers: Set<HotkeyModifier>

    init(keyCode: Int, modifiers: Set<HotkeyModifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: - 预设（plan.md §2.2 默认快捷键）

    static func regionCapture() -> HotkeyDescriptor {
        HotkeyDescriptor(keyCode: Int(kVK_ANSI_A), modifiers: [.command, .shift])
    }

    static func recordRegion() -> HotkeyDescriptor {
        HotkeyDescriptor(keyCode: Int(kVK_ANSI_R), modifiers: [.command, .shift])
    }

    static func history() -> HotkeyDescriptor {
        HotkeyDescriptor(keyCode: Int(kVK_ANSI_H), modifiers: [.command, .shift])
    }

    static func quickAccess() -> HotkeyDescriptor {
        HotkeyDescriptor(keyCode: Int(kVK_ANSI_V), modifiers: [.command, .shift])
    }

    // MARK: - Carbon 转换

    var carbonKeyCode: UInt32 { UInt32(keyCode) }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    // MARK: - 展示

    /// 键码 → 显示字符（仅覆盖常用 ANSI 键；不匹配返回键码数字）。
    var keyDisplay: String {
        let keySymbols: [Int: String] = [
            Int(kVK_ANSI_A): "A", Int(kVK_ANSI_B): "B", Int(kVK_ANSI_C): "C", Int(kVK_ANSI_D): "D",
            Int(kVK_ANSI_E): "E", Int(kVK_ANSI_F): "F", Int(kVK_ANSI_G): "G", Int(kVK_ANSI_H): "H",
            Int(kVK_ANSI_I): "I", Int(kVK_ANSI_J): "J", Int(kVK_ANSI_K): "K", Int(kVK_ANSI_L): "L",
            Int(kVK_ANSI_M): "M", Int(kVK_ANSI_N): "N", Int(kVK_ANSI_O): "O", Int(kVK_ANSI_P): "P",
            Int(kVK_ANSI_Q): "Q", Int(kVK_ANSI_R): "R", Int(kVK_ANSI_S): "S", Int(kVK_ANSI_T): "T",
            Int(kVK_ANSI_U): "U", Int(kVK_ANSI_V): "V", Int(kVK_ANSI_W): "W", Int(kVK_ANSI_X): "X",
            Int(kVK_ANSI_Y): "Y", Int(kVK_ANSI_Z): "Z",
            Int(kVK_ANSI_0): "0", Int(kVK_ANSI_1): "1", Int(kVK_ANSI_2): "2", Int(kVK_ANSI_3): "3",
            Int(kVK_ANSI_4): "4", Int(kVK_ANSI_5): "5", Int(kVK_ANSI_6): "6", Int(kVK_ANSI_7): "7",
            Int(kVK_ANSI_8): "8", Int(kVK_ANSI_9): "9",
            Int(kVK_Space): "Space", Int(kVK_Return): "↩", Int(kVK_Tab): "⇥", Int(kVK_Escape): "⎋",
        ]
        return keySymbols[keyCode] ?? "Key \(keyCode)"
    }

    /// 形如 `⌘⇧A` 的展示文本。
    var displayName: String {
        let sorted: [HotkeyModifier] = [.control, .option, .shift, .command]
        let mods = sorted.filter { modifiers.contains($0) }.map(\.symbol).joined()
        return mods + keyDisplay
    }

    /// 是否与另一快捷键冲突（相同键码 + 相同修饰键）。
    func conflicts(with other: HotkeyDescriptor) -> Bool {
        self == other
    }

    /// 从 NSEvent（设置窗口录制控件）构造描述符。
    /// - Parameters:
    ///   - keyCode: 事件键码（= Carbon 虚拟键码）。
    ///   - flags: 事件修饰键，仅提取 command/option/shift/control。
    /// - Returns: 修饰键为空时返回 nil（快捷键必须至少含一个修饰键）。
    static func fromEvent(keyCode: Int, flags: NSEvent.ModifierFlags) -> HotkeyDescriptor? {
        var modifiers = Set<HotkeyModifier>()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard !modifiers.isEmpty else { return nil }
        return HotkeyDescriptor(keyCode: keyCode, modifiers: modifiers)
    }
}

/// 功能标识 ↔ 快捷键映射，应用内统一入口。
enum HotkeyAction: String, Codable, CaseIterable {
    case regionCapture
    case recordRegion
    case history
    case quickAccess

    var defaultDescriptor: HotkeyDescriptor {
        switch self {
        case .regionCapture: return .regionCapture()
        case .recordRegion: return .recordRegion()
        case .history: return .history()
        case .quickAccess: return .quickAccess()
        }
    }

    var displayName: String {
        switch self {
        case .regionCapture: return "区域截图"
        case .recordRegion: return "区域录制"
        case .history: return "历史记录"
        case .quickAccess: return "快速剪贴板"
        }
    }

    /// Carbon 注册用的稳定数字 ID（进程内与跨版本一致）。
    var stableID: UInt32 {
        switch self {
        case .regionCapture: return 1
        case .recordRegion: return 3
        case .history: return 2
        case .quickAccess: return 4
        }
    }
}

/// 对一组快捷键映射做冲突检测（design.md Task 3：注册前必须可发现冲突）。
enum HotkeyConflictChecker {
    /// - Returns: 冲突的 (action, descriptor) 对列表；为空表示无冲突。
    static func conflicts(in mapping: [HotkeyAction: HotkeyDescriptor]) -> [(HotkeyAction, HotkeyDescriptor)] {
        var seen: [HotkeyDescriptor: HotkeyAction] = [:]
        var result: [(HotkeyAction, HotkeyDescriptor)] = []
        for (action, descriptor) in mapping.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let existing = seen[descriptor] {
                result.append((action, descriptor))
                if result.count == 1 { result.insert((existing, descriptor), at: 0) }
            } else {
                seen[descriptor] = action
            }
        }
        return result
    }
}
