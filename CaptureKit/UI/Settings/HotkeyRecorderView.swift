import AppKit
import SwiftUI

/// 快捷键录制控件（ui-design.md §11.3 快捷键设置）。
/// 点击进入录制态，捕获下一个「修饰键 + 按键」组合；Esc 取消录制。
struct HotkeyRecorderView: NSViewRepresentable {
    let descriptor: HotkeyDescriptor
    let onRecord: (HotkeyDescriptor) -> Void

    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onRecord = { recorded in
            isRecording = false
            onRecord(recorded)
        }
        view.onCancel = { isRecording = false }
        view.onBegin = { isRecording = true }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.isActive = isRecording
        if isRecording {
            // 进入录制态时成为第一响应者
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    /// 显示文本由 SwiftUI 侧统一控制（录制态/常规态）。
    final class RecorderNSView: NSView {
        var onRecord: ((HotkeyDescriptor) -> Void)?
        var onCancel: (() -> Void)?
        var onBegin: (() -> Void)?

        var isActive = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func mouseDown(with event: NSEvent) {
            onBegin?()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard isActive else {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 53: // Esc → 取消录制
                onCancel?()
            default:
                guard let descriptor = HotkeyDescriptor.fromEvent(
                    keyCode: Int(event.keyCode),
                    flags: event.modifierFlags
                ) else {
                    // 无修饰键组合：忽略（NSSound 提示）
                    NSSound.beep()
                    return
                }
                onRecord?(descriptor)
            }
        }
    }
}

/// 快捷键行：名称 + 录制按钮（显示当前组合或录制态）。
struct HotkeyRow: View {
    let title: String
    let descriptor: HotkeyDescriptor
    let onRecord: (HotkeyDescriptor) -> Void

    @State private var isRecording = false

    var body: some View {
        LabeledContent(title) {
            HotkeyRecorderView(descriptor: descriptor, onRecord: onRecord, isRecording: $isRecording)
                .frame(width: 110, height: 24)
                .overlay {
                    // 事件捕获层之上绘制显示效果
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                    Text(isRecording ? "按下新组合…" : descriptor.displayName)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .help("点击后录制新快捷键（需含修饰键，Esc 取消）")
        }
    }
}
