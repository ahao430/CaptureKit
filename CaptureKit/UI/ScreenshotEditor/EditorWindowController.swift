import AppKit
import CoreGraphics
import SwiftUI

/// 编辑器窗口（AppKit 托管 + SwiftUI 内容，ui-design.md §6）。
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var document: EditorDocument?

    var onCopyComposed: ((EditorDocument, NSWindow?) -> Void)?
    var onSaveComposed: ((EditorDocument) -> Void)?

    func show(image: CGImage) {
        let document = EditorDocument(baseImage: image)
        self.document = document
        openWindow(with: document)
    }

    /// 复用已有窗口替换文档（连续截图场景）。
    func replaceDocument(image: CGImage) {
        guard let window, let hosting = window.contentViewController as? NSHostingController<AnyView> else {
            show(image: image)
            return
        }
        let document = EditorDocument(baseImage: image)
        self.document = document
        hosting.rootView = AnyView(
            EditorContentView(
                onCopy: { [weak self] in self?.copyCurrent() },
                onSave: { [weak self] in self?.saveCurrent() },
                onClose: { [weak self] in self?.close() }
            )
            .environmentObject(document)
        )
        fitWindow(to: image)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    var windowRef: NSWindow? { window }

    // MARK: - 私有

    private func openWindow(with document: EditorDocument) {
        let contentView = EditorContentView(
            onCopy: { [weak self] in self?.copyCurrent() },
            onSave: { [weak self] in self?.saveCurrent() },
            onClose: { [weak self] in self?.close() }
        )
        .environmentObject(document)

        let hosting = NSHostingController(rootView: AnyView(contentView))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CaptureKit 编辑器"
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.resizable)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("EditorWindow")
        window.delegate = self
        self.window = window

        fitWindow(to: document.baseImage)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.editor.info("Editor opened (image \(document.baseImage.width)×\(document.baseImage.height))")
    }

    // MARK: - NSWindowDelegate（关闭前未导出提醒）

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard let document, document.hasUnexportedChanges else { return true }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "有未导出的修改"
            alert.informativeText = "标注或裁剪尚未复制/保存，关闭后将丢失（原始截图不受影响）。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "直接关闭")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func fitWindow(to image: CGImage) {
        guard let window else { return }
        let maxContent = NSSize(
            width: NSScreen.main?.visibleFrame.width ?? 1200,
            height: (NSScreen.main?.visibleFrame.height ?? 800) - 120
        )
        let content = NSSize(
            width: min(max(680, CGFloat(image.width) * 0.75 + 40), maxContent.width),
            height: min(max(460, CGFloat(image.height) * 0.75 + 130), maxContent.height)
        )
        window.setContentSize(content)
        window.center()
    }

    private func copyCurrent() {
        guard let document else { return }
        onCopyComposed?(document, window)
    }

    private func saveCurrent() {
        guard let document else { return }
        onSaveComposed?(document)
    }
}

/// 编辑器协调器：窗口生命周期 + 导出交付（复制/保存复用统一渲染管线）。
@MainActor
final class EditorCoordinator {
    private var windowController: EditorWindowController?

    var errorHandler: ((CaptureKitError) -> Void)?

    func edit(image: CGImage) {
        if let existing = windowController, existing.windowRef != nil, existing.windowRef?.isVisible == true {
            existing.replaceDocument(image: image)
        } else {
            let controller = EditorWindowController()
            controller.onCopyComposed = { [weak self] document, window in
                self?.copyComposed(document, anchorWindow: window)
            }
            controller.onSaveComposed = { [weak self] document in
                self?.saveComposed(document)
            }
            windowController = controller
            controller.show(image: image)
        }
    }

    // MARK: - 交付

    private func copyComposed(_ document: EditorDocument, anchorWindow: NSWindow?) {
        guard let composed = AnnotationRenderer.compose(baseImage: document.effectiveImage, annotations: document.annotations) else {
            errorHandler?(.exportFailed(underlying: nil))
            return
        }
        do {
            try ClipboardWriter.copy(composed)
            document.markExported()
            var anchor = anchorWindow?.frame
            if anchor == nil { anchor = NSScreen.main?.frame }
            if let anchor {
                CaptureResultToast.show(image: composed, message: "已复制合成图到剪贴板", anchorRect: anchor)
            }
            Log.editor.info("Composed image copied (\(composed.width)×\(composed.height), \(document.annotations.count) annotations)")
        } catch {
            errorHandler?(.clipboardWriteFailed)
        }
    }

    private func saveComposed(_ document: EditorDocument) {
        guard let composed = AnnotationRenderer.compose(baseImage: document.effectiveImage, annotations: document.annotations) else {
            errorHandler?(.exportFailed(underlying: nil))
            return
        }
        SavePanelPresenter.presentPNGPanel(for: composed) {
            document.markExported()
        }
        Log.editor.info("Composed save panel presented (\(document.annotations.count) annotations)")
    }
}
