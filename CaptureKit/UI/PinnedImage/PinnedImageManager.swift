import AppKit
import CoreGraphics

/// 贴图管理器：持有全部贴图窗口，限制数量（超出关闭最早的）。
@MainActor
final class PinnedImageManager {
    static let shared = PinnedImageManager()

    /// 同时保留的贴图上限（防止窗口泛滥）
    private let maxCount = 12
    private var controllers: [PinnedImagePanelController] = []

    /// 在选区原位钉一张截图。
    func show(image: CGImage, at screenRect: CGRect) {
        if controllers.count >= maxCount, let oldest = controllers.first {
            oldest.close()
        }
        let controller = PinnedImagePanelController(image: image, screenRect: screenRect)
        controller.onClose = { [weak controller, weak self] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.show()
        Log.overlay.info("Pinned image shown (\(self.controllers.count) active)")
    }

    /// 关闭全部贴图。
    func closeAll() {
        for controller in controllers {
            controller.close()
        }
        controllers.removeAll()
    }

    var count: Int { controllers.count }
}
