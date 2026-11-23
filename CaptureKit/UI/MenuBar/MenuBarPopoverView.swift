import SwiftUI

/// MenuBar Popover 主界面（ui-design.md §4）。
/// 「最近内容」待 Phase 5 History。
struct MenuBarPopoverView: View {
    let onRegionCapture: () -> Void
    let onRecordRegion: () -> Void
    let onFullscreenCapture: () -> Void
    let onWindowCapture: () -> Void
    let onDelayedCapture: () -> Void
    let onScrollCapture: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(spacing: 10) {
                primaryAction(
                    title: "截图",
                    subtitle: "⇧⌘A",
                    systemImage: "crop",
                    action: onRegionCapture
                )
                primaryAction(
                    title: "录制",
                    subtitle: "⇧⌘R",
                    systemImage: "record.circle",
                    action: onRecordRegion
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("快捷操作")
                row("全屏截图", systemImage: "display", action: onFullscreenCapture)
                row("窗口截图", systemImage: "macwindow", action: onWindowCapture)
                row("延时截图", systemImage: "timer", action: onDelayedCapture)
                row("滚动截图（长图）", systemImage: "arrow.up.and.down.square", action: onScrollCapture)
            }

            Divider()

            row("设置…", systemImage: "gearshape", action: onSettings)
            row("退出 CaptureKit", systemImage: "power", action: onQuit)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("CaptureKit")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                onSettings()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }

    private func primaryAction(title: String, subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }
}
