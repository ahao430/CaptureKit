import SwiftUI

/// 动态属性面板（ui-design.md §6.5）：
/// 按当前工具/选中对象显示相关属性，不展示无关参数。
struct AnnotationInspectorView: View {
    @EnvironmentObject var document: EditorDocument

    /// 面板针对的对象类型（选中标注优先，否则当前工具）
    private var targetType: AnnotationType? {
        document.selectedAnnotation?.type ?? document.activeTool.annotationType
    }

    var body: some View {
        HStack(spacing: 16) {
            if document.activeTool == .crop {
                cropControls
            } else if let type = targetType {
                Text("\(type.displayName)属性")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .leading)

                if type != .mosaic && type != .blur {
                    ColorSwatchPicker()
                }

                if type == .rectangle || type == .ellipse {
                    strokeSlider(label: "线宽", range: 1...16, keyPath: \.lineWidth)
                    fillToggle
                } else if type == .brush || type == .arrow {
                    strokeSlider(label: "线宽", range: 1...16, keyPath: \.lineWidth)
                } else if type == .text {
                    strokeSlider(label: "字号", range: 10...72, keyPath: \.fontSize)
                } else if type == .numberedMarker {
                    strokeSlider(label: "大小", range: 14...48, keyPath: \.fontSize)
                } else if type == .mosaic {
                    strokeSlider(label: "粒度", range: 6...40, keyPath: \.mosaicGranularity)
                } else if type == .blur {
                    strokeSlider(label: "强度", range: 4...40, keyPath: \.blurRadius)
                }
            } else {
                Text("选择工具（V）可选中并调整标注")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    /// 裁剪工具属性（ui-design.md §6.5 裁剪：比例 + 确认/取消）。
    private var cropControls: some View {
        HStack(spacing: 14) {
            Text("裁剪")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("比例", selection: Binding(
                get: {
                    aspectSelection
                },
                set: { document.cropAspect = $0.aspect }
            )) {
                Text("自由").tag(AspectSelection.free)
                Text("1:1").tag(AspectSelection.ratio1x1)
                Text("4:3").tag(AspectSelection.ratio4x3)
                Text("16:9").tag(AspectSelection.ratio16x9)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            if document.cropRect != nil {
                Button("重置裁剪") {
                    document.resetCrop()
                }
                .controlSize(.small)
            }

            Text("拖出裁剪框 → ⏎ 应用 · ⎋ 取消")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private enum AspectSelection: Hashable {
        case free, ratio1x1, ratio4x3, ratio16x9

        var aspect: CGFloat? {
            switch self {
            case .free: return nil
            case .ratio1x1: return 1
            case .ratio4x3: return 4.0 / 3.0
            case .ratio16x9: return 16.0 / 9.0
            }
        }

        init(aspect: CGFloat?) {
            switch aspect {
            case nil: self = .free
            case 1: self = .ratio1x1
            case 4.0 / 3.0: self = .ratio4x3
            case 16.0 / 9.0: self = .ratio16x9
            default: self = .free
            }
        }
    }

    private var aspectSelection: AspectSelection {
        AspectSelection(aspect: document.cropAspect)
    }

    // MARK: - 控件

    private func strokeSlider(label: String, range: ClosedRange<CGFloat>, keyPath: WritableKeyPath<AnnotationStyle, CGFloat>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: {
                        document.displayStyle[keyPath: keyPath]
                    },
                    set: { newValue in
                        document.setStyleLive(displayStyleSetting(keyPath, to: newValue))
                    }
                ),
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        document.beginStyleEdit()
                    } else {
                        document.endStyleEdit()
                    }
                }
            )
            .frame(width: 120)
            Text(String(format: "%.0f", document.displayStyle[keyPath: keyPath]))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private var fillToggle: some View {
        Toggle("填充", isOn: Binding(
            get: { document.displayStyle.isFilled },
            set: { newValue in
                document.beginStyleEdit()
                document.setStyleLive(displayStyleSetting(\.isFilled, to: newValue))
                document.endStyleEdit()
            }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    private func displayStyleSetting<T>(_ keyPath: WritableKeyPath<AnnotationStyle, T>, to value: T) -> AnnotationStyle {
        var style = document.displayStyle
        style[keyPath: keyPath] = value
        return style
    }
}

/// 颜色色板（8 色，ui-design.md §2.1）。
struct ColorSwatchPicker: View {
    @EnvironmentObject var document: EditorDocument

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationColor.allCases, id: \.rawValue) { color in
                Button {
                    document.beginStyleEdit()
                    var style = document.displayStyle
                    style.color = color
                    document.setStyleLive(style)
                    document.endStyleEdit()
                } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 16, height: 16)
                        .overlay {
                            if document.displayStyle.color == color {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color.rawValue.capitalized)
            }
        }
    }
}
