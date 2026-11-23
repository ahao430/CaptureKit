import AppKit
import Foundation

/// App Translocation 检测（ADR-030）：
/// 未公证应用从 DMG/下载目录以 quarantine 属性首次运行时，macOS 会把 .app
/// 拷到随机只读路径（/private/var/folders/…/AppTranslocation/…）再启动。
/// TCC 屏幕录制授权按代码签名+路径记录，Translocation 下每次启动路径都变，
/// 表现为「授权了下次还弹」。根治办法是让用户把 App 移出受保护位置
/// （拖到 /Applications，或对 .app 执行 xattr 清隔离）。
enum TranslocationChecker {
    /// 是否正处于 Translocation（只读随机路径）。
    static func isTranslocated(_ bundle: Bundle = .main) -> Bool {
        let path = bundle.bundlePath
        return path.hasPrefix("/private/var/folders/")
            && path.contains("AppTranslocation")
    }

    /// 是否带 quarantine 属性（用户拖 App 时该属性通常一并带过去）。
    static func hasQuarantine(_ bundle: Bundle = .main) -> Bool {
        let path = bundle.bundlePath as NSString
        // LSCopyApplicationWithURL 不适合；直接 xattr 探测（快且无副作用）
        let result = runXattr(path: path as String)
        return result
    }

    /// 启动时检查；命中则弹一次引导弹窗（记住「不再提示」）。
    static func checkAndGuideIfNeeded() {
        guard isTranslocated() || hasQuarantine() else { return }
        let defaults = UserDefaults.standard
        let skipKey = "com.wanghao.capturekit.suppressTranslocationGuide"
        guard !defaults.bool(forKey: skipKey) else {
            Log.app.info("Translocation/quarantine detected (guide suppressed)")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要完成一次安装，权限才能生效"
        alert.informativeText = """
        CaptureKit 检测到它正从「临时位置」运行（通常是直接从 DMG 打开，或下载目录未解除隔离）。\
        这会导致「屏幕录制」权限每次启动都要重新授权。

        请任选其一（推荐第 1 种）：
        1. 把 CaptureKit.app 拖入「应用程序」文件夹，从那里启动；
        2. 或在终端执行：xattr -dr com.apple.quarantine /Applications/CaptureKit.app

        完成后重新打开 CaptureKit 即可正常使用。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "不再提示")
        if alert.runModal() == .alertSecondButtonReturn {
            defaults.set(true, forKey: skipKey)
        }
        Log.app.warning("Translocation/quarantine guide shown (translocated=\(isTranslocated()), quarantine=\(hasQuarantine()))")
    }

    private static func runXattr(path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-p", "com.apple.quarantine", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
