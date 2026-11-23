import AppKit

/// Dock 图标显示策略（LSUIElement + activationPolicy 动态切换）。
@MainActor
enum AppDockIconService {
    static func apply(showDockIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
        Log.app.debug("Activation policy → \(showDockIcon ? "regular" : "accessory")")
    }
}
