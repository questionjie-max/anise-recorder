# AGENTS.md

本文件适用于仓库的全部内容。开始修改前先读 `README.md`，再按任务阅读
`docs/ARCHITECTURE.md`、`docs/DEVELOPMENT.md` 和 `docs/TESTING.md`。

八角录屏（anise-recorder）是一个只在本机运行的 macOS 录屏与演示编辑工具。
项目要求 macOS 15+、Swift 6.0+ 工具链（Xcode 16+），使用 SwiftPM 构建，
不依赖第三方运行时库。

## 工作原则

1. **编码前思考**：不要默默假设。先确认现有行为、数据格式和坐标约定；
   有多种合理解释时说明取舍，不要自行选择后直接大改。
2. **简洁优先**：用最少的代码解决问题。不要添加未被要求的功能、抽象、
   配置项或防御性分支。
3. **精准修改**：只改与当前目标直接相关的代码。匹配现有 Swift 风格；
   不重构没坏的部分，不删除无关死代码，只清理自己改动产生的孤儿代码。
4. **目标驱动执行**：先定义可验证的成功标准，再实现并循环验证。修 bug
   时优先补复现测试；跨模块改动要说明每一步如何验证。

## 常用命令

```bash
# 编译并运行全部单元 / 合成测试
swift test

# Debug 构建
swift build

# Release 构建并打包、签名 八角录屏.app
./scripts/build_app.sh

# 运行已打包的应用（录屏、摄像头和权限相关验证应使用它）
open 八角录屏.app
```

只运行单个测试：

```bash
swift test --filter AniseRecorderTests/testLegacyProjectMigratesToSchemaFive
```

`.build/` 和 `八角录屏.app/` 是生成物，不修改、不提交。当前仓库没有
SwiftLint、SwiftFormat 或其他自动格式化配置，按现有代码风格手工保持一致。

## 代码地图

| 路径 | 责任 |
| --- | --- |
| `Sources/AniseRecorder/AniseRecorderApp.swift` | App 生命周期、菜单和全局快捷键 |
| `Sources/AniseRecorder/StudioModel.swift` | `@MainActor` 应用状态与录制 / 编辑 / 导出协调 |
| `Sources/AniseRecorder/Models.swift` | 录制设置、工程模型、持久化、画布与坐标布局 |
| `Sources/AniseRecorder/Recording/` | ScreenCaptureKit 录屏、摄像头、点击采集、窗口和区域选择 |
| `Sources/AniseRecorder/Editor/` | 录制设置、播放器、时间线与编辑界面 |
| `Sources/AniseRecorder/Export/` | 预览 / 导出、字幕渲染、SRT 和本机离线识别 |
| `Sources/AniseRecorder/Design/` | 主题、颜色和基础视图样式 |
| `Tests/AniseRecorderTests/` | 模型迁移、坐标、布局、渲染和真实导出测试 |
| `scripts/` | App 打包、签名和图标生成脚本 |

## 不可破坏的约定

- 工程数据只写入 `~/Movies/八角录屏/`（旧版目录 `~/Movies/Local Studio/`
  在 App 首次启动时一次性迁移，不丢工程）；导出位置由用户选择。应用当前
  不使用网络，不接入上传、云同步、分析或遥测。
- `project.json` 当前 `schemaVersion` 为 5。修改模型时必须考虑旧数据，
  增加迁移而不是让旧工程静默消失，并补迁移测试。
- 自动字幕只能使用 `SFSpeechRecognizer` 的本机离线识别，必须设置
  `requiresOnDeviceRecognition = true`；不可用时明确失败并退回 SRT，不能
  静默切换云端或新增网络服务。
- 录屏、系统声音、麦克风和摄像头分别写入文件，预览和导出时再由
  `CompositionBuilder` 合成；不要为预览和导出维护两套渲染规则。
- 归一化区域、点击和摄像头位置约定为“左上角原点、y 向下”；AppKit 与
  Core Image 使用 y 向上的坐标。跨坐标空间修改必须同时验证转换和最终画面。
- `StudioModel` 的 UI 状态在主线程更新；捕获数据在 `ScreenRecorder` 的
  串行队列处理。不要跨 actor 直接修改这些状态。
- 录屏权限依赖稳定的 App 签名和 bundle 标识。权限、窗口抓取、音视频设备
  相关改动不能只用 `swift test` 判定完成，必须用 `八角录屏.app` 手动验证。
- 保持“干净重写”边界：不要引入其他录屏软件的资源、代码或授权逻辑；
  不要擅自添加第三方依赖或许可证。

## 文档同步

改动完成前按影响范围更新文档：

| 改动 | 必须更新 |
| --- | --- |
| 用户可见功能、限制或使用方式 | `README.md`、`docs/FEATURES.md`、`CHANGELOG.md` |
| 工程结构、数据流、持久化或坐标约定 | `docs/ARCHITECTURE.md` |
| 构建、签名、权限、目录或发布流程 | `docs/DEVELOPMENT.md`、`AGENTS.md`（命令变化时） |
| 测试策略或手动验收范围 | `docs/TESTING.md` |
| 隐私、网络或数据存储行为 | `PRIVACY.md`、`CHANGELOG.md` |
| 版本号 | `Resources/Info.plist`、`CHANGELOG.md` |

`CHANGELOG.md` 的 `Unreleased` 区域应随开发持续更新，发版时再改为版本号和日期。

## 完成标准

- 普通代码改动：`swift test` 全部通过。
- 录屏、权限、音频、摄像头或 HUD 改动：完成 `docs/TESTING.md` 中对应的
  手动验收项。
- 导出或渲染改动：除自动测试外，至少检查一次真实工程的导出画面和声音。
- 提交前确认没有修改 `.build/`、`八角录屏.app/`、用户工程数据或无关文件，
  并完成对应文档同步。
