# 开发进度

> 状态：Todo / In Progress / Blocked / Done
> 规则：前一阶段核心验收未通过不得进入下一阶段（plan.md §12.4）。

## 阶段总览

| Phase | 名称 | 状态 |
| --- | --- | --- |
| 0 | 技术验证 | **Done（待人工多屏验收）** |
| 1 | 截图 MVP | **Done（待人工验收）** |
| 2 | Screenshot Editor | **Done（全部工具，待人工验收）** |
| 3 | Scroll Capture | **Done（手动滚动基础版：匹配/拼接/预览，待人工验收）** |
| 4 | Recording | **Done（批次 1 核心管线；批次 2 预览编辑器+窗口录制，待人工验收）** |
| 5 | History + Clipboard | **Done（批次 1 数据层+采集+History 窗口；批次 2 QuickAccess/网格/存储页，待人工验收）** |
| 6 | 完善与增强 | **基本完成（OCR/批量删除/系统音频/麦克风/退出清空/效果缓存/点击效果/速度调节/孤儿自愈 Done；删帧编辑延后）** |

## Phase 0 任务明细（design.md §20）

| 任务 | 内容 | 状态 |
| --- | --- | --- |
| Task 1 | 项目初始化（xcodegen、目录、OSLog、Info.plist、部署版本 14.0） | Done |
| Task 2 | 菜单栏常驻 + 隐藏 Dock（可切换） | Done |
| Task 3 | 全局快捷键（Carbon 注册/注销/冲突检测/配置模型） | Done |
| Task 4 | 屏幕录制权限（preflight/request/系统设置引导） | Done |
| Task 5 | ScreenCaptureKit（全屏/窗口/区域 + 剪贴板复制 + 保存） | Done |
| Task 6 | 多显示器 Overlay 选区 + 坐标转换（单测覆盖） | Done |
| Task 7 | Phase 0 验证报告 | Done（自动化部分） |

## 验证记录

- 2026-11-23：Debug 构建通过；27/27 单元测试通过；启动冒烟（进程存活 4s）通过。（Phase 0）
- 2026-11-23：Phase 1 完成后构建通过；38/38 单元测试通过；启动冒烟通过。
- 2026-11-23：Phase 2 完成后构建通过；62/62 单元测试通过（新增标注几何 12、命令 5、视口 5、渲染 2）；启动冒烟通过。
- 2026-11-23：Phase 2 扩展（马赛克/模糊/编号/裁剪/关闭提醒）构建通过；73/73 单元测试通过（新增 11：新几何、比例约束、裁剪命令、导出状态）；启动冒烟通过。
- 2026-11-23：Phase 4 批次 1（录制核心管线）构建通过；85/85 单元测试通过（新增 12：暂停时间轴、区域→帧像素坐标、GIF/MP4 编码器真实文件烟测、录制设置兼容解码）；启动冒烟通过。API 编译期验证：`SCStreamConfiguration.clipBounds` 与 `CGImage(cvpixelBuffer:)` 在 MacOSX26.5 SDK 不可用 → 采用 ADR-015/CIImage 替代方案。
- 2026-11-23：Phase 5 批次 1（SQLite 数据层 + 剪贴板采集 + History 窗口）构建通过；110/110 单元测试通过（新增 25：SQLite/仓库 CRUD·分类·搜索·清理·哈希 17、剪贴板分类·敏感检测 8）；启动冒烟通过。修复一处模型缺陷：ContentItem 行映射未还原 updated_at 列（由 touch 断言暴露）。
- 2026-11-23：Phase 5 批次 2（QuickAccessPanel ⌘⇧V、History 网格视图、存储设置页）构建通过；111/111 单元测试通过（新增 quickAccess 默认快捷键与 stableID 唯一性）；启动冒烟通过。
- 2026-11-23：Phase 4 批次 2（录制预览编辑器：播放/双把手裁剪/mp4·GIF 导出；窗口录制）构建通过；113/113 单元测试通过（新增 mp4 裁剪导出与 mp4→GIF 转换真实文件烟测）；启动冒烟通过。
- 2026-11-23：Phase 6 首批（OCR + 批量删除）构建通过；117/117 单元测试通过（新增 4：渲染文本→Vision 真实识别、空白图零识别、OCR 设置解码）；启动冒烟通过。
- 2026-11-23：Phase 6 第二批（系统音频录制、退出清空、马赛克/模糊渲染缓存）构建通过；118/118 单元测试通过（mp4 导出新增音轨断言、效果缓存 key/命中测试）。AVFoundation 约束确认：AVAssetWriter input 必须在 startWriting 前添加 → 音频轨在 VideoWriter init 按 SCK 约定格式（48kHz Float32 stereo）预建；`SCStreamOutputType.microphone` 在本 SDK 已存在。
- 2026-11-23：Phase 6 第三批（点击高亮、导出速度调节、孤儿条目自愈）构建通过；127/127 单元测试通过（新增 9：点击坐标换算与像素绘制、2× 导出时长减半、GIF 延迟缩放、极端速度钳制、孤儿自愈三类条目）。重要发现：`AVMutableVideoComposition(propertiesOf:)` 同步初始化存在偶发 -11841 竞态 → GIF 导出改用 TrackOutput 像素缩放（ADR-023）；URL(":memory:") 经 `.path` 破坏 sqlite 内存库标记 → 测试库改临时文件。
- 2026-11-23：Phase 6 第四批（麦克风采集）构建通过；127/127 单元测试通过。API 可用性验证：`SCStreamConfiguration.captureMicrophone` 与 `SCStreamOutputType.microphone` 需 **macOS 15.0+**（部署目标 14 下 `#available` 门控）→ ADR-025。删帧编辑按 P1 延后。
- 2026-11-23：Phase 3（滚动截图基础版：手动滚动 + 帧匹配拼接）构建通过；135/135 单元测试通过（新增 8：合成页面位移恢复、拼接还原、重复帧去重、低置信降级、单帧直通、高度上限）。修复拼接器偏移累计 bug（`offset == totalHeight` 条件错误 → max 公式重写，由拼接还原测试暴露）。
- 2026-11-23：性能打磨（缩略图异步加载 + NSCache）构建通过；139/139 单元测试通过（新增 4：缓存命中同一实例、缺失文件/nil 路径/损坏数据返回 nil）。
- 2026-11-23：Phase 3 补全（自动滚动）构建通过；141/141 单元测试通过（新增 2：AppKit→CG 坐标 y 翻转、滚轮事件构造与方向/位置字段）。API 校准：`CGEvent(scrollWheelEvent2Source:...)`（wheel1 Int32）；`scrollWheelEventIsContinuous` 字段在本 SDK 不可用 → ADR-027。
- 2026-11-23：删帧编辑（GIF 胶片条）构建通过；151/151 单元测试通过（新增 10：区间合并/半开命中/切换增删/裁剪/编解码往返、导出跳帧集成烟测）。
- 待人工：`docs/phase-0-validation.md` §4 清单 + Phase 1/2/3/4/5/6 人工验收清单。

## Phase 6 任务明细（进行中）

| 任务 | 状态 |
| --- | --- |
| OCR 文字识别（Vision 本地：编辑器「识别文字」按钮 + 结果面板复制；截图/剪贴板图片入库后台识别写入搜索索引；设置可关，默认开） | Done |
| 历史批量删除（列表/网格选择模式 + 全选 + 确认批量删除） | Done |
| Pin 收藏增强（已有 Pin + 豁免清理） | Done（Phase 5 已含） |
| 录制系统音频（SCStream capturesAudio + 排除自身进程音频；AAC 音轨；暂停联动；设置开关默认关；单测验证音轨落盘） | Done |
| 退出时清空全部历史（设置开关，默认关；Pin 同删已在 footer 说明） | Done |
| 马赛克/模糊渲染缓存（NSCache，key=标注+区域+参数+底图身份；裁剪自动失效） | Done |
| 鼠标点击高亮（全局鼠标监听无需辅助权限；帧内扩散圆环合成；区域/全屏坐标换算单测；设置开关默认关） | Done |
| 导出速度调节（0.5×/1×/1.5×/2×：mp4 AVMutableComposition 重定时（重编码）、GIF 帧延迟缩放；单测验证时长减半与延迟缩放） | Done |
| 孤儿条目自愈（启动扫描引用文件丢失的条目并清理；单测覆盖真实文件/丢失/纯文本三类） | Done |
| 麦克风采集（SCStream .microphone，macOS 15+ 门控；TCC 授权拒绝降级；与系统音频共用 AAC 音轨 + PTS 单调保护；设置开关默认关） | Done |
| 缩略图异步加载（ThumbnailStore：后台解码 + NSCache，History 列表/网格与 QuickAccess 复用 AsyncThumbnailView，列表滚动不再阻塞主线程） | Done |
| **删帧编辑**（GIF 胶片条 20 格点选排除 + 区间合并纯函数 + 导出跳帧集成；导出按钮按有效时长禁用） | Done |
| 崩溃恢复增强 | Done（孤儿自愈已覆盖核心场景） |

## Phase 6 人工验收清单

1. 编辑器 → 工具栏「文字识别」按钮 → 含文字的截图识别出结果 → 「复制全部」。
2. 设置 → 通用 → 关闭 OCR → 新截图不再写搜索索引（历史搜索图片内文字不再命中）。
3. 开启 OCR 时截图一张含文字的图 → ⌘⇧H 搜索图中关键词 → 命中该截图条目。
4. History → 搜索栏右侧 ⭕ 进入选择模式 → 点选多项 → 「删除所选」→ 确认 → 条目与文件消失。
5. 设置 → 录制 → 开启「录制系统音频」→ 录一段带声音的内容（播放音乐）→ 停止 → 预览编辑器/QuickTime 回放有声音；暂停段静音且时间连续。
6. 设置 → 剪贴板 → 开启「退出时清空全部历史」→ 退出 app → 重新打开历史为空；关闭该选项时退出不清空。
7. 设置 → 录制 → 开启「鼠标点击高亮」→ 录制中点击几下 → 回放可见蓝色扩散圆环，位置与点击处一致。
8. 预览编辑器导出选 2× → mp4 时长减半；GIF 播放明显变快。
9. 手动删除 Content 目录里某条目引用的文件 → 重启 app → 该条目被自动清理。
10. 设置 → 录制 → 开启「录制麦克风」（macOS 15+）→ 首次录制弹麦克风授权 → 允许 → 录制后回放有人声；拒绝授权 → 录制正常完成但无人声。
11. 同时开启系统音频 + 麦克风录制 → 回放两个声源都存在（混音质量人工评估）。

## Phase 1 任务明细（plan.md §9）

| 任务 | 状态 |
| --- | --- |
| MenuBar Popover（截图主入口 + 快捷操作列表，SwiftUI） | Done |
| 全局快捷键（Phase 0 已实现，含自定义录制 UI 与即时生效） | Done |
| Capture Overlay（多屏、暗化、选区） | Done |
| 区域截图 / 全屏截图 / 窗口截图（单击选中、双击捕获） | Done |
| 窗口吸附（悬停高亮、拖拽边缘吸附 6pt、单击选中窗口为选区） | Done |
| 选区调整（8 控制点、内部拖动、空格+拖动、方向键 1px / Shift 10px） | Done |
| 放大镜（4x 放大、像素坐标、创建/调整时跟随鼠标） | Done |
| 复制 / 保存（PNG，NSSavePanel） | Done |
| 延时截图（设置 1–10s，倒计时面板可取消） | Done |
| 基础 Settings（通用/截图/快捷键，登录启动、Dock 切换） | Done |
| 显示器排列变化自动取消 Overlay | Done |

## Phase 1 人工验收清单

1. 菜单栏左键 → Popover 显示；点「截图」→ Popover 关闭 → Overlay 出现；右键 → NSMenu。
2. 无选区时鼠标划过窗口 → 蓝色高亮；单击窗口 → 整窗作为选区；双击 → 直接捕获该窗口。
3. 拖拽选区时放大镜跟随鼠标（4x + 坐标）；松开后控制点可拖拽调整，方向键微调（Shift = 10px）。
4. 拖拽边缘接近其它窗口边缘（<6pt）→ 自动吸附。
5. 设置 → 快捷键 → 点击录制 → 按 ⌘⇧S → 立即生效；冲突时显示橙色提示。
6. 延时截图：倒计时浮条 → 可取消；倒计时归零自动进入区域截图。

## Phase 2 任务明细（plan.md §9）

| 任务 | 状态 |
| --- | --- |
| 编辑器窗口（AppKit 窗口 + SwiftUI 工具栏/Inspector） | Done |
| Canvas（缩放 0.1–8x 锚定缩放、平移、Space 拖动、⌘滚轮/捏合缩放） | Done |
| Annotation 数据模型（值类型几何 + bbox/平移/缩放/命中纯函数，单测覆盖） | Done |
| 工具：选择/箭头/矩形/椭圆/文字/画笔（快捷键 V/A/R/O/T/P） | Done |
| 马赛克（像素化，粒度可调）/ 模糊（CIGaussianBlur，强度可调） | Done |
| 编号标注（自动递增取号，圆形徽标 + 数字） | Done |
| 裁剪工具（非破坏性 cropRect、比例约束 自由/1:1/4:3/16:9、Enter 应用/ESC 取消、重置裁剪、可撤销） | Done |
| 标注选中/移动/8 控制点 resize/Delete 删除/双击编辑文字 | Done |
| 动态 Inspector（按对象类型显示：色板/线宽/字号/填充/粒度/强度/裁剪比例） | Done |
| Undo/Redo（Command Pattern，add/remove/update/setCrop；slider 拖完才入栈） | Done |
| 非破坏性导出（AnnotationRenderer 画布与导出共用；复制/保存一致） | Done |
| 关闭未导出提醒（有标注/裁剪未复制保存时弹确认） | Done |
| Overlay 工具栏「编辑」按钮 + 截图后自动进编辑器（设置可关，默认开） | Done |

## Phase 2 人工验收清单

1. 截图（Enter 或工具栏「编辑」）→ 编辑器窗口自动打开并显示截图。
2. 按箭头工具（A）拖一条箭头 → 自动切回选择（V）并选中；拖动移动、控制点调整大小、Delete 删除。
3. 文字工具（T）点击画布 → 输入文字 → 回车；双击已有文字重新编辑。
4. 马赛克（M）/模糊（B）拖矩形 → 敏感信息被遮盖；Inspector 调粒度/强度即时变化。
5. 编号（N）连续点击多处 → 自动 1、2、3 递增；可拖动/改颜色大小。
6. 裁剪（C）：Inspector 选 1:1 → 拖出正方形裁剪框 → Enter 应用；⌘Z 撤销恢复；「重置裁剪」回到原图。
7. 底部 Inspector：按选中对象类型显示对应属性；修改即时生效。
8. ⌘Z/⌘⇧Z 撤销重做（含裁剪）；slider 拖动一次只回退一步。
9. 有未导出修改时关闭窗口 → 弹出确认；⌘C/⌘S 后关闭不提示。
10. ⌘C 复制合成图 → 粘贴包含标注与裁剪；原始截图数据未被修改。

## 已实现文件索引

```
CaptureKit/
├── App/
│   ├── CaptureKitApp.swift            @main 入口（纯 AppKit）
│   ├── AppDelegate.swift              生命周期回调
│   ├── AppEnvironment.swift           依赖装配 + 快捷键绑定 + 错误/完成呈现
│   └── AppDockIconService.swift       Dock 图标策略
├── Core/
│   ├── Errors/CaptureKitError.swift
│   ├── Models/CaptureSession.swift    CaptureMode/State/DeliveryAction
│   ├── Models/RecordingSession.swift  RecordingMode/State/Settings + PauseTimeline
│   └── Utils/ScreenGeometry.swift     坐标转换 + 控制点/吸附/比例约束（纯函数可测）
├── Infrastructure/
│   ├── Logging/Log.swift              OSLog 分类
│   ├── Permissions/ScreenCapturePermission.swift
│   ├── Hotkeys/HotkeyDescriptor.swift 模型 + 冲突检测 + NSEvent 转换
│   ├── Hotkeys/CarbonHotkeyCenter.swift
│   ├── ScreenCapture/ScreenCaptureEngine.swift   静态捕获
│   ├── ScreenCapture/ScreenRecorder.swift        SCStream 流式捕获
│   ├── VideoProcessing/VideoWriter.swift         AVAssetWriter mp4
│   ├── VideoProcessing/GIFEncoder.swift          ImageIO GIF 流式
│   └── VideoProcessing/PixelBufferCropper.swift  帧裁剪（区域录制，ADR-015）
├── Application/
│   ├── Capture/CaptureCoordinator.swift     截图业务（权限→Overlay→捕获→交付→延时）
│   ├── Capture/ClipboardWriter.swift       PNG+TIFF 写入
│   ├── Recording/RecordingCoordinator.swift 录制业务（状态机+帧管线+HUD）
│   └── Settings/AppSettings.swift          Codable 配置 + UserDefaults 存储
└── UI/
    ├── MenuBar/MenuBarManager.swift       左键 Popover + 右键 NSMenu
    ├── MenuBar/MenuBarPopoverView.swift   Popover 内容（SwiftUI）
    ├── CaptureOverlay/                    Model/Window/View/Controller/Toolbar
    ├── DelayedCapture/DelayedCapturePanel.swift
    ├── CaptureResult/CaptureResultToast.swift
    ├── RecordingHUD/RecordingHUDPanel.swift   录制控制条
    ├── ScreenshotEditor/                  EditorWindowController+Coordinator
    │                                      AnnotationCanvasView（AppKit Canvas）
    │                                      EditorContentView + AnnotationInspectorView
    └── Settings/SettingsWindowController.swift
        Settings/SettingsRootView.swift（通用/截图/录制/快捷键）
        Settings/HotkeyRecorderView.swift
```

## Phase 2 待办

（全部完成；后续增强见 Phase 6）

## Phase 3 任务明细（plan.md §9 基础版）

| 任务 | 状态 |
| --- | --- |
| 滚动区域选择（复用 Overlay 区域选择） | Done |
| 采集循环（0.35s 定时抓帧，重复帧自动跳过，上限 120 帧，单帧失败不中断） | Done |
| 帧间重叠匹配（灰度降采样 128×256 + 逐候选位移平均绝对差，置信度输出） | Done |
| 图片拼接（后帧新增区追加；低置信段整帧追加防内容丢失；高度上限 16000px） | Done |
| 采集 HUD（帧数计数/完成⏎/取消⎋，可拖动） | Done |
| 结果交付（拼接图 → 编辑器打开 + 历史入库） | Done |
| 合成页面单测（位移恢复 ±3px、拼接还原、重复帧去重、低置信降级、单帧直通、高度上限） | Done |
| **自动滚动**（CGEvent 滚轮注入 + 辅助功能权限引导与手动降级 + 到底自动完成，ADR-027；设置默认开） | Done |
| 人工调整拼接结果 | 延后（结果直接进编辑器，可用裁剪/标注工具调整） |

## Phase 3 人工验收清单（含自动滚动）

1. Popover/右键菜单「滚动截图（长图）」→ 选区 → 首次弹辅助功能授权引导。
2. 授权后重新触发 → HUD「自动滚动中…」→ 页面自动滚动、到底自动完成 → 编辑器打开拼接长图。
3. 未授权选「手动滚动」→ 手动匀速滚动 →「完成」→ 拼接结果正常。
4. 长图内容应连续无重复断层；历史出现该长图条目。
5. 选区后不滚动直接「完成」→ 输出单帧等大长图。
6. 设置 → 截图 → 关闭「滚动截图自动滚动」→ 不再注入滚动事件。
7. 滚动过快或页面含动画 → 可能出现重复/断层（评估拼接质量）。

## Phase 4 任务明细（plan.md §9；批次 1 = 核心录制管线）

| 任务 | 状态 |
| --- | --- |
| ScreenCaptureKit 录制（SCStream + 帧回调，排除自身 app） | Done |
| 区域录制（Overlay 录制选区模式 → 整屏流 + PixelBufferCropper 逐帧裁剪，ADR-015） | Done |
| 全屏录制（鼠标所在屏） | Done |
| Recording HUD（REC/时间/暂停/停止/取消，可拖动，不入镜） | Done |
| 暂停和继续（PauseTimeline 时间轴：丢帧 + PTS 重写，单测） | Done |
| 停止（AVAssetWriter finishWriting 流式落盘） | Done |
| 视频编码（H.264 mp4，背压丢帧策略，单测：合成帧 → 可播放 mp4） | Done |
| GIF 编码（ImageIO 流式 + 帧率节流 + 宽度上限，单测：帧数/延迟/尺寸） | Done |
| 录制完成提示（Finder 定位） | Done |
| 全局快捷键 ⇧⌘R 区域视频录制（可自定义） | Done |
| 录制设置页（FPS 5–60 / 鼠标指针 / GIF 宽度 480/720/1080） | Done |

Phase 4 批次 2 已完成：录制预览编辑器（AVPlayer 播放/暂停/进度拖动、双把手时间轴裁剪与预览循环、导出 mp4（原始 passthrough/720p/1080p/480p）或 GIF（帧率 10/15/20 + 宽度上限，复用 GIFEncoder 流式管线）、导出进度、Finder 定位；录制完成自动打开（设置可关，改为 Finder 提示））、窗口录制（Overlay 双击选窗 → desktopIndependentWindow）。

Phase 4 遗留（Phase 6）：音频采集（麦克风/系统音频）、录制中鼠标点击效果、速度调节、删帧。

## Phase 4 人工验收清单（批次 1 + 2）

1. ⇧⌘R 或 Popover「录制」→ Overlay 提示"拖拽选择录制区域" → 拖框 → Enter → 出现 HUD。
2. HUD 显示 ● REC + 计时；**拖动 HUD 后回放确认 HUD 不在视频中**（ADR-017 验证点）。
3. 暂停 → 时间停走（点变橙）；继续 → 恢复；回放确认暂停段被移除（时间连续）。
4. 停止 → **预览编辑器自动打开**（默认）：空格播放/暂停；拖动双把手调整裁剪区间（播放头循环于裁剪区间）。
5. 导出 mp4（原始尺寸 passthrough，仅裁剪不重编码）→ QuickTime 播放，时长 = 裁剪区间。
6. 导出 GIF（选 480p + 10FPS）→ 文件明显变小、可播放、帧率正确。
7. 右键菜单「录制 GIF（区域）」→ 停止后直接进编辑器 → 导出 GIF。
8. 取消 → 确认弹窗 → 半成品文件被删除（Recordings 目录无残留）。
9. 长录制（≥2 分钟）期间观察活动监视器：内存无持续增长（流式写入验证）。
10. 窗口录制（右键菜单 → 双击某窗口）：输出仅含该窗口（无桌面背景）。
11. 全屏录制（右键菜单）：输出尺寸 = 显示器物理像素。
12. 设置关闭「录制后自动打开预览编辑器」→ 完成后显示 Finder 提示而非编辑器。

## Phase 5 任务明细（批次 1 = 数据层 + 剪贴板采集 + History 窗口）

| 任务 | 状态 |
| --- | --- |
| Content Model（ContentType/typed ContentMetadata/ContentQuery） | Done |
| SQLite 数据库（自研轻量封装：串行队列、WAL、user_version 迁移） | Done |
| ContentRepository（CRUD/分类查询/搜索/去重哈希查找/超龄超量清理/Pin 豁免） | Done |
| Content Store（按月分目录、临时文件+原子移动、删除同步清文件） | Done |
| 缩略图生成（图片 320px / 视频首帧） | Done |
| Clipboard Monitor（changeCount 0.6s 轮询、启停受设置驱动） | Done |
| 文本/URL/图片（PNG/TIFF）/文件引用采集（多 representation 记录） | Done |
| 类型分类（文件>图片>URL>富文本>纯文本，单测覆盖） | Done |
| 敏感内容过滤（AWS/GitHub/sk-/Bearer/password/私钥/高熵串，默认开） | Done |
| 内容去重（SHA256：文本规范化/二进制；重复 bump 更新时间） | Done |
| 恢复到剪贴板（文本/图片/文件 URL/视频引用） | Done |
| 自动清理（启动+每小时：超龄与超量，Pin 豁免，关联文件同步删除） | Done |
| 剪贴板隐私设置（默认关闭/暂停/保留量/清理天数/排除应用/敏感过滤） | Done |
| 截图与录制接入统一历史（哈希去重联动） | Done |
| History 窗口（分类导航/搜索防抖/缩略图列表/右键复制·Pin·Finder·删除/空状态）+ ⇧⇧⌘H | Done |

Phase 5 批次 2 已完成：QuickAccessPanel（⌘⇧V：搜索/键盘导航/Enter 复制自动关闭/ESC/失焦关闭/屏幕居中，快照式加载 30 条）、History 网格视图（列表/网格切换、双击复制、Pin 角标）、设置存储页（内容/数据库占用、条目数、打开目录、确认后清空全部历史）。

遗留（Phase 6 增强）：退出时清空选项、历史批量删除、GIF 动画预览。

## Phase 5 人工验收清单（批次 1 + 2）

1. ⌘⇧H → 历史窗口打开；默认显示全部；左侧切换分类；搜索栏右侧按钮切换列表/网格。
2. 截图（⌘⇧A）→ 完成后历史出现截图条目（缩略图 + 尺寸）；录制完成 → 视频/GIF 条目。
3. 设置 → 剪贴板 → 开启 → 复制一段文本 → 历史出现文本条目（来源 app 显示）。
4. 复制同一文本两次 → 只有一条记录（去重 bump）。
5. 复制图片/文件（Finder 中复制文件）→ 各自类型条目正确。
6. 复制 `AKIA...` 风格密钥 → 不记录（敏感过滤）；设置关闭敏感过滤后可记录。
7. 暂停监听 → 复制内容不新增；恢复后新增。
8. 搜索关键词 → 文本/URL 条目可检索；删除条目 → Content 目录文件同步消失；Pin 条目在自动清理后保留。
9. 右键 → 复制 → 到其它应用粘贴，内容与原一致（图片不失真）。
10. 关闭剪贴板历史 → 监控停止，重启 app 后保持关闭（默认隐私）。
11. **⌘⇧V → 快速面板弹出、自动聚焦搜索**；输入过滤、↑↓ 选择高亮滚动、⏎ 复制选中并自动关闭、⎋ 关闭、点击面板外自动关闭。
12. 设置 → 存储：显示内容与数据库占用/条目数；「打开存储目录」定位；「清空全部历史」需确认且清空后条目与文件均消失。

## 发布基建任务明细（DESIGN.md §22 / ADR-028/029）

| 任务 | 状态 |
| --- | --- |
| Sparkle 2.10.1 SPM 集成（exactVersion 锁定；UpdateCoordinator 包装，AppSettings.update 单一事实源） | Done |
| EdDSA 密钥对（公钥入 Info.plist；私钥导出 ~/.config/capturekit/，仓库外） | Done |
| Info.plist 更新配置（SUFeedURL/SUPublicEDKey/24h 间隔/安装需确认/关闭系统剖析） | Done |
| 设置 → 更新页 + 菜单右键「检查更新…」+ 当前版本显示 | Done |
| scripts/build-release.sh（Universal 构建 + lipo 断言 + ad-hoc 签名校验 + DMG + ditto zip + Sparkle 嵌入断言） | Done |
| scripts/make-appcast.sh（官方 generate_appcast 下载缓存 + stdin 密钥 + 签名/URL 自检） | Done |
| .github/workflows/build.yml（push/PR → 构建 + 全量测试） | Done |
| .github/workflows/release.yml（v* tag → 三附件自动发布，github.repository 全 owner 无关） | Done |
| docs/index.html Homepage（GitHub Pages；下载/特性/安装/xattr/故障排除；design 审计） | Done |
| 文档：README 安装章节、DESIGN.md §22、ADR-028/029、docs/releasing.md | Done |

验证记录：Sparkle 集成构建通过（框架自动嵌入 app/Contents/Frameworks）；**159/159 单测通过**（新增 UpdateConfigTests 8 项：feed URL/公钥 32 字节/间隔/确认安装/关闭剖析/默认开/旧配置回退）；本地发布演练通过（lipo 双架构、codesign verify、DMG + zip 产物、appcast EdDSA 签名自检）；Homepage design 审计必修项清零（1440/390 双视口 0 must-fix；1440 与 390 全分辨率截图经视觉复核无重叠；4 项 10px eyebrow 小字继承自骨架基线，按规则保留并报告）。appcast 前缀陷阱已实证修复：generate_appcast 将 --download-url-prefix 视为目录基址，不以 / 结尾会丢弃末段（v0.1.0 tag），脚本内统一补齐。

## 发布基建人工验收清单（首次发布）

1. push main → GitHub Actions build.yml 绿灯（CI 环境 Build + 159 测试）。
2. 配置 Secret `SPARKLE_PRIVATE_KEY`（docs/releasing.md §0）→ 打 tag v0.1.0 → release.yml 产出三附件 DMG/zip/appcast.xml。
3. DMG 安装 → 首次 `xattr` → 启动正常、功能与本地一致。
4. 菜单「检查更新…」→ Sparkle 面板弹出（首个 Release 前会报 feed 404，属预期）。
5. 发更高版本 → 老版本检出更新 → 确认安装 → 自动重启为新版（若被 Gatekeeper 拦截重跑 xattr，记录到 ADR-029）。
6. Settings → Pages（main /docs）→ Homepage 可访问且下载按钮指向最新 DMG。
7. Intel Mac 或 Rosetta 下 DMG 可运行（universal 断言已在 CI 日志）。

## 品牌与文档资产批次（图标 / 截图 / 主页）

| 任务 | 状态 | 说明 |
| --- | --- | --- |
| 应用图标（gpt-image 生成 → squircle 后处理 → AppIcon.appiconset 单尺寸 512@2x） | Done | actool 校验通过，AppIcon.icns 产出；favicon/logo 同源 |
| 演示模式（--demo-editor/history/settings/quick/popover/overlay + --demo-snap 自截图） | Done | 历史演示走临时数据库不污染真实数据；mock 网页底图归一化 1600×1000（2x 屏 cgImage 3200×2000 陷阱） |
| 真实 UI 截图 ×3（编辑器/历史/设置）入 docs/images/ | Done | 窗口离屏快照（cacheDisplay）绕过终端无屏幕录制 TCC 的限制；screencapture 在本机只能拍到壁纸 |
| 主页截图区（编辑器 hero + 历史/设置卡）+ 真实图标导航/favicon + design 审计 0 必修 | Done | 动态版本 fetch 因「页面不调用服务」规则移除 |
| README「界面一览」章节 + 图标说明 | Done | |

开发环境注意（本机 Xcode 26.6 / macOS 27.2）：scheme 的 build targets 同时包含 app 与测试 target 时，xcodebuild 会卡死在 CreateBuildDescription（SWBBuildService 挂起，100% 复现；-target 模式与纯 app scheme 正常）。本地构建用 `xcodebuild -target CaptureKit`；CI（macos-26 runner）行为待首次流水线验证，若同样挂死需将 test 改为独立 scheme。

人工验收：图标在 Dock/关于面板/Finder 显示是否清晰；主页截图区块渲染；GitHub 首次 CI 与 Release 流水线（见 docs/releasing.md）。

## 首次发布闭环（v0.1.0，全部线上实证）

| 里程碑 | 结果 |
| --- | --- |
| GitHub 仓库 ahao430/CaptureKit（public）+ main 推送 | Done |
| CI build.yml（Build + 159 测试，macos-26） | ✅ success |
| GitHub Pages（main /docs → ahao430.github.io/CaptureKit） | ✅ HTTP 200 |
| Sparkle Secret（SPARKLE_PRIVATE_KEY） | ✅ 已配置 |
| release.yml @ v0.1.0（DMG 3.9M + zip 3.5M + appcast.xml 三附件） | ✅ success |
| 稳定直链 releases/latest/download/CaptureKit.dmg | ✅ HTTP 200 |
| 远端 appcast EdDSA 验签（下载 zip ↔ appcast 签名比对） | ✅ VALID |

线上实证修复（都是本地无法暴露的 CI 行为）：
1. app-only scheme 无 test action → 拆双 scheme（CaptureKit 构建 / CaptureKitTests 测试）。
2. generate_appcast 在 cd 后按 CWD 重解析相对目录 → make-appcast.sh 内转绝对路径。
3. 本机 xcodebuild「scheme 含测试 target 即挂死」仅限本机（Xcode 26.6/macOS 27.2），CI 正常——双 scheme 保留为本地规避。

剩余人工项（docs/releasing.md §3）：真实下载 DMG → xattr → 启动验收；更高版本号发的更新回路（v0.1.1+）验证 Sparkle 全流程；Intel/Rosetta 抽查。

## v0.1.1 用户实测修复批次（三个问题的根因与处理）

| 问题 | 根因 | 修复 |
| --- | --- | --- |
| ① 授权后下次还弹屏幕录制弹窗 | App Translocation：带 quarantine 的 app 被迁移到随机只读路径，TCC 授权按路径记录，每次启动路径都变 → 授权失效。右键「打开」不清隔离属性，无法根治 | `TranslocationChecker`：启动检测 AppTranslocation/xattr（可「不再提示」），弹窗引导拖入「应用程序」或执行 xattr；README/主页双语说明 |
| ② 录屏不进历史 | 下游症状：TCC 失效会话里 SCStream 失败 → onRecordingCompleted 不触发。回归测试证明 recordRecording 入库链路本身正常（真实 mp4 → 条目/类型/落盘/缩略图/去重 全通过） | recordRecording 静默失败改记 error 日志；新增 RecordingHistoryTests 2 例 |
| ③ ⇧⌘R/H/V「有问题」 | ⇧⌘R 同①（TCC 失效实例上录屏必失败并弹权限引导）；⇧⌘H/⇧⌘V 窗口在全屏应用当前 Space 打不开 | 历史/设置/QuickAccess 窗口加 `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` |

另：主页完成双语（默认中文，导航 EN 切换，localStorage 记忆）；eyebrow 10px→12px、移动端 nav 压缩（隐藏下载按钮）修复审计必修。

本地 161/161 测试通过。遗留观察项：v0.1.1 安装后请用户复测 ①②③；若 ⇧⌘H/⇧⌘V 仍异常需用户给出具体现象（无反应/弹窗/内容为空）。

## 快捷键占用实证与提示（v0.1.3 后追加）

用户反馈「快捷键拉起的截图是钉钉的」。本机实证（钉钉/微信运行中）：
- `RegisterEventHotKey` 对已被占用的 ⇧⌘A **返回 noErr**——注册层面无法检测冲突，事件归先注册的应用；本 app 的注册"成功"但永不触发。
- 这解释了此前的「快捷键截图正常」——响应的其实是钉钉，不是 CaptureKit。

修复：`HotkeyConflictChecker.externalConflictHint`（纯函数 + 6 例单测）+ `AppEnvironment.warnExternalHotkeyConflictIfNeeded`（启动检测钉钉/微信运行且区域截图为默认 ⇧⌘A 时一次性弹窗建议改键，可「不再提示」）。161 → 167 测试。



## v0.1.4：签名流程修正 + 快捷键占用提示（2026-11-23）

更正：草稿 v0.1.3 的安装包实际是 ad-hoc（CI 上证书不受信任、脚本回退），不能用于验证授权问题；v0.1.3 未公开。

| 项 | 状态 | 依据 |
| --- | --- | --- |
| CI 证书导入：去掉 `add-trusted-cert`（runner 上挂起） | Done | 第一次重跑卡在该步骤 20 分钟后取消 |
| 身份检测不要求受信任；发布模式 `MACOS_SIGNING_REQUIRED=1` 缺身份即失败；签名后核对 `Authority` | Done | 用现存 universal 产物跑真实脚本三条分支：证书签名成功 / 发布模式缺身份 exit 1 / 开发模式回退 ad-hoc |
| Sparkle 对签名身份变化的处理 | 已读源码确认 | Sparkle 2.10.1 仅在 EdDSA 验签失败后才用 Developer ID 匹配兜底；我们的更新均有 EdDSA 签名 |
| 文档改为如实表述（README / 主页 / releasing.md / ADR-030） | Done | 删除「授权自动保留」的断言 |
| 快捷键占用提示随本版发布 | Done | 167 测试通过；弹窗本身未在屏幕上实际运行过 |

本地未能完整预演 `build-release.sh`：这台机器的 xcodebuild 再次卡在 `CreateBuildDescription`（CI 上同一命令一直正常），所以改为跳过构建步骤、只对签名段做验证。CI 全流程以 v0.1.4 的发布运行为准，发版后需下载已发布的 DMG 核对 `Authority`。

未经证实、需实机确认：自签名证书能否让屏幕录制授权保留下来；「ad-hoc 指纹变化导致授权留不住」这一根因推断。

## 排查结案：屏幕录制授权反复提示（DESIGN.md §23 / ADR-030）

排查清单逐项结论：权限检查无缓存、每次实时 preflight；CGRequest 仅在未授权时调用；Bundle ID 全构建一致；**根因为 ad-hoc 签名的 DR 绑定单次构建 cdhash**（`codesign -d -r-` 对比实验，v0.1.2 实包验证）；权限生效需重启应用。修复：v0.1.4 固定证书（已发布并核对 Authority）+ 权限提示文案（面板新名称「屏幕与系统音频录制」+ 重启生效说明）。用户侧操作：`tccutil reset ScreenCapture com.wanghao.capturekit` → 装 v0.1.4 → 授权 → 重启。

## 授权修复用户验证通过（2026-11-23）

v0.1.4 实机结果：授权成功后不再重复弹出——根因（ad-hoc DR 逐构建变化）与修复（固定自签名证书 + 一次性 tccutil reset）均证实。此前的 Translocation 假设（v0.1.1）与「每版本重新授权一次」的口径均为误判，已在 ADR-030 修正。后续发布按 DESIGN.md §23.3 验收（重点：新版本覆盖安装后授权保留）。

## 截图交互升级：参考钉钉三批次（2026-11-23）

用户反馈钉钉截图体验好，按「小改动 → 选区标注 → 贴图」三批次落地（189 测试通过，新增 22 个）：

| 批次 | 内容 | 关键实现 |
| --- | --- | --- |
| 1 | 取色放大镜：坐标 + HEX/RGB + `C` 复制颜色；无选区悬停也显示 | `PixelColorReader`（快照 1×1 采样，`ScreenGeometry` 统一坐标）；工具栏图标化 + OCR/录屏/长截图入口；选区右键菜单 |
| 2 | 选区内直接标注（矩形/椭圆/箭头/画笔/马赛克/编号/文字 + 8 色 + ⌘Z 撤销），Enter 复制含标注截图，不打开编辑器 | 复用 `Annotation`/`AnnotationRenderer` 统一渲染管线；标注存选区本地逻辑坐标，导出经 `OverlayAnnotationExporter` 缩放到像素坐标合成；文字用 `OverlayTextEntryPanel` 浮层输入 |
| 3 | 贴图：选区钉在原位置顶浮窗 | `PinnedImageManager`（上限 12 张）+ `PinnedImagePanelController`；拖动/滚轮缩放/⌥滚轮透明度/双击还原/悬停关闭/右键复制关闭 |

新增 Overlay Result 分支：`regionAnnotated` / `recognizeRegion` / `recordRegion` / `scrollRegion` / `pinRegion`；`RecordingCoordinator.startRecordingInRegion`、`ScrollCoordinator.startCapturing(in:)` 提供选区直入口（AppEnvironment 装配）。

测试夹具坑（记录）：`CGColor(red:...)` 构造的是扩展 sRGB 色，绘制进 DeviceRGB 位图上下文会色彩转换偏色（实测红变 255,38,0）——测试需用分量式 `setFillColor(red:green:blue:alpha:)`。

## 一体化工具栏重构：对齐钉钉交互（2026-11-23）

用户反馈三批次后「跟钉钉差别仍大」。确认差距后全量重构（192 测试通过）：

| 方向 | 实现 |
| --- | --- |
| 一体化工具栏 | 删除「标注模式」二段式概念（`annotateMode` 移除）；`OverlayTool`（.select / .annotate(type)）统一工具状态。选中选区后工具栏两行常驻：上行工具+颜色+线宽+撤销，下行动作。默认「选择」工具 = 拖动移动选区/调整控制点 |
| 悬停十字参考线 | 无选区悬停时全屏虚线十字跟随（`drawDashedCrosshair`），配合放大镜坐标/取色 |
| 标注可编辑 | 选择工具点选已画标注（命中测试从最上层）→ 虚线包围盒 → 拖动移动、⌫/Delete/右键/⌘Z 删除；改颜色/线宽实时同步到选中标注 |
| 视觉细节 | 选区描边外发光（shadow blur 6）；工具栏圆角 12 + 两行布局；`SelectionToolbarPanel.reflect` 同步 toggle 选中态 |

Esc 阶梯变为：草稿 → 选中标注 → 选区 → 取消 Overlay。新建选区/选区外右键会连同标注一并清空（标注属于选区）。
`AnnotateToolPanel` 已删除（并入 SelectionToolbarPanel）；选区像素快照改为视图内懒重建（rect 比对 + 仅有效果标注时）。

## 模式胶囊 + 工具栏钉钉视觉重构（2026-11-23，第二轮用户反馈）

用户提供两张钉钉实测截图，据像素级描述对齐（196 测试通过）：

| 项 | 实现 |
| --- | --- |
| 顶部模式胶囊 | `OverlayModePanel`：深色毛玻璃（NSVisualEffectView hudWindow）胶囊、可拖动（isMovableByWindowBackground），[手柄] 截图/滚动截图/录屏/文字识别；选中 = 白卡黑字。仅 CaptureCoordinator 区域截图流程开启（`showsModePanel`），复用 Overlay 的 Scroll/Recording 协调器不受影响 |
| 意图路由 | `CaptureIntent` + `OverlayFinishRouter`（纯函数可单测）：截图 → 有标注合成/无标注复制；滚动/录屏/文字识别 → 选区确定后立即执行（不留标注工具栏） |
| 工具栏重做 | 单行深色毛玻璃胶囊，贴**选区上方**（原为下方两行浅色）：[色圆（点击展开 8 色板+线宽三档，胶囊动态变宽）] 矩形/椭圆/箭头/画笔/马赛克/模糊/文字/编号 \| 撤销 \| 贴图 保存 ✕ ✓；白色线性图标，当前工具蓝色高亮 |
| 去掉「选择」按钮 | `activeTool: AnnotationType?`，nil = 选择（拖动 = 移动选区/标注）；再点当前工具 = 取消回到选择（与钉钉一致） |

OCR/长截图/录制入口从选区工具栏移到模式胶囊（右键菜单仍保留全部入口）。

## 第三轮反馈修正：图标统一/录屏边框/✓ 语义/OCR 结果窗（2026-11-23）

| 反馈 | 实现 |
| --- | --- |
| 图标不统一、缺文字提示 | 工具栏按钮改为图标(15pt 统一 SymbolConfiguration)+9pt 白色文字标签竖排；画笔→scribble、模糊→drop、编号→number |
| 录屏看不到边框 | `RecordingRegionBorderPanel`：区域四周 3pt 红色描边 + 四角白点，`ignoresMouseEvents`；录屏流排除自身 App 不会入镜；随 cleanup 隐藏（窗口录制不画：窗口可移动） |
| ✓ 应写剪贴板 | `deliver(.copy)` 去掉 autoOpenEditor 分支，一律复制 + toast；设置页移除该开关（编辑器改经右键「在编辑器中打开」） |
| OCR 先显示不立刻关 | `OCRResultPanelController`：结果窗口展示识别文字（可选中），「复制全部/关闭」手动操作，不再自动写剪贴板自动消失 |

CaptureResultToast 增加 showText 纯文本变体（与图片 toast 共用定位/悬停逻辑）。

## 取色器钉钉化 + Esc 直取消（2026-11-23，第四轮反馈）

依据用户提供的钉钉取色器实测截图（官方说明文档需登录无法读取）：

- 放大镜：像素网格（每源像素一格坐标纸纹理）+ 蓝色十字贯穿 + 中心白色空心取色框
- 信息区三行（左对齐）：`坐标：x, y` / `■ 当前格式色值` / `⌘C 复制颜色值 · Shift 切换 RGB/HEX`
- Shift 边沿检测切换 HEX/RGB（flagsChanged）；C 与 ⌘C 均按当前格式复制
- ESC 改为直接取消截图（去掉 草稿→选中标注→选区→取消 的阶梯；回到选择态走右键「重选」）

## 文字/编号工具修复（2026-11-23，第五轮反馈）

- 文字面板在 mouseDown 处理中途弹出：makeFirstResponder 后紧跟的 mouse-up 让 field editor
  立即结束编辑（空文本 → 走取消 → 面板闪退）；热键触发时 App 未激活也收不到键盘。
  修复：落点暂存 `pendingTextPoint`，mouseUp 后再弹面板；show() 先 NSApp.activate，
  `becomesKeyOnlyIfNeeded = false`
- 编号/绘制工具点击选区外会触发「新建选区」→ 框选区域突变。修复：绘制工具激活时
  选区外点击一律忽略（与钉钉一致）

## 文字输入彻底重构：内嵌 Overlay 窗口（2026-11-23，第六轮反馈）

独立无边框 NSPanel 方案三轮未修利索（key window/first responder/激活状态多变量纠缠，
用户实测仍无法输入且 Esc 失效）。放弃该方案：

- 输入框直接挂到鼠标所在屏的 Overlay 视图上（NSTextField 子视图），
  复用 Overlay 窗口已被验证的键盘链路（Enter/Esc/取色键一直正常）
- NSTextFieldDelegate doCommandBy 拦截 Enter（提交）/ Esc（取消），不依赖
  didEndEditing 的模糊语义；点击其他处提交并吞掉该次点击
- Overlay present 时 NSApp.activate（热键触发路径的键盘保障）
- 删除 OverlayTextEntryPanel；CaptureOverlayController 改为 NSObject 子类以实现 NSTextFieldDelegate

## 自动取色 + Shift 切换 + 编号卡死修复（2026-11-23，第七轮反馈）

1. 自动取色：showsMagnifier 改为「鼠标点+快照可用即显示」，mouseMoved 全程更新
   currentDragPoint（含已有选区悬停、标注草稿拖拽），不再需要按住拖拽才出取色
2. Shift 切换 RGB/HEX 失效根因：CaptureOverlayView 未声明 acceptsFirstResponder，
   flagsChanged 不送达（keyDown 能工作属侥幸路径）。补上声明
3. 编号后无法退出/按钮无响应根因：工具栏/模式胶囊面板可被点击成为 key window，
   一次点击即偷走键盘焦点。两个面板 canBecomeKey=false；切工具先结束文字编辑

## 文字编辑态移开自动提交（2026-11-23，第八轮反馈）

用户实测：输入框打开后鼠标移到工具栏，按钮点不了、仍处于文字输入态。
修复：mouseMoved 检测鼠标移出输入框范围（含 6pt 容差）即自动提交（非空落标注），
编辑态立即解除，工具栏恢复正常点击；endTextEditing 加防重入保护。

## 层序翻转根治：CGEvent 自动化复现实锤（2026-11-23，第九轮反馈）

不再盲改——写 CGEvent 驱动脚本 + CGWindowList 层序 dump + 应用侧探针日志，本地完整复现：

| 证据 | 结论 |
| --- | --- |
| driver 分步 dump：工具栏选区后置顶 ✓ → 点选区内（marker/文字）后 overlay 升到工具栏上面 | "其他按钮点不了" = 点击实际落在 overlay 上（变成绘制/重开输入框） |
| 翻转点在 mouseUp 尾部的 updateToolbar 之后；矩形/画笔路径因 orderOut→orderFrontRegardless 循环自愈，marker/文字路径工具栏一直可见跳过置顶 | 显式修复：工具栏显示即无条件 orderFrontRegardless |
| 点击选区会激活 App 并把 key 窗口置顶（nonactivatingPanel 修复后复现消失） | CaptureOverlayWindow 从 NSWindow 改为 NSPanel(.borderless + .nonactivatingPanel) |
| driver2 全流程：文字打字 ab+Return → TEXT COMMITTED → 编号 TOOL TAPPED → UNDO TAPPED → regionAnnotated 交付（含 1 编号 + 1 文字） | 端到端全部打通 |

其他：中文输入法组字 Enter 不再误提交（markedRange）；意图路由每选区只触发一次；
Esc 直接取消；文字输入为 Overlay 内嵌 NSTextField（复用已验证键盘链路），移开自动提交。

## 工具栏补回 OCR/滚动/录屏 + 打字激活修复（2026-11-24，第十轮反馈）

- 工具栏加回 识别文字/长截图/录屏 三按钮（此前移入模式胶囊，用户要求同排可见），
  宽度自适应挂到 position()（固定宽导致新按钮溢出裁剪）
- 打字失效根因（nonactivatingPanel 化后）：点击不再激活应用，热键路径应用可能
  仍是后台态，输入框收不到键盘。修复：输入框打开时 NSApp.activate +
  NSRunningApplication.activate(.activateAllWindows) 双机制 + makeKeyAndOrderFront
- Return 同步收起输入框会让在途按键重新派发到 overlay keyDown（实测触发整图复制）
  → 提交/取消改异步派发
- CGEvent 回归（坐标来自应用自报按钮探针）：文字打字提交 → 编号 → OCR 按钮结束
  并弹结果窗，全程层序稳定

## 取色提交边界修正：移出选区才退出输入态（2026-11-24，第十一轮反馈）

上一轮"移出输入框即提交"判定过严：输入框以点击落点为原点，鼠标停在框角，
打字时手一动就触发提交收起，字打不进去（自动化测试鼠标不动，测不出来）。
修正为钉钉语义：鼠标移出**框选区域**才自动提交；选区内移动不打断输入。
CGEvent 回归：打字时模拟人手晃动 → 字段保持焦点 → 撤销按钮可点。

## OCR 内联化：识别不退出截图（2026-11-24，第十二轮反馈）

钉钉行为对齐：OCR 时截图保持打开。工具栏/右键/模式胶囊的识别文字均改为内联路径
（overlay.onInlineOCR → CaptureCoordinator.runInlineOCR：捕获选区 → Vision 识别 →
结果窗展示），不再走 finish/recognizeRegion。模式胶囊「文字识别」选完区识别后自动
回到截图态（工具栏恢复）。结果窗层级提到 screenSaver+1（高于截图遮罩）。
CGEvent 回归：OCR 后 overlay/工具栏全部存活，撤销按钮仍可点。

## v0.1.5 发布（2026-11-24）

钉钉式截图交互整套落地（模式胶囊 / 一体化工具栏 / 自动取色 / 选区内标注与编辑 /
贴图 / OCR 内联 / 录屏边框 / Esc 取消），CGEvent 自动化回归端到端验证。
发布流程按 docs/releasing.md：打 tag v0.1.5 → release.yml 自动构建。

## 长截图钉钉化 + 工具栏提示（2026-11-24，v0.1.5 后反馈）

- 长截图改为显式流程：选区中央出现 **▶**（`isScrollPending`）→ 点击才开始采集；
  会话控制条 `ScrollCapturePanel`（☑ 自动滚动 / 帧数 / 结束并保存 / 取消）+ 选区蓝色边框；
  不再到底自动结束、不再弹模态授权框（无辅助功能权限时禁用开关并在控制条提示）
- 鼠标驱动滚动 `ScrollEdgeDriver`（纯函数）：鼠标靠近选区下/上边缘按距离加速滚动
- 「结束并保存」→ 历史入库 + 保存面板（不再自动进入编辑器）
- 菜单栏「滚动截图」入口同样走 ▶（`autoScrollPending`）
- 工具栏：长截图图标改 `arrow.up.arrow.down`；自定义悬浮提示 `OverlayTooltip`
  （显示在按钮上方、12pt、鼠标穿透），替换系统 tooltip

教训：CGEvent 驱动脚本会注入真实鼠标事件，与用户操作冲突（表现为光标被"拉回"）。
用户正在使用机器时不得运行会移动光标的自动化。

## 修复：自动滚动时光标被拽回选区中心（2026-11-24）

真实缺陷（非测试脚本所致，用户在无脚本运行时复现）：自动滚动每拍通过 HID 层注入
带固定坐标（选区中心）的滚动事件，系统会把光标移动到该坐标，表现为"鼠标一移开就弹回中间"。

修复 `AutoScroller.postScrollDown`：按坐标找到最前普通窗口（layer 0，排除自身进程）的
所属 PID，用 `CGEvent.postToPid` 直投——坐标仅供对方判断滚哪个视图，光标不再被移动；
找不到目标进程时回退为不设置坐标的 HID 注入。新增 `AutoScrollerRoutingTests`（4 例）。

## 长截图结束方式：停止 / 保存图片 / 取消 / ✓ 复制（2026-11-24）

用户反馈「结束后直接弹保存」不符合钉钉：钉钉提供 停止播放、保存图片、取消、对号（复制）。

- `ScrollCapturePanel` 改两行控制条：提示行 + [☑ 自动滚动][已采集 N 帧]｜[■ 停止][保存图片][取消][✓ 复制]
- 采集中四个动作均可直接用：保存图片 / ✓ 复制 一步完成（先拼接再交付）；「停止」只拼接并进入
  复核态（隐藏自动滚动与停止，保留 保存 / 取消 / ✓）
- `ScrollCoordinator`：`endCapture(then:)` 统一「停采集 → 后台拼接 → 回调」；
  `deliver(_:save:)` 复制走 `ClipboardWriter` + toast、保存走 `SavePanelPresenter`；
  `onStitched` 语义改为「结果被采纳 → 历史入库」，AppEnvironment 不再代弹保存面板
- 帧数上限触发时改为进入复核态（不再直接交付）

## v0.1.6 发布（2026-11-24）

v0.1.5 之后的长截图重构与修补：

- 长截图钉钉化：选区中央 ▶ 开始；会话控制条（自动滚动 / 帧数）；鼠标靠边滚动（`ScrollEdgeDriver`）
- 结束方式：停止 / 保存图片 / 取消 / ✓ 复制（不再强制保存面板、不再自动进编辑器、不再弹模态授权框）
- 修复自动滚动时光标被拽回选区中心（`CGEvent.postToPid` 直投目标进程）
- 工具栏：长截图图标更新、悬浮提示显示在按钮上方并放大、色圆与工具组拉开间距

发布流程按 docs/releasing.md：打 tag v0.1.6 → release.yml 自动构建。
