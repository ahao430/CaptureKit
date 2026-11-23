# 关键技术决策记录（ADR）

> 记录决策及原因，避免后续 Agent 擅自更改架构（DESIGN.md 要求）。
> 格式：决策 → 背景 → 理由 → 影响面。

---

## ADR-001 最低部署版本 macOS 14.0

- **背景**：DESIGN.md §19 要求先验证核心 API 再锁定版本。
- **决策**：macOS 14.0（Sonoma）。
- **理由**：`SCScreenshotManager`（静态截图）为 14.0+，覆盖截图全链路最简路径；M1 目标设备可升级，实际覆盖率可控。
- **影响**：不为 12/13 写 SCStream 兼容层；若未来需要支持 13，须实现 `SCStream` 单帧捕获 fallback 并重新验证。

## ADR-002 静态截图用 SCScreenshotManager，区域捕获 = 整屏捕获 + 像素裁剪

- **背景**：SCK 无直接区域捕获 API；`SCStreamConfiguration.clipBounds` 版本行为需另行验证。
- **决策**：整屏捕获 → `ScreenGeometry.pixelRect` → `CGImage.cropping`。
- **理由**：路径简单、不依赖 clipBounds 的多版本行为；裁剪前 integral+clamp 防越界。
- **影响**：单次区域截图需捕获整屏（M1 上耗时可忽略）；录制模块（Phase 4）不受此决策约束。

## ADR-003 缩放比例由「实际图像尺寸 / 显示器逻辑尺寸」推导

- **背景**：Retina、非整数倍缩放、SCK 输出与请求尺寸可能不一致。
- **决策**：`ScreenGeometry.pixelRect` 不读取 `backingScaleFactor`，按实际输出推导 scale。
- **理由**：对任意缩放与 API 行为鲁棒；逻辑集中一处便于单测。
- **影响**：业务代码禁止自行乘 backingScaleFactor（DESIGN.md §5.2 约定）。

## ADR-004 全局快捷键用 Carbon RegisterEventHotKey

- **背景**：无公开原生 Swift API；NSEvent addGlobalMonitorForEvents 不拦截且不可靠。
- **决策**：Carbon Hot Key API（`RegisterEventHotKey` + `GetApplicationEventTarget`）。
- **理由**：久经验证的方案，iTerm/CleanShot 等主流工具同款；依赖仅 HIToolbox。
- **影响**：回调为 C 函数指针，经 `Unmanaged` 传上下文、主线程分发；注册失败必须显式提示（不允许静默）。

## ADR-005 应用形态：纯 AppKit 入口 + LSUIElement + 动态 activationPolicy

- **背景**：菜单栏应用；SwiftUI App 生命周期对无窗口 Scene 支持较弱。
- **决策**：`@main` 手写 `NSApplication.run()`；Info.plist `LSUIElement=true`；设置里切换 `setActivationPolicy`。
- **理由**：最少魔法、完全可控；Settings 用 AppKit 窗口 + SwiftUI 内容（NSHostingController）混合。
- **影响**：不使用 SwiftUI `Settings` scene；⌘, 等菜单快捷键需要主菜单支持时另行评估。

## ADR-006 选区交互：共享 OverlaySelectionModel + 每屏一个 NSWindow/NSView

- **背景**：多显示器、跨屏拖拽。
- **决策**：每个 NSScreen 创建 borderless 透明窗口（screenSaver level、canBecomeKey 子类），视图共享全局坐标选区模型，各自绘制本屏交集。
- **理由**：单屏/多屏代码路径统一；事件 grab 保证拖拽跨屏不断流。
- **影响**：Phase 1 的控制点/放大镜/吸附在 view 层扩展，模型保持全局坐标。

## ADR-007 排除自身窗口：SCContentFilter(excludingApplications: [SCRunningApplication])

- **背景**：Overlay/工具栏/Toast 不得进入捕获结果（窗口截图同理）。
- **决策**：从 `SCShareableContent.applications` 中按自身 PID 匹配 `SCRunningApplication` 传入 filter。
- **理由**：filter 参数类型是 SCRunningApplication（非 NSRunningApplication）；这是 Phase 4「HUD 排除」的同一机制预演。
- **影响**：`captureDisplay` 需要传入 SCShareableContent（签名已含）。

## ADR-008 工程由 xcodegen 管理（project.yml 为源）

- **背景**：pbxproj 不可读且易冲突。
- **决策**：`project.yml` → `xcodegen generate`。
- **理由**：可 code review、可重复生成；Swift 语言模式 5（后续可迁移 Swift 6 strict concurrency）。
- **影响**：改 target/依赖须改 project.yml 后重新 generate，不要手改 pbxproj。

## ADR-009 放大镜/悬停高亮基于「展示时刻屏幕快照」而非实时流（Phase 1）

- **背景**：放大镜与窗口高亮需要屏幕像素数据；Overlay 覆盖在真实屏幕之上。
- **决策**：Overlay present 后异步对每屏做一次静态捕获（`SCScreenshotManager`，排除自身窗口），快照存入共享模型；放大镜从快照裁剪放大。
- **理由**：无需 SCStream 生命周期；排除自身窗口使快照天然不含 Overlay 暗化层；dismiss 时统一释放。
- **代价**：快照之后屏幕内容变化不会反映到放大镜（可接受）；快照常驻内存约每屏一帧物理像素（5K 屏 ≈ 56MB），仅展示期间持有。

## ADR-010 窗口检测/吸附使用 SCShareableContent 的窗口 frame 集合（Phase 1）

- **背景**：悬停高亮、单击选中窗口、边缘吸附需要窗口几何。
- **决策**：与快照同一次 `SCShareableContent` 调用中取 `content.windows`（排除自身与过小窗口），存 frame 列表；命中取「包含点的最小面积 frame」，吸附阈值为 6pt，纯函数 `ScreenGeometry.snappedPoint` 实现并有单测。
- **理由**：不引入 CGWindowList 第二套窗口 API；数据在 Overlay 展示期间固定，行为可预期。
- **影响**：展示期间新开/移动的窗口不会更新检测列表（可接受）。

## ADR-011 编辑器标注 = 值类型几何枚举 + 统一渲染管线；坐标 y 向上（Phase 2）

- **背景**：DESIGN.md §7 要求画布显示与导出合成一致、非破坏性编辑。
- **决策**：`AnnotationGeometry` 为带关联值的值类型枚举（SE-0295 自动 Codable）；`AnnotationRenderer` 是唯一绘制实现，画布与 `compose(baseImage:annotations:)` 导出共用；编辑器全链路使用「图像坐标 y 向上、原点左下」（与画布视口一致），画布 NSView 非 flipped。
- **理由**：单一渲染源保证一致；y 向上避免 AppKit/CG 混用翻转心智负担；`CGContext.draw(image, in:)` 在非翻转上下文天然正立。
- **影响**：标注几何不得混入 Overlay 的 y 向下像素坐标；马赛克/模糊等基于像素的实现须做一次翻转转换。

## ADR-012 Undo/Redo 用 Command（add/remove/update 三命令），slider 实时编辑不入栈（Phase 2）

- **背景**：DESIGN.md §7.4 要求 Command Pattern 且不保存大图副本。
- **决策**：命令只存标注值（几何/样式差异）；Inspector slider 拖动期间走 `setStyleLive` 直接驱动渲染，`beginStyleEdit/endStyleEdit` 之间只记一条命令，避免撤销栈被中间态淹没。
- **理由**：标注值数据量极小（KB 级），无需快照整组；交互上一次拖动对应一次撤销符合直觉。
- **影响**：新增标注类型时 update 命令天然兼容（值替换），无需扩展命令集。

## ADR-013 裁剪为文档级 cropRect（非破坏），显示与导出统一走 effectiveImage（Phase 2）

- **背景**：裁剪是破坏性最大的编辑操作；DESIGN.md 要求非破坏性编辑与可撤销。
- **决策**：`EditorDocument` 持有 `cropRect`（原始图像坐标）；`effectiveImage` 为 baseImage 按 cropRect 裁剪的缓存，画布显示/标注坐标/导出合成全部基于 effectiveImage；`setCrop` 命令同时记录裁剪区与标注集合（标注平移到新坐标系，框外标注剔除）。
- **理由**：原始 CGImage 从不修改；连续裁剪用原始坐标累计表达；撤销/重置只切换 cropRect 并还原标注。
- **影响**：马赛克/模糊渲染基于 effectiveImage 像素；重复裁剪-撤销链路已由单测覆盖。

## ADR-014 马赛克/模糊实时渲染不缓存（Phase 2）

- **背景**：效果类标注需要原图像素参与合成。
- **决策**：绘制时从 baseImage 裁剪区域 → 缩小放大（马赛克）/ CIGaussianBlur（模糊）→ 贴回，无缓存；CIContext 复用单例。
- **理由**：区域通常小（数百像素），单帧毫秒级；避免缓存失效管理复杂度。
- **影响**：超大区域频繁缩放时可能掉帧；如需优化按 (annotationID, rect, 参数) 做 NSCache（Phase 6）。

## ADR-015 区域录制 = 整屏 SCStream + 帧管线逐帧裁剪（Phase 4）

- **背景**：`SCStreamConfiguration.clipBounds` 在当前 SDK（MacOSX26.5）不存在（编译期验证）；区域录制的裁剪必须另寻路径。
- **决策**：SCStream 始终捕获整台显示器（物理像素）；`PixelBufferCropper` 在帧回调后按像素矩形裁剪（视频走 CVPixelBuffer 重造 CMSampleBuffer，GIF 走 CGImage.cropping）。裁剪 rect 由 `PixelBufferCropper.pixelRect`（逻辑区域 → 帧像素坐标，y 翻转 + 按实际帧尺寸缩放）计算，单测锁定。
- **理由**：不依赖版本不确定的裁剪 API；逻辑集中于一个纯函数；帧尺寸与请求不一致时按实际帧推导。
- **影响**：每帧多一次位图拷贝（M1 上区域录制可忽略）；CVPixelBuffer→CGImage 转换走 CIImage（`CGImage(cvpixelBuffer:)` 在此 SDK 不可用，编译期验证）。

## ADR-016 录制写入链路：直接追加 + 背压丢帧 + 暂停时间轴重写 PTS（Phase 4）

- **背景**：design.md §8.4 要求有界缓冲、明确丢帧策略、时间戳准确。
- **决策**：
  - `VideoWriter`：AVAssetWriterInput `expectsMediaDataInRealTime = true`，`isReadyForMoreMediaData == false` 时直接丢帧（无中间队列积压）；
  - 暂停：`PauseTimeline`（纯函数，单测）记录暂停段，帧丢弃 + 输出 PTS 扣除暂停段后由 `CMSampleBufferCreateCopyWithNewTiming` 重写；
  - GIF：帧率节流（fps 间隔的 0.9 倍）+ 固定帧延迟，`CGImageDestinationCreateWithURL` 增量追加，不驻留全部帧。
- **理由**：SCStream 的 `queueDepth` 已提供有限缓冲；应用层再加有界队列只会后移背压；丢帧策略对录屏可接受。
- **影响**：编码器偶发拥塞时录制丢帧而非卡顿（符合预期）；暂停/恢复时间轴精度受帧间隔限制（±1 帧）。

## ADR-017 HUD 不入镜：SCContentFilter 排除自身 app（Phase 4）

- **决策**：录制 filter 一律 `excludingApplications: [自身 SCRunningApplication]`（与截图 ADR-007 同机制）；HUD 为本 app 窗口，天然被排除。
- **验证**：需人工确认录制结果中无 HUD/菜单栏 Popover/Toast（验收清单）。
- **兜底**：HUD 可拖动（`isMovableByWindowBackground`），若个别系统版本过滤失效用户可移开。

## ADR-018 SQLite 用自研轻量封装（sqlite3 C API），不引入第三方 ORM（Phase 5）

- **背景**：design.md §1.2 不为简单功能引入第三方依赖；表结构简单（单表起步）。
- **决策**：`SQLiteDatabase` 封装 sqlite3 C API：专用串行队列（design.md §13.2）、WAL、参数化绑定（防注入）、`PRAGMA user_version` 迁移（幂等）。仓库层按需写 SQL。
- **理由**：依赖面最小；查询需求（分类/搜索/排序）SQL 直写最直观；迁移机制符合 design.md §10.5 要求。
- **影响**：新增表结构时在 `migrations` 数组追加版本；复杂查询多时再评估抽象层。

## ADR-019 剪贴板来源应用按「读取时刻前台应用」近似（Phase 5）

- **背景**：macOS 未提供 pasteboard 来源应用 API；plan.md §2.7 要求应用排除与来源展示。
- **决策**：`ClipboardReader` 在读取时记录 `NSWorkspace.frontmostApplication.bundleIdentifier` 作为疑似来源，仅用于展示与排除过滤（近似值，不作为安全依据）。
- **影响**：后台 App 复制内容（如密码管理器自动填充）来源归属可能不准——敏感过滤是主要防线（ADR 记录于 development-progress）。

## ADR-020 剪贴板去重 = 内容哈希 + bump；来源行为不做关系建模（Phase 5 第一版）

- **背景**：design.md §10.3 建议来源关系表；plan.md §2.8 允许第一版用简单哈希去重。
- **决策**：第一版只做内容哈希（文本规范化 SHA256 / 二进制 SHA256）去重：命中即 bump `updated_at`，不插入新行；截图与剪贴板联动（截图先入库，复制后剪贴板同哈希命中 bump，不产生第二条）。
- **理由**：避免重复记录优先于来源溯源；关系表待批次 2/Phase 6 需要时再加（migration 追加）。
- **影响**：无法表达"同一内容多个来源"的谱系；可接受。

## ADR-021 音频轨在 VideoWriter 初始化时预建（SCK 约定格式）（Phase 6）

- **背景**：AVAssetWriter 要求所有 input 在 `startWriting()` 之前添加；而音频帧格式只有运行时才见。
- **决策**：利用 ScreenCaptureKit 音频输出的约定格式（48kHz / Float32 / 双声道，`audioChannelCount` 默认），在 `VideoWriter.init` 时按 `makeDefaultAudioFormatDescription()` 预建 AAC 音轨（audioEnabled 时）；运行期若实际格式与预期不符，AVAssetWriter 以 sourceFormatHint 自动重采样兼容。
- **验证**：单测以约定格式写入静音块 → 导出 mp4 含 1 视频轨 + 1 音频轨；真机回放有声需人工验收。
- **影响**：`SCStreamOutputType.microphone` 在本 SDK 已存在（编译期确认），后续麦克风采集走独立输出并复用同 writer 音轨机制。

## ADR-022 马赛克/模糊渲染缓存（Phase 6，对 ADR-014 的升级）

- **决策**：`EffectRenderCache`（NSCache，countLimit 32），key = 类型|标注ID|区域|参数|底图 ObjectIdentifier；命中直接 blit。
- **失效**：标注移动/缩放/改参数、裁剪（effectiveImage 换实例）自动 miss；无需手动失效逻辑。
- **代价**：移动/缩放过程中的每一帧 miss（与之前无缓存相同）；静止状态（多数时间）零计算。

## ADR-023 GIF 导出不用 AVMutableVideoComposition(propertiesOf:)（Phase 6）

- **背景**：`AVMutableVideoComposition(propertiesOf:)` 在同步路径下偶发 `AVAssetReader.startReading()` 失败（AVFoundationErrorDomain -11841，疑为内部指令未就绪的竞态；单测稳定复现）。
- **决策**：GIF 导出改用 `AVAssetReaderTrackOutput` + 输出 settings 像素缩放；方向修正改为读取 `preferredTransform` 推导 orientedSize（截屏录制永不旋转，变换仅用于尺寸推导）。
- **代价**：真正旋转过的视频导出 GIF 会方向错误——非截图场景，可接受；mp4 变速导出仍用 composition（重编码路径未观察到该竞态，出现时按 ADR-021 降级策略失败重试）。

## ADR-024 点击高亮 = 全局鼠标监听 + 帧到达时合成（Phase 6）

- **背景**：plan.md §2.6.5 点击效果；NSEvent 全局鼠标监听不需要辅助功能权限（键盘才需要）。
- **决策**：`ClickHighlighter` 记录 mousedown（全局坐标 + wall clock，0.45s 存活）；帧回调时刻取活跃效果，经 `ClickEffectRenderer.pixelPoint`（内容原点/尺寸 + y 翻转 + 输出缩放，纯函数单测）换算到输出帧像素坐标，就地绘制扩散圆环后写入编码器。
- **取舍**：效果定时用 wall clock 而非帧 PTS——点击与帧到达毫秒级错位可接受，省去时间轴对齐复杂度；仅视频录制生效（GIF 15fps 下效果不明显）。

## ADR-025 麦克风采集 = SCStream .microphone 输出（macOS 15+ 门控）+ 双来源单音轨（Phase 6）

- **API 事实（编译期验证）**：`SCStreamConfiguration.captureMicrophone` 与 `SCStreamOutputType.microphone` 需要 **macOS 15.0+**；部署目标 14.0 下全部用 `#available` 门控，14 上开关无效（footer 已注明）。权限走 TCC 麦克风（`AVCaptureDevice.authorizationStatus(for: .audio)`），拒绝时降级为无麦克风录制并记日志。
- **决策**：系统音频与麦克风输出共用 VideoWriter 的单条 AAC 音轨；`enqueueAudio` 统一走暂停过滤 + PTS 调整，并用 `lastAudioPTS` 单调保护——双来源 PTS 乱序时丢弃迟到块（毫秒级间隙可接受，避免 AVAssetWriter 因 PTS 回退报错）。
- **影响**：真机双源同时录音的混音质量需人工验收；若质量不可接受，后续升级为 AVMutableAudioMix 离线混音。删帧编辑（plan.md P1）延后：需要帧级时间轴 UI，投入产出比低于已完成项，记录于进度文档。

## ADR-026 滚动截图 = 手动滚动 + 被动采集，不注入滚动事件（Phase 3 基础版）

- **背景**：自动滚动需 CGEvent 注入（辅助功能权限，风险面大）；plan.md §2.5 要求先做稳定基础拼接。
- **决策**：v1 用户手动滚动，应用以 0.35s 周期被动抓帧（复用截图引擎 captureRegion）；`ScrollFrameMatcher` 在 128×256 灰度降采样上逐候选位移求重叠区平均绝对差，最小差为位移（d=0 判重复帧跳过）；`ScrollImageStitcher` 按位移追加新增区，低置信段（<0.25）整帧追加防内容丢失，总高上限 16000px。
- **代价**：滚动过快/动态内容会产生重复或断层（HUD 提示匀速滚动；验收清单注明限制）；自动滚动与人工调整延后。
- **测试**：合成"长页"图 + 视口裁剪模拟滚动 → 位移恢复 ±3px、拼接还原、去重、降级全链路单测。

## ADR-027 自动滚动 = CGEvent 滚轮注入（辅助功能权限门控）+ 到底自动完成（Phase 3 补全）

- **API 事实（编译期验证）**：本 SDK 事件构造为 `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:...)`（2 后缀，wheel1 为 Int32）；`CGEventField.scrollWheelEventIsContinuous` 不可用（pixel units 事件本身即像素语义，无需该标志）。
- **决策**：`AutoScroller` 构造 pixel 单位向下滚轮事件并 `.cghidEventTap` 注入到选区中心（AppKit→CG 坐标 y 翻转纯函数，单测）；权限走辅助功能 `AXIsProcessTrusted()`，未授权弹一次引导（打开系统设置/手动滚动二选一）后降级手动；设置开关默认开。到底检测：自动模式下连续 2 帧位移为 0 且高置信 → 自动完成。
- **取舍**：滚动步长固定 90px/0.35s（≈257px/s，多数页面可接受）；注入事件只路由到选区下的窗口，不影响其它输入；手动滚动始终可用（匹配器不区分来源）。

## ADR-028 GitHub Releases 分发：Universal DMG + 稳定资产名 + ad-hoc 签名（发布基建）

- **背景**：无 Developer ID / 不公证（发布策略定稿）。需要零服务器成本的官方分发通道。
- **决策**：
  - 产物单一 DMG（`hdiutil` UDZO，App + `/Applications` 符号链接），`scripts/build-release.sh` 全流程本地可复现（xcodegen → `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` Release 构建 → `lipo` 双架构断言 → `codesign --force --sign - --deep` ad-hoc 统一签名 + verify → DMG + ditto zip）。
  - **资产名固定** `CaptureKit.dmg` / `CaptureKit.zip` / `appcast.xml`：`releases/latest/download/<name>` 是永久直链，Homepage 与 feed 均不随版本改 URL。
  - Gatekeeper 引导走 README/Homepage 的 `xattr -dr com.apple.quarantine`（只清隔离属性，不是安全验证；文档明示仅对信任来源使用）。
- **验证**：本地演练输出双架构 lipo 信息、codesign verify 通过、DMG/zip 生成（见进度文档验证记录）。

## ADR-029 自动更新 = Sparkle 2（appcast 作为 Release 附件 + EdDSA + 关闭系统剖析）

- **API 事实（工具实测）**：Sparkle 2.10.1 发行包含 `bin/generate_keys` / `bin/generate_appcast` / `bin/sign_update`；`generate_appcast --ed-key-file -` 支持从 stdin 读私钥（CI Secret 友好），`--download-url-prefix` 直接生成绝对 enclosure URL；密钥存 macOS 钥匙串，`generate_keys -x` 可导出私钥文件。
- **决策**：
  - SPM 锁定 `exactVersion: 2.10.1`；`UpdateCoordinator` 包装 `SPUStandardUpdaterController`，应用侧 `AppSettings.update.autoCheck` 是唯一事实来源，启动与变更时推送给 Sparkle（避免双写漂移）。
  - **feed 即 Release 附件**：`SUFeedURL = …/releases/latest/download/appcast.xml`，省去 Pages/服务器维护；每次发布由 CI 重新生成签名 appcast 覆盖上传。
  - Ed25519 密钥对已生成：公钥入 `Info.plist SUPublicEDKey`，私钥导出至 `~/.config/capturekit/sparkle_ed25519_privkey.pem`（仓库外，勿提交、勿丢失——丢失则老版本无法校验新更新，只能重发 + 换 key 引导重装）。
  - 隐私：`SUEnableSystemProfiling = false`（检查更新零信息上报）；`SUAutomaticallyUpdate = false`（安装需确认）。
- **边界（人工验收项）**：未公证应用经 Sparkle 更新后可能再被 Gatekeeper 拦截（quarantine 属性随新包回来），届时重跑 `xattr` 即可——已写入 README/Homepage；EdDSA 完整性校验 ≠ Apple 公证。

## ADR-030 稳定签名 = 自签名代码签名证书（TCC 授权跨版本保留；v0.1.2 用户实测驱动）

- **根因（用户实测 v0.1.2 仍每次弹授权）**：TCC 把屏幕录制授权绑定到应用的代码签名标识。ad-hoc 签名的 cdhash 每次构建都不同——Sparkle 升级一次、授权即失效一次；且 System Settings 对 ad-hoc 应用的开关写入经常不生效（切换后仍拒绝），用户陷入「授权→失败→再授权」循环。此前 ADR-029 文档的「每版本重新授权一次」在真实使用中不可接受。
- **决策**：本地生成自签名代码签名证书（CN=CaptureKit Developer，EKU=codeSigning，10 年），导入登录钥匙串并信任；`build-release.sh` 用 `MACOS_SIGNING_IDENTITY` 签名（缺失时回退 ad-hoc 并告警）；CI 从 Secret 导入 p12 到临时钥匙串。TCC 从此绑定证书身份——同一证书签名的任何版本（含 Sparkle 更新）授权自动保留。
- **工具链实证**：OpenSSL 3 默认 p12（PBES2/AES-256）macOS `security import` 报 MAC 校验失败，需 `-certpbe/-keypbe PBE-SHA1-3DES -macalg sha1`；`security add-trusted-cert -r trustRoot`（用户域）非交互可用；`find-identity -p codesigning` 验证身份有效。
- **代价**：p12 是信任根，丢失则授权再次失效（与 Sparkle EdDSA 私钥同级备份）；证书 10 年过期需续签重发引导。无 Apple 公证的安全语义不变（EdDSA 验签 + 用户信任来源）。
