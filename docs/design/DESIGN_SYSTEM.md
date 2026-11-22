# 八角设计规范 v0.2 · 图谱蓝线描

> 状态：v0.2。App 使用「图谱蓝线描」浅色体系：白底、蓝色线描、清清爽爽。
> 本文档是 UI 改造与视觉验收的依据；色值全部来自品牌 Logo 原图实测采样，
> 不许自行调色或换近似色。对比度数值为按 WCAG 2.x 相对亮度公式的脚本
> 计算值（保留两位）；未实测的机制均标「待验证」。

## 0. 范围与消费方式

- 适用范围：App 全部界面（录制工作台、编辑器三栏、设置、导出、工程管理、
  HUD 与浮层）。不含 App 图标配色的改版、不含导出成片内的字幕 / 光标
  渲染——那是出片像素，遵循视频渲染的行业惯例（如白描边字幕、黑 scrim），
  与 UI chrome 是两套规则，属设计决定不是遗漏。
- 消费方式：颜色走 `StudioTheme` 语义令牌（SwiftPM 下以 `NSColor` 单套
  浅色值提供，无 Any/Dark 双值）；几何量（间距 / 圆角 / 时长）保留在
  `StudioTheme` 静态常量。视图代码里只允许出现语义 token 名，禁止出现
  `Color(red:...)`、hex 字面量和 `colorScheme` switch（双主题不需要第二套
  主题的概念）。

## 1. 设计原则（5 条）

1. **原生骨架，品牌皮肤。** 控件结构、窗口行为、交互状态（hover / press /
   焦点环 / 失焦退灰）全部用系统控件与系统行为；只品牌化颜色、圆角、间距
   token 与少量容器（卡片、录制 HUD 浮层）。纯 SwiftUI 零第三方依赖，
   系统控件免费提供全套状态与适配；品牌感由 token 层承担，用户看到的仍是
   “一个规规矩矩的 Mac App”。
2. **白底蓝线描，图鉴气质。** 默认且唯一外观 = 纸白底 + 图谱蓝线描；层级靠
   边框线（`#DCE9F3` / `#CFE3F2`）与一档浅蓝面（`#F4FAFE`）表达，不堆投影。
   预览画布是内容区例外（见 2.7）。录课 / 口播创作者的工具需要“清爽、不抢
   内容”的底；白底蓝线与品牌 Logo（手绘线描八角）同语系，截图即识别。
3. **一个动作色的纪律。** 全 App 只有一组蓝强调（图谱蓝 = 主按钮 / 选中 /
   图标 / 滑杆 / 链接），每视图 prominent 按钮 ≤2 个；陶橙只给「录制进行中」
   的状态点与计时，播放头 / 进度归图谱蓝，二者严格不混用；警告三色只给
   权限告示卡。单动作色让“该点哪个”永远只有一个答案。
4. **少而清楚。** 低密度、渐进披露、分组折叠一次只露一组参数；状态永远
   双通道（颜色 + 文字 / 形状），动效短促有目的，高频操作不加动效。
   界面反馈是本机工具唯一的反馈通道，所以状态表达必须可读而不是好看。
5. **说人话。** 界面文案用创作者语言（“精剪”“字幕”“导出微信尺寸”），
   不做开发者 / 工程语系（diff、issue、mono 术语）；品牌不做精英 indie
   套路（订阅话术、折扣倒计时）。

## 2. 色板令牌

### 2.1 两层组织

- **palette 层（原始值）**：只回答“存在什么”，组件不直接消费。命名
  `palette<色名><深浅档>`。
- **semantic 层（角色）**：回答“为什么用”，是唯一随明暗外观换值的层。
  命名小驼峰、只写用途不写颜色词（`accent` 可以，`orangeLight` 不行）；
  前景色与容器色成对定义（`accent` ↔ `textOnAccent`）。
- **组件层不开**：时间轴片段、播放器等复杂控件确需局部常量时先内联，
  3 个以上组件共享同一需求才提升为 semantic token（“3+ 组件法则”）。
- 明确不做：多品牌 ThemeProvider 协议、Environment 注入主题对象、
  JSON token 管线、`colorScheme` switch。

### 2.2 palette 层（全部来自品牌 Logo 原图实测采样，不许自行调色）

| token | 值 | 说明 |
| --- | --- | --- |
| `atlasBlue` | `#25A1E0` | 图谱蓝。Logo 线条原色；主按钮填充、开关开启态、滑杆填充、选中态、分区小图标、链接、录制列表选中条 |
| `paperWhite` | `#FFFFFF` | 纸白。全局底、侧栏底、卡片面、悬浮层 |
| `mistBlue` | `#F4FAFE` | 浅蓝面。次级面：分段控件底、悬停态、输入区底、预览画布 |
| `selectionBlue` | `#EAF5FC` | 选中面。列表选中行背景、字数徽标底 |
| `lineBlue` | `#DCE9F3` | 边框线（常规）。卡片边框、分隔线 |
| `lineBlueStrong` | `#CFE3F2` | 边框线（稍强）。输入框边界、主按钮 1px 描边、开关 off 底 |
| `inkBlue` | `#20303C` | 墨蓝。标题与正文；亦作画面内容上的暗色 scrim |
| `slateBlue` | `#5B7183` | 蓝灰。次级文字 |
| `fogBlue` | `#93A9B8` | 浅蓝灰。三级文字、未激活图标 |
| `clayOrange` | `#D97D3E` | 陶橙。全 App 唯一暖色，只用于「录制进行中」状态点与计时 |
| `warnSurface` | `#FFF9EC` | 警告底（只用于权限告示卡） |
| `warnBorder` | `#EDD9A3` | 警告边（只用于权限告示卡） |
| `warnIcon` | `#C08F1D` | 警告图标（只用于权限告示卡） |
| `errorRed` | `#C93A3A` | 错误文字 / destructive 同源（功能性红，非装饰暖色） |

### 2.3 semantic 层（颜色角色，单套浅色值；不做深色模式）

**表面与描边**

| 角色 | 值 | 用途 |
| --- | --- | --- |
| `surfaceCanvas` | `#FFFFFF` | 窗口最底层背景 |
| `surfacePanel` | `#FFFFFF` | 卡片/面板/侧栏（层级靠边框线不靠底色差） |
| `surfaceRaised` | `#FFFFFF` | 悬浮层：HUD、弹层、下拉 |
| `surfaceSunken` | `#F4FAFE` | 次级面 / 预览画布：分段控件底、悬停态、输入区底 |
| `separatorLine` | `#DCE9F3` | 描边/分隔线（常规档） |
| `separatorLineStrong` | `#CFE3F2` | 强描边：输入框边界、主按钮 1px 描边、开关 off 底 |
| `scrimOverMedia` | `#20303C` | 浮在画面内容上的中性暗色（提示条底、手柄投影） |
| `textOnScrim` | `#FFFFFF` | 画面内容上的文字/手柄，与 scrimOverMedia 成对 |

**文字（三级；规格只定三级，占位符/时间戳并入最浅档）**

| 角色 | 值 | 对白底对比度（正文门槛 4.5 / 大字与图形 3.0） |
| --- | --- | --- |
| `textPrimary` | `#20303C` | 13.55:1 |
| `textSecondary` | `#5B7183` | 5.08:1 |
| `textTertiary` | `#93A9B8` | 2.44:1 —— 只用于未激活图标与可有可无的标注（WCAG 对禁用组件豁免）；**禁止做正文** |

**强调与动作**

| 角色 | 值 | 用途与配额 |
| --- | --- | --- |
| `accent` | `#25A1E0` | 图谱蓝：主按钮填充、开关开启态、滑杆填充、选中态、分区小图标、链接、录制列表选中条（对白底 2.90:1，图形档贴线；选中态另靠选中面 `#EAF5FC` 底色双通道识别） |
| `accentContainer` | `#25A1E0` | 主按钮容器底（唯一 prominent 填充色），加 1px 强描边补边界 |
| `textOnAccentContainer` | `#20303C` | 主按钮文字（墨蓝 4.68:1 过正文门槛；白字仅 2.90:1 不取） |
| `selectionTint` | `#EAF5FC` | 列表/侧栏选中行底（tint 式选中，见 5.4） |

**语义色**

| 角色 | 值 | 用途 |
| --- | --- | --- |
| `recIndicator` | `#D97D3E` | 「录制进行中」状态点/胶囊（对白底 3.02:1 图形达标） |
| `recText` | `#D97D3E` | 录制计时文字（3.02:1；仅限计时短文本，成句说明不用它） |
| `warning` | `#C08F1D` | 警告图标（只用于权限告示卡，对白底 2.92:1 图形档） |
| `warningSurface` | `#FFF9EC` | 权限告示卡底 |
| `warningBorder` | `#EDD9A3` | 权限告示卡描边 |
| `errorText` | `#C93A3A` | 错误文字（5.06:1）；destructive 同源，永不当 primary |
| `playbackGold` | `#25A1E0` | 播放头/进度/播放态徽标（图谱蓝，只做图形不做文字） |

**状态层（不是 Color Set，是公式）**：hover = 内容色 8% 叠加、
pressed = 12%（Material state layers）；全部组件统一用这一组数，不许组件
自定。禁用态 = 内容 38% 透明度（Material disabled content），不发新色。

**暖色纪律（验收项）**：陶橙 `#D97D3E` 是全 App 唯一暖色，只准出现在
「录制进行中」的状态点与计时；警告三色只出现在权限告示卡；其余任何地方
（按钮、图标、徽标、编辑器警示标记）不许出现暖色——编辑器里的可删除建议、
打码区、时间线提示等警示语义一律用图谱蓝（可交互）或蓝灰文字（纯提示）
表达。

### 2.4 落地路径：SwiftPM 下的单套浅色

1. 语义色 token 以 `NSColor(srgbRed:…)` 单值提供——图谱蓝线描只有一套
   浅色值，不做 Any/Dark 双值（不推导深色令牌）。
2. `StudioTheme` 是几何量与语义名的 Swift 门面，视图层只写
   `StudioTheme.accent`；全 App 禁止 `@Environment(\.colorScheme)` 驱动
   取色。
3. 外观锁定浅色：主窗口 `RootView`、设置窗口 `SettingsView` 用
   `.preferredColorScheme(.light)`；HUD / 倒计时 / 快捷键帮助窗口的
   `NSWindow.appearance` 设 `.aqua`；提词器浮层同样锁浅色。
4. 「待验证」：高对比变体（Increased Contrast）本轮不做，待系统设置下
   实测后再补（手动验收时覆盖）。

### 2.5 白/蓝/墨配比纪律（防“玩具感”）

- **约 60% 纸白**：`surfaceCanvas` + `surfacePanel` 构成绝对面积主体
  （白底 + 边框线分层）；
- **约 25% 墨蓝结构**：文字、时间线、描边等结构元素（`textPrimary` /
  `separatorLine` 族）；
- **约 15% 图谱蓝强调**：主按钮、选中态、图标、滑杆填充合计不超过一成半
  的视面积；陶橙只允许出现在「录制进行中」状态点与计时（面积 <1%）。
- 自查口径：任一界面截屏后眯眼看，若“蓝色跳出来比文字还多”或“除录制点外
  还有第二处暖色”，即配比超标，回退该视图的强调色用法。

### 2.6 预览画布与画面内容区例外

预览画布区（`surfaceSunken` = 浅蓝面 `#F4FAFE`）随浅色主题走线描体系：
来源预览、摄像头小预览、窗口选择器预览、编辑器视频面都是浅蓝面 + 边框线的
「图鉴图版」效果，信箱填充边（`VideoSurface` 层底色）为纸白。浮在画面内容
之上的暗色收敛为一对令牌：`scrimOverMedia`（墨蓝，提示条底 / 手柄投影）与
`textOnScrim`（纸白，提示文字 / 手柄）——真实内容区（摄像头画面、成片
像素）不受浅色主题约束。画布内的摄像头边框、点击波纹等属于**用户内容
设置**（存工程文件），不走本规范 token。

## 3. 字体

- **只用系统字体**（苹方/SF Pro）。不引入任何字体文件，不联网加载。

### 3.1 字阶五档

全 App 只许五档字号，同一屏同一角色只许一个字号：

| 角色 | 字号/字重 | SwiftUI | 用途 |
| --- | --- | --- | --- |
| 标题 | 20 semibold | `.system(size: 20, weight: .semibold)` | 页头标题（录制工作台 / 工程名页头），每屏 ≤1 处 |
| 区块标题 | 15 semibold | `.title3.weight(.semibold)` | 卡片分组标题（来源 / 提词器 / 画布与背景…） |
| 正文 | 13 regular | `.body` | 默认正文、列表主文字、按钮文字 |
| 次级 | 12 regular | `.callout` | 次要说明、字段标签 |
| 最小 | 11 regular | `.subheadline` | 辅助行、属性名、时间戳、元数据；**11pt 是下限** |

- **<11pt 清零**（9 / 9.5 / 10pt 全部退役；`.caption`/`.caption2` 一律迁到
  `.callout` 或 `.subheadline`，按角色归位）。
- 字重随角色表：标题与区块标题 semibold；正文 regular（按钮与可点击行可
  medium 内衬）；次级与最小档 regular。禁 Light 及以下。
- 行高 1.35–1.5：多行正文/次级文字用 `lineSpacing` 补足（13pt × 1.35 ≈
  +2pt；12pt ≈ +2pt；11pt ≈ +1pt），单行不额外加。
- **数字一律 tabular**：计时、时长、帧率、分辨率、文件大小、百分比用
  `.monospacedDigit()`，不许跳动；需要真等宽（时间轴标尺）用
  `NSFont.userFixedPitchFont`。
- 中英文混排不手动加空格 hack，用系统默认字距。
- 时间码颜色：`textSecondary` 蓝灰（mono 蓝灰是识别点）；录制中的时间码用
  `recText` 陶橙——陶橙计时是唯一暖色配额。

### 3.2 间距与对齐

- 8pt 网格：4 / 8 / 12 / 16 / 24（space2/3/4/5/6），沿用 StudioTheme space
  阶梯；不再新增 14 等网格外值（区块间距取 16）。
- 卡片内边距统一 16（`studioCard` 默认 space5）。
- 控件高度两档 28 / 34（主按钮可 38）；行内小控件 20 / 22 豁免（菜单按钮、
  胶囊角标）。
- 同屏同一角色一个间距值：同类卡片之间同距，同类行之间同距。

### 3.3 图标与动效

- SF Symbols 统一 **regular 权重观感**（`.font(.system(size:))` 不带
  weight，或 `.regular`）；尺寸三档 12 / 14 / 16，与同行文字基线对齐
  （图标放进 HStack 默认居中对齐，禁止手动 offset 改基线）。
- 动效只许状态变化动效，时长 120–200ms（现有 0.18s/0.2s 均合规）；不新增
  装饰动效；签名结构仍只有来源预览图版框一处。

### 3.4 对比度复核（WCAG 2.x 相对亮度公式计算）

| 令牌 | 值 | 对白底 | 结论 |
| --- | --- | --- | --- |
| `textPrimary` #20303C | 13.55:1 | ✓ 正文 | 正文 ≥4.5 ✓ |
| `textSecondary` #5B7183 | 5.08:1 | ✓ 正文 | 次级 ≥3 ✓（实为正文级） |
| `textTertiary` #93A9B8 | 2.44:1 | ✗ 正文 | **只许大字（≥15 semibold）与纯装饰（分隔符、禁用图标）**；承载信息的 tertiary 全部提级 `textSecondary` |

### 3.5 角色完整性自查

耐看的主题来自「一套封闭角色表，任何元素都能对上一个角色」。按此核对
图谱蓝令牌（§2.3）：

| 角色 | 令牌 | 状态 |
| --- | --- | --- |
| 底 | `surfaceCanvas` / `surfacePanel` / `surfaceRaised` | ✓ 三层抬升面齐 |
| 次级面 | `surfaceSunken` | ✓ |
| 边框 | `separatorLine` / `separatorLineStrong` | ✓ 两档齐 |
| 文字三级 | `textPrimary/Secondary/Tertiary` | ✓（tertiary 用途收紧见 §3.4） |
| 主色及其阶梯 | `accent` / `accentContainer` / `selectionTint` / `textOnAccentContainer` | ✓（图谱蓝单值 + 选中面浅档 + 反白字；明度阶梯靠选中面/浅蓝面承担，无深蓝档——白底体系不需要） |
| 内容区 | `scrimOverMedia` / `textOnScrim` | ✓ 内容区专用角色 |
| 语义 | `recIndicator/recText`（陶橙）、`warning 三色`（告示卡专用）、`errorText`、`playbackGold` | ✓ 各有封闭角色 |

**自查结论：无孤儿色**。所有界面颜色均可归入上表；边缘项 `playbackGold`
已与 `accent` 同值（图谱蓝收编播放语义），保留独立 token 名以维持语义
搜索性。

### 3.6 工具栏约束备忘

- 工具栏标题 <15 字符、不用 App 名；工具栏每项必须同时是菜单栏命令。

## 4. 间距与圆角

**间距阶梯（2/4/8 基数，8 档封顶）**

| token | 值 | 用途 |
| --- | --- | --- |
| `space1` | 2 | 图标与文字微调、描边内衬 |
| `space2` | 4 | 紧凑控件内距、页签与内容间距 |
| `space3` | 8 | 默认控件内距、组内行距 |
| `space4` | 12 | 相关控件组内间距 |
| `space5` | 16 | 卡片内距、分组之间 |
| `space6` | 24 | 区块之间、三栏面板间距 |
| `space7` | 32 | 页面左右安全边距 |
| `space8` | 48 | 大区块分隔（工作台页头与内容） |

- 响应式不新增 token：窗口变窄允许跳档（space7→space4），禁止出现表外值。
- 工具栏分组 ≤3 组；按钮命中区沿用系统控件默认。

**圆角阶梯（卡片 12 / 主按钮 11 / 普通控件 8–9）**

| token | 值 | 用途 |
| --- | --- | --- |
| `radiusS` | 8 | 输入框、小控件、页签（普通控件下档） |
| `radiusM` | 9 | 次按钮、卡片内嵌元素（普通控件上档） |
| `radiusPrimary` | 11 | 主按钮专用档 |
| `radiusL` | 12 | 卡片/面板（`studioCard`） |
| `radiusPill` | 胶囊（高度一半） | 状态胶囊（REC/暂停徽标） |

- 主按钮独立一档 11，与普通控件（8–9）和卡片（12）区分。
- 剪辑片段、摄像头框等叠加在画布上的内容元素圆角走 8/9，与 UI 面板同律
  但凭内容区暗色 scrim 区分层。

## 5. 组件状态规范

统一口径：对比度要求 **正文 ≥4.5:1，大字（≥14pt Bold）/图形/焦点指示
≥3:1（WCAG 2.x AA）**；hover/pressed 用 2.3 的状态层公式；禁用 = 内容
38% 透明度；**颜色不是唯一信息通道**（配文字/形状）。

### 5.1 按钮

| 状态 | 主按钮（accentContainer） | 次按钮（描边式） | 幽灵按钮（工具栏/行内） | destructive |
| --- | --- | --- | --- | --- |
| rest | bg `accentContainer`，text `textOnAccentContainer`（4.68:1），1px 强描边 | bg `surfacePanel`，border `separatorLine`，text `textPrimary` | 无填充无边框，text `textPrimary` | bg `surfacePanel`，text `errorText` |
| hover | 主按钮不响应 hover 变色（普通填充按钮不吃 hover） | 状态层 +8% | 状态层 +8% 浮现 bezel | 状态层 +8% |
| pressed | 状态层 +12%（内容色叠加深） | 状态层 +12% | 状态层 +12% | 状态层 +12% |
| disabled | 内容整体 38% 透明度，去填充感知，无 hover | 同左 | 同左 | 同左 |
| focus | 系统焦点环（accent，≥3:1） | 同左 | 同左 | 同左 |

- 每视图 prominent（填充）按钮 ≤2 个；destructive 永不当 primary/默认按钮。
- 开窗或需更多输入的按钮标题加尾随「…」；自定义按钮必须有 pressed 态。

### 5.2 输入框 / ColorPicker / 滑杆

| 状态 | bg | border | text |
| --- | --- | --- | --- |
| rest | `surfacePanel` | `separatorLine` 强描边（30%/20%） | `textPrimary`；占位符 `textTertiary` |
| hover | 不变色 | 强描边不变 | — |
| pressed/focus | `surfacePanel` | 系统焦点环（图谱蓝）+ 描边 | 光标系统色 |
| disabled | `surfaceCanvas` | `separatorLine` | 内容 38% |

- 错误校验显示：边框转 `warning`（可纠正）或 `errorText` + 文字说明，
  不许只靠颜色（加图标/文案）。
- 滑杆（`Design/StudioSlider.swift`，线描定制）：拇指 13pt 白面 + 1.5pt
  图谱蓝描边；轨道 4pt 圆角，轨道底 `separatorLine`、填充 `accent` 随值
  生长；disabled 整体 38%。系统 `Slider` 的 `.tint` 只能给蓝色拇指，拿不到
  线描观感，故包 NSSlider 自绘（拖拽 / 键盘 / 无障碍仍走系统）。

### 5.3 开关（Switch/Checkbox）

- 状态差异不能只靠颜色：on = 填充 `accent` + 圆点位移到 trailing；off =
  `surfaceCanvas` 底 + `separatorLine` 强描边；混合态（checkbox）用短横线
  形状。
- on 填充上圆点为 `#FFFFFF`（纸白，对图谱蓝 2.90:1 贴 3:1 图形线，on/off
  另靠滑块位置双通道）；disabled 内容 38%。
- 主设置用 regular switch，从属行用 mini（macOS ControlSize 体系）。

### 5.4 列表 / 侧栏选中

| 状态 | bg | border | text |
| --- | --- | --- | --- |
| rest | 透明 | — | `textPrimary` |
| hover | 状态层 +8% | — | `textPrimary` |
| selected | `selectionTint`（选中面 `#EAF5FC`）+ 3pt 宽 leading 指示条（`accent`） | — | `textPrimary`（在 tint 上恢复原对比度，tint 后仍 >10:1，待验证） |
| selected + 非活动窗口 | tint 减半（手动退灰，对齐系统 selectedControlColor 失焦行为） | — | `textSecondary` |

- 选型说明：macOS 系统默认是饱和 accent 填充 + 反白文字（图谱蓝上白字只有
  2.90:1，正文不达标）；我们改用 tint 式选中——对比度可守 AA、饱和色视
  面积受控（配比纪律）、与纸白气质一致。这是对系统外观的有意偏离，理由
  如上，不要随手改回饱和填充。
- 侧栏图标 rest 态 `textSecondary`，selected/hover 吃 `accent`。

### 5.4b 分段选择（`Design/StudioSegmented.swift`）

| 状态 | bg | border | text |
| --- | --- | --- | --- |
| rest | 透明 | — | `textPrimary` |
| hover | 状态层 +8% | — | `textPrimary` |
| selected | `selectionTint`（选中面 `#EAF5FC`） | — | `textPrimary` |

- 选型理由：本机 macOS 上系统 `.segmented` 的选中段渲染为凸起白段，
  `.tint` 改不了该观感，拿不到「选中态 = 图谱蓝」的规范要求；故用
  `SecondaryActionButtonStyle(cornerRadius: radiusS, isSelected:,
  transparentRest: true)` 的自绘按钮组（与录制工作台「来源三选一」同一
  模式，26pt 高、caption 字）。菜单式下拉（`.menu`）保留系统控件，仅补
  `.tint(accent)` 让箭头着图谱蓝。
- 覆盖范围：画质 / 帧率 / 倒计时 / 摄像头分辨率、画布比例 / 画面适配 /
  抠像模式 / 过渡 / 预设应用范围 / 跟随灵敏度 / 原声试听 / 副字幕位置 /
  导出烧录 / 导出方式 / 分辨率 / 帧率 / 编码 / GIF 档位 / 精剪节奏。
- 行为不变：每段一个 Button，选中态带 `.isSelected` trait；拖拽 / 键盘 /
  无障碍走按钮语义。

### 5.5 录制中指示（全 App 语义专属）

| 状态 | 形态 |
| --- | --- |
| 录制中 | 陶橙点 `recIndicator` + “正在录制”文字 `recText` + mono 时间码常驻；呼吸动效 ≤0.5Hz、透明度幅度 ≤15%，或纯静态（HIG：避免持续振荡，~0.2Hz 最敏感） |
| 暂停 | 静态墨蓝点 + “已暂停”文字（不闪烁；陶橙只留给“进行中”，暂停回到中性墨蓝） |
| 完成 | 不设专门图形，回落中性 |
| 系统边界 | 不模仿 macOS 菜单栏隐私指示点的紫/绿语义；陶橙语义专属「录制进行中」的状态点与计时，播放语义图谱蓝与之严格不混用 |

- 双通道：状态点必须伴随文字/时间码；Reduce Motion 下保持静态形态可读。
- HUD 的「再按一次确认停止」确认提示用 `recText` 陶橙（录制期状态，仍在
  唯一暖色配额内）。

## 6. 动效原则

1. **有目的才动**：动效只用于表达状态变化（出现/消失/切换/进行中），
   不为装饰加动效（HIG motion）。
2. **时长三档**：微反馈（开关、按压）0.1–0.15s；标准过渡（面板展开、页签
   切换）0.2–0.3s；大面板/浮层 0.35–0.45s。上限 0.5s。
3. **曲线**：入场 easeOut、离场 easeIn、位移 easeInOut；SwiftUI 优先
   `.easeOut(duration:)` 与轻阻尼 `.spring(response: 0.25,
   dampingFraction: 0.8)`，禁弹跳过冲（bounce 类参数）。
4. **高频操作零动效**：录制/暂停/停止、切页签、拖滑杆不播动画——反馈用
   瞬时状态变化表达（HIG：高频交互不加动效）。
5. **持续动效白名单**：仅录制呼吸点（≤0.5Hz、幅度 ≤15% 透明度）与导出
   进度条；其余禁持续振荡。
6. **可跳过与降级**：尊重系统 Reduce Motion（动效信息必须有文字/形态替代
   通道）；窗口失焦时持续动效降为静态。
7. 摄像头布局平滑过渡（0.3/0.5/0.8s）属于**内容动效**（画面合成，用户可配），
   不受本表时长约束。

## 7. 线性图标规则

### 7.1 与 App 图标同语系

App 图标（`scripts/make_icon.py`）为定版的八角线描：白底、图谱蓝线条、
圆头端点的手绘八角母题。界面图标继承其中可迁移的三点：**圆角端点、圆润
转角、线描母题**；不使用投影与渐变（那是桌面图标的舞台光，界面里显得油腻）。

### 7.2 系统优先

- **SF Symbols 优先**（`Image(systemName:)`）：与文本同字重自动对齐、随文本
  缩放；只在 SF Symbols 缺失所需隐喻时才自绘。
- 自绘图标：24pt 栅格基准，描边 1.5–2pt（对齐 SF Symbols medium 视重），
  全圆角端点与圆角连接（stroke line cap/join round），无渐变无投影，几何
  居中留 2pt 呼吸。

### 7.3 颜色

- 单色：rest 态 `textSecondary`，selected/hover 吃 `accent`；语义图标
  （录制点、警告三角）用对应语义色。
- 图标不做多色填充；品牌 mark（侧栏 34pt logo 位）是唯一例外。

## 8. 设计立场

- 不像素级模仿任何录屏 / 剪辑软件的具体界面；界面表达自己的品牌语言。
- 文案说创作者语言，不做开发者 / 工程语系；不出现订阅话术、折扣倒计时、
  紧迫感营销元素。
- 界面第一眼由 App 内本身承担：白底蓝线描 + 低密度布局，官网与文档不堆
  营销页。

### 8.1 八角录屏的三个识别点（所有 UI 决策向此收敛）

1. **白底图谱蓝线描**：纸白 chrome + 边框线分层 + 图鉴图版预览。打开
   第一眼是“清爽”，与行业默认的深灰近黑工具形成截图级差异。
2. **单动作色纪律**：图谱蓝一组强调；陶橙只出现在录制语义；红只出现在
   destructive；金黄不用于界面。
3. **讲台气质布局**：三区 + 一个可折叠检查器的低密度布局、大间距
   （space5–6）、小圆角（radiusL 12）、mono 蓝灰时间码——“创作者的讲台”
   而非“导播的控制台”。

## 9. UI 自检清单（视觉改动自查）

- [ ] 本改动未出现新的 `Color(red:...)` / hex 字面量 /
      `Color.white.opacity` / `Color.black.opacity`（同口径 grep 对比改前
      改后；用户内容 `Color(hex:)` ColorPicker 绑定除外，见 §0）
- [ ] 所有取色来自 semantic token，无 `colorScheme` switch
- [ ] 各窗口浅色外观下截屏核对：背景/表面/文字层级清晰，无“黑底黑字/
      白底白字”类事故
- [ ] 正文对比度 ≥4.5:1；大字/图形/焦点指示 ≥3:1（对照 §2.3 表；例外项
      注明理由）
- [ ] 三级文字（`textTertiary`）只用于大字/图标/次要标注，未用于正文
- [ ] 本视图 prominent 填充按钮 ≤2 个；destructive 未当 primary
- [ ] hover/pressed 用状态层公式（8%/12%），未发明新色；disabled 为 38%
      透明度
- [ ] 每个交互状态有颜色之外的第二通道（文字/形状/图标）
- [ ] 陶橙只出现在录制语义；播放头/进度用图谱蓝；两者无混用
- [ ] 间距取自 space1–8、圆角取自 radiusS/M/Primary/L/Pill，无表外值
- [ ] 字号在五档阶梯内且 ≥11pt，无 Light 字重；时间码用
      `.monospacedDigit()` 等宽
- [ ] 新增图标为 SF Symbols 或符合 §7.2 的线性自绘（24pt 栅格、圆角端点、
      单色）
- [ ] 动效：时长 ≤0.5s、无持续振荡（录制呼吸点除外）、Reduce Motion 下可
      静态读
- [ ] 预览画布保持 `surfaceSunken`，未把 chrome 色混进画布
- [ ] 界面文案为创作者语言，无工程术语（diff/编号类）
- [ ] 未像素级模仿竞品的具体界面
- [ ] 截屏验证：能截屏的已附说明；不能的如实标注「未做画面级验证」
      （不许假装）

---

## 附：未决事项

| 事项 | 状态 |
| --- | --- |
| 高对比变体（Increased Contrast） | 待验证（§2.4），手动验收覆盖 |
| `selectionTint` 混底后的精确对比度复测 | 待验证（§5.4） |
| 所有对比度数值的工具复核 | 待验证（本文数值为脚本按 WCAG 公式计算） |
