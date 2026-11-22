# 开发与发布

## 环境要求

- macOS 15 或更高版本
- Xcode 16 或更高版本
- Swift 6.0+ 工具链（Xcode 16+）
- 可选的 Apple Developer 签名身份；无证书时可使用 ad-hoc 签名

仓库使用 `Package.swift`，没有 `.xcodeproj`。可以在 Xcode 中直接打开
`Package.swift`，也可以使用命令行构建。

## 首次开发

```bash
swift test
swift build
```

运行测试会构建应用目标，并执行当前全部单元与合成测试，其中包括真实
AVFoundation 合成导出。测试通常在数秒内完成。
10 分钟长时导出验收默认跳过：

```bash
ANISE_RECORDER_LONG_EXPORT=1 swift test \
  --filter AniseRecorderTests/testTenMinuteProjectExport
```

打开 Xcode：

```bash
open Package.swift
```

## 打包运行

```bash
./scripts/build_app.sh
open 八角录屏.app
```

脚本会：

1. 执行 `swift build -c release --product anise-recorder`。
2. 重建 `八角录屏.app`，复制可执行文件、`Info.plist` 和图标。
3. 优先使用本机 `Developer ID Application` 证书；找不到时使用 ad-hoc 签名。
4. 用 `Resources/AniseRecorder.entitlements` 声明摄像头与音频输入
   （`com.apple.security.device.camera` / `audio-input`）。hardened runtime
   下缺少这两项时，系统会直接拒绝授权：不弹窗，隐私面板列表里也看不到
   本应用——改动签名参数时不要漏掉 `--entitlements`。

可以显式指定签名身份：

```bash
ANISE_RECORDER_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build_app.sh
```

`八角录屏.app` 和 `.build/` 都是生成物，已被 `.gitignore` 忽略。只运行
`.build` 中的裸可执行文件无法可靠复现屏幕录制和摄像头授权流程，涉及系统
权限的验收应使用打包后的 App。

## 权限与调试

首次使用需要在“系统设置 › 隐私与安全性”中允许：

- 屏幕与系统音频录制
- 麦克风
- 摄像头
- 语音识别（只在本机字幕初稿时）

如果重新签名后权限没有沿用，退出并重新打开 App。需要为本应用重置某项权限：

```bash
tccutil reset ScreenCapture com.localstudio.recorder
tccutil reset Microphone com.localstudio.recorder
tccutil reset Camera com.localstudio.recorder
tccutil reset SpeechRecognition com.localstudio.recorder
```

这些命令只重置本项目 bundle 标识对应的权限，下次使用时会重新弹出授权提示。
摄像头/麦克风记录由系统级 TCC 管理：终端没有「完全磁盘访问权限」时，
`tccutil reset Camera …` 可能提示成功但实际不生效，此时用
`sudo tccutil reset Camera com.localstudio.recorder` 或在系统设置里手动改。

常见排查：

- 没有画面：确认屏幕录制权限，彻底退出后重开 App。
- 没有系统声音：确认录制设置中已开启，并检查输出设备是否在播放。
- 没有麦克风：确认权限和输入设备，必要时重新选择麦克风来源。
- 摄像头未启用：应用会保留录屏并按错误降级为无摄像头工程，检查设备占用
  和权限。
- 本机字幕不可用：确认语音识别权限、系统语言包和
  `SFSpeechRecognizer.supportsOnDeviceRecognition`；应用不会改用云端识别。
- 窗口列表为空：目标窗口可能已关闭、被最小化且系统未返回，或开启了
  “仅当前桌面”而窗口在别的桌面；关闭该开关并点“刷新窗口”后重试。
- 旧工程看不到：检查 `project.json` 是否可解码；不要直接删除原目录，先备份。

## 本地数据

工程与素材目录：

```text
~/Movies/八角录屏/
```

录制偏好保存在 `UserDefaults` 的 `LocalStudio.recordSetup`。导出文件写入用户
在保存面板中选择的位置。调试时不要随意删除该目录；测试创建的临时工程会在
测试结束时清理。

## 图标与品牌 Logo

品牌资产（八角线描、白底、图谱蓝线条）：

- 图标源：`Resources/AppIcon-source.png`（1024×1024，白底 + 圆角透明角；
  原始资产固定不改）。生成时按 macOS 画布规范把本体缩到 824、四周各留
  100 透明边，成品写入 `Resources/AppIcon-1024.png`（勿当源图再喂回）
- 侧栏品牌 Logo：`Sources/AniseRecorder/Resources/anise-logo.png`（同一张图；
  `Package.swift` 将其声明为 SwiftPM 资源供开发期 `Bundle.module` 回退，
  `build_app.sh` 另外把它复制进 `八角录屏.app/Contents/Resources/` 供
  打包版经 `Bundle.main` 解析）

重新生成 `.icns` 需要 Python 3 和 Pillow（脚本只做缩放，不再绘制图形）：

```bash
python3 scripts/make_icon.py
```

`work/` 已被 `.gitignore` 忽略。生成后检查 `Resources/AppIcon.icns` 已更新
（Finder 中查看 Dock / 访达里的 App 图标）。

> 打包注意：不要把 SwiftPM 资源包（`AniseRecorder_AniseRecorder.bundle`）复制到
> `.app` 根目录——`Bundle.module` 访问器虽然首选那里，但 codesign 会以
> 「unsealed contents present in the bundle root」拒绝；也不要用 SwiftUI
> `Image(name, bundle:)` 加载它——那走 `NSImage(named:)` 语义，找不到资源包
> 里的散图（侧栏用 `Bundle.main.url` + `NSImage(contentsOf:)`，回退
> `Bundle.module.image(forResource:)`）。

## 版本与发布

版本信息位于 `Resources/Info.plist`：

- `CFBundleShortVersionString`：用户可见版本，例如 `0.2.0`
- `CFBundleVersion`：递增构建号，例如 `2`

发布前检查：

- [ ] 更新 `CFBundleShortVersionString` 和 `CFBundleVersion`
- [ ] 将 `CHANGELOG.md` 的 `Unreleased` 整理为版本号和日期
- [ ] 同步更新 `README.md` / `docs/FEATURES.md` 的功能与限制
- [ ] `swift test` 通过
- [ ] `./scripts/build_app.sh` 成功
- [ ] 用打包后的 App 完成 `docs/TESTING.md` 的手动验收
- [ ] `codesign --verify --deep --strict 八角录屏.app` 通过

完整发布流水线使用 `scripts/release_package.sh`：构建、Developer ID 签名、
可选公证与 staple，产物为 `dist/八角录屏-<版本>.zip` 与
`dist/八角录屏-<版本>.dmg`。公证需要先在本机用
`xcrun notarytool store-credentials` 建立钥匙串配置，并通过
`ANISE_RECORDER_NOTARY_PROFILE` 环境变量传入；未配置时脚本跳过公证并注明
缺口。分发给其他 Mac 必须完成公证与装订票据，否则 Gatekeeper 会拦截。
