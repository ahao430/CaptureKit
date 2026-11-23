import Carbon.HIToolbox
import Foundation

/// 基于 Carbon RegisterEventHotKey 的全局快捷键中心（Phase 0 实现方案，design.md §4.1 技术选型）。
///
/// 职责：
/// - 注册 / 注销全局快捷键。
/// - 按功能 ID 分发回调（主线程执行）。
/// - 注册失败返回明确结果，由上层提示用户（不允许静默失效）。
final class CarbonHotkeyCenter {
    static let shared = CarbonHotkeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef?] = [:]
    private var installed = false

    private init() {}

    // MARK: - 注册 / 注销

    /// 注册全局快捷键。
    /// - Returns: false 表示系统注册失败（快捷键可能被占用或参数非法）。
    @discardableResult
    func register(actionID: UInt32, descriptor: HotkeyDescriptor, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(actionID: actionID)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("CPTK"), id: actionID)
        let status = RegisterEventHotKey(
            descriptor.carbonKeyCode,
            descriptor.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, ref != nil else {
            Log.hotkey.error("RegisterEventHotKey failed (action \(actionID), status \(status))")
            return false
        }
        hotKeyRefs[actionID] = ref
        actions[actionID] = action
        Log.hotkey.debug("Hotkey registered: action=\(actionID, privacy: .public) \(descriptor.displayName, privacy: .public)")
        return true
    }

    func unregister(actionID: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: actionID) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: actionID)
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    // MARK: - 事件处理

    private func installHandlerIfNeeded() {
        guard !installed else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // C 回调无法捕获上下文 → 通过 userData 传 self。
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let center = Unmanaged<CarbonHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            center.dispatch(hotKeyID.id)
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        installed = installStatus == noErr
    }

    private func dispatch(_ id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let action = self.actions[id] else { return }
            action()
        }
    }

    // MARK: - 工具

    private func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) | OSType(scalar.value & 0xFF)
        }
        return result
    }
}
