import SwiftUI

/// 图谱蓝线描分段选择（规范 §5.4 选中态口径）：tint 式选中——选中段
/// 选中面底 + 墨蓝字，未选中透明底 + 墨蓝字，悬停 / 按下走状态层。
/// 替代系统 `.segmented`：本机 macOS 上 `.tint` 改不了分段选中段观感
/// （仍是系统凸起白段），拿不到「选中态 = 图谱蓝」的规范要求；结构上
/// 与录制工作台「来源三选一」同一模式。拖拽 / 键盘 / 无障碍仍走按钮
/// 语义（每段一个 Button，选中态带 `.isSelected` trait）。
struct StudioSegmented<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: StudioTheme.space2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
                .buttonStyle(
                    SecondaryActionButtonStyle(
                        cornerRadius: StudioTheme.radiusS,
                        isSelected: selection == option,
                        transparentRest: true
                    )
                )
                .accessibilityAddTraits(
                    selection == option ? [.isSelected] : []
                )
            }
        }
    }
}
