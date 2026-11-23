import AVFoundation
import AVKit
import CoreMedia
import SwiftUI

/// 录制编辑器视图模型（plan.md §2.6.6 P0）。
@MainActor
final class RecordingEditorViewModel: ObservableObject {
    enum Format: String, CaseIterable, Identifiable {
        case mp4 = "MP4"
        case gif = "GIF"
        var id: String { rawValue }
    }

    enum SizePreset: String, CaseIterable, Identifiable {
        case original = "原始尺寸"
        case p720 = "720p"
        case p1080 = "1080p"
        case p480 = "480p"

        var id: String { rawValue }

        /// mp4 导出 preset。
        var exportPreset: String {
            switch self {
            case .original: return AVAssetExportPresetPassthrough
            case .p720: return AVAssetExportPreset1280x720
            case .p1080: return AVAssetExportPreset1920x1080
            case .p480: return AVAssetExportPreset640x480
            }
        }

        /// GIF 最大宽度。
        var gifMaxWidth: Int {
            switch self {
            case .original: return 1920
            case .p1080: return 1080
            case .p720: return 720
            case .p480: return 480
            }
        }
    }

    let sourceURL: URL
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    @Published var exportFormat: Format = .mp4
    @Published var sizePreset: SizePreset = .original
    @Published var gifFPS: Int = 15
    /// 播放速度（1.0 正常；Phase 6 速度调节）
    @Published var playbackSpeed: Double = 1.0
    @Published var isExporting = false

    // MARK: - 删帧编辑（GIF，plan.md §2.6.6 P1）
    @Published var exclusions = FrameExclusions()
    @Published private(set) var filmstrip: [FilmCell] = []

    struct FilmCell {
        let time: Double
        let image: NSImage?
    }

    /// 扣除删帧后的有效导出时长。
    var effectiveExportDuration: Double {
        trimDuration - exclusions.clipped(lower: trimStart, upper: trimEnd).totalExcludedDuration
    }
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?
    @Published var errorMessage: String?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    var trimDuration: Double { max(0, trimEnd - trimStart) }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        player = AVPlayer(url: sourceURL)
        Task {
            await loadDuration()
            await loadFilmstrip()
        }
        installObservers()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func loadDuration() async {
        let asset = AVURLAsset(url: sourceURL)
        if let seconds = try? await asset.load(.duration).seconds {
            duration = max(0, seconds)
            trimStart = 0
            trimEnd = duration
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            sourceDimensions = "\(Int(size.width)) × \(Int(size.height))"
        }
    }

    /// 加载胶片条（20 格均匀抽帧，后台 AVAssetImageGenerator）。
    func loadFilmstrip() async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.maximumSize = CGSize(width: 120, height: 120)
        generator.appliesPreferredTrackTransform = true
        let count = 20
        let duration = self.duration
        let cells: [FilmCell] = await Task.detached(priority: .utility) {
            var result: [FilmCell] = []
            for index in 0..<count {
                let time = duration * (Double(index) + 0.5) / Double(count)
                if let cg = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) {
                    result.append(FilmCell(time: time, image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))))
                } else {
                    result.append(FilmCell(time: time, image: nil))
                }
            }
            return result
        }.value
        filmstrip = cells
    }

    /// 切换第 index 格的排除状态（格 = 源时间轴均匀分段）。
    func toggleFilmstripCell(_ index: Int) {
        let count = filmstrip.count
        guard count > 0, index >= 0, index < count else { return }
        let start = duration * Double(index) / Double(count)
        let end = duration * Double(index + 1) / Double(count)
        exclusions.toggle(ExcludedRange(start: start, end: end))
    }

    func isFilmstripCellExcluded(_ index: Int) -> Bool {
        guard index < filmstrip.count else { return false }
        return exclusions.isExcluded(filmstrip[index].time)
    }

    @Published var sourceDimensions: String = ""

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                // 预览循环：播放到裁剪终点 → 回到起点
                if self.isPlaying, self.trimEnd > 0, self.currentTime >= self.trimEnd - 0.05 {
                    self.seek(to: self.trimStart)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    // MARK: - 播放控制

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime < trimStart || currentTime >= trimEnd - 0.05 {
                seek(to: trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
    }

    func setTrimStart(_ seconds: Double) {
        trimStart = min(max(0, seconds), trimEnd - 0.1)
        if currentTime < trimStart { seek(to: trimStart) }
    }

    func setTrimEnd(_ seconds: Double) {
        trimEnd = max(min(duration, seconds), trimStart + 0.1)
        if currentTime > trimEnd { seek(to: trimStart) }
    }

    // MARK: - 导出

    func export(onSaved: @escaping (URL) -> Void) {
        guard !isExporting else { return }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = exportFormat == .mp4 ? [.mpeg4Movie] : [.gif]
        panel.nameFieldStringValue = defaultExportName()
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.runExport(to: url, onSaved: onSaved) }
        }
    }

    private func runExport(to destination: URL, onSaved: @escaping (URL) -> Void) async {
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        defer { isExporting = false }

        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: trimDuration, preferredTimescale: 600)
        )

        do {
            let url: URL
            switch exportFormat {
            case .mp4:
                url = try await VideoExporter.exportMP4(
                    from: sourceURL,
                    to: destination,
                    timeRange: range,
                    preset: sizePreset.exportPreset,
                    speed: playbackSpeed
                )
            case .gif:
                url = try await VideoExporter.exportGIF(
                    from: sourceURL,
                    to: destination,
                    timeRange: range,
                    fps: gifFPS,
                    maxPixelWidth: sizePreset.gifMaxWidth,
                    speed: playbackSpeed,
                    exclusions: exclusions.clipped(lower: trimStart, upper: trimEnd)
                ) { [weak self] progress in
                    self?.exportProgress = progress
                }
            }
            exportedURL = url
            onSaved(url)
        } catch {
            errorMessage = (error as? VideoExporter.ExportError).map { "\($0)" } ?? error.localizedDescription
        }
    }

    private func defaultExportName() -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = exportFormat == .mp4 ? "trimmed.mp4" : "trimmed.gif"
        return "\(base)-\(suffix)"
    }

    static func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let tenths = Int((max(0, seconds) - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", total / 60, total % 60, tenths)
    }
}

/// 录制编辑器主界面（ui-design.md §8）。
struct RecordingEditorView: View {
    @EnvironmentObject var viewModel: RecordingEditorViewModel
    let onRevealInFinder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            playerSection
            Divider()
            timelineSection
            if viewModel.exportFormat == .gif {
                Divider()
                filmstripSection
            }
            Divider()
            exportSection
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    /// 胶片条（删帧编辑）：点击格子切换排除该时间段。
    private var filmstripSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("删帧（点按格子移除对应片段）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !viewModel.exclusions.isEmpty {
                    Text(String(format: "已移除 %.1fs", viewModel.exclusions.totalExcludedDuration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.orange)
                    Button("清空") {
                        viewModel.exclusions = FrameExclusions()
                    }
                    .controlSize(.mini)
                }
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(viewModel.filmstrip.enumerated()), id: \.offset) { index, cell in
                        FilmstripCellView(image: cell.image, excluded: viewModel.isFilmstripCellExcluded(index)) {
                            viewModel.toggleFilmstripCell(index)
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 预览

    private var playerSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.sourceURL.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                Text(viewModel.sourceDimensions)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onRevealInFinder()
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            PlayerContainerView(player: viewModel.player)
                .background(Color.black)
                .overlay {
                    if viewModel.isExporting {
                        exportingOverlay
                    }
                }
        }
        .frame(maxHeight: .infinity)
    }

    private var exportingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView(value: viewModel.exportFormat == .gif ? viewModel.exportProgress : nil)
                .frame(width: 200)
            Text(viewModel.exportFormat == .gif ? "正在编码 GIF \(Int(viewModel.exportProgress * 100))%" : "正在导出…")
                .font(.system(size: 12))
                .foregroundStyle(.white)
        }
        .padding(16)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 时间轴

    private var timelineSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    viewModel.togglePlay()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                Text(Self.timeLabel(viewModel.currentTime, duration: viewModel.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                TrimTimelineView(
                    duration: viewModel.duration,
                    trimStart: $viewModel.trimStart,
                    trimEnd: $viewModel.trimEnd,
                    currentTime: viewModel.currentTime,
                    onSeek: { viewModel.seek(to: $0) },
                    onChangeStart: { viewModel.setTrimStart($0) },
                    onChangeEnd: { viewModel.setTrimEnd($0) }
                )
                .frame(height: 28)

                Text("裁剪 \(RecordingEditorViewModel.timeString(viewModel.trimDuration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    static func timeLabel(_ current: Double, duration: Double) -> String {
        "\(RecordingEditorViewModel.timeString(current)) / \(RecordingEditorViewModel.timeString(duration))"
    }

    // MARK: - 导出

    private var exportSection: some View {
        HStack(spacing: 16) {
            Picker("格式", selection: $viewModel.exportFormat) {
                ForEach(RecordingEditorViewModel.Format.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            Picker("尺寸", selection: $viewModel.sizePreset) {
                ForEach(RecordingEditorViewModel.SizePreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .frame(width: 160)

            if viewModel.exportFormat == .gif {
                Picker("FPS", selection: $viewModel.gifFPS) {
                    ForEach([10, 15, 20], id: \.self) { fps in
                        Text("\(fps)").tag(fps)
                    }
                }
                .frame(width: 100)
            }

            Picker("速度", selection: $viewModel.playbackSpeed) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("1.5×").tag(1.5)
                Text("2×").tag(2.0)
            }
            .frame(width: 100)

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.export { url in
                    Task { @MainActor in
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } label: {
                if viewModel.isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("导出…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExporting
                || viewModel.trimDuration <= 0.2
                || viewModel.effectiveExportDuration <= 0.2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// AVPlayer 视图容器。
private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// 胶片条单元格：点击切换排除（排除 = 半透明遮罩 + 叉）。
private struct FilmstripCellView: View {
    let image: NSImage?
    let excluded: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "film")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if excluded {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.55))
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 56, height: 34)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help(excluded ? "点按恢复该片段" : "点按移除该片段")
    }
}

/// 双把手裁剪时间轴（plan.md §2.6.6：起点/终点/播放头）。
struct TrimTimelineView: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let currentTime: Double
    let onSeek: (Double) -> Void
    let onChangeStart: (Double) -> Void
    let onChangeEnd: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = duration > 0 ? trimStart / duration * width : 0
            let endX = duration > 0 ? trimEnd / duration * width : width
            let playX = duration > 0 ? min(max(currentTime / duration, 0), 1) * width : 0

            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 6)

                // 裁剪区间
                Capsule()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(0, endX - startX), height: 6)
                    .offset(x: startX)

                // 播放头
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: 20)
                    .offset(x: playX - 0.75)

                // 起点把手
                handle(x: startX) { deltaX in
                    onChangeStart(min(max(0, trimStart + deltaX * duration / max(1, width)), trimEnd - 0.1))
                }

                // 终点把手
                handle(x: endX) { deltaX in
                    onChangeEnd(max(min(duration, trimEnd + deltaX * duration / max(1, width)), trimStart + 0.1))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        // 点击轨道（非把手）→ 跳转播放头
                        let x = min(max(0, value.location.x), width)
                        let nearStart = abs(value.location.x - startX) < 14
                        let nearEnd = abs(value.location.x - endX) < 14
                        if !nearStart, !nearEnd {
                            onSeek(x / max(1, width) * duration)
                        }
                    }
            )
        }
    }

    private func handle(x: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 12, height: 22)
            .clipShape(Capsule())
            .offset(x: x - 6)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onDrag(value.translation.width)
                    }
            )
    }
}
