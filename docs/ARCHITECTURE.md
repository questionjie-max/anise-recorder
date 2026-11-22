# 架构说明

## 概览

Local Studio 是一个单进程 macOS 应用，没有后台服务、账号系统或网络依赖。
界面使用 SwiftUI，系统能力使用 AppKit、ScreenCaptureKit、AVFoundation 和
Core Image。工程使用 SwiftPM 管理，入口和依赖见
`Package.swift` 与 `Resources/Info.plist`。

```text
AniseRecorderApp
└── RootView
    ├── SidebarView
    ├── SettingsView
    └── RecorderSetupView / EditorView
            │
            ▼
        StudioModel (@MainActor)
        ├── Timeline rules
        │   └── AniseRecorderCore (Swift 6)
        ├── Recording
        │   ├── ScreenRecorder
        │   ├── CameraRecorder
        │   ├── CameraTrackBuilder
        │   ├── ClickTracker
        │   ├── CursorTracker
        │   ├── RegionSelectorController
        │   ├── RecordingHUDController
        │   │   └── CameraRecordingOverlayController
        │   └── TeleprompterPanelController
        │       └── TeleprompterScrollEngine（AniseRecorderCore）
        ├── Preview
        │   └── CompositionBuilder → AVPlayerItem → AVPlayer
        └── Export
            ├── CompositionBuilder → AVAssetReader → AVAssetWriter
            ├── CanvasRenderer / ChromaKeyRenderer
            └── CaptionRenderer / OfflineCaptionTranscriber
```

已拆出 `AniseRecorderCore`，存放可独立测试的时间线片段、源时间 /
成片时间映射，以及智能精剪的语音活动检测、停顿 / 气口候选、
批量剪切事务与输出时间 ripple 映射、语音驱动摄像头显隐计划、
音频优化 DSP（K 加权近似响度、增益钳制、压缩、ducking 包络、
噪声门）、字幕术语表替换与人脸居中焦点规划纯逻辑，以及竖屏
跟随规划（复用人脸居中的采样、死区与平滑规则，差异为无脸回中与
限速平移，灵敏度三档映射平移速率）。App target 继续保持
Swift 5 语言模式，避免采集、AVFoundation 和 SwiftUI 的 sendability
改造与编辑器功能开发同时进行。工程 Schema 为 5（Schema 5 新增语音显隐
自动段 ID 列表；1.2 的新字段——音频处理设置、打码区域、副字幕轨、
烧录模式、章节标题卡、精剪设置——全部带逐字段安全默认值，旧工程解码
即升级，缺失字段回退默认，不升版本号）。

## 目录职责

- `Sources/AniseRecorder/AniseRecorderApp.swift`：应用生命周期、菜单命令和快捷键。
- `Sources/AniseRecorderCore/Timeline.swift`：不依赖 UI 的片段、变速和双向
  时间映射。
- `Sources/AniseRecorderCore/SmartCut.swift`：智能精剪的纯逻辑
  分析引擎：PCM 语音活动检测（自适应噪声底、hangover）、自然 / 紧凑两种
  阈值模式的停顿 / 气口候选生成与合并。未检测到语音时不生成整段删除候选。
  候选是临时数据，不写入 `project.json`。`SmartCutVoiceCamera` 复用
  语音活动生成摄像头显隐计划：静默 1.5 秒后隐藏、下一段说话前 0.2 秒
  恢复、下一“段”不足 0.35 秒（咳嗽 / 碰麦）不触发。
  `SmartCutFillerDetector` 只分析现有字幕 cue：整条字幕为填充词、
  4 秒窗口内完全重复或前缀重开时给出建议，建议由应用层转成候选并复用
  剪切事务应用；无字幕时明确降级，不联网、不重新识别。
  句内模式：有原始识别分段时，按 segment 归一化匹配
  「独立成词」的填充词（中英文词表分开维护，时长 ≤1.5 秒，不做段内
  子串匹配，宁可漏删不误删），产出子区间建议并按置信度分高 / 低两档；
  `estimatedSavedDuration` 估算勾选建议合计剪掉秒数。
- `Sources/AniseRecorder/Export/SubtitleTools.swift`：SRT 解析 / 写出、
  分段合并成 cue（`SubtitleFile.cues(from:)`）与句内填充词的字幕文本
  手术（`CaptionSegmentSurgery`）。本机识别经
  `OfflineCaptionTranscriber.transcribeWithSegments` 同时返回合并 cue
  与原始分段；分段只进 `StudioModel.rawCaptionSegments` 会话状态，
  不写入 `project.json`，时间线或字幕一变即清空。应用句内填充词建议
  时，主字幕轨由手术取代纯 ripple（时间裁剪同规则）：重建校验通过的
  cue 按 segment 边界重写文本（只删被选子串及紧随一个空白），切成
  两段按 segment 时间归属，重写为空的片段随事务删除；校验不过（SRT
  导入、术语表改写、手动字幕）文本原样保留。副字幕轨不做手术。
- `Sources/AniseRecorderCore/Timeline.swift` 中的 `TimelineCutTransaction`：
  批量剪切事务。候选删除窗口吸附视频帧网格、从后往前切开并移除中间
  片段，会留下低于最短源时长的候选整条跳过；`mappedTime` / `keptRanges`
  为摄像头布局段、缩放区和字幕 cue 提供输出时间 ripple 映射。
- `Sources/AniseRecorder/Export/SmartCutAnalyzer.swift`：应用层精剪审计器。
  复用 `CompositionBuilder` 的时间线音频组合逻辑读取有效成片音频
  （16 kHz 单声道 PCM，无临时文件），可分析系统声音轨用于“保护系统声音”，
  把点击事件映射为屏幕活动保护区间，再调用 Core 纯逻辑；进度按 1% 节流，
  支持取消。
- `Sources/AniseRecorder/Editor/SmartCutPanel.swift`：精剪页 UI：
  模式 / 保护开关、扫描与取消、候选列表（勾选、跳转、试听）和应用；
  候选区绘制在 `EditorTimelineView` 视频轨上并支持悬停提示。
- `Sources/AniseRecorder/StudioModel.swift`：唯一的全局应用状态、工程撤销栈、
  保存 / 预览协调者，以及工程隐藏、归档、导入、删除的 UI 流程和当前工程
  任务清理；同时维护录制来源选择、会话级静态预览、窗口选择器状态和系统
  壁纸入口，不把这些临时状态写入工程。
- `Sources/AniseRecorder/Models.swift`：设置、工程、构图预设、布局命中、
  持久化和格式化工具；`ProjectStore` 的工程目录安全校验、隐藏标记、归档和
  Trash 操作也在此集中实现。
- `Sources/AniseRecorder/SettingsView.swift`：`⌘,` 设置窗口，管理 Delete
  默认动作、已移除工程显示开关和归档目录入口。
- `Sources/AniseRecorder/Recording/`：采集、暂停时钟、光标 / 点击采样、恢复清单
  和摄像头分段压缩；`CameraRecordingOverlay.swift` 负责录制期摄像头
  `NSPanel`、点击穿透和与最终画布一致的几何换算。`TeleprompterPanel.swift`
  （提词器）负责提词面板：`NSPanel` 以 `sharingType = .none` 创建且可交互
  （不穿透），滚动由 `AniseRecorderCore` 的 `TeleprompterScrollEngine` 纯逻辑
  驱动（速度档位映射、暂停不跳位、进度钳制、段尾减速系数），文稿分段与
  段位置计算在 `TeleprompterDocument` 与面板会话内完成。`WindowCatalog` 用
  `onScreenWindowsOnly: false` 枚举所有桌面的窗口并截取屏幕 / 窗口静态预览，
  `isOnScreen` 记录窗口是否在当前桌面可见；`WindowPickerSupport` 负责按
  窗口中心归属显示器、可见优先排序、`currentDesktopOnly` 过滤和稳定排序，
  `WindowPickerView` 负责独立选择器。`RegionSelector` 是区域框选浮层，
  `RegionSelectionGeometry` 提供命中 / 平移 / 缩放 / 归一化的纯几何逻辑。
  `RecordingStatusItem` 是录制中的菜单栏状态项（暂停 / 标记 / 停止的
  第三操作入口，随录制出现与消失）。
- `Sources/AniseRecorder/Editor/`：录制设置、播放器、时间线、检查器、录像标记
  和字幕 / 章节编辑界面。`EditorView` 固定预览与时间线并为检查器保留独立
  滚动区，`EditorInspectorSupport` 定义页签目标、折叠分组和轨道映射；
  `RecorderSetupView` 是录制工作台，右侧设置区滚动顺序为来源、提词器、
  镜头与声音、高级选项；「提词器」卡片始终展开（输入 / 粘贴、导入文件、
  字数与首行预览、清除、字号 / 速度和面板开关），保证第一屏即可看到文稿
  入口，`CanvasBackgroundInstaller` 统一安装本地图片和系统壁纸快照。
- `Sources/AniseRecorder/Export/`：音频 / 视频组合、画布合成、缩放、字幕渲染、
  SRT 工具、本机离线识别、缩略图与导出；音频优化离线处理器
  （`AudioOptimization`，处理缓存位于系统临时目录，预览 miss 回落原始
  音轨、导出 ensure 确保处理）、打码渲染（`RedactionRenderer`，经
  RenderPlan 作用于最终输出像素）、GIF 导出（`GifExporter`，与 MP4 共用
  合成链）与人脸居中分析（`FaceFocusAnalyzer`，Vision 采样检测，同一
  采样复用给竖屏跟随规划）；摄像头抠像由 `ChromaKeyRenderer` 完成：
  绿幕模式用自动取色估计的 12×7 背景色场 + YCbCr 色度距离逐像素键控
  （标准 CIFilter 组合：色度差分 → 距离平方 → 渐变带 alpha → 形态学
  收缩 → 高斯羽化 → 带内均值型去溢色），手动取色退回单点色场；亮度
  噪声权重只乘在键出量上（近黑背景不参与键控，暗前景键出量为 0 因此
  完整保留，不会因暗被折成半透明）；自动
  分割模式把 Vision accurate 人像 mask 作为 alpha 接进同一后段。首版
  抠像的 32³ LUT 保留为 `applyLegacyCube` 供 A/B 对照测试。
- `Sources/AniseRecorder/Design/`：设计令牌门面（`StudioTheme`）与通用
  视觉样式。颜色只走语义令牌（图谱蓝线描单套浅色值：白底 + 蓝色线描，
  App 外观锁定浅色，本轮不做深色模式；规格见
  `docs/design/DESIGN_SYSTEM.md`），视图层不写颜色字面量；浮在画面
  内容上的暗色（提示条底、手柄投影）走 `scrimOverMedia` /
  `textOnScrim` 一对令牌，真实内容区不受浅色主题约束；
  `Color(hex:)` 仅用于解析用户工程数据（画布背景、绿幕色等存储值）。

## 录制流程

`RecorderSetupView` 在开始录制前使用静态来源预览，而不是持续截屏：
`StudioModel.sourcePreviewRequestKey` 由来源类型、显示器、窗口和区域组成，
只有该键变化或用户点“刷新来源”时才重新读取当前帧。屏幕与区域由
`WindowCatalog.captureDisplayPreview` 截取一次，窗口使用现有窗口预览；
区域接着在预览上叠加裁切框。区域框选浮层是非阻塞的独立窗口，支持拖动
内部移动、拖边角缩放，`Enter` / 双击确认，`Esc` / 取消按钮 / 点击其他窗口
退出；归一化后仍按左上原点、y 向下的 `CaptureRegion` 写回 `RecordSetup`。
窗口列表枚举所有 macOS 桌面（Space）的窗口，`isOnScreen` 标记当前可见性，
默认把可见窗口排在前面，并提供“仅当前桌面”过滤；切换窗口后，
`WindowPickerLogic` 以窗口中心所在显示器分组，未知显示器归入“其他显示器”，
搜索同时匹配应用名、窗口标题和显示器名。

1. `StudioModel` 根据 `RecordSetup` 校验来源，并检查屏幕 / 麦克风权限。
2. `ProjectStore.newFolder()` 在 `~/Movies/八角录屏/` 创建工程目录。
3. `CaptureClock` 在开始时固定首帧锚点。暂停时记录墙钟区间并停止附加
   屏幕 / 音频帧；继续时恢复写入。成片时间会减去所有暂停区间。
3.5. 若启用摄像头，`CameraRecordingOverlayController` 在倒计时前显示
   独立 `NSPanel`，复用 `CameraRecorder.session` 的实时预览。悬浮窗默认
   `ignoresMouseEvents = true`，HUD 的“调整镜头”只切换调整态；拖动和缩放
   使用 `CameraOverlayGeometry` 在屏幕 AppKit 坐标、录屏源矩形和最终画布
   之间换算。录制结束时用 `RecordSetup.cameraComposition` 初始化工程。
4. 摄像头可选地由 `CameraRecorder` 先启动。每次暂停 / 继续产生独立的
   `camera-session-<UUID>.mov`，停止后由 `CameraTrackBuilder` 按统一时钟
   压成单一 `camera.mov`。
5. `ScreenRecorder` 用 ScreenCaptureKit 采集屏幕画面、系统声音和麦克风，
   分别写入 `screen.mp4`、`system.m4a`、`microphone.m4a`。
   `RecordSetup.microphoneDeviceID` 会写入
   `SCStreamConfiguration.microphoneCaptureDeviceID`；为空时使用系统默认。
   点击放大的前置配置（`captureClickZoom` / `clickZoomDuration` /
   `clickZoomScale`）在停止建工程时写入 `autoZoom / zoomDuration /
   zoomScale`，预览与导出的 `ZoomRenderer` 按工程字段消费。
   开始时写入 `recording.json`，音视频 writer 每 2 秒分片，供异常退出恢复。
6. `CursorTracker` 独立以 60 Hz 保存光标位置、可见性、静止状态和样式；
   屏幕采集关闭系统光标烧录，预览 / 导出时再由 `CursorRenderer` 合成。
7. `ClickTracker` 以 60 Hz 检查左键按下状态，记录归一化位置；窗口录制
   每次采样都会重新读取当前 `CGWindow` 几何，窗口移动或缩放后不会继续
   使用录制开始时的固定 frame。0.65 秒内且 28 点范围内的连续点击会合并。
8. 停止后，视频时间戳被转换为工程时长；点击、光标和标记时间都以首帧为
   原点，并经过同一个 `CaptureClock` 映射。摄像头开始
   时间与屏幕首帧之差写入 `cameraOffset`，供合成时对齐。
9. `ProjectStore` 写入 `project.json`，清理恢复清单，应用生成
   `thumbnail.jpg` 并进入编辑器。若上次进程异常退出，启动时会扫描有
   `recording.json` 和已落盘媒体的目录，恢复为可见工程。

录屏和摄像头在录制阶段不混流。这样做保留了后期对齐、修剪和布局调整能力。
摄像头悬浮窗、录制 HUD 与提词面板不参与屏幕合成；整屏 / 区域采集通过
`SCContentFilter.excludingApplications` 排除当前 App，窗口采集只读取目标
窗口；提词面板额外以 `NSWindow.sharingType = .none` 标记为窗口服务器级
不可共享，窗口选择器的清单过滤也永不列出本 App 窗口，因此提词面板不会
写入 `screen.mp4`。

## 编辑器布局与导航

编辑器根视图由固定页头和下方的双列工作区组成。左列包含画布预览和时间线，
右列是固定宽度 `338` 的检查器；只有检查器内部是 `ScrollView`，因此检查器
滚到任何位置都不会带走左侧画面和播放头。页签栏固定在检查器顶部，切换
页签会滚回顶部。

左列在三栏容器里带 `layoutPriority(1)` 与预览保底高度（160pt）：栏间争
空间时中间主编辑区优先，窗口矮于兜底高度时保预览、时间线底部由窗口裁剪，
右栏内容长度不参与中间区尺寸计算（由 `EditorLayoutTests` 的布局回归覆盖）。

检查器分两层表达层级：

- 六个页签负责大任务：画面、摄像头、剪辑、精剪、字幕、导出。
- `InspectorDisclosureSection` 负责页签内的渐进披露；主设置默认展开，
  高级设置默认折叠，收起时显示当前值摘要。

展开状态由 `EditorView` 的会话级 `@State` 保存，不进入 `project.json`，
重新启动恢复默认（默认集合为 `EditorView.defaultExpandedSections`）。摄像头页
默认展开“当前构图”与“绿幕抠像”，位置、外观和人脸居中（竖屏跟随）默认折叠，
因此默认窗口高度下能直接看到并用上绿幕入口。

时间线左侧 `TimelineTrack` 标题是独立按钮，轨道内容仍处理播放头、片段
修剪和区域拖动。映射固定如下：

| 轨道 | 页签 | 检查器分组 |
| --- | --- | --- |
| 视频 | 剪辑 | 当前片段 |
| 摄像头 | 摄像头 | 当前构图 |
| 缩放 | 剪辑 | 缩放 |
| 声音 | 剪辑 | 声音 |

轨道入口调用与页签共用的 `InspectorDestination`，自动展开目标分组并通过
`ScrollViewReader` 滚动定位；它不创建第二套编辑模式，也不修改工程内容。

## 预览与导出

预览和导出使用同一个 `CompositionBuilder`、同一个 `RenderPlan` 和同一个
`CanvasRenderer`。任何时间线编辑都会先生成固定工程快照，再进入合成。

1. 读取 `screen.mp4`，按 `timeline.clips` 顺序插入片段；每个片段用
   `scaleTimeRange` 应用播放速度。
2. 系统声音和麦克风按同一组片段映射插入，分别应用 `AudioTrackSettings`
   的增益 / 静音；多片段音轨在每个片段边界加约 10 ms 音量淡入淡出，避免
   切点爆音，预览与导出共用同一 `audioMix`。系统声音通常比录屏短，音轨与
   片段的交集为空时直接跳过该段，不能把反向边界传给 `CMTimeRange`，否则
   智能精剪后会出现 AVFoundation `-12780`。摄像头按 `cameraOffset` 和
   片段变速同步插入；部分摄像头文件以零时长坏样本开头，绝对零起点插入
   会跳过最小 1/600 秒，避免合成读取卡死。
3. `StudioVideoCompositor` 在每一帧按成片时间解析摄像头布局段和过渡。
4. `RenderPlan` 固定该时刻的输出尺寸、背景、屏幕矩形、摄像头矩形、点击映射、
   手动缩放区和阴影参数；画中画摄像头在缩放焦点冲突时会按同一矩形规则缩小
   和滑移。摄像头抠像开启时，先在摄像头图像上应用 `ChromaKeyRenderer`
   （绿幕：YCbCr 色度距离键控 + 12×7 背景色场逐像素参照 + alpha 渐变带 /
   哑光内收 / 羽化 / 去溢色；自动分割：Vision accurate 人像 mask 接同一
   后段；优化第一波起另有边缘光包裹在 rect 空间叠加），再进入共享的
   fill / fit、镜像和布局合成；透明像素保留，摄像头圆角 / 形状遮罩、
   边框和矩形阴影不参与该帧。`CanvasRenderer` 只消费计划结果。
5. 光标按成片时间插值、平滑、静止隐藏和点击波纹后合成到画面。
6. 字幕按成片时间取活动 cue，由 CoreText 生成透明气泡层；预览始终显示
   已启用字幕，导出仅在 `captions.burnIn` 为真时烧录。
7. 摄像头布局变化使用完整帧交叉淡化过渡；手动缩放区优先于自动点击缩放。
8. 预览包装为 `AVPlayerItem`。导出使用同一个 `AVVideoComposition`：
   `AVAssetReaderVideoCompositionOutput` 逐帧调用共享合成器，
   `AVAssetReaderAudioMixOutput` 应用音频混合，再交给 `AVAssetWriter`
   编码 H.264 / HEVC。
9. 导出前检查目标目录、写入权限和按分辨率 / 帧率 / 时长估算的可用空间；
   可用容量优先读取 `volumeAvailableCapacityForImportantUsage`，该值不可用
   或为 0 时回退到 `volumeAvailableCapacity`。导出先写同目录临时文件，完整
   成功后才原子替换目标文件；取消或失败只清理临时文件，不破坏已有成片或
   源素材。导出开始时复制工程值作为快照，后续编辑不会改变正在运行的任务。
   底层 ENOSPC、只读目录等错误会映射为明确原因，而不是笼统的“导出失败”。
10. 导出成功后若有非空字幕，写同名 `.srt` 旁车文件；章节文本由用户显式导出。

任何渲染规则都应修改共享的合成链路，不要在预览或导出侧另复制一份逻辑。
摄像头的选中框、四角手柄和拖动命中都从 `CanvasLayout.normalizedCameraFrame`
推导，和 `CanvasRenderer` 使用同一套归一化矩形；不能给编辑器另写一套
“看起来差不多”的定位公式。

摄像头拖动或缩放开始时，`StudioModel` 保存一次交互前快照；结束或失焦时
才写入撤销历史并立即刷新预览。连续滑杆和数值编辑使用 0.7 秒分组窗口合并，
因此一次拖动不会生成几十条撤销记录。预览重建耗时写入统一日志的
`com.localstudio.recorder` / `Preview` 分类，字段为 `preview_refresh_ms`，
用于比较 1080p / 4K 的性能预算。

侧栏缩略图由 `ProjectThumbnailCache` 用 ImageIO 解码到最长边 216 px，并以
文件 URL 为键放入 `NSCache`。侧栏刷新不再重复解码原尺寸 `thumbnail.jpg`，
避免长录工程导出时在主线程产生不必要的图像解码和内存峰值。

## 工程数据

一个工程对应一个文件夹，典型内容如下：

```text
~/Movies/八角录屏/YYYYMMDD-HHMMSS-XXXXXX/
├── project.json
├── project.previous.json # 上一份成功保存
├── screen.mp4
├── system.m4a          # 可选
├── microphone.m4a      # 可选
├── camera.mov          # 可选
├── thumbnail.jpg
└── background.<ext>    # 可选
```

`StudioProject` 当前 schema 为 5，包含源信息、点击、摄像头布局 / 外观、
绿幕抠像、画布、媒体文件名、录像标记、光标采样 / 样式、字幕设置、字幕 cue、
素材叠加片段（`overlayClips`：`start+duration` 成片时间区间与
`anchor/customCenter/size` 归一化位置，素材文件复制进工程目录、数据只存
相对文件名；视频叠加在合成里各占一条 composition track）与提词器设置
（`teleprompter`：文稿、字号、速度、面板位置，逐字段安全默认值，
旧工程缺字段回退默认，不升版本号）。
`ProjectStore.decode` 会先读当前时间线与新字段，缺失字段使用安全默认值；
旧工程的 `trimStart / trimEnd` 自动迁移为单段 `timeline`，最后回退到
`StudioProjectV1`。`CameraSettings` 的自定义解码为新增的填充模式、裁剪焦点、
边框、阴影和避让开关提供逐字段默认值；`CameraChromaKeySettings` 同样为
颜色、容差、柔化和去溢色提供逐字段默认值。光标采样为空时视为旧录制，保留
视频内已有光标。
新增字段必须保留默认值或实现显式迁移，不能破坏旧工程读取。

工程保存采用短延迟合并（约 380ms），在切换工程、开始录制等关键节点会立即
落盘。`ProjectStore` 用锁串行化所有写入；每次覆盖主文件前，把上一份可解析
的 `project.json` 写为 `project.previous.json`。主文件损坏时读取备份并
产生可见恢复提示。所有媒体路径均相对工程文件夹，便于整体移动。

工程管理不修改 `project.json` 的 Schema：

- “从列表移除”在工程目录写入 `.localstudio-hidden` 空标记；加载时默认跳过，
  设置中开启“显示已移除工程”后可显示并移除标记。
- “归档”把整个目录移动到 `~/Movies/八角录屏/Archive/`；同名目录追加
  `-2`、`-3` 等后缀。`Archive/` 不作为普通工程加载。
- “删除工程和原视频”调用 `FileManager.trashItem`，整个工程目录进入废纸篓；
  工程目录外用户另存的成片不受影响。
- 导入先复制目录到工程库、解码并验证 `project.json`，必要时修正
  `folderName` 后保存，成功后才移除源目录。任何校验或复制失败都保留源目录。

`ProjectStore` 只允许工程库根目录的直接子目录；拒绝根目录本身、路径穿越、
符号链接和保留的 `Archive` 名称。删除 / 归档当前工程前，`StudioModel`
取消保存、预览、精剪、音频和人脸分析任务，停止播放并清空编辑状态；导出
进行中拒绝移动当前工程，移动失败时恢复原选中工程。

## 字幕与离线识别

`CaptionCue` 以成片时间保存 `start / end / text / language`，不跟随片段
源时间，因此切分、ripple 和变速后的字幕位置直接以编辑结果为准。SRT 导入会
按工程成片时长裁边界，SRT 写出使用标准 `HH:MM:SS,mmm`。

“本机生成”先用 `CompositionBuilder.makeTranscriptionAudio` 将麦克风轨
（没有时回退工程声音）按时间线裁剪和变速生成临时 M4A，再交给
`OfflineCaptionTranscriber`。识别固定 `requiresOnDeviceRecognition = true`；
当前语言或系统没有本机识别能力时明确失败，并提示改用 SRT。章节由 cue 合并，
短章节和 1.5 秒内的小停顿归入同一章。

## 坐标约定

这是项目中最容易出错的部分，跨模块修改前先确认坐标空间：

| 数据 / API | 原点与方向 |
| --- | --- |
| `CaptureRegion`、`ClickEvent`、`NormalizedPoint` | 左上角，y 向下，取值 0...1 |
| AppKit 屏幕坐标 | 全屏坐标系，左下角，y 向上 |
| ScreenCaptureKit 区域 `sourceRect` | 显示器本地坐标，左上角，y 向下 |
| Core Image / Core Graphics 图像 | 图像本地坐标，左下角，y 向上 |

`CaptureRegion.screenRect(in:)` 负责转换为 AppKit 屏幕坐标，
`displayLocalCaptureRect(in:)` 负责转换为显示器本地捕获坐标。
`ClickCoordinateMapper.appKitFrame` 以主屏高度把 `CGWindow` 的左上角全局
坐标转换为 AppKit 左下角坐标；该公式也支持副屏的负 x / y 原点。
`ZoomRenderer` 和 `CanvasLayout.cameraSlot` 负责把左上归一化点转换到
Core Image / 画布坐标。相关行为由 `testCanvasSizesAndRegionConversion`、
`testClickCoordinateMapperUsesCurrentWindowFrame`、
`testClickCoordinateMapperSupportsNegativeDisplayOrigins`、
`testCameraAnchorAndSideBySideLayout` 和缩放渲染测试覆盖。
`CameraOverlayGeometry` 只把最终画布中的画中画矩形归一化后映射回录屏源
矩形，输入可以是整屏、窗口或区域，也支持副屏负坐标；它不把桌面绝对坐标
直接当作摄像头位置。悬浮窗实际高度取 AppKit 左下原点，因此映射时会翻转
归一化 y。`testCameraOverlayGeometryUsesSourceAndCanvasFrames` 和
`testCameraOverlayGeometryCoversDisplayWindowAndRegionOrigins` 覆盖圆角 /
圆形、拖动吸附、缩放边界及整屏 / 窗口 / 负坐标区域。

## 画布规则

- 横屏输出固定 `1920 × 1080`，竖屏固定 `1080 × 1920`，原始比例使用录制尺寸。
- 屏幕按 aspect-fit 放入槽位；摄像头可选择 aspect-fill（填满并裁切）或
  aspect-fit（完整显示并露出画布背景），并可设置 0...1 的裁剪焦点。
- 并排布局在横屏左右分割、竖屏上下分割；`splitRatio` 限制在 0.5...0.8。
- 画中画摄像头受画布边距约束，自定义中心限制在 0.05...0.95。
- 画中画拖动使用 2.5% 画布边距和九宫格 / 边缘吸附；四角缩放限制在
  10%...50%，预览和导出都从同一 `CameraSettings` 重新计算最终矩形。
- 画中画摄像头与当前缩放焦点相交时，默认缩到原面积的 75%；若焦点仍在
  摄像头下，则选择离当前中心最近的空闲角，并按缩放强度插值回位。
- 摄像头边框宽度以 1080p 短边为参考等比缩放；边框和阴影默认关闭。
- 摄像头绿幕抠像使用工程级 `cameraChromaKey`，不绑定某个布局段。三态：
  关闭 / 绿幕 / 自动分割（`enabled` + `personSegmentation` 组合表达）。
  绿幕模式逐像素用所在位置的背景色场作键控参照（色场由自动取色从边框
  多点估计，存 `backgroundFieldData`，手动取色为单点模式），alpha 经
  渐变带、哑光内收与羽化后合成，去溢色只作用于半透明带与哑光内侧环；
  亮度噪声权重只压低键出量（近黑背景不参与键控以避免闪点），暗前景的
  键出量为 0，因此黑发 / 深色衣物完整保留，不会因亮度低被透成半透明；
  自动分割模式用 Vision accurate 逐帧生成人像 mask，背景可透明或自身
  重模糊。两种模式都忽略摄像头圆角 / 形状遮罩、边框和矩形阴影，随后
  再应用当前布局段的 fill / fit 和位置。
- 六个构图预设只改工程参数，不修改媒体文件，也不引入第三方素材。
  “从播放头生效”在当前播放头创建或更新布局段，把该段过渡设为 0，并清除
  该段的自动段 ID；“应用到全片”更新基础构图、删除全部布局段和自动段 ID，
  只记一个撤销步骤。手动预设覆盖自动语音显隐 / 人脸布局段后，该段视为
  用户手动段，后续自动生成不会静默覆盖。
- “竖屏上下”和“并排讲解”的画布比例修改始终作用于全片；其余预设也遵循
  同一规则。预设面板明确提示原始 `camera.mov` 不会被改写。
- 背景可使用纯色、渐变或用户图片；图片以 aspect-fill 填满画布。

背景图片由 `CanvasBackgroundImageInstaller` 统一安装到工程目录：

- “选择图片”和“系统壁纸…”共用复制、图片可读性校验和失败回滚。
- 源路径先 `resolvingSymlinksInPath()`，复制的是实际图片内容，不是符号
  链接本身。扩展名沿用源文件；目标保留为 `background.<ext>`。
- 同名替换先写临时文件，再把旧文件移到备份名并换入新文件；换入失败时
  恢复旧背景。切换到不同扩展名后清理旧背景文件。
- “系统壁纸…”用 `NSWorkspace.desktopImageURL(for:)` 枚举每块屏幕当前
  壁纸，只保存该静态快照并继续使用 `.image` 背景，不增加动态壁纸播放或
  新的工程 Schema。

`CanvasRenderer` 的图片缓存键包含文件路径以及文件身份 / 大小 / 修改时间。
同名背景替换后缓存会失效，不必重启预览或导出。

## 平台边界

- 最低系统版本为 macOS 15，构建使用 SwiftPM，不包含 Xcode 工程文件。
- ScreenCaptureKit 和 TCC 权限依赖正确签名、bundle 标识与用户授权。
- 应用当前不包含网络代码。新增网络能力时，必须先更新隐私说明和版本变更记录。
