import SwiftUI

/// 编辑器主界面（ui-design.md §6.2）：
/// 顶部操作栏（工具 + Undo/Redo + OCR + 复制/保存/完成）、中央画布、底部动态 Inspector。
struct EditorContentView: View {
    @EnvironmentObject var document: EditorDocument

    let onCopy: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    @State private var isRecognizing = false
    @State private var ocrResult: String?
    @State private var ocrError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            AnnotationCanvasRepresentable(document: document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            AnnotationInspectorView()
        }
        .frame(minWidth: 680, minHeight: 460)
        .sheet(isPresented: Binding(
            get: { ocrResult != nil },
            set: { if !$0 { ocrResult = nil } }
        )) {
            OCRResultSheet(text: ocrResult ?? "") {
                ocrResult = nil
            }
        }
        .alert("识别失败", isPresented: Binding(
            get: { ocrError != nil },
            set: { if !$0 { ocrError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(ocrError ?? "")
        }
    }

    // MARK: - 顶部操作栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            toolButtons

            Divider()
                .frame(height: 20)

            undoRedoButtons

            ocrButton

            Spacer()

            Button("复制", action: onCopy)
                .keyboardShortcut("c", modifiers: .command)
            Button("保存", action: onSave)
                .keyboardShortcut("s", modifiers: .command)
            Button("完成") { onClose() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 文字识别（对裁剪后的有效图像）。
    private var ocrButton: some View {
        Button {
            runOCR()
        } label: {
            if isRecognizing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "text.viewfinder")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isRecognizing)
        .help("识别文字（Vision，本地处理）")
    }

    private func runOCR() {
        isRecognizing = true
        Task {
            defer { isRecognizing = false }
            do {
                let text = try await OCRService.recognizeText(in: document.effectiveImage)
                if text.isEmpty {
                    ocrError = "未识别到文字。"
                } else {
                    ocrResult = text
                }
            } catch {
                ocrError = error.localizedDescription
            }
        }
    }

    private var toolButtons: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                ToolButton(tool: tool)
            }
        }
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 2) {
            Button {
                document.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!document.canUndo)
            .help("撤销 (⌘Z)")

            Button {
                document.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!document.canRedo)
            .help("重做 (⌘⇧Z)")
        }
        .buttonStyle(.borderless)
    }
}

/// 工具按钮。
private struct ToolButton: View {
    @EnvironmentObject var document: EditorDocument
    let tool: EditorTool

    var body: some View {
        Button {
            document.activeTool = tool
            if tool == .select {
                document.selectedAnnotationID = nil
            }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(document.activeTool == tool ? Color.accentColor.opacity(0.22) : .clear)
                )
                .foregroundStyle(document.activeTool == tool ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help("\(tool.displayName) (\(tool.shortcutKey))")
    }
}

/// OCR 结果面板（可编辑选择、一键复制）。
private struct OCRResultSheet: View {
    let text: String
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("识别结果")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制全部", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                Button("关闭") { onClose() }
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)

            Divider()

            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 480, height: 360)
    }
}
