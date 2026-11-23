import AppKit
import SwiftUI

/// 异步缩略图视图：占位图标 → 后台解码 → 缓存命中。
/// 供 History 列表/网格与 QuickAccess 行复用。
struct AsyncThumbnailView: View {
    @EnvironmentObject var viewModel: HistoryViewModel
    let item: ContentItem
    var cornerRadius: CGFloat = 4

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: item.type.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.thumbnailPath) {
            image = await viewModel.thumbnail(for: item)
        }
    }
}
