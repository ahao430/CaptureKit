接下来这份 `design.md` 会和刚才的 `plan.md` 配套，重点从产品规划转向**技术实现设计**。

我会特别把几个容易踩坑的地方写清楚：AppKit 与 SwiftUI 的边界、多显示器坐标系统、截图状态机、录制帧管线、剪贴板采集、统一内容存储，以及模块之间的依赖关系。

这份文档也会考虑 Coding Agent 的实际开发方式：先定义接口和边界，再逐步实现，避免 Agent 把所有业务逻辑堆进一个 Manager 或 ViewModel。

# CaptureKit — Technical Design

> 技术架构与模块设计文档\
> 配套文档：plan.md\
> 版本：v1.0

---

# 1. 技术设计目标

## 1.1 设计目标

CaptureKit 采用原生 macOS 技术栈，构建模块化、低资源占用、易扩展的内容捕获与复用系统。

核心技术目标：

1. 截图、录制、剪贴板采集相互独立。
2. 内容存储和历史索引统一。
3. UI 与底层业务逻辑解耦。
4. 采集、处理、存储采用异步流程。
5. 录制和大图处理必须控制内存。
6. 核心模块具备可测试性。
7. 所有系统 API 使用前验证最低系统版本和行为。
8. 不过度抽象，优先保证第一版可实现。

## 1.2 技术栈

| 层级       | 技术                      |
| -------- | ----------------------- |
| 语言       | Swift                   |
| App 生命周期 | AppKit                  |
| UI       | AppKit + SwiftUI        |
| 屏幕采集     | ScreenCaptureKit        |
| 图形绘制     | Core Graphics           |
| 图片处理     | Core Image / Accelerate |
| 视频处理     | AVFoundation            |
| GIF      | ImageIO                 |
| OCR      | Vision                  |
| 数据库      | SQLite                  |
| 配置       | Codable + UserDefaults  |
| 文件管理     | FileManager             |
| 日志       | OSLog                   |
| 并发       | Swift Concurrency       |

优先使用 Apple 官方 Framework。

不为简单功能引入第三方依赖。

---

# 2. 总体架构

## 2.1 分层架构

```
┌──────────────────────────────────────────┐
│                  UI Layer                │
│                                          │
│ MenuBar / Overlay / Editor / HUD         │
│ History / QuickAccess / Settings         │
└────────────────────┬─────────────────────┘
                     │
┌────────────────────▼─────────────────────┐
│              Application Layer           │
│                                          │
│ AppCoordinator                           │
│ WindowCoordinator                        │
│ CaptureCoordinator                       │
│ RecordingCoordinator                     │
│ ClipboardCoordinator                     │
│ HistoryCoordinator                       │
└────────────────────┬─────────────────────┘
                     │
┌────────────────────▼─────────────────────┐
│                Domain Layer               │
│                                          │
│ CaptureSession                            │
│ RecordingSession                          │
│ ContentItem                               │
│ Annotation                                │
│ ClipboardItem                             │
│ ExportTask                                │
└────────────────────┬─────────────────────┘
                     │
┌────────────────────▼─────────────────────┐
│               Infrastructure              │
│                                          │
│ ScreenCaptureKit / AVFoundation           │
│ NSPasteboard / CoreGraphics               │
│ SQLite / FileManager / ImageIO            │
└──────────────────────────────────────────┘
```

## 2.2 分层职责

### UI Layer

只负责：

- 展示状态。
- 接收用户操作。
- 调用业务接口。
- 展示错误。
- 管理局部 UI 状态。

禁止：

- 在 View 中直接实现屏幕采集。
- 在 View 中直接读写 SQLite。
- 在 View 中处理复杂文件生命周期。
- 在 View 中实现录制编码。
- 在 View 中直接管理剪贴板监控。

### Application Layer

负责业务流程协调。

例如：

- 启动截图流程。
- 创建 CaptureSession。
- 管理 Overlay 生命周期。
- 调用 CaptureEngine。
- 保存结果。
- 通知 History 更新。

Application Layer 不负责具体图像算法或系统 API 细节。

### Domain Layer

定义业务模型、状态和规则。

尽量不依赖 AppKit 和 SwiftUI。

### Infrastructure Layer

封装系统 API 和底层存储。

例如：

- ScreenCaptureKit。
- NSPasteboard。
- SQLite。
- AVFoundation。
- 文件系统。

---

# 3. 项目目录结构

建议初期保持单一 Xcode Project。

```
CaptureKit/
│
├── App/
│   ├── CaptureKitApp.swift
│   ├── AppDelegate.swift
│   ├── AppCoordinator.swift
│   ├── AppEnvironment.swift
│   └── AppLifecycle.swift
│
├── Core/
│   ├── Models/
│   ├── Errors/
│   ├── Events/
│   ├── State/
│   ├── Protocols/
│   ├── Utils/
│   └── Extensions/
│
├── Infrastructure/
│   ├── ScreenCapture/
│   ├── Clipboard/
│   ├── Database/
│   ├── FileSystem/
│   ├── ImageProcessing/
│   ├── VideoProcessing/
│   ├── Permissions/
│   └── Logging/
│
├── Application/
│   ├── Capture/
│   ├── Recording/
│   ├── Clipboard/
│   ├── History/
│   ├── Export/
│   └── Settings/
│
├── UI/
│   ├── MenuBar/
│   ├── Overlay/
│   ├── ScreenshotEditor/
│   ├── RecordingHUD/
│   ├── RecordingEditor/
│   ├── History/
│   ├── QuickAccess/
│   └── Settings/
│
├── Domain/
│   ├── Capture/
│   ├── Recording/
│   ├── Clipboard/
│   ├── Content/
│   ├── Annotation/
│   └── Export/
│
├── Resources/
│
└── Tests/
    ├── UnitTests/
    ├── IntegrationTests/
    └── UITests/
```

不要求一开始创建所有文件。

按照 Phase 实际开发进度逐步创建目录。

---

# 4. App 生命周期与窗口管理

## 4.1 AppLifecycle

AppLifecycle 负责：

- 应用启动。
- 初始化依赖。
- 初始化菜单栏。
- 注册快捷键。
- 加载设置。
- 初始化数据库。
- 初始化文件存储。
- 管理应用退出。

建议入口：

```
@main
struct CaptureKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
        }
    }
}
```

实际项目可以根据菜单栏应用的生命周期需求调整 Scene 配置。

## 4.2 AppDelegate

负责：

- NSStatusItem。
- Dock 图标策略。
- 应用启动与退出。
- 全局服务初始化。
- 系统通知注册。

不要让 AppDelegate 承担所有业务逻辑。

## 4.3 WindowCoordinator

统一管理窗口生命周期。

建议接口：

```
@MainActor
protocol WindowCoordinatorProtocol {
    func showMenuBarPopover()
    func showCaptureOverlay()
    func showScreenshotEditor()
    func showRecordingHUD()
    func showRecordingEditor()
    func showHistory()
    func showQuickAccess()
    func showSettings()
}
```

实际实现需要保存窗口引用，避免重复创建不必要的窗口。

需要区分：

- 独立窗口。
- 临时浮动面板。
- 全屏 Overlay。
- MenuBar Popover。

不同类型使用不同的 Window 配置。

## 4.4 窗口层级

建议：

| 窗口               | 类型                          |
| ---------------- | --------------------------- |
| MenuBar          | NSPopover                   |
| CaptureOverlay   | NSPanel / NSWindow          |
| ScreenshotEditor | NSWindow                    |
| RecordingHUD     | NSPanel                     |
| RecordingEditor  | NSWindow                    |
| History          | NSWindow                    |
| QuickAccess      | NSPanel                     |
| Settings         | NSWindow / SwiftUI Settings |

浮动面板需要谨慎设置 Window Level。

不要简单地把所有窗口设置为 floating。

尤其是：

- Overlay 需要覆盖目标屏幕。
- HUD 需要位于可见界面上方。
- 编辑器需要正常参与窗口切换。
- QuickAccess 需要响应快捷键并保持适当焦点行为。

---

# 5. 多显示器与坐标系统

这是截图模块最重要的基础设计之一。

## 5.1 坐标体系

必须区分：

1. NSScreen 坐标。
2. AppKit 全局逻辑坐标。
3. 屏幕像素坐标。
4. CGImage 像素坐标。
5. 局部 Overlay 坐标。
6. 图片 Canvas 坐标。

不能直接混用。

## 5.2 统一坐标模型

建议内部定义：

```
struct ScreenPoint {
    var x: CGFloat
    var y: CGFloat
}

struct ScreenRect {
    var origin: ScreenPoint
    var width: CGFloat
    var height: CGFloat
}

struct PixelRect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}
```

统一约定：

- Overlay 交互使用 AppKit 逻辑坐标。
- 实际图像裁剪使用像素坐标。
- 坐标转换由专门的 ScreenCoordinateConverter 负责。
- 不允许在业务代码中随意乘以 backingScaleFactor。

## 5.3 ScreenCoordinateConverter

建议接口：

```
protocol ScreenCoordinateConverter {
    func appKitToScreenPixel(
        _ rect: ScreenRect,
        screen: NSScreen
    ) -> PixelRect

    func screenPixelToAppKit(
        _ rect: PixelRect,
        screen: NSScreen
    ) -> ScreenRect
}
```

以上为接口示意，实际实现需要根据所使用的捕获 API 验证坐标原点和方向。

## 5.4 注意事项

- Retina 屏幕逻辑像素与物理像素不同。
- 多显示器可能拥有不同 backingScaleFactor。
- macOS 全局屏幕坐标存在负坐标。
- AppKit 和 Core Graphics 坐标原点可能不同。
- 不能假设所有显示器分辨率一致。
- 显示器排列变化后需要重新计算。
- 屏幕插拔需要重新获取屏幕信息。

Phase 0 必须先验证这些行为。

---

# 6. Capture 截图模块

## 6.1 模块职责

CaptureCoordinator 负责截图业务流程。

CaptureEngine 负责实际采集。

Overlay 只负责选区交互。

```
CaptureCoordinator
       │
       ├── CaptureSession
       │
       ├── OverlayManager
       │
       ├── CaptureEngine
       │      ├── RegionCapture
       │      ├── FullscreenCapture
       │      └── WindowCapture
       │
       ├── ClipboardService
       │
       └── ContentStore
```

## 6.2 CaptureSession

```
struct CaptureSession {
    let id: UUID
    let createdAt: Date
    var mode: CaptureMode
    var state: CaptureState
    var selection: CaptureSelection?
    var result: CaptureResult?
}
```

状态：

```
enum CaptureState {
    case idle
    case selecting
    case selected
    case capturing
    case completed
    case cancelled
    case failed
}
```

## 6.3 CaptureCoordinator 接口

```
@MainActor
protocol CaptureCoordinatorProtocol {
    func start(mode: CaptureMode)
    func confirmSelection()
    func cancel()
    func retry()
}
```

实际采集任务可以异步执行。

不要让整个 CaptureCoordinator 阻塞等待屏幕捕获。

## 6.4 CaptureEngine

建议抽象：

```
protocol CaptureEngineProtocol {
    func capture(
        request: CaptureRequest
    ) async throws -> CaptureResult
}
```

CaptureRequest：

```
struct CaptureRequest {
    var mode: CaptureMode
    var selection: CaptureSelection?
    var displayID: CGDirectDisplayID?
    var windowID: CGWindowID?
}
```

CaptureResult：

```
struct CaptureResult {
    var image: CGImage
    var pixelSize: CGSize
    var scale: CGFloat
    var capturedAt: Date
}
```

具体采集实现优先使用 ScreenCaptureKit。

如果不同模式需要不同系统 API，可以在 CaptureEngine 内部实现适配，不要让 UI 直接感知具体 API。

## 6.5 Overlay 状态机

```
Idle
  │
  ▼
Selecting
  │
  ├── ESC ───────────► Cancelled
  │
  ▼
Selected
  │
  ├── ESC ───────────► Selecting
  │
  ▼
Capturing
  │
  ├── Error ─────────► Failed
  │
  ▼
Completed
  │
  ▼
Editor / Export
```

Overlay 必须处理：

- 鼠标事件。
- 键盘事件。
- 窗口焦点。
- 屏幕切换。
- 选区更新。
- 窗口吸附。
- 放大镜。
- 坐标转换。

## 6.6 Overlay 实现建议

使用 AppKit 实现。

核心组件：

```
CaptureOverlayController
├── CaptureOverlayWindow
├── CaptureOverlayView
├── SelectionRenderer
├── SelectionController
├── WindowDetector
├── MagnifierView
└── CaptureToolbar
```

避免一个巨大的 NSView 承担所有职责。

Overlay 的绘制可以使用 Core Graphics。

选区数据和绘制逻辑分离。

---

# 7. Screenshot Editor 模块

## 7.1 架构

```
ScreenshotEditor
│
├── EditorCoordinator
├── Canvas
│   ├── CanvasView
│   ├── CanvasRenderer
│   └── CanvasViewport
│
├── Annotation
│   ├── AnnotationModel
│   ├── AnnotationRenderer
│   ├── AnnotationHitTester
│   └── AnnotationStore
│
├── Tools
│   ├── SelectionTool
│   ├── ArrowTool
│   ├── RectangleTool
│   ├── EllipseTool
│   ├── BrushTool
│   ├── TextTool
│   ├── MosaicTool
│   ├── BlurTool
│   ├── CropTool
│   └── NumberedMarkerTool
│
├── Inspector
├── UndoRedo
└── Export
```

## 7.2 Canvas

Canvas 负责：

- 显示原始图片。
- 显示标注。
- 缩放。
- 平移。
- 坐标转换。
- 处理鼠标事件。

建议采用分层绘制：

```
Canvas
├── Background Image
├── Committed Annotations
├── Active Annotation
├── Selection Handles
└── Interaction Overlay
```

原始图片不应该因为标注变化而重复解码和绘制。

## 7.3 Annotation Model

统一定义：

```
protocol AnnotationObject {
    var id: UUID { get }
    var type: AnnotationType { get }

    func draw(in context: CGContext)

    func hitTest(
        point: CGPoint,
        tolerance: CGFloat
    ) -> Bool
}
```

实际项目可使用值类型模型 + Renderer 的组合，不强制所有对象继承同一个引用类型。

建议：

- 模型保存几何数据。
- Renderer 负责绘制。
- HitTester 负责命中判断。
- Tool 负责用户交互。
- Inspector 负责属性修改。

## 7.4 Undo / Redo

使用 Command Pattern。

```
protocol EditorCommand {
    func execute()
    func undo()
}
```

例如：

- AddAnnotationCommand
- DeleteAnnotationCommand
- MoveAnnotationCommand
- UpdateStyleCommand
- CropImageCommand

不要简单保存每次操作的完整大图副本。

对于标注，保存操作数据即可。

对于裁剪等破坏性较大的变更，保存必要的历史状态或使用非破坏性编辑数据。

## 7.5 导出

导出时：

1. 获取原始图片。
2. 获取所有有效标注。
3. 使用统一 Renderer 合成。
4. 输出最终 CGImage。
5. 根据用户选择保存 PNG / JPEG 等格式。

复制和保存应该复用同一套渲染结果，避免两套渲染逻辑出现不一致。

---

# 8. Recording 模块

## 8.1 模块架构

```
RecordingCoordinator
       │
       ▼
RecordingSession
       │
       ▼
ScreenCaptureKit
       │
       ▼
FramePipeline
       │
       ├── VideoWriter
       │
       └── GIFEncoder
                │
                ▼
          Recording Output
                │
                ▼
          Recording Editor
```

## 8.2 RecordingSession

```
struct RecordingSession {
    let id: UUID
    let createdAt: Date
    var mode: RecordingMode
    var state: RecordingState
    var settings: RecordingSettings
    var outputURL: URL?
}
```

状态：

```
enum RecordingState {
    case idle
    case selecting
    case starting
    case recording
    case paused
    case stopping
    case completed
    case cancelled
    case failed
}
```

## 8.3 RecordingCoordinator

负责：

- 创建 Session。
- 选择录制区域。
- 启动采集。
- 暂停。
- 继续。
- 停止。
- 取消。
- 更新 HUD。
- 处理输出文件。
- 通知 History。

## 8.4 FramePipeline

FramePipeline 是录制系统的核心。

要求：

- 控制帧流。
- 控制缓存大小。
- 丢帧策略明确。
- 时间戳准确。
- 编码与采集解耦。
- 不阻塞采集回调。
- 发生背压时有明确处理。

建议采用有界缓冲队列。

不能无限制向内存中积累 CMSampleBuffer 或 CGImage。

## 8.5 VideoWriter

使用 AVFoundation。

建议使用：

- AVAssetWriter。
- AVAssetWriterInput。
- Pixel Buffer。
- CMSampleBuffer 时间戳。

根据录制模式决定是否包含音频。

录制结束后正确完成写入和资源释放。

## 8.6 GIFEncoder

使用 ImageIO。

设计要求：

- 逐帧处理。
- 控制帧率。
- 控制尺寸。
- 控制颜色数量。
- 支持无限循环。
- 支持临时文件。
- 不长期保存所有完整帧。

GIF 导出需要关注：

- 帧间延迟。
- 调色板。
- 透明度。
- 文件大小。
- 颜色抖动。
- 帧重复优化。

## 8.7 Recording HUD 排除

必须验证 ScreenCaptureKit 的捕获过滤能力。

建议：

- HUD 使用独立窗口。
- 尽量通过 SCContentFilter 排除自身窗口。
- 录制区域变化时重新验证过滤条件。
- 不依赖简单隐藏 HUD 作为唯一解决方案。

---

# 9. Clipboard 模块

## 9.1 模块架构

```
ClipboardCoordinator
       │
       ▼
ClipboardMonitor
       │
       ▼
ClipboardReader
       │
       ▼
ClipboardClassifier
       │
       ▼
ClipboardFilter
       │
       ▼
ClipboardDeduplicator
       │
       ▼
ContentStore
```

## 9.2 ClipboardMonitor

使用 NSPasteboard.general。

通过 changeCount 判断剪贴板是否发生变化。

建议接口：

```
@MainActor
protocol ClipboardMonitorProtocol {
    func start()
    func stop()
    func pause()
    func resume()
}
```

要求：

- 监控状态可控。
- 不无限制高频轮询。
- 支持应用生命周期。
- 支持用户主动暂停。
- 不在主线程处理大文件。
- 处理重复事件。
- 处理读取失败。

监控策略应考虑 macOS 的隐私提示与用户预期。

不要假设所有系统版本上的剪贴板访问行为完全一致。

## 9.3 ClipboardReader

负责读取 Pasteboard Items。

需要支持：

- String。
- URL。
- Image。
- File URL。
- RTF。
- HTML。
- 多 Item。

对于不同 representation，优先保留可以恢复原始内容的类型。

不要只读取一个字符串就认为已经完成内容采集。

## 9.4 ClipboardClassifier

分类优先级：

1. 文件。
2. 图片。
3. URL。
4. 富文本。
5. 纯文本。
6. 其他内容。

分类规则应该允许多类型信息共存。

例如一条剪贴板记录可能同时拥有 HTML、纯文本和 RTF representation。

## 9.5 ClipboardFilter

负责：

- 应用排除。
- 用户排除规则。
- 敏感内容检测。
- 空内容过滤。
- 无效内容过滤。

敏感内容检测仅作为辅助保护，不能作为安全保证。

## 9.6 ClipboardDeduplicator

第一版建议使用内容哈希。

图片可以基于实际内容计算 Hash。

文本可以基于规范化内容计算 Hash，但应谨慎处理大小写、空白和富文本语义。

重复内容策略：

- 同一内容短时间内重复变化，可以更新最近时间。
- 已有内容重新复制，可以更新最近使用时间。
- 不要简单删除所有历史重复项。
- Pin 内容优先保留。

## 9.7 QuickAccessPanel

QuickAccessPanel 不直接访问 NSPasteboard 历史数据。

它只调用 ClipboardHistoryRepository。

主要流程：

```
快捷键
  ↓
显示 QuickAccessPanel
  ↓
加载最近内容
  ↓
搜索 / 选择
  ↓
恢复到系统剪贴板
  ↓
模拟或执行用户粘贴操作
  ↓
关闭面板
```

建议第一版只执行复制回系统剪贴板，由用户自行粘贴。

不要默认模拟键盘快捷键向其他应用输入内容。

---

# 10. Content Store 与 History

## 10.1 核心原则

Capture、Recording、Clipboard 是不同的数据来源。

但最终产生的内容可以进入统一存储和历史索引。

```
Capture ───────┐
Recording ─────┼──► ContentStore ──► History
Clipboard ─────┘                       │
                                      ├── HistoryWindow
                                      └── QuickAccess
```

## 10.2 Content Model

建议：

```
struct ContentItem {
    let id: UUID
    var type: ContentType
    var createdAt: Date
    var updatedAt: Date
    var storagePath: URL?
    var thumbnailPath: URL?
    var textContent: String?
    var metadata: ContentMetadata
    var isPinned: Bool
}
```

注意：

`ContentMetadata` 应采用类型化数据，而不是把所有属性塞入 `[String: String]`。

例如：

```
enum ContentMetadata {
    case screenshot(ScreenshotMetadata)
    case recording(RecordingMetadata)
    case clipboard(ClipboardMetadata)
}
```

## 10.3 内容来源关联

建议独立设计来源关系：

```
struct ContentSourceRelation {
    let contentID: UUID
    let sourceType: ContentSourceType
    let sourceID: UUID?
    let createdAt: Date
}
```

这样可以表达：

- 一张截图被复制到剪贴板。
- 一张图片通过剪贴板导入。
- 一个视频由录制产生。
- 一个文件通过剪贴板引用。

不需要强制一个内容只有一个来源。

## 10.4 Repository

建议接口：

```
protocol ContentRepository {
    func insert(_ item: ContentItem) async throws

    func fetch(
        query: ContentQuery
    ) async throws -> [ContentItem]

    func delete(id: UUID) async throws

    func update(_ item: ContentItem) async throws

    func setPinned(
        id: UUID,
        pinned: Bool
    ) async throws
}
```

## 10.5 数据库表建议

第一版可以包含：

### contents

- id
- type
- created_at
- updated_at
- storage_path
- thumbnail_path
- text_content
- metadata_json
- is_pinned

### content_sources

- id
- content_id
- source_type
- source_id
- created_at

### clipboard_metadata

- content_id
- original_type
- application_bundle_id
- content_hash

### annotations

- id
- content_id
- type
- geometry_json
- style_json

### settings

- key
- value

实际表结构根据实现需要调整。

数据库升级必须提供 migration 机制。

## 10.6 ContentStore

ContentStore 负责：

- 文件写入。
- 文件读取。
- 缩略图管理。
- 删除。
- 生命周期管理。
- 缓存管理。
- 存储路径安全。

文件写入应先写临时文件，完成后再原子移动到最终位置。

避免数据库已经记录成功，但文件实际没有写入的情况。

建议使用明确的失败恢复策略。

---

# 11. Export 模块

ExportCoordinator 负责统一导出流程。

支持：

- PNG。
- JPEG。
- GIF。
- MP4。

不同格式由不同 Exporter 实现。

```
protocol ContentExporter {
    func export(
        request: ExportRequest
    ) async throws -> ExportResult
}
```

导出任务应该支持：

- 用户指定路径。
- 文件覆盖确认。
- 格式参数。
- 导出进度。
- 取消。
- 错误提示。

导出不应该直接写入 ContentStore 的内部目录，除非该操作明确属于历史素材保存。

---

# 12. Settings 模块

## 12.1 配置存储

简单配置使用 UserDefaults。

复杂配置使用 Codable。

避免把大量配置散落在各个 View 中。

建议：

```
struct AppSettings: Codable {
    var general: GeneralSettings
    var capture: CaptureSettings
    var recording: RecordingSettings
    var clipboard: ClipboardSettings
    var storage: StorageSettings
    var hotkeys: HotkeySettings
}
```

## 12.2 设置模块职责

- 加载配置。
- 修改配置。
- 保存配置。
- 提供默认值。
- 配置迁移。
- 通知相关模块配置变化。

配置发生变化时，相关模块应通过明确接口更新，而不是全局随意读取 UserDefaults。

---

# 13. 并发与线程模型

## 13.1 总体原则

- UI 状态只在 MainActor 更新。
- 图像处理尽量放在后台。
- 文件 I/O 放在后台。
- 数据库操作放在专用执行上下文。
- ScreenCaptureKit 回调不能执行耗时工作。
- 录制编码不能阻塞帧采集。
- 避免无界 Task 创建。

## 13.2 建议职责

| 模块                 | 执行上下文        |
| ------------------ | ------------ |
| WindowManager      | MainActor    |
| Overlay UI         | MainActor    |
| Editor UI          | MainActor    |
| CaptureCoordinator | MainActor 协调 |
| ScreenCapture      | 异步任务         |
| ImageProcessing    | 后台           |
| Recording Pipeline | 独立有界队列       |
| GIF Encoding       | 后台           |
| Clipboard Monitor  | 独立监控逻辑       |
| Database           | 专用数据库执行上下文   |
| File Storage       | 后台           |

不要为了形式而给每个模块创建一个 Actor。

只有存在明确共享可变状态或并发安全需求时才使用 Actor。

## 13.3 取消机制

以下操作需要支持取消：

- 截图。
- 录制。
- GIF 编码。
- 图片导出。
- 视频导出。
- 历史搜索。
- OCR。
- 自动清理。

异步任务需要处理：

- Task cancellation。
- 资源释放。
- 临时文件清理。
- 状态恢复。

---

# 14. 事件与模块通信

模块之间不要直接依赖对方的 UI。

建议通过 Coordinator 和明确的协议通信。

重要事件：

```
enum CaptureKitEvent {
    case captureCompleted(UUID)
    case captureFailed(UUID, Error)
    case recordingStarted(UUID)
    case recordingCompleted(UUID)
    case clipboardItemAdded(UUID)
    case contentDeleted(UUID)
    case settingsChanged
}
```

可以使用 AsyncStream、闭包或轻量事件机制。

第一版不需要建立复杂的全局 EventBus。

优先使用显式依赖注入和明确的调用关系。

---

# 15. 权限管理

建立统一 PermissionManager。

需要管理：

- Screen Recording。
- 麦克风。
- 文件访问（必要时）。

建议：

```
enum PermissionType {
    case screenRecording
    case microphone
}

enum PermissionStatus {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unknown
}
```

具体系统 API 可能无法提供所有权限的精确实时状态，应按系统实际能力实现，不要虚构授权状态。

权限流程：

```
用户操作
  ↓
检查权限
  ↓
已授权 ───► 执行功能
  │
  未授权
  ↓
解释原因
  ↓
引导系统设置
  ↓
用户返回应用
  ↓
重新检测
```

---

# 16. 日志与错误处理

## 16.1 Logging

使用 OSLog。

日志分类：

- app
- capture
- overlay
- recording
- clipboard
- storage
- editor
- export
- permission

不要把剪贴板正文、Token、密码等敏感内容写入日志。

## 16.2 错误模型

建议：

```
enum CaptureKitError: Error {
    case permissionDenied
    case captureFailed
    case recordingFailed
    case exportFailed
    case storageFailed
    case invalidSelection
    case unsupportedFormat
    case insufficientDiskSpace
    case cancelled
}
```

各模块可以拥有更具体的错误类型。

UI 层将底层错误转换为用户可理解的提示。

不要直接向用户显示原始系统错误堆栈。

---

# 17. 测试策略

## 17.1 Unit Tests

优先测试：

- 坐标转换。
- Annotation 几何计算。
- HitTest。
- Undo / Redo。
- 内容分类。
- 内容去重。
- 数据库 Repository。
- 文件生命周期。
- Settings 编解码。
- GIF 参数计算。

## 17.2 Integration Tests

测试：

- ScreenCaptureKit 捕获。
- 截图写入 ContentStore。
- 编辑结果导出。
- 录制输出文件。
- GIF 输出。
- 剪贴板读取和恢复。
- 数据库与文件同步。
- 自动清理。

## 17.3 UI Tests

测试：

- MenuBar 入口。
- Overlay 选区。
- 编辑器基本操作。
- History 搜索。
- QuickAccess 复制。
- Settings 修改。

## 17.4 真机测试

必须在实际 macOS 设备测试：

- M1 Mac。
- Retina。
- 外接显示器。
- 不同缩放比例。
- 多屏幕。
- 权限撤销。
- 长时间录制。
- 大图片编辑。
- 高密度剪贴板内容。

---

# 18. 技术风险与验证顺序

以下功能不能仅靠代码结构设计解决，需要先做技术验证。

| 项目               | 验证重点           | 优先级 |
| ---------------- | -------------- | --- |
| ScreenCaptureKit | 区域、窗口、屏幕捕获     | 最高  |
| 多显示器             | 坐标和缩放转换        | 最高  |
| Overlay          | 窗口层级与鼠标交互      | 最高  |
| 全局快捷键            | 注册与冲突          | 高   |
| Editor           | 大图渲染和命中测试      | 高   |
| GIF              | 内存和编码性能        | 高   |
| Video            | 长时间录制          | 高   |
| HUD 排除           | Capture Filter | 高   |
| Clipboard        | 变化检测与恢复        | 高   |
| Scroll Capture   | 匹配与拼接          | 中   |
| OCR              | 识别和搜索          | 低   |

---

# 19. 最低系统版本策略

项目正式开始前必须确定最低 macOS 版本。

不能在未验证 API 可用性的情况下直接锁定部署版本。

建议：

1. 先以目标 M1 设备当前使用的 macOS 版本验证核心 API。
2. 核查 ScreenCaptureKit 的 API 可用版本。
3. 核查相关音频采集能力。
4. 核查 SwiftUI 和 AppKit 相关 API。
5. 决定最低部署版本。
6. 对较新系统 API 使用 availability 检查。

不要为了支持很老的系统而过早增加大量兼容代码。

---

# 20. Phase 0 技术验证实施方案

第一阶段先创建最小可运行工程。

## Task 1：项目初始化

- 创建 CaptureKit Xcode Project。
- 配置 Swift。
- 配置 Bundle Identifier。
- 配置最低部署版本。
- 建立目录结构。
- 建立 OSLog。

## Task 2：菜单栏

- 创建 NSStatusItem。
- 显示菜单栏图标。
- 创建 Popover。
- 关闭 Dock 图标。
- 测试应用启动和退出。

## Task 3：快捷键

- 实现全局快捷键注册。
- 实现注销。
- 实现冲突检测。
- 实现快捷键配置模型。

## Task 4：权限

- 检测屏幕捕获权限。
- 引导授权。
- 测试授权成功和失败。

## Task 5：ScreenCaptureKit

- 获取可用显示器。
- 获取可用窗口。
- 捕获全屏。
- 捕获窗口。
- 捕获指定区域。
- 保存 PNG。
- 复制到剪贴板。

## Task 6：多显示器

- 单显示器。
- 双显示器。
- 不同分辨率。
- 不同缩放。
- 负坐标。
- 显示器插拔。

## Task 7：验证报告

记录：

- API 使用方式。
- 权限行为。
- 坐标转换规则。
- 系统版本要求。
- 性能表现。
- 已知限制。
- 后续架构调整建议。

Phase 0 验收通过后才进入 Phase 1。

---

# 21. Coding Agent 实施约束

## 21.1 架构约束

- UI 不直接调用系统采集 API。
- View 不直接访问数据库。
- 不允许把所有逻辑塞进 AppDelegate。
- 不允许一个 Manager 承担所有模块职责。
- 不要在没有实际需求时引入复杂依赖注入框架。
- 不要为了未来可能的功能提前实现过度抽象。
- 模块间使用协议或明确的调用接口。

## 21.2 API 使用约束

使用 Apple Framework 前：

1. 确认 API 名称。
2. 确认系统版本。
3. 确认权限要求。
4. 确认线程要求。
5. 确认资源生命周期。
6. 验证真实运行行为。

不允许编造 API。

## 21.3 代码质量

- 优先使用 async/await。
- 避免不必要的回调嵌套。
- 明确处理 Task cancellation。
- 避免强引用循环。
- 对共享可变状态明确隔离。
- 对文件资源及时释放。
- 对临时文件提供清理机制。
- 避免主线程执行耗时操作。

## 21.4 开发方式

每次开发：

1. 明确目标。
2. 阅读现有代码。
3. 检查相关接口。
4. 设计最小改动。
5. 实现。
6. 编译。
7. 测试。
8. 更新文档。
9. 汇报结果。

一个任务只解决一个明确问题。

不要一次性开发多个大型模块。

---

# 22. 最终架构原则

CaptureKit 的架构始终围绕三个独立的内容获取模块：

- Capture：捕获屏幕。
- Recording：捕获动态内容。
- Clipboard：捕获复制内容。

三个模块共享：

- Content Model。
- Content Store。
- History。
- Search。
- Export。
- Settings。

编辑器和快速访问面板是不同的内容消费入口。

最终结构：

```
             CaptureKit
                 │
       ┌─────────┼─────────┐
       │         │         │
    Capture  Recording  Clipboard
       │         │         │
       └─────────┼─────────┘
                 │
            ContentStore
                 │
          ┌──────┴──────┐
          │             │
        History      Search
          │             │
          └──────┬──────┘
                 │
       ┌─────────┴─────────┐
       │                   │
    Editor            QuickAccess
       │                   │
       └─────────┬─────────┘
                 │
               Export
```

架构核心：

**采集模块独立，内容存储统一，UI 入口按场景拆分。**

不要让统一架构变成统一大模块。

CaptureKit 应该先是一款优秀的截图工具，然后逐步成为可靠的 macOS 内容捕获与复用工具。



## **这份设计文档里，我特别建议 Agent 注意三个地方**

1. **坐标转换要先验证。** M1 外接显示器、Retina、负坐标很容易让截图选区出现偏差。不要先把 Overlay 做漂亮再处理坐标。
2. **录制不能无限缓存帧。** 采集、编码、写盘必须有明确的缓冲边界和背压策略。
3. **剪贴板历史不是简单轮询加数据库。** 必须先设计隐私开关、应用排除、Pasteboard 多 representation 和恢复机制。

## **接下来建议的文档结构**

```
CaptureKit/
├── plan.md
├── design.md
├── ui-design.md
├── README.md
├── docs/
│   ├── architecture-decisions.md
│   ├── phase-0-validation.md
│   └── development-progress.md
└── CaptureKit.xcodeproj
```

其中 `architecture-decisions.md` 可以记录关键技术决策及原因，避免后续 Agent 擅自更改架构。

**我的建议是先不要急着继续扩充功能文档，下一步应该完成&#x20;**`ui-design.md`**，然后让 Agent 按 Phase 0 开始搭建和验证。**
---

# 22. Build & Release（构建与发布）

> 发布策略定稿：GitHub Releases 分发 + Sparkle 自动更新 + GitHub Pages Homepage。不购买 Developer ID、不做公证。

## 22.1 分发策略

| 项目 | 方案 |
| --- | --- |
| 最低系统 | macOS 14.0 |
| CPU 架构 | Universal Binary（arm64 + x86_64） |
| 签名 | ad-hoc（`codesign --force --sign - --deep`），不做 Developer ID |
| 公证 | 不做（无 Apple Developer Program） |
| 安装包 | 单一 DMG（App + /Applications 快捷方式，`hdiutil` UDZO） |
| 发布平台 | GitHub Releases（tag `v*` 驱动，CI 自动打包上传） |
| Gatekeeper | README/Homepage 提供 `xattr -dr com.apple.quarantine /Applications/CaptureKit.app` |
| 更新包 | `CaptureKit.zip`（ditto 打包，Sparkle 安装）+ `appcast.xml`（EdDSA 签名） |
| Homepage | `docs/index.html` 经 GitHub Pages 发布，下载链接固定指向 `releases/latest/download/CaptureKit.dmg` |

**稳定资产名**：每次 Release 上传 `CaptureKit.dmg` / `CaptureKit.zip` / `appcast.xml` 三个同名附件——`latest/download/<name>` 是永久链接，Homepage 与 appcast 都无需随版本改 URL。

## 22.2 自动更新（Sparkle 2）

- 依赖：SPM `sparkle-project/Sparkle`（锁定 2.10.1），`UpdateCoordinator` 包装 `SPUStandardUpdaterController`。
- Feed：`SUFeedURL = https://github.com/ahao430/CaptureKit/releases/latest/download/appcast.xml`（Release 附件即 feed）。
- 验签：`SUPublicEDKey`（Ed25519 公钥，Info.plist）；更新包由 CI 用 EdDSA 私钥签名（`generate_appcast --ed-key-file -`，密钥存 GitHub Secret `SPARKLE_PRIVATE_KEY`）。
- 节奏：启动后 Sparkle 自查 + `SUScheduledCheckInterval = 86400`（24h）；安装需用户确认（`SUAutomaticallyUpdate = false`）；系统剖析关闭（`SUEnableSystemProfiling = false`，隐私优先）。
- 设置：设置 → 更新（自动检查开关 + 立即检查 + 当前版本）；菜单右键「检查更新…」。
- 已知边界：未公证应用更新后可能再次被 Gatekeeper 拦截，README/Homepage 注明重跑 `xattr`；Sparkle 的 EdDSA 验签 ≠ Apple 公证。

## 22.3 CI/CD（GitHub Actions）

- `.github/workflows/build.yml`：push/PR → `xcodegen` → Build + 全量测试（macos-26 runner）。
- `.github/workflows/release.yml`：推 `v*` tag → `scripts/build-release.sh`（Universal 构建 → ad-hoc 签名校验 → DMG + zip）→ `scripts/make-appcast.sh`（下载 Sparkle 官方工具 → EdDSA 签名生成 appcast，enclosure URL 用 `--download-url-prefix` 指向本 Release 附件）→ 创建 Release 上传三附件。
- 本地演练：`scripts/build-release.sh <版本> [构建号]` 全流程可脱离 CI 执行；appcast 生成用本地私钥文件 `scripts/make-appcast.sh <dir> <url-prefix> ~/.config/capturekit/sparkle_ed25519_privkey.pem`。

## 22.4 版本规范

- `CFBundleShortVersionString` = tag 版本（`v1.2.0` → `1.2.0`，CI 覆写 `MARKETING_VERSION`）。
- `CFBundleVersion` = CI run number（`CURRENT_PROJECT_VERSION`，Sparkle `sparkle:version` 比较依据，严格递增）。
- tag 必须以 `v` 开头；未打 tag 的 push 永远只构建测试、不发布。

运维操作手册见 `docs/releasing.md`（密钥生成/Secret 配置/Pages 开启/首次发布验收）。


---

# 23. macOS TCC 权限与应用身份稳定性

> 背景：v0.1.2 用户实测「授权后仍反复弹屏幕录制提示」。机制级实验（designated requirement 对比，ADR-030）确证根因为 ad-hoc 签名，本节固化身份稳定性约束与发布验收。

## 23.1 约束

- Bundle ID 固定：`com.wanghao.capturekit`，Debug/Release/CI 一致，不允许任何构建环境改动。
- 发布安装包必须用固定证书（`CaptureKit Developer`，ADR-030）签名；**禁止 ad-hoc 签名的版本对外发布**——ad-hoc 的 designated requirement 绑定单次构建的 cdhash，TCC 视每个构建为新应用。
- 不允许在业务流程中重置 TCC、跳过权限检查或吞掉捕获错误。
- 权限检查以 `CGPreflightScreenCaptureAccess` 实时查询为准（无缓存、无绕过）；提示文案必须包含「授权后需重启应用生效」（macOS 要求权限变更后重启才生效）。

## 23.2 机制实验记录（2026-11-23，`codesign -d -r-`）

| 签名 | DR | TCC 语义 |
| --- | --- | --- |
| ad-hoc（v0.1.2 实包） | `cdhash H"bbeb00ce…"` | 绑定该构建二进制；任何新构建 = 新应用 → 授权失效 |
| 证书（v0.1.4 起，两个不同构建） | `identifier "com.wanghao.capturekit" and certificate root = H"d32d7db1…"`（两者完全一致） | 同证书所有版本 = 同一应用 → 授权保留 |

推论：ad-hoc 时代的每次发版必然丢授权；v0.1.4 起跨版本保留（待发布验收确认）。

## 23.3 发布验收（每次发布必测）

1. 首次授权成功。
2. 重启应用后授权保留。
3. 新版本覆盖安装后授权保留（核心项，验证签名身份未漂移）。
4. 连续截图不重复提示授权。
5. 主动撤销权限后能正确检测并提示。
6. 权限变更后提示文案包含「重启应用生效」。
