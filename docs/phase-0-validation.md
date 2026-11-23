# Phase 0 技术验证报告

> 对应 design.md §20 / plan.md §9 Phase 0
> 状态：代码实现完成，构建与单元测试通过（27/27）
> 日期：2026-11-23

---

## 1. 验证环境

| 项目 | 值 |
| --- | --- |
| 开发机 | Apple Silicon (arm64) |
| 系统 | macOS 27.2.1 (26B131) |
| Xcode | 26.6 (17F113) / Swift 6.3.3 |
| SDK | MacOSX26.5 |
| 最低部署版本 | **macOS 14.0** |

## 2. 关键决策与验证结论

### 2.1 最低系统版本 = macOS 14.0

依据（design.md §19 按实际 API 核查）：

- `SCScreenshotManager.captureImage(contentFilter:configuration:)` 要求 **macOS 14.0+**。这是静态截图（无 SCStream 生命周期管理）的最简可靠路径。
- `SCContentFilter.excludingApplications` / `desktopIndependentWindow` 均为 macOS 12.0+。
- `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 为 macOS 10.15+。
- `SMAppService`（登录启动）为 macOS 13.0+。

结论：锁 14.0 可让截图全链路使用官方静态 API，无需为 12/13 写 `SCStream` 单帧捕获兼容层。目标设备为 M1 Mac（可升级至最新系统），兼容性风险可控。

### 2.2 坐标转换规则（已单测固化）

实测规则与 API 文档一致：

1. `NSScreen.frame`、`SCDisplay.frame` 均为 **AppKit 全局逻辑坐标**（原点 = 主屏左下，副屏可为负坐标），两者可直接比较。
2. `SCScreenshotManager` 输出 CGImage 为**物理像素**，原点在**图像左上**。
3. 转换公式（`ScreenGeometry.pixelRect`）：
   - `local = logicalRect - displayFrame.origin`
   - `pixel.y = (displayFrame.height - local.maxY) × scaleY`（y 轴翻转）
   - `scale` 由 `实际图像宽 / 显示器逻辑宽` 推导，**不假设 backingScaleFactor**（兼容 SCK 输出与请求尺寸不一致的场景）。
4. 裁剪前 `integral` + 与图像 bounds 求交（`clampedPixelRect`），防止越界导致 `CGImage.cropping` 返回 nil。

单元测试覆盖：Retina 2x、1x 外接屏、**负坐标左外接屏**（-1920 起点）、非整数倍缩放（3x）、y 翻转四象限、越界裁剪、多显示器最大相交选择。

### 2.3 ScreenCaptureKit 静态捕获

已实现并通过编译验证的 API 用法：

- 内容发现：`SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`
- 整屏：`SCContentFilter(display:excludingApplications:exceptingWindows:)`；排除自身通过 `content.applications` 中匹配自身 PID 的 `SCRunningApplication`（**注意：参数类型是 `SCRunningApplication` 而非 `NSRunningApplication`**）
- 窗口：`SCContentFilter(desktopIndependentWindow:)`，`config.width/height = window.frame × backingScale`
- 输出尺寸：`CGDisplayCopyDisplayMode(displayID).pixelWidth/Height`（物理像素）
- **`SCScreenshotManager.captureImage` 返回单个 `CGImage`**（非数组）
- `SCWindow` 无 `layer` 属性（那是 CGWindowList 信息的字段）；层级排序改用「包含点的最小 frame」启发式

### 2.4 权限行为

- `CGPreflightScreenCaptureAccess()`：无弹窗静默检测，用于每次截图入口前置检查。
- `CGRequestScreenCaptureAccess()`：触发系统 TCC 弹窗（仅首次），在后台线程调用（会阻塞等待用户响应）。
- 拒绝后：NSAlert 引导打开「系统设置 → 隐私与安全性 → 屏幕录制」。
- 无实时权限变更通知：用户从系统设置返回后，下次截图入口会重新 preflight。

### 2.5 全局快捷键（Carbon）

- `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget(), kEventClassKeyboard/kEventHotKeyPressed)`。
- C 回调不能捕获上下文 → `Unmanaged` 传 `self`，回调内 `DispatchQueue.main.async` 分发。
- 冲突检测在应用层（`HotkeyConflictChecker`，同键码+同修饰键判定），注册失败返回 `noErr` 以外的 OSStatus 并向用户提示（不静默失效）。
- ⌘⇧A 默认绑定区域截图，实测注册成功（冒烟运行无错误日志）。

### 2.6 多显示器 Overlay

- 每个 `NSScreen` 一个无边框透明 `NSWindow`（`.screenSaver` level，`canJoinAllSpaces`），共享同一选区模型 → 拖拽可跨屏，每屏绘制本屏交集。
- borderless window 默认不可成为 key → 子类 override `canBecomeKey` 接收 ESC/Enter。
- 捕获时按「与选区相交面积最大的显示器」取图并裁剪交集（跨屏选区输出为交集部分，Phase 0 不做双屏拼接）。
- 拖拽事件持续路由到起始窗口（事件 grab），跨屏时坐标可能为负，全局坐标计算天然兼容。

## 3. 自动化验证结果

| 验证项 | 结果 |
| --- | --- |
| Debug 构建 | ✅ BUILD SUCCEEDED（0 error / 0 warning） |
| 单元测试 | ✅ 27/27 通过（坐标 11、快捷键 7、设置 7、剪贴板 2） |
| 启动冒烟 | ✅ 进程存活、菜单栏出现、无崩溃（运行 4s 后退出） |

## 4. 需人工验证清单（涉及 TCC 授权与真实多屏，Agent 无法代验）

| # | 场景 | 预期 |
| --- | --- | --- |
| 1 | 首次 ⌘⇧A / 菜单触发截图 | 系统弹出屏幕录制授权；拒绝后出现引导 Alert |
| 2 | 授权后区域截图（Retina 主屏） | 暗化遮罩 + 蓝色选区；捕获内容与选区视觉一致、无偏移；粘贴尺寸 = 选区逻辑尺寸 × 2 |
| 3 | 选区交互 | 拖拽创建、内部拖动移动、ESC 清除/退出、Enter 复制、工具栏四按钮 |
| 4 | 双击窗口捕获 | 输出仅含该窗口内容（无桌面背景），Retina 清晰 |
| 5 | 全屏截图（多屏时） | 捕获鼠标所在屏而非固定主屏 |
| 6 | 外接显示器（不同缩放/负坐标排列） | 各屏选区均无偏移；跨屏拖拽选区捕获交集 |
| 7 | 窗口排除开关 | 开启时结果不含 CaptureKit 自身窗口（Overlay/工具栏/Toast） |
| 8 | 设置项持久化 | 自动复制/Dock 图标切换重启后保留 |

## 5. 已知限制与遗留

1. **跨屏选区**输出为单屏交集，不拼接双屏内容（符合 Phase 0 范围）。
2. 选区无 8 控制点 / 放大镜 / 窗口吸附 —— Phase 1 任务。
3. `SCShareableContent` 在无权限时 `excludingDesktopWindows` 可能抛错而非返回空 —— 已由错误路径统一捕获并提示。
4. 测试宿主启动时的 `linkd.autoShortcut` 连接警告为系统噪音（无 App Intents），不影响功能。
5. 录制（SCStream）、剪贴板监控、历史存储未开始 —— 属 Phase 4/5。
6. App 为 ad-hoc 签名：`SMAppService` 登录启动在正式签名后才可靠；开发期注册失败仅记录日志。

## 6. 对后续 Phase 的架构建议

- 坐标转换已固化在 `ScreenGeometry`，Phase 1 的控制点/吸附必须复用，禁止散落乘 scale。
- Overlay 的「共享模型 + 每屏视图」结构可直接承载放大镜与窗口高亮。
- `CaptureCoordinator.errorHandler` 注入模式延续到 Recording/Clipboard 模块。
- 快捷键模型（`HotkeyDescriptor`）已 Codable，Phase 1 的自定义快捷键 UI 只需增加录制控件。
