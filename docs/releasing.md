# 发布运维手册（Releasing）

> 面向维护者的操作手册。发布策略背景见 `DESIGN.md` §22，决策依据见 ADR-028/029。

## 0. 一次性准备（已完成项打勾）

- [x] **EdDSA 密钥对已生成**（本机钥匙串 + 导出文件）
  - 公钥（已在 `CaptureKit/Resources/Info.plist` → `SUPublicEDKey`）：
    `HcFCIA2Y0EYHpiGz+hTIDYgDKC4rkbqTNcIRwYsWWG4=`
  - 私钥文件：`~/.config/capturekit/sparkle_ed25519_privkey.pem`
    **这是唯一副本，请异地备份。** 丢失后老版本无法验证新更新（只能换公钥重发并引导重装）。
- [x] **GitHub 仓库**：`github.com/ahao430/CaptureKit`（main 分支持续推送，tag 触发发布）。
- [x] **配置 Secret**（已完成，共 3 个）：
  - `SPARKLE_PRIVATE_KEY`：`cat ~/.config/capturekit/sparkle_ed25519_privkey.pem` 的完整内容（EdDSA appcast 签名）。
  - `MACOS_SIGNING_P12_B64`：`base64 < ~/.config/capturekit/signing/capturekit-signing.p12`（自签名证书，目的是让 TCC 授权跨版本保留，ADR-030；效果待实机确认）。
  - `MACOS_SIGNING_P12_PASSWORD`：`cat ~/.config/capturekit/signing/p12-password.txt`。
  - **备份提醒**：Sparkle 私钥与签名 p12 是两份信任根，请异地备份 `~/.config/capturekit/` 整个目录。
- [ ] **开启 GitHub Pages**：Settings → Pages → Source 选 `Deploy from a branch` → 分支 `main` / 目录 `/docs` → Save。
  首页地址变为 `https://ahao430.github.io/CaptureKit/`（index.html 已就绪，下载链接自动指向最新 Release）。
- [ ] **改仓库名/账号时**：需同步修改 3 处硬编码（grep `ahao430/CaptureKit`）：
  1. `CaptureKit/Resources/Info.plist` 的 `SUFeedURL`（+ 单测 `UpdateConfigTests` 断言）
  2. `docs/index.html` 内的下载/仓库链接
  3. `README.md` 安装章节链接
  CI（workflows）使用 `${{ github.repository }}`，无需改。

## 1. 日常发布流程

```bash
git tag v1.0.0
git push origin v1.0.0
```

release.yml 自动完成：Universal 构建 → 测试 → 固定证书签名（`CaptureKit Developer`，ADR-030）→ DMG + 更新 zip → EdDSA 签名 appcast → 创建 GitHub Release 并上传 `CaptureKit.dmg` / `CaptureKit.zip` / `appcast.xml`。

版本规范：tag = `vX.Y.Z`；`CFBundleVersion` 取 CI run number（自动递增，勿手填）。发布说明直接写在 tag annotation 或 Release 页（`generate_release_notes` 会自动生成增量对比）。

## 2. 本地演练（不碰 GitHub）

```bash
# 完整产物（DMG + zip，双架构 + 签名校验 + Sparkle 嵌入断言）
scripts/build-release.sh 0.1.0 99

# appcast 生成（用本地私钥，URL 前缀任意填一个模拟 Release 地址）
mkdir -p /tmp/appcast-dryrun && cp build/release/CaptureKit.zip /tmp/appcast-dryrun/
scripts/make-appcast.sh /tmp/appcast-dryrun https://github.com/ahao430/CaptureKit/releases/download/v0.1.0 \
  ~/.config/capturekit/sparkle_ed25519_privkey.pem
cat /tmp/appcast-dryrun/appcast.xml
```

## 3. 首次发布验收清单（人工）

1. **CI**：push 后 build.yml 绿灯（Build + 全量测试在 macos-26 runner 上）。
2. **Release**：打 tag 后三附件齐全；DMG 挂载 → 拖入 Applications → 启动（首次 `xattr` 解除隔离）。
3. **双架构**：Intel 机或 `lipo -info` 复核（CI 日志有输出）。
4. **Sparkle 更新回路**：装 v1 → 发 v2 → 菜单「检查更新…」→ 确认安装 → 自动重启为 v2。**需要验证：v0.1.4+ 之间的更新是否不再触发重新授权屏幕录制**（ADR-030 的预期，尚未实机确认）。若更新后被 Gatekeeper 拦截，重跑 `xattr`。
4b. **签名自检**：下载 DMG 后 `codesign -dvv /Volumes/CaptureKit/CaptureKit.app` 应显示 `Authority=CaptureKit Developer`。v0.1.3 草稿及更早版本显示的是 `Signature=adhoc`。
5. **Homepage**：Pages 生效，下载按钮拿到最新 DMG。
6. **隐私复核**：Sparkle 检查更新时抓包/日志确认无系统剖析上报（SUEnableSystemProfiling=false）。

## 4. 故障排查

| 症状 | 处理 |
| --- | --- |
| CI 上 SPM 拉取 Sparkle 超时 | 重跑即可（GitHub 网络抖动）；持续失败检查 `exactVersion` 与网络策略 |
| appcast 缺签名 | Secret `SPARKLE_PRIVATE_KEY` 未配置或内容有换行——value 必须与私钥文件内容逐字一致 |
| 客户端「检查更新」报错 | 看 App 日志（Console.app 搜 SUUpdater）；常见：`SUPublicEDKey` 与私钥不配对、feed URL 404（首个 Release 未上传 appcast.xml） |
| 升级后每次启动都要求重新授权屏幕录制 | v0.1.2 及更早是 ad-hoc 签名，授权留不住。先 `tccutil reset ScreenCapture com.wanghao.capturekit` 清掉旧条目，再安装 v0.1.4+ 并重新授权一次。v0.1.4 起固定证书方案已实机验证有效（含 v0.1.5 覆盖安装后授权保留）；若此后仍复现，先核对安装包签名是否为 `Authority=CaptureKit Developer`（`codesign -dvv`），再重新排查 |
| 更新安装后被 Gatekeeper 拦截 | ADR-029 已知边界：重跑 `xattr -dr com.apple.quarantine /Applications/CaptureKit.app` |
| 老版本收不到新更新 | 检查 `CFBundleVersion`（run number）是否严格递增——Sparkle 按 build 号比较 |
