import SwiftUI

// 八角设计规范 §5.1 自绘按钮的统一状态实现（状态层公式见 §2.3）：
// hover = 内容色 +8% 叠加、pressed = +12%、disabled = 内容整体 38% 透明度；
// 主按钮 hover 不变色（Evil Martians 口径）。全部叠加只用语义 token，不发明新色。

/// 主按钮：accentContainer 填充 + 1px 强描边（§2.3），pressed 内容色 +12%。
/// 圆角走主按钮专用档 11（普通控件 8–9、卡片 12，§4）。
struct PrimaryActionButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = StudioTheme.radiusPrimary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(StudioTheme.textOnAccentContainer)
            .background(StudioTheme.accentContainer)
            .overlay(
                StudioTheme.textOnAccentContainer.opacity(
                    configuration.isPressed ? 0.12 : 0
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isEnabled ? 1 : 0.38)
    }
}

/// 次按钮：surfacePanel 底 + separatorLine 描边；hover +8%、pressed +12%。
/// isSelected：页签/筛选选中态（§5.4 selectionTint + textPrimary）；
/// transparentRest：分段选择的 rest 态（透明底 + textSecondary，§5.4 rest 行）；
/// destructive：删除类次动作（§5.1 rest 行）——errorText 内容 + 40% 同色描边，
/// 几何与普通次按钮完全一致，避免出现第二套自绘 destructive 卡。
struct SecondaryActionButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = StudioTheme.radiusM
    var isSelected = false
    var transparentRest = false
    var destructive = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isSelected
                    ? StudioTheme.textPrimary
                    : (transparentRest
                        ? StudioTheme.textSecondary
                        : (destructive
                            ? StudioTheme.errorText
                            : StudioTheme.textPrimary))
            )
            .background(
                isSelected
                    ? StudioTheme.selectionTint
                    : (transparentRest ? Color.clear : StudioTheme.surfacePanel)
            )
            .overlay(
                (destructive
                    ? StudioTheme.errorText
                    : StudioTheme.textPrimary).opacity(
                    configuration.isPressed ? 0.12 : (isHovering ? 0.08 : 0)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isSelected
                            ? Color.clear
                            : (destructive
                                ? StudioTheme.errorText.opacity(0.4)
                                : StudioTheme.separatorLine),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { isHovering = $0 }
    }
}

/// HUD 胶囊按钮：rest 内容色 8% 内衬（§9.6 现状收敛值），hover +8%、pressed +12% 叠加；
/// isActive 由调用方给 tint（调整镜头 selectionTint、暂停 warning、停止 textPrimary）。
struct HUDChipButtonStyle: ButtonStyle {
    var isActive = false
    var activeTint: Color = StudioTheme.selectionTint
    var activeForeground: Color = StudioTheme.textPrimary
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isActive ? activeForeground : StudioTheme.textSecondary
            )
            .background(
                isActive
                    ? activeTint
                    : StudioTheme.textPrimary.opacity(0.08)
            )
            .overlay(
                StudioTheme.textPrimary.opacity(
                    configuration.isPressed ? 0.12 : (isHovering ? 0.08 : 0)
                )
            )
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { isHovering = $0 }
    }
}

/// 幽灵按钮（行内文字链接）：无填充无描边，hover/pressed 用内容色状态层（§5.1 幽灵行）。
/// 禁用走内容整体 38%（与其他按钮同公式），调用方不再各自补 opacity。
struct GhostActionButtonStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, StudioTheme.space2)
            .padding(.vertical, StudioTheme.space1)
            .background(
                StudioTheme.textPrimary.opacity(
                    configuration.isPressed ? 0.12 : (isHovering ? 0.08 : 0)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { isHovering = $0 }
    }
}

/// 图标按钮（§5.1 图标行）：点击区不小于 28pt（Theme.minHitTarget），
/// rest 透明、hover +8%、pressed +12% 叠加（§2.3 状态层公式），禁用 38%。
/// 状态层叠在 label 之上——label 里的图标或自绘小底都不被盖掉观感，
/// hover 反馈两种用法一致。
struct IconButtonStyle: ButtonStyle {
    var width: CGFloat = StudioTheme.minHitTarget
    var height: CGFloat = StudioTheme.minHitTarget
    var cornerRadius: CGFloat = StudioTheme.radiusS
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: width, height: height)
            .overlay(
                StudioTheme.textPrimary.opacity(
                    configuration.isPressed ? 0.12 : (isHovering ? 0.08 : 0)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { isHovering = $0 }
    }
}
