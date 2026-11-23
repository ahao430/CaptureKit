import AppKit

/// AppDelegate：仅承载应用生命周期回调（design.md §4.2）。
/// 业务装配与模块逻辑都在 AppEnvironment。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }
}
