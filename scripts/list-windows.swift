// 列出 CaptureKit 的在屏窗口（文档截图用）：
//   swift scripts/list-windows.swift          → 全部窗口 id/标题/尺寸
// 用法示例：screencapture -x -o -l<ID> out.png
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("无法枚举窗口\n".data(using: .utf8)!)
    exit(1)
}
for window in list {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == "CaptureKit" else { continue }
    let id = window[kCGWindowNumber as String] as? Int ?? 0
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0
    let x = bounds["X"] as? Int ?? 0
    let y = bounds["Y"] as? Int ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    print("\(id)\tlayer=\(layer)\t\(x),\(y)\t\(width)x\(height)\t\(name)")
}
