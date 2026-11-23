我把前面讨论的内容整合成一份完整的 `plan.md`，产品定位调整为 **macOS 内容捕获与复用工具**，包含截图、录屏、GIF、剪贴板管理、统一历史记录，以及技术架构和分阶段开发计划。

这份文档可以直接作为 Codex / Claude Code 的项目入口。开发策略是：先完成稳定的截图 MVP，再逐步扩展，不要求 Agent 一次性实现所有功能。

# CaptureKit — Product & Development Plan

> macOS 内容捕获与复用工具\
> Capture. Organize. Reuse.

- **项目名称**：CaptureKit
- **平台**：macOS
- **目标设备**：Apple Silicon，优先适配 M1
- **主要技术栈**：Swift、AppKit、SwiftUI、ScreenCaptureKit、AVFoundation
- **产品形态**：Menu Bar Utility
- **文档类型**：产品规划与开发实施计划
- **当前版本**：v1.0

---

# 1. 产品概述

## 1.1 产品定位

CaptureKit 是一款轻量、原生、注重效率的 macOS 内容捕获与复用工具。

它不只是截图工具，而是围绕日常工作中的内容获取、编辑、存储、检索和复用建立统一工作流。

核心能力包括：

1. 屏幕截图
2. 截图编辑与标注
3. 滚动截图
4. GIF 录制
5. 视频录制
6. 剪贴板历史管理
7. 统一内容历史记录

产品核心理念：

**捕获内容 → 编辑内容 → 管理内容 → 复用内容**

## 1.2 产品设计原则

### 轻量化

- 常驻菜单栏，不需要一直打开主窗口。
- 快捷键快速唤起。
- 操作流程尽量短。
- 不把复杂配置暴露给普通用户。
- 录制、截图、编辑等界面按需出现。

### 原生化

- 优先使用 macOS 原生 API。
- 优先适配 Apple Silicon。
- 支持 Light / Dark Mode。
- 尽可能遵循 macOS Human Interface Guidelines。
- 使用系统原生窗口、菜单、面板和控件。

### 模块化

- 截图、录制、剪贴板采集各自独立。
- 内容存储和历史索引统一。
- UI 与底层采集逻辑解耦。
- 各功能可以独立开发、测试和迭代。

### 隐私优先

- 所有内容默认保存在本地。
- 不主动上传用户内容。
- 剪贴板历史默认关闭，需要用户主动开启。
- 支持应用排除、暂停监听、自动清理。
- 敏感内容处理不能仅依赖自动识别。

## 1.3 产品范围

| 模块             | 功能         | 优先级 |
| -------------- | ---------- | --- |
| Capture        | 区域、全屏、窗口截图 | P0  |
| Editor         | 截图编辑与标注    | P0  |
| MenuBar        | 菜单栏入口      | P0  |
| Hotkeys        | 全局快捷键      | P0  |
| Settings       | 基础设置       | P0  |
| Scroll Capture | 滚动截图       | P1  |
| Recording      | 视频录制       | P1  |
| GIF            | GIF 录制与导出  | P1  |
| Clipboard      | 剪贴板历史      | P1  |
| History        | 统一内容历史     | P1  |
| Quick Access   | 快速剪贴板面板    | P1  |
| OCR            | 图片文字识别     | P2  |
| Pin            | 内容收藏       | P2  |
| Smart Search   | 智能搜索       | P3  |

---

# 2. 产品功能规划

# 2.1 MenuBar 菜单栏

CaptureKit 采用菜单栏应用形态，菜单栏是主要入口。

不需要为核心功能设计传统主窗口。

## 菜单结构

### 主操作

- 区域截图
- 全屏截图
- 窗口截图
- 滚动截图
- 延时截图
- 视频录制
- GIF 快速录制

### 内容管理

- 剪贴板历史
- 最近记录
- 打开保存目录

### 设置

- 设置
- 关于 CaptureKit
- 退出

## 视觉设计

- Popover 宽度约 300～340px。
- 截图和录制作为主要入口。
- 其他功能使用普通列表。
- 使用 SF Symbols。
- 适配系统明暗模式。
- 不在菜单栏 Popover 中堆积复杂配置。

---

# 2.2 全局快捷键

建议默认快捷键：

| 功能    | 快捷键         |
| ----- | ----------- |
| 区域截图  | `⌘ + ⇧ + A` |
| 开始录制  | `⌘ + ⇧ + R` |
| 历史记录  | `⌘ + ⇧ + H` |
| 快速剪贴板 | `⌘ + ⇧ + V` |

以上为默认建议，必须允许用户自定义。

快捷键要求：

- 支持全局注册。
- 支持冲突检测。
- 支持快捷键禁用。
- 支持恢复默认。
- 支持录入快捷键组合。
- 注册失败时提供明确反馈。
- 不得覆盖系统关键快捷键。
- 需要考虑其他应用的快捷键冲突。

快捷键主要负责唤起功能，具体模式选择可以在菜单栏和操作界面中完成。

---

# 2.3 Screenshot Capture 截图

## 2.3.1 支持模式

```
enum CaptureMode {
    case region
    case fullscreen
    case window
    case scrollingRegion
    case scrollingWindow
    case delayed
}
```

### 区域截图

- 鼠标拖拽选择区域。
- 显示选区边框。
- 支持选区调整大小。
- 支持选区移动。
- 支持窗口边缘吸附。
- 支持放大镜。
- 显示选区尺寸。
- 支持跨显示器选区。

### 全屏截图

- 捕获指定显示器。
- 支持多显示器。
- 可以从模式菜单选择显示器。
- 处理不同显示器的分辨率和缩放比例。

### 窗口截图

- 自动识别窗口。
- 鼠标悬停高亮窗口。
- 单击选择窗口。
- 支持窗口内容捕获。
- 尽量排除窗口阴影或允许用户配置。

### 延时截图

- 支持延时秒数设置。
- 倒计时提示。
- 倒计时结束自动捕获。
- 倒计时过程中允许取消。

## 2.3.2 Capture Overlay

Overlay 是 CaptureKit 的核心交互界面。

采用全屏透明窗口覆盖屏幕。

### 初始状态

- 屏幕轻微暗化。
- 显示鼠标十字准星。
- 显示坐标。
- 可选局部放大镜。
- 自动识别鼠标下方窗口。
- 支持模式切换。

### 选区状态

选区包含：

- 高亮边框。
- 8 个调整控制点。
- 尺寸信息。
- 选区移动。
- 选区缩放。
- 重新选择。
- 确认捕获。
- 取消。

### 快捷操作

| 操作          | 行为      |
| ----------- | ------- |
| ESC         | 取消      |
| Enter       | 确认      |
| 空格 + 拖动     | 移动选区    |
| 方向键         | 1px 微调  |
| Shift + 方向键 | 10px 微调 |
| 鼠标拖动        | 创建选区    |
| 双击窗口        | 捕获窗口    |

### 选区确认后的工具栏

- 重新选择
- 复制
- 编辑
- 保存
- 完成

工具栏根据屏幕空间自动调整位置，不能超出屏幕，也不能被选区裁切。

## 2.3.3 Overlay 状态机

```
Idle
  ↓
Selecting
  ↓
Selected
  ↓
Capturing
  ↓
Editing / Completed
```

异常情况：

- 任意阶段按 ESC 可以取消。
- 屏幕权限不足时提示授权。
- 捕获失败时恢复到可操作状态。
- 多显示器发生变化时重新计算坐标和覆盖层。

---

# 2.4 Screenshot Editor 截图编辑器

截图完成后默认进入编辑器，用户可以在设置中关闭自动编辑。

## 2.4.1 编辑器布局

采用：

```
┌─────────────────────────────────────┐
│ Toolbar                 Undo / Redo │
├─────────────────────────────────────┤
│                                     │
│                                     │
│             Canvas                  │
│                                     │
│                                     │
├─────────────────────────────────────┤
│         Context Inspector            │
├─────────────────────────────────────┤
│       Copy       Save       Done     │
└─────────────────────────────────────┘
```

### 顶部工具栏

工具：

- 选择
- 箭头
- 矩形
- 椭圆
- 画笔
- 文字
- 马赛克
- 模糊
- 裁剪
- 编号

### 工具快捷键

| 工具  | 快捷键    |
| --- | ------ |
| 选择  | V      |
| 箭头  | A      |
| 矩形  | R      |
| 椭圆  | O      |
| 画笔  | P      |
| 文字  | T      |
| 马赛克 | M      |
| 模糊  | B      |
| 裁剪  | C      |
| 编号  | N      |
| 删除  | Delete |
| 撤销  | ⌘ Z    |
| 重做  | ⌘ ⇧ Z  |
| 复制  | ⌘ C    |
| 保存  | ⌘ S    |

### 交互要求

- 工具选择后持续生效，直到切换。
- 绘制完成后进入对象选中状态。
- 对象可以重新选择。
- 支持移动。
- 支持缩放。
- 支持修改属性。
- 支持删除。
- 支持复制。
- 支持 Undo / Redo。
- 支持画布缩放。
- 支持画布平移。
- 双击文字进入编辑状态。

## 2.4.2 Context Inspector 动态属性面板

属性面板根据当前选中的工具或对象动态变化。

箭头：

- 颜色
- 线宽
- 箭头样式

矩形：

- 边框颜色
- 线宽
- 填充颜色
- 透明度

椭圆：

- 边框颜色
- 线宽
- 填充颜色

画笔：

- 颜色
- 线宽
- 透明度

文字：

- 字体
- 字号
- 颜色
- 粗体
- 背景
- 对齐

马赛克：

- 马赛克粒度

模糊：

- 模糊强度

裁剪：

- 裁剪范围
- 宽高比
- 确认 / 取消

编号：

- 编号颜色
- 编号大小
- 起始编号

不要同时展示所有属性。

## 2.4.3 编辑数据模型

所有标注统一抽象：

```
struct Annotation {
    var id: UUID
    var type: AnnotationType
    var geometry: AnnotationGeometry
    var style: AnnotationStyle
    var transform: CGAffineTransform
}
```

类型：

```
enum AnnotationType {
    case arrow
    case rectangle
    case ellipse
    case text
    case brush
    case mosaic
    case blur
    case numberedMarker
}
```

所有标注应支持：

- draw
- select
- move
- resize
- delete
- updateStyle
- undo
- redo

采用非破坏性编辑：

- 原始图片保持不变。
- 标注作为独立数据保存。
- 导出时合成最终图片。
- 支持未来重新编辑。

---

# 2.5 Scroll Capture 滚动截图

支持：

- 滚动区域截图。
- 滚动窗口截图。
- 自动滚动。
- 自动识别重叠区域。
- 多帧拼接。
- 长图预览。
- 手动调整拼接结果。

核心技术模块：

```
ScrollCapture
├── ScrollCoordinator
├── ScrollController
├── FrameMatcher
├── ImageStitcher
├── ScrollSession
└── ScrollPreview
```

关键技术：

- 图像特征匹配。
- 重叠区域检测。
- 帧间位移估计。
- 拼接边界处理。
- 动态内容处理。
- 失败后允许手动调整。

注意：

滚动截图存在较大技术不确定性，尤其是动态网页、固定导航栏、异步加载和复杂滚动容器。

应先实现稳定的基础拼接，再考虑复杂页面支持。

---

# 2.6 Recording 视频与 GIF 录制

## 2.6.1 统一采集系统

GIF 和视频共享底层采集系统。

```
ScreenCaptureKit
       ↓
Frame Pipeline
       ↓
Recording Session
       ↓
 ┌───────────┬───────────┐
 │ Video     │ GIF       │
 │ Encoder   │ Encoder   │
 └───────────┴───────────┘
       ↓
 Preview / Export
```

不要开发两套完全独立的屏幕采集系统。

采集层统一，编码和导出分别实现。

## 2.6.2 录制模式

```
enum RecordingMode {
    case video
    case gif
}
```

支持：

- 区域录制。
- 全屏录制。
- 窗口录制。
- GIF 快速录制。
- 视频录制。

## 2.6.3 Recording HUD

录制 HUD 是小型悬浮控制条。

默认显示：

- REC 状态。
- 录制时间。
- 暂停 / 继续。
- 停止。
- 取消。

展开后显示：

- 麦克风状态。
- 系统音频状态。
- FPS。
- 鼠标显示。
- 点击效果。

必须避免 HUD 被录入录制内容。

优先研究 ScreenCaptureKit 的内容过滤和窗口排除能力。

## 2.6.4 GIF 预设

默认提供：

| 预设  | FPS | 最大宽度   |
| --- | --- | ------ |
| 小体积 | 10  | 480px  |
| 平衡  | 15  | 720px  |
| 高清  | 20  | 1080px |
| 自定义 | 可调  | 可调     |

默认 GIF：

- 15 FPS。
- 720px 最大宽度。
- 自动颜色优化。
- 无限循环。

支持：

- 录制时长限制。
- 录制区域。
- 帧率。
- 输出尺寸。
- 颜色优化。
- 循环模式。
- 导出质量。

## 2.6.5 视频参数

支持：

- FPS。
- 分辨率。
- 视频质量。
- 音频。
- 麦克风。
- 鼠标显示。
- 点击效果。

## 2.6.6 Recording Editor

录制完成后进入预览编辑器。

布局：

```
┌───────────────────────────────────────┐
│ File Info                Undo / Redo  │
├───────────────────────────────────────┤
│                                       │
│               Preview                 │
│                                       │
├───────────────────────────────────────┤
│             Timeline                  │
│          Start / End                  │
├───────────────────────────────────────┤
│          Export Inspector             │
└───────────────────────────────────────┘
```

P0：

- 播放。
- 暂停。
- 进度拖动。
- 开始时间裁剪。
- 结束时间裁剪。
- 视频 / GIF 格式选择。
- 尺寸设置。
- FPS 设置。
- 质量设置。
- 音频开关。
- 导出。

P1：

- GIF 文件大小估算。
- 删除帧。
- 速度调节。
- 鼠标效果编辑。

录制过程必须流式写入文件或采用受控缓存，不允许无限制地将原始帧保存在内存中。

---

# 2.7 Clipboard 剪贴板历史管理

剪贴板管理是 CaptureKit 的第二条核心能力。

第一阶段只做本地剪贴板历史，不扩展成完整知识库或云同步系统。

## 2.7.1 核心功能

- 监控剪贴板变化。
- 记录文本。
- 记录图片。
- 记录 URL。
- 记录文件引用。
- 识别内容类型。
- 历史搜索。
- 点击复制。
- 删除记录。
- Pin 收藏。
- 自动清理。

## 2.7.2 内容类型

```
enum ClipboardContentType {
    case text
    case url
    case image
    case file
    case richText
    case multiple
}
```

需要考虑 NSPasteboard 的多种 representation。

不能假设每次剪贴板变化只有一种内容。

尽量保留可恢复的原始类型信息，避免复制回去时丢失格式。

## 2.7.3 采集机制

使用：

```
NSPasteboard.general
```

通过：

```
NSPasteboard.general.changeCount
```

检测剪贴板变化。

采集流程：

```
检测 changeCount
       ↓
确认内容变化
       ↓
读取 Pasteboard Items
       ↓
类型识别
       ↓
敏感内容过滤
       ↓
内容去重
       ↓
写入 Content Store
       ↓
生成缩略图
```

要求：

- 不要高频无休止轮询。
- 变化后按需读取。
- 避免重复存储相同内容。
- 避免不必要的大文件复制。
- 不能阻塞主线程。
- 支持暂停监听。
- 支持应用排除。

剪贴板历史默认关闭，用户主动开启后才开始采集。

## 2.7.4 隐私保护

这是剪贴板模块的关键要求。

支持：

- 首次启用时明确告知用户。
- 本地存储。
- 不上传内容。
- 排除指定应用。
- 手动暂停监听。
- 删除单条记录。
- 清空全部记录。
- 设置自动清理。
- 可选退出时清空。
- Pin 内容不自动清理。

敏感内容处理：

- 检测疑似 API Key。
- 检测疑似 Token。
- 检测疑似密码。
- 检测验证码等高风险内容。
- 对高风险内容默认跳过或提供可配置策略。

敏感检测不是可靠的安全边界，不能承诺完全识别。

## 2.7.5 Quick Access Panel

独立的快速剪贴板面板。

建议默认快捷键：

`⌘ + ⇧ + V`

功能：

- 搜索。
- 最近复制内容。
- 上下键选择。
- Enter 复制。
- ESC 关闭。
- 复制后自动关闭。
- 图片预览。
- Pin 收藏。
- 删除。
- 应用来源提示。

快速面板强调复用，不承担完整历史管理职责。

---

# 2.8 Unified History 统一历史记录

截图、录制和剪贴板内容统一进入 Content Store。

统一历史窗口支持：

- 全部。
- 剪贴板。
- 截图。
- 录制。

内容按时间倒序排列。

支持：

- 网格视图。
- 列表视图。
- 搜索。
- 分类过滤。
- 复制。
- 预览。
- 编辑。
- 删除。
- Finder 定位。
- Pin。

## 内容去重和关联

截图复制后可能同时触发剪贴板变化。

不应该产生两条完全重复的历史记录。

建议：

- 内容实体与来源行为分离。
- Screenshot 类型记录截图来源。
- Clipboard 事件可以关联已有内容。
- 同一内容可存在多个来源关系。
- 第一版可以采用简单的内容哈希去重。

---

# 3. UI / UX 设计规范

## 3.1 视觉定位

Minimal Utility + Floating Toolbar + Native macOS

目标：

- 简洁。
- 原生。
- 轻量。
- 专注内容。
- 操作高效。

## 3.2 Design System

| 项目     | 规范                   |
| ------ | -------------------- |
| 字体     | macOS 系统字体           |
| 图标     | SF Symbols           |
| 主色     | 系统蓝                  |
| 录制状态   | 红色                   |
| GIF 标识 | 橙色                   |
| 成功状态   | 系统绿                  |
| 圆角     | 8 / 12 / 16          |
| 间距     | 4 / 8 / 12 / 16 / 24 |
| 背景     | 系统背景材质               |
| 阴影     | 仅浮层使用                |
| 主题     | Light / Dark         |
| 动画     | 轻量、快速                |

不要过度使用透明玻璃材质。

## 3.3 界面列表

| 界面               | 类型      | 主要职责  |
| ---------------- | ------- | ----- |
| MenuBar          | Popover | 功能入口  |
| CaptureOverlay   | 全屏透明窗口  | 截图选区  |
| ScreenshotEditor | 独立窗口    | 图片标注  |
| RecordingHUD     | 浮动面板    | 录制控制  |
| RecordingEditor  | 独立窗口    | 预览与导出 |
| HistoryWindow    | 独立窗口    | 内容管理  |
| QuickAccessPanel | 浮动面板    | 快速复制  |
| SettingsWindow   | 设置窗口    | 配置    |

## 3.4 UI 交互原则

- 主要操作使用图标按钮。
- 重要操作使用文字按钮。
- 属性面板根据上下文动态变化。
- 不显示不相关的参数。
- 悬浮面板不能遮挡主要内容。
- 操作完成后尽快关闭临时窗口。
- 所有交互支持键盘操作。
- 支持系统明暗模式。
- 保证足够的颜色对比度。

---

# 4. 技术架构

## 4.1 技术选型

| 模块     | 技术                      |
| ------ | ----------------------- |
| 开发语言   | Swift                   |
| 主 UI   | AppKit                  |
| 辅助 UI  | SwiftUI                 |
| 屏幕采集   | ScreenCaptureKit        |
| 图形绘制   | Core Graphics           |
| 图像处理   | Core Image / Accelerate |
| 视频编码   | AVFoundation            |
| GIF 编码 | ImageIO                 |
| OCR    | Vision                  |
| 本地数据库  | SQLite                  |
| 配置     | Codable / UserDefaults  |
| 全局快捷键  | Carbon API 或经过验证的原生方案   |
| 文件管理   | FileManager             |
| 日志     | OSLog                   |

优先使用系统 API，避免引入不必要的第三方依赖。

## 4.2 为什么 AppKit 为主

CaptureKit 涉及大量系统级窗口操作：

- 全屏透明窗口。
- 多显示器。
- 窗口层级。
- 鼠标事件。
- 全局快捷键。
- HUD。
- 屏幕捕获。
- 面板位置控制。

这些场景优先使用 AppKit。

SwiftUI 主要用于：

- Settings。
- History。
- 普通配置界面。
- 部分列表与表单。

不要为了统一 UI 技术栈而强行使用 SwiftUI 实现所有窗口。

## 4.3 模块架构

```
CaptureKit
│
├── App
│   ├── AppDelegate
│   ├── AppLifecycle
│   ├── WindowManager
│   └── PermissionManager
│
├── Core
│   ├── Models
│   ├── Events
│   ├── State
│   ├── Session
│   ├── Storage
│   └── Utils
│
├── MenuBar
│   ├── MenuBarManager
│   └── MenuBarPopover
│
├── Hotkeys
│   ├── HotkeyManager
│   ├── HotkeyRegistration
│   └── HotkeySettings
│
├── Capture
│   ├── CaptureCoordinator
│   ├── CaptureEngine
│   ├── ScreenCapture
│   ├── WindowCapture
│   ├── RegionCapture
│   └── Overlay
│
├── ScrollCapture
│   ├── ScrollCoordinator
│   ├── ScrollController
│   ├── FrameMatcher
│   ├── ImageStitcher
│   └── ScrollPreview
│
├── Recording
│   ├── RecordingCoordinator
│   ├── RecordingSession
│   ├── RecordingHUD
│   ├── FramePipeline
│   ├── VideoEncoder
│   ├── GIFEncoder
│   └── RecordingEditor
│
├── Editor
│   ├── ScreenshotEditor
│   ├── Canvas
│   ├── Annotation
│   ├── Tools
│   ├── Inspector
│   ├── RenderEngine
│   └── UndoRedo
│
├── Clipboard
│   ├── ClipboardMonitor
│   ├── ClipboardReader
│   ├── ClipboardClassifier
│   ├── ClipboardFilter
│   ├── ClipboardDeduplicator
│   └── QuickAccessPanel
│
├── History
│   ├── HistoryManager
│   ├── HistoryWindow
│   ├── HistorySearch
│   ├── ThumbnailManager
│   └── PinManager
│
├── Content
│   ├── ContentStore
│   ├── ContentRepository
│   ├── ContentIndexer
│   └── ContentLifecycle
│
├── Export
│   ├── ImageExporter
│   ├── VideoExporter
│   └── GIFExporter
│
├── Settings
│   ├── SettingsManager
│   └── SettingsWindow
│
└── Resources
```

以上为逻辑模块划分，不要求每个目录都拆成独立 Swift Package。

第一阶段建议保持单一 Xcode Project，避免过早增加工程复杂度。

---

# 5. 核心数据模型

## 5.1 Content Model

统一内容索引，但不要强制所有内容使用相同的数据结构。

```
enum ContentType {
    case screenshot
    case scrollingScreenshot
    case gif
    case video
    case text
    case url
    case image
    case file
}
```

```
struct ContentItem {
    var id: UUID
    var type: ContentType
    var createdAt: Date
    var source: ContentSource
    var storagePath: URL?
    var thumbnailPath: URL?
    var textContent: String?
    var metadata: ContentMetadata
    var isPinned: Bool
}
```

根据类型保存专属元数据：

- ScreenshotMetadata
- RecordingMetadata
- ClipboardMetadata

建议将内容来源单独建模：

```
enum ContentSource {
    case screenshot
    case recording
    case clipboard
    case imported
}
```

必要时一个内容可以有多个来源关联，因此实际数据库可以使用 ContentSourceRelation 表。

## 5.2 CaptureSession

```
struct CaptureSession {
    var id: UUID
    var createdAt: Date
    var mode: CaptureMode
    var state: CaptureState
    var source: CaptureSource
    var result: URL?
}
```

## 5.3 RecordingSession

```
struct RecordingSession {
    var id: UUID
    var createdAt: Date
    var mode: RecordingMode
    var state: RecordingState
    var settings: RecordingSettings
    var output: URL?
}
```

## 5.4 Annotation

```
struct Annotation {
    var id: UUID
    var type: AnnotationType
    var geometry: AnnotationGeometry
    var style: AnnotationStyle
    var transform: CGAffineTransform
}
```

## 5.5 数据库建议

SQLite 负责：

- 内容索引。
- 元数据。
- 搜索字段。
- Pin 状态。
- 内容来源关联。
- 创建时间。
- 自动清理策略。

大文件不直接存数据库。

图片、视频、GIF 使用文件存储。

缩略图单独管理。

---

# 6. 文件存储规划

建议统一使用 Application Support 目录。

示意：

```
~/Library/Application Support/CaptureKit/
│
├── Database/
│   └── capturekit.sqlite
│
├── Content/
│   ├── Images/
│   ├── Videos/
│   ├── GIFs/
│   └── Clipboard/
│
├── Thumbnails/
│
├── Cache/
│
└── Temp/
```

说明：

- 数据库只保存元数据和索引。
- 图片、GIF、视频保存为文件。
- 临时帧写入 Temp。
- 导出文件由用户选择保存位置。
- 缩略图可以独立清理。
- 历史记录删除时同步处理关联文件。
- Pin 内容不参与普通自动清理。

不要无限制保存录制原始帧。

---

# 7. 权限与隐私

## 7.1 屏幕录制权限

- 使用系统屏幕捕获权限。
- 启动时检测权限状态。
- 首次使用时解释授权用途。
- 授权失败时提供系统设置入口。
- 权限变更后支持重新检测。

## 7.2 剪贴板隐私

- 默认关闭剪贴板历史。
- 用户主动开启。
- 明确说明记录内容及存储位置。
- 默认本地存储。
- 支持暂停。
- 支持应用排除。
- 支持清空历史。
- 支持自动清理。
- 敏感内容过滤。
- 不承诺自动检测能够识别所有敏感内容。

## 7.3 文件访问

- 尽量使用系统文件选择面板。
- 不申请无关的文件访问权限。
- 对外部文件使用安全作用域访问机制（需要时）。
- 不擅自复制用户所有文件到内部存储。

---

# 8. 性能与稳定性要求

目标设备优先为 M1 Mac。

## 8.1 内存管理

- 录屏必须流式写入。
- GIF 编码避免一次性加载全部原始帧。
- 图片缩放和编辑避免重复创建大尺寸 Bitmap。
- 缩略图异步生成。
- 历史列表按需加载。
- 临时资源及时释放。
- 不保留无用的完整分辨率图片副本。

## 8.2 多显示器

必须处理：

- 多屏幕。
- 不同分辨率。
- Retina。
- 不同缩放比例。
- 屏幕坐标与像素坐标转换。
- 屏幕排列变化。
- 显示器插拔。

## 8.3 错误恢复

以下情况需要明确处理：

- 屏幕权限被撤销。
- 快捷键注册失败。
- ScreenCaptureKit 启动失败。
- 录制编码失败。
- 磁盘空间不足。
- 用户取消录制。
- 数据库写入失败。
- 文件导出失败。
- 显示器配置变化。
- 应用异常退出。

---

# 9. 开发阶段规划

开发采用渐进式方式。

每个阶段必须有可运行版本和明确验收标准。

不要在基础能力没有验证的情况下同时开发多个复杂模块。

## Phase 0：技术验证

目标：验证 macOS 原生能力。

任务：

- 创建 macOS App。
- 实现菜单栏常驻。
- 隐藏 Dock 图标。
- 注册全局快捷键。
- 检测屏幕录制权限。
- 使用 ScreenCaptureKit 捕获全屏。
- 实现区域选择。
- 实现窗口捕获。
- 测试多显示器。
- 测试 Retina。

验收：

- 快捷键能够唤起截图。
- 能够跨屏选择区域。
- 能够正确捕获指定区域。
- 能够复制图片到系统剪贴板。
- 不发生明显坐标偏移。
- 权限异常有明确提示。

## Phase 1：截图 MVP

目标：完成可以日常使用的截图工具。

任务：

- MenuBar Popover。
- 全局快捷键。
- Capture Overlay。
- 区域截图。
- 全屏截图。
- 窗口截图。
- 窗口吸附。
- 选区调整。
- 放大镜。
- 复制。
- 保存。
- 基础 Settings。

验收：

- 截图流程稳定。
- 操作响应及时。
- 多显示器工作正常。
- 支持 Light / Dark Mode。
- 可以独立打包运行。

## Phase 2：Screenshot Editor

目标：完成基础图片标注。

任务：

- 编辑器窗口。
- Canvas。
- 缩放和平移。
- 选择工具。
- 箭头。
- 矩形。
- 椭圆。
- 画笔。
- 文字。
- 马赛克。
- 模糊。
- 裁剪。
- 编号。
- 动态属性面板。
- Undo / Redo。
- 复制与保存。
- 非破坏性编辑。

验收：

- 标注对象可重新选中。
- 标注对象可移动和修改。
- Undo / Redo 正确。
- 编辑不破坏原始图片。
- 导出图片与画布显示一致。

## Phase 3：Scroll Capture

目标：实现基础滚动截图。

任务：

- 滚动区域选择。
- 自动滚动。
- 帧采集。
- 重叠区域识别。
- 图片拼接。
- 长图预览。
- 人工调整。
- 长图导出。

验收：

- 常见网页可以稳定拼接。
- 拼接结果无明显重复和断层。
- 异常场景能够提示。
- 用户可以调整结果。

## Phase 4：Recording

目标：实现 GIF 和视频录制。

任务：

- ScreenCaptureKit 录制。
- 区域录制。
- 全屏录制。
- 窗口录制。
- Recording HUD。
- 暂停和继续。
- 停止。
- 视频编码。
- GIF 编码。
- 预览编辑器。
- 时间轴裁剪。
- 导出设置。
- HUD 排除。
- 内存和磁盘管理。

验收：

- 长时间录制不发生持续内存增长。
- 视频文件可以正常播放。
- GIF 文件可以正常播放。
- HUD 不会出现在录制结果中。
- 暂停、继续和停止状态正确。
- 录制异常有恢复机制。

## Phase 5：Unified History + Clipboard

目标：实现统一内容历史和剪贴板管理。

任务：

- Content Model。
- SQLite 数据库。
- Content Store。
- Clipboard Monitor。
- 文本采集。
- URL 识别。
- 图片采集。
- 文件引用。
- 类型分类。
- 内容去重。
- 缩略图生成。
- History Window。
- 分类过滤。
- 搜索。
- 复制。
- 删除。
- 自动清理。
- 快速剪贴板面板。
- 剪贴板隐私设置。
- 应用排除。

验收：

- 用户开启后才能开始记录剪贴板。
- 文本、图片、URL 可以正确恢复。
- 多 representation 不会无故丢失。
- 同一内容不会大量重复。
- 历史记录能够检索。
- 删除记录时正确处理关联资源。
- 自动清理正常。
- 暂停监听后不再新增记录。
- 快速面板可以通过快捷键唤起并复制内容。

## Phase 6：完善与增强

任务：

- Pin 收藏。
- 批量删除。
- OCR。
- OCR 搜索。
- 历史筛选增强。
- 录制质量优化。
- 滚动截图优化。
- 导出体验优化。
- 性能优化。
- 崩溃恢复。
- 自动更新机制（后续决定）。

---

# 10. MVP 范围控制

为了避免项目过大，第一版不要求所有功能同时完成。

建议 MVP：

### 必须完成

- 菜单栏常驻。
- 全局快捷键。
- 区域截图。
- 全屏截图。
- 窗口截图。
- 截图编辑。
- 复制和保存。
- 基础设置。
- 基础权限处理。

### 可以延后

- 滚动截图。
- GIF。
- 视频录制。
- 剪贴板历史。
- 快速剪贴板面板。
- OCR。
- AI 功能。
- 云同步。
- 智能整理。

统一 Content Store 和 History 的数据模型应提前设计，但不应因此阻塞截图 MVP。

---

# 11. 非功能性要求

## 稳定性

- 不因单次截图失败导致应用退出。
- 录制异常能够安全结束。
- 数据库异常不影响截图主流程。
- 权限被撤销时能够恢复。

## 性能

- 菜单栏启动快速。
- Overlay 唤起迅速。
- 截图操作响应及时。
- 历史列表按需加载。
- 大图编辑避免不必要的全量重绘。
- 长时间录制采用流式处理。

## 可维护性

- 模块职责清晰。
- 不允许 View 直接承担采集业务逻辑。
- 核心流程有明确状态机。
- 关键模块提供日志。
- 核心数据模型可测试。
- 重要逻辑有单元测试。

---

# 12. Coding Agent 开发规范

本项目会通过 Codex / Claude Code 等 Coding Agent 辅助开发。

必须遵守以下原则。

## 12.1 开发前

开始任务前：

1. 阅读项目 README。
2. 阅读 plan.md。
3. 阅读当前架构文档。
4. 检查已有代码。
5. 确认当前阶段。
6. 不重复实现已有功能。
7. 对有不确定性的系统 API 先验证。

不要直接根据文档假设 API 一定可用。

需要查阅 Apple 官方文档，确认 API 的系统版本要求、权限和限制。

## 12.2 开发过程中

- 优先完成小而完整的功能。
- 每个功能尽量独立。
- 不要一次性修改大量无关模块。
- 不要为了抽象而过度设计。
- 不引入不必要的依赖。
- 不要随意改变已经稳定的架构。
- 不要用模拟实现冒充真实功能。
- 复杂功能先做技术验证。
- 所有异步操作考虑取消和错误处理。
- 避免主线程执行耗时任务。

## 12.3 完成任务后

必须：

- 编译项目。
- 修复新增编译错误。
- 运行相关测试。
- 检查功能流程。
- 检查权限和异常处理。
- 更新必要文档。
- 说明修改内容。
- 说明已知问题。
- 标注尚未实现的部分。

## 12.4 任务管理

每个 Phase 应拆分为可独立验收的任务。

任务状态：

- Todo
- In Progress
- Blocked
- Done

不要在前一阶段核心验收失败时直接进入下一阶段。

---

# 13. 风险清单

| 风险        | 影响     | 应对方式                |
| --------- | ------ | ------------------- |
| 多显示器坐标转换  | 截图位置错误 | 早期验证                |
| Retina 缩放 | 图片尺寸错误 | 统一坐标模型              |
| 屏幕权限      | 无法捕获   | 权限状态管理              |
| 窗口捕获      | 窗口识别异常 | ScreenCaptureKit 验证 |
| 滚动拼接      | 长图错位   | 独立技术验证              |
| GIF 内存    | 内存占用过高 | 流式编码                |
| 视频长录制     | 内存增长   | 文件流式写入              |
| HUD 被录入   | 录制结果异常 | Capture Filter      |
| 大图编辑      | UI 卡顿  | 分层渲染、缓存             |
| 剪贴板敏感信息   | 隐私泄漏   | 默认关闭、过滤、排除          |
| 剪贴板去重     | 历史重复   | 内容哈希和来源关联           |
| 文件存储膨胀    | 磁盘占用   | 自动清理和配额             |

---

# 14. 项目成功标准

CaptureKit 第一阶段的成功标准不是功能数量，而是核心体验足够稳定。

## 截图

- 快捷键唤起可靠。
- 选区操作自然。
- 多显示器正常。
- 截图质量正确。
- 复制和保存稳定。

## 编辑

- 标注操作顺手。
- 对象可编辑。
- Undo / Redo 可靠。
- 编辑过程流畅。

## 录制

- 录制稳定。
- 长时间录制不出现明显内存问题。
- GIF 和视频导出可靠。

## 剪贴板

- 采集行为可控。
- 用户知道哪些内容会被保存。
- 历史搜索方便。
- 内容恢复正确。
- 隐私保护明确。

## 整体体验

- 常驻但不打扰。
- 唤起迅速。
- 操作路径短。
- 界面统一。
- 不因功能扩展而变得臃肿。

---

# 15. 当前开发启动任务

建议从 Phase 0 开始，不要直接进入所有功能开发。

首批任务：

1. 创建 CaptureKit macOS Xcode Project。
2. 确定最低 macOS 部署版本。
3. 建立 AppLifecycle。
4. 实现 MenuBar 常驻。
5. 实现隐藏 Dock 图标。
6. 实现基础 Settings 窗口。
7. 实现全局快捷键注册。
8. 实现屏幕录制权限检测。
9. 验证 ScreenCaptureKit 全屏捕获。
10. 验证跨显示器区域截图。
11. 验证窗口捕获。
12. 编写 Phase 0 技术验证报告。

完成后再进入 Phase 1。

---

# 16. 项目最终愿景

CaptureKit 不追求成为一个庞大的综合工具箱。

它的核心始终是：

**让用户快速捕获屏幕和工作内容，并在需要时轻松找到、编辑和复用。**

截图与录制是内容获取入口。

剪贴板是日常内容获取入口。

统一 History 是内容管理中心。

Quick Access 是内容复用入口。

最终形成一个轻量、原生、可靠的 macOS 内容捕获与复用工具。

**CaptureKit — Capture. Organize. Reuse.**

## **建议接下来这样使用**

把这份文件放在项目根目录：

```
CaptureKit/
├── plan.md
├── README.md
└── CaptureKit.xcodeproj
```

我建议后续再补两份配套文档：

- `design.md`：技术架构、模块职责、状态机、数据模型、API 设计。
- `ui-design.md`：窗口布局、视觉规范、组件规范、交互细节。

**不要让 Coding Agent 仅凭这份 plan.md 就一次性开发整个项目。** 先让它完成 Phase 0 技术验证，确认 macOS 原生 API 和多屏幕行为，再逐阶段实施。