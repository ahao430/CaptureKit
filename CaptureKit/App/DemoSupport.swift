import AppKit
import CoreGraphics

/// 文档截图演示模式（--demo-* 启动参数）：
/// 只负责打开真实窗口/控件供 `screencapture` 截图，不改变任何业务行为；
/// 历史演示使用临时数据库，不污染真实数据。
enum DemoContent {
    /// 高对比测试底图（验证快照图片渲染通路）。
    static func contrastTestImage() -> CGImage? {
        let url = URL(fileURLWithPath: "/tmp/icon-out/icon-1024.png")
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: CGSize(width: 1600, height: 1000))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 合成的"网页截图"画布（编辑器/历史演示底图，1600×1000）。
    static func mockWebPage() -> CGImage {
        let size = NSSize(width: 1600, height: 1000)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return emptyImage()
        }

        let page = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
        ctx.fill(page)

        // 窗口主体
        let body = NSRect(x: 20, y: 20, width: 1560, height: 960)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 16, yRadius: 16)
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0.1, alpha: 0.18))
        NSColor.white.setFill()
        bodyPath.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.saveGState()
        bodyPath.addClip()

        // 顶部栏（含红绿灯）
        let chrome = NSRect(x: 20, y: 20, width: 1560, height: 56)
        NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
        ctx.fill(chrome)
        let lamps: [NSColor] = [system(1.0, 0.36, 0.36), system(1.0, 0.74, 0.28), system(0.26, 0.80, 0.38)]
        for (index, color) in lamps.enumerated() {
            let dot = NSBezierPath(ovalIn: NSRect(x: CGFloat(44 + index * 26), y: 39, width: 13, height: 13))
            color.setFill()
            dot.fill()
        }
        draw(text: "CaptureKit 设计规范 — design.spec", font: .systemFont(ofSize: 14, weight: .medium),
             color: .gray, at: NSPoint(x: 132, y: 41))

        // 侧栏
        let sidebar = NSRect(x: 20, y: 76, width: 300, height: 904)
        NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
        ctx.fill(sidebar)
        let sideTitles = ["概览", "截图", "编辑器", "录制", "历史", "剪贴板", "OCR", "快捷键"]
        for (index, title) in sideTitles.enumerated() {
            let row = NSRect(x: 28, y: CGFloat(120 + index * 52), width: 284, height: 40)
            if title == "历史" {
                teal.setFill()
                NSBezierPath(roundedRect: row, xRadius: 9, yRadius: 9).fill()
                draw(text: title, font: .systemFont(ofSize: 15, weight: .semibold), color: .white, at: NSPoint(x: 48, y: row.minY + 11))
            } else {
                draw(text: title, font: .systemFont(ofSize: 15),
                     color: .darkGray, at: NSPoint(x: 48, y: row.minY + 11))
            }
        }

        // 主区标题与段落
        draw(text: "统一内容历史", font: .systemFont(ofSize: 40, weight: .bold),
             color: .black, at: NSPoint(x: 372, y: 130))
        draw(text: "截图、录制与剪贴板进入同一个本地库，可搜索、可固定、自动清理。",
             font: .systemFont(ofSize: 17), color: .darkGray, at: NSPoint(x: 372, y: 196))

        // 段落灰条
        for row in 0..<3 {
            for col in 0..<2 {
                let bar = NSRect(x: CGFloat(372 + col * 560), y: CGFloat(246 + row * 26),
                                 width: col == 0 ? 520 : 460, height: 11)
                NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 5.5, yRadius: 5.5).fill()
            }
        }

        // 条形图卡
        let chart = NSRect(x: 372, y: 360, width: 620, height: 240)
        card(chart)
        draw(text: "本周捕获量", font: .systemFont(ofSize: 15, weight: .semibold),
             color: .black, at: NSPoint(x: chart.minX + 22, y: chart.minY + 18))
        let bars = [0.35, 0.62, 0.48, 0.80, 0.55, 0.92, 0.68]
        for (index, ratio) in bars.enumerated() {
            let bar = NSRect(x: chart.minX + 30 + CGFloat(index) * 82, y: chart.minY + 62,
                             width: 46, height: 150 * ratio)
            NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
            NSBezierPath(roundedRect: bar.insetBy(dx: 0, dy: -4), xRadius: 8, yRadius: 8).fill()
            let value = NSRect(x: bar.minX, y: bar.minY, width: 46, height: 150 * ratio - 6)
            teal.setFill()
            NSBezierPath(roundedRect: value, xRadius: 8, yRadius: 8).fill()
        }

        // 表单卡（含敏感字段供马赛克演示）
        let form = NSRect(x: 1030, y: 360, width: 526, height: 240)
        card(form)
        draw(text: "部署配置", font: .systemFont(ofSize: 15, weight: .semibold),
             color: .black, at: NSPoint(x: form.minX + 22, y: form.minY + 18))
        fieldBackground = form
        draw(text: "服务地址", font: .systemFont(ofSize: 12), color: .gray,
             at: NSPoint(x: form.minX + 22, y: form.minY + 56))
        let host = NSRect(x: form.minX + 22, y: form.minY + 74, width: 482, height: 34)
        textField(host)
        draw(text: "https://api.capturekit.local", font: .monospacedSystemFont(ofSize: 13, weight: .regular),
             color: .darkGray, at: NSPoint(x: host.minX + 10, y: host.minY + 9))
        draw(text: "API Token", font: .systemFont(ofSize: 12), color: .gray,
             at: NSPoint(x: form.minX + 22, y: form.minY + 126))
        let token = NSRect(x: form.minX + 22, y: form.minY + 144, width: 482, height: 34)
        textField(token)
        draw(text: "sk-live-9f3a····························",
             font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: .darkGray,
             at: NSPoint(x: token.minX + 10, y: token.minY + 9))
        tokenField = token

        // 底部按钮
        let button = NSRect(x: 1290, y: 660, width: 266, height: 52)
        teal.setFill()
        NSBezierPath(roundedRect: button, xRadius: 12, yRadius: 12).fill()
        draw(text: "导出 PNG", font: .systemFont(ofSize: 17, weight: .semibold),
             color: .white, at: NSPoint(x: button.minX + 74, y: button.minY + 15))
        exportButton = button

        ctx.restoreGState()
        image.unlockFocus()

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return emptyImage()
        }
        // 2x 屏上 NSImage 的 cgImage 是 3200×2000 像素：归一化到 1600×1000，
        // 使标注坐标与图像坐标一一对应
        guard cg.width != 1600 || cg.height != 1000 else { return cg }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        return ctx.makeImage() ?? cg
    }

    /// 供演示标注定位的合成元素位置（image 像素坐标，y 向下）。
    static let pageHeight: CGFloat = 1000
    static var exportButton: CGRect = .zero
    static var tokenField: CGRect = .zero
    static var fieldBackground: CGRect = .zero

    // MARK: - 绘制小件

    private static var teal: NSColor { NSColor(calibratedRed: 0.055, green: 0.431, blue: 0.40, alpha: 1) }

    private static func system(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    private static func card(_ rect: NSRect) {
        NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
        NSColor(calibratedWhite: 0.91, alpha: 1).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        path.lineWidth = 1
        path.stroke()
    }

    private static func textField(_ rect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.lineWidth = 1
        path.stroke()
    }

    private static func draw(text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private static func emptyImage() -> CGImage {
        let size = NSSize(width: 4, height: 4)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            ?? NSImage().cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}
