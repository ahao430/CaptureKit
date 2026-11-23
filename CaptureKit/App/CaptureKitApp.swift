import AppKit

/// 纯 AppKit 入口（菜单栏应用，design.md §4.1）。
/// LSUIElement=true + activationPolicy(.accessory) 双保险隐藏 Dock 图标；
/// 设置中可切换为 regular 显示 Dock 图标。
@main
enum CaptureKitApp {
    static func main() {
        let app = NSApplication.shared
        let environment = AppEnvironment()
        let delegate = AppDelegate(environment: environment)

        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
