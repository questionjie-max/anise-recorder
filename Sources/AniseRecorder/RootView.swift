import SwiftUI

struct RootView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(StudioPreferences.sidebarCollapsedKey)
    private var sidebarCollapsed = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, collapsed: sidebarCollapsed)
            sidebarDivider
            Group {
                if model.isRecording {
                    // 1118 Loop：录制中把主窗口带回前台时显示操作状态页，
                    // 保证「再次进入软件点停止」永远可达。
                    RecordingStatusView(model: model)
                } else if model.draft != nil {
                    EditorView(model: model)
                } else {
                    RecorderSetupView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(StudioTheme.surfaceCanvas)
        .preferredColorScheme(.light)
        .overlay(alignment: .bottomTrailing) {
            if let message = model.errorMessage {
                ErrorToast(
                    message: message,
                    // 权限类错误给直达动作，错过引导卡时少走一步
                    showOpenSettings: message.contains("屏幕录制权限")
                ) {
                    model.clearError()
                }
                .padding(.trailing, StudioTheme.space6)
                .padding(
                    .bottom,
                    // 92 = 无编辑器时避让底部主按钮区的对位锚点，非内容间距
                    model.draft == nil ? 92 : StudioTheme.space6
                )
                .transition(
                    reduceMotion
                        ? .identity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
                // 8 秒自动消失——错误不该驻留跨多个操作；
                // 每次新错误重置计时。
                .task(id: message) {
                    if reduceMotion { return }
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    model.clearError()
                }
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: model.errorMessage
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: sidebarCollapsed
        )
    }

    private var sidebarDivider: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(StudioTheme.separatorLine)
                .frame(width: 1)
            Button {
                sidebarCollapsed.toggle()
            } label: {
                Image(
                    systemName: sidebarCollapsed
                        ? "chevron.right"
                        : "chevron.left"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 16, height: 32)
                .background(StudioTheme.surfacePanel)
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                        .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
                )
            }
            // 侧栏折叠手柄：视觉仍是 16pt 窄条，点击区扩到 28×32（§5.1 图标行）。
            .buttonStyle(IconButtonStyle(width: StudioTheme.minHitTarget, height: 32))
            .padding(.top, 76)
            .help(sidebarCollapsed ? "展开工程列表" : "收起工程列表")
            .accessibilityLabel(
                sidebarCollapsed ? "展开工程列表" : "收起工程列表"
            )
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
    }
}

/// T4：toast 语义判定（可测试纯函数）——P5 口径：负向关键词判错误
/// 样式（红色三角 + 红描边），否则中性信息样式。
enum ToastSemantics {
    static let negativeKeywords: [String] = [
        "失败", "无法", "错误", "权限", "需要处理", "未能", "损坏",
        "已停止", "未完成", "意外停止",
    ]

    static func isError(_ message: String) -> Bool {
        negativeKeywords.contains { message.contains($0) }
    }
}

private struct ErrorToast: View {
    let message: String
    let showOpenSettings: Bool
    let dismiss: () -> Void

    private var isError: Bool {
        ToastSemantics.isError(message)
    }

    var body: some View {
        HStack(alignment: .top, spacing: StudioTheme.space3) {
            Image(
                systemName: isError
                    ? "exclamationmark.triangle.fill"
                    : "info.circle"
            )
            .foregroundStyle(isError ? StudioTheme.errorText : StudioTheme.accent)
            .font(.system(size: 13))
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: StudioTheme.space2) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                // 权限类错误给直达动作（与告示卡同款入口）。
                if showOpenSettings {
                    Button {
                        PrivacySettingsPane.screenRecording.open()
                    } label: {
                        Text("打开系统设置")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(
                        SecondaryActionButtonStyle(
                            cornerRadius: StudioTheme.radiusS
                        )
                    )
                    .help("打开隐私与安全性里的屏幕录制设置")
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .buttonStyle(IconButtonStyle())
            .help("关闭提示")
            .accessibilityLabel("关闭错误提示")
        }
        .padding(StudioTheme.space4)
        .frame(maxWidth: 420, alignment: .leading)
        .background(StudioTheme.surfaceRaised)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .stroke(
                    isError
                        ? StudioTheme.errorText.opacity(0.28)
                        : StudioTheme.separatorLine,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
        // 悬浮层投影走全 App 统一的一层极淡投影（墨蓝 16%），不各飘一种
        .studioFloatingShadow()
    }
}
