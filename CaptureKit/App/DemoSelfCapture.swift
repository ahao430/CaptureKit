import AppKit

/// 演示自截图（--demo-snap <目录>）：N 秒后把全部可见窗口离屏渲染为 PNG 后退出。
/// drawHierarchy 离屏渲染不经过屏幕，不需要屏幕录制 TCC。
enum DemoSelfCapture {
    /// 在 AppEnvironment.start() 最早处调用（参数在，即接管生命周期）。
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--demo-snap") else { return false }
        let outputDir = args[index + 1]
        let delay: Double = {
            if let i = args.firstIndex(of: "--demo-snap-delay") {
                return Double(args[i + 1]) ?? 5.0
            }
            return 5.0
        }()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            snapAllWindows(to: outputDir)
            exit(0)
        }
        return true
    }

    private static func snapAllWindows(to directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.contentView != nil }
        for (offset, window) in windows.enumerated() {
            let raw = window.title.isEmpty ? "window-\(offset)" : window.title
            if let png = pngData(windowContentView: window.contentView!) {
                try? png.write(to: url.appendingPathComponent("\(sanitize(raw)).png"))
            }
        }
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    private static func pngData(windowContentView view: NSView) -> Data? {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2),   // 2x，等 retina
            pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
