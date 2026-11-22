import AppKit
import SwiftUI

/// 图谱蓝线描设计规范令牌门面（docs/design/DESIGN_SYSTEM.md §2–§4）。
///
/// 颜色：semantic 层单套浅色值——白底、蓝色线描；本轮不做深色模式，
/// 不推导深色令牌（深色模式暂不提供）。
/// 机制说明：§2.5 的 Asset Catalog Color Set 在纯 SwiftPM 构建下不可用
/// （`swift build` 只原样拷贝 .xcassets，不执行 actool，Color Set 无法
/// 编译进 Assets.car），按指令改用等价的 NSColor 实现；
/// 视图层只允许引用这里的语义名，禁止 Color(red:)/hex 字面量与
/// `colorScheme` 取色（§0）。
///
/// 字体：只用系统字体语义修饰符（.body/.title2…，§3），不设字体常量。
/// 几何：间距 8 档 + 圆角 4 档（卡片 12 / 主按钮 11 / 普通控件 8–9，
/// 状态胶囊用 Capsule()，§4）。
enum StudioTheme {
    // MARK: 表面与描边（§2.3）

    /// 窗口最底层背景（纸白）。
    static let surfaceCanvas = token(0xFFFFFF)
    /// 卡片/面板/侧栏（纸白；层级靠边框线表达，不靠底色差）。
    static let surfacePanel = token(0xFFFFFF)
    /// 悬浮层：HUD、弹层、下拉（纸白）。
    static let surfaceRaised = token(0xFFFFFF)
    /// 次级面 / 预览画布：分段控件底、悬停态、输入区底（浅蓝面）。
    static let surfaceSunken = token(0xF4FAFE)
    /// 描边/分隔线（常规档）。
    static let separatorLine = token(0xDCE9F3)
    /// 强描边：输入框边界、主按钮 1px 描边、开关 off 底（§5.1–5.3）。
    static let separatorLineStrong = token(0xCFE3F2)
    /// 浮在画面内容上的中性暗色（提示条底、手柄投影）：真实内容区
    /// 不受浅色主题约束，白字与白手柄靠它保持可读。
    static let scrimOverMedia = token(0x20303C)
    /// 画面内容上的文字/手柄（纸白），与 scrimOverMedia 成对。
    static let textOnScrim = token(0xFFFFFF)

    // MARK: 文字三级（§2.3；规格只定三级，占位符/时间戳并入最浅档）

    /// 标题与正文（墨蓝）。
    static let textPrimary = token(0x20303C)
    /// 次级文字（蓝灰）。
    static let textSecondary = token(0x5B7183)
    /// 三级文字、未激活图标（浅蓝灰）。
    static let textTertiary = token(0x93A9B8)

    // MARK: 强调与动作（§2.3，前景色与容器色成对）

    /// 图谱蓝：主按钮填充、开关开启态、滑杆填充、选中态、分区小图标、
    /// 链接、录制列表选中条。
    static let accent = token(0x25A1E0)
    /// 唯一 prominent 填充色（主按钮容器底）。
    static let accentContainer = token(0x25A1E0)
    /// 主按钮文字，与 accentContainer 成对（墨蓝 4.68:1 过正文门槛；
    /// 白字仅 2.90:1 不取）。
    static let textOnAccentContainer = token(0x20303C)
    /// 列表/侧栏选中行底（tint 式选中，§5.4）。
    static let selectionTint = token(0xEAF5FC)

    // MARK: 语义色（§2.3/§5.5）

    /// 陶橙：全 App 唯一暖色，只用于「录制进行中」的状态点与计时。
    static let recIndicator = token(0xD97D3E)
    /// 录制计时文字，与 recIndicator 同色。
    static let recText = token(0xD97D3E)
    /// 警告图标（只用于权限告示卡）。
    static let warning = token(0xC08F1D)
    /// 权限告示卡底 / 描边（只用于权限告示卡）。
    static let warningSurface = token(0xFFF9EC)
    static let warningBorder = token(0xEDD9A3)
    /// 错误文字；destructive 同源，永不当 primary。规格未覆盖错误色，
    /// 沿用功能性红（非装饰暖色，不进旧色清零清单）。
    static let errorText = token(0xC93A3A)
    /// 播放头/进度/播放态徽标（图谱蓝，只做图形不做文字）。
    static let playbackGold = token(0x25A1E0)

    // MARK: 间距阶梯（§4，2/4/8 基数，8 档封顶）

    static let space1: CGFloat = 2
    static let space2: CGFloat = 4
    static let space3: CGFloat = 8
    static let space4: CGFloat = 12
    static let space5: CGFloat = 16
    static let space6: CGFloat = 24
    static let space7: CGFloat = 32
    static let space8: CGFloat = 48

    // MARK: 圆角阶梯（§4：卡片 12 / 主按钮 11 / 普通控件 8–9；状态胶囊用 Capsule()）

    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 9
    static let radiusL: CGFloat = 12
    static let radiusPrimary: CGFloat = 11

    /// 图标按钮最小点击区（§5.1）：视觉图标可以小，点区不许低于 28pt。
    static let minHitTarget: CGFloat = 28

    /// 语义 token 的单值实现。规范 §2.5 首选 Asset Catalog，纯 SwiftPM
    /// 下不可用（见类型注释），此处为指令允许的等价实现。
    private static func token(
        _ hex: UInt32,
        alpha: Double = 1
    ) -> Color {
        Color(
            NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: alpha
            )
        )
    }
}

struct StudioCard: ViewModifier {
    var padding: CGFloat = StudioTheme.space5

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(StudioTheme.surfacePanel.opacity(0.84))
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.radiusL)
                    .stroke(StudioTheme.separatorLine, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusL))
    }
}

extension View {
    func studioCard(padding: CGFloat = StudioTheme.space5) -> some View {
        modifier(StudioCard(padding: padding))
    }

    /// 悬浮层唯一投影：极淡一层，全 App 统一，不许各层各飘一种阴影。
    func studioFloatingShadow() -> some View {
        modifier(StudioFloatingShadow())
    }
}

/// 悬浮层（toast、HUD）统一投影：墨蓝 16% + 半径 10 + 下沉 3。
struct StudioFloatingShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(
            color: StudioTheme.scrimOverMedia.opacity(0.16),
            radius: 10,
            y: 3
        )
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(
            in: CharacterSet(charactersIn: "#")
        )
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let red = Double((number >> 16) & 0xFF) / 255
        let green = Double((number >> 8) & 0xFF) / 255
        let blue = Double(number & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String {
        guard
            let color = NSColor(self).usingColorSpace(.deviceRGB)
        else {
            return "#101414"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}
