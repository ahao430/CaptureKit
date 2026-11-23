import CoreGraphics
import Foundation

/// 屏幕录制权限状态（design.md §15）。
///
/// 注意：macOS 未提供实时权限变更通知，本类型只反映检测时刻的状态，
/// 不虚构授权状态。用户从系统设置返回后需要重新检测。
enum ScreenCapturePermission {
    /// 静态检测当前是否已授权（不弹窗）。
    /// - Returns: nil 表示无法判断（API 不可用），true/false 为确定结果。
    static func isAuthorized() -> Bool? {
        // CGPreflightScreenCaptureAccess: macOS 10.15+
        let granted = CGPreflightScreenCaptureAccess()
        Log.permission.debug("Preflight screen capture access: \(granted)")
        return granted
    }

    /// 请求屏幕录制权限（触发系统弹窗；仅首次有效）。
    /// - Returns: true 表示已授权（原本已授权也会返回 true）。
    @discardableResult
    static func request() async -> Bool {
        // CGRequestScreenCaptureAccess 必须在主线程外调用时注意：
        // 该函数会阻塞等待用户响应弹窗，因此放到后台线程执行。
        let granted = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        Log.permission.info("Request screen capture access result: \(granted)")
        return granted
    }
}
