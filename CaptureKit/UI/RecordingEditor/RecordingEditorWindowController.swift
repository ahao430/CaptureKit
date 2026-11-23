import AppKit
import SwiftUI

/// 录制编辑器窗口控制器（单窗口复用，连续录制场景替换源）。
@MainActor
final class RecordingEditorWindowController {
    private var window: NSWindow?
    private var viewModel: RecordingEditorViewModel?

    func show(url: URL) {
        NSApp.activate(ignoringOtherApps: true)

        if let window, viewModel != nil {
            // 复用窗口：替换播放源
            let newModel = RecordingEditorViewModel(sourceURL: url)
            self.viewModel = newModel
            if let hosting = window.contentViewController as? NSHostingController<AnyView> {
                hosting.rootView = AnyView(makeContent(viewModel: newModel))
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = RecordingEditorViewModel(sourceURL: url)
        self.viewModel = viewModel

        let hosting = NSHostingController(rootView: AnyView(makeContent(viewModel: viewModel)))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CaptureKit 录制编辑器"
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 760, height: 600))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RecordingEditorWindow")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        Log.editor.info("Recording editor opened: \(url.lastPathComponent, privacy: .public)")
    }

    private func makeContent(viewModel: RecordingEditorViewModel) -> some View {
        RecordingEditorView(
            onRevealInFinder: { [weak viewModel] in
                guard let url = viewModel?.sourceURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        )
        .environmentObject(viewModel)
    }
}
