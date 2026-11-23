import AVFoundation
import Foundation

/// 麦克风权限（Phase 6：plan.md §7.1 权限管理）。
/// SCStream 麦克风采集同样受 TCC 麦克风授权约束。
@MainActor
enum MicrophonePermission {
    /// 当前授权状态（不弹窗）。
    static func isAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 请求授权（触发系统弹窗；已授权立即返回 true）。
    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 确保已授权：已授权直接 true；未决定则请求；被拒返回 false（调用方降级为无麦克风录制）。
    static func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await request()
        default:
            return false
        }
    }
}
