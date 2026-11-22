import AppKit
import SwiftUI

// MARK: - 快捷键目录（数据 model）

/// 一条快捷键的展示条目：标题、按键描述与可选的生效条件说明。纯文档，
/// 不驱动任何行为——行为仍由菜单与各处键盘监听负责。
struct AppShortcut: Identifiable, Equatable {
    /// 稳定标识：测试与 README 对照用，不进 UI。
    let id: String
    let title: String
    let keys: String
    var note: String? = nil
}

/// 快捷键分组（帮助面板里的一个区块）。
struct ShortcutGroup: Identifiable, Equatable {
    let id: String
    let name: String
    /// 组级生效条件说明（条目级差异用 `AppShortcut.note`）。
    var note: String? = nil
    let shortcuts: [AppShortcut]
}

/// 应用全部快捷键的唯一事实源：帮助面板只读这里。与菜单
/// （AniseRecorderApp.swift）、编辑器与 HUD / 提词面板的键盘监听
/// （EditorView.swift / RecordingHUD.swift / TeleprompterPanel.swift）
/// 的实际行为保持一致；新增快捷键时同步维护本目录。
enum AppShortcutCatalog {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(
            id: "global",
            name: "全局",
            shortcuts: [
                AppShortcut(id: "global.new-recording", title: "新建录制", keys: "⌘N"),
                AppShortcut(id: "global.import", title: "导入工程…", keys: "⌘⇧I"),
                AppShortcut(id: "global.toggle-recording", title: "开始 / 停止录制", keys: "⌘⇧R"),
                AppShortcut(
                    id: "global.pause",
                    title: "暂停 / 继续录制",
                    keys: "⌘⇧P",
                    note: "录制中可用"
                ),
                AppShortcut(
                    id: "global.stop-esc",
                    title: "停止录制",
                    keys: "Esc",
                    note: "录制中按 HUD 停止键生效；设置里可开启二次确认"
                ),
                AppShortcut(
                    id: "global.export",
                    title: "导出 MP4…",
                    keys: "⌘E",
                    note: "按导出卡当前「导出方式」执行：整片 / 入出点 / 按标记分段"
                ),
                AppShortcut(id: "global.reveal", title: "在访达中显示素材", keys: "⌘⇧O"),
                AppShortcut(id: "global.undo", title: "撤销工程编辑", keys: "⌘Z"),
                AppShortcut(id: "global.redo", title: "重做工程编辑", keys: "⇧⌘Z"),
                AppShortcut(id: "global.settings", title: "打开设置", keys: "⌘,"),
                AppShortcut(id: "global.shortcut-help", title: "键盘快捷键（本面板）", keys: "⌘/"),
            ]
        ),
        ShortcutGroup(
            id: "editor-playback",
            name: "编辑器 · 播放与标记",
            note: "非文本输入状态时生效",
            shortcuts: [
                AppShortcut(id: "editor.space", title: "播放 / 暂停", keys: "空格"),
                AppShortcut(id: "editor.marker", title: "在播放头添加标记", keys: "M"),
                AppShortcut(
                    id: "editor.playhead-step",
                    title: "步进播放头（左 / 右）",
                    keys: "←→",
                    note: "默认步进 1 帧；按住 ⇧ 步进 1 秒"
                ),
            ]
        ),
        ShortcutGroup(
            id: "editor-trim",
            name: "编辑器 · 掐头去尾",
            note: "非文本输入状态时生效；设置导出「入出点」模式的区间",
            shortcuts: [
                AppShortcut(id: "editor.trim-start", title: "把导出区间起点设到播放头", keys: "I"),
                AppShortcut(id: "editor.trim-end", title: "把导出区间终点设到播放头", keys: "O"),
                AppShortcut(
                    id: "editor.split",
                    title: "在播放头切分当前片段",
                    keys: "⌘B",
                    note: "与时间线「在播放头切分」按钮同一行为，一步撤销"
                ),
                AppShortcut(
                    id: "editor.timeline-collapse",
                    title: "折叠 / 展开时间线",
                    keys: "⌘\\",
                    note: "收起时预览区放大；状态跨工程与重启保留"
                ),
            ]
        ),
        ShortcutGroup(
            id: "editor-camera",
            name: "编辑器 · 摄像头微调",
            note: "画中画布局且已选中摄像头时生效",
            shortcuts: [
                AppShortcut(
                    id: "editor.camera-nudge",
                    title: "微调摄像头位置",
                    keys: "⌥←→↑↓",
                    note: "按住 ⇧ 步进 5%，默认步进 1%"
                ),
            ]
        ),
        ShortcutGroup(
            id: "teleprompter",
            name: "提词器",
            shortcuts: [
                AppShortcut(id: "teleprompter.toggle", title: "打开 / 关闭提词面板", keys: "⌘⌥T"),
                AppShortcut(
                    id: "teleprompter.pause",
                    title: "暂停 / 继续滚动",
                    keys: "⌘⌥P",
                    note: "面板打开时"
                ),
                AppShortcut(
                    id: "teleprompter.speed",
                    title: "加速 / 减速一档",
                    keys: "⌘⌥↑ ⌘⌥↓",
                    note: "面板打开时"
                ),
                AppShortcut(
                    id: "teleprompter.line",
                    title: "回退 / 前进一行",
                    keys: "⌘⌥← ⌘⌥→",
                    note: "面板打开时"
                ),
                AppShortcut(
                    id: "teleprompter.space",
                    title: "暂停 / 继续滚动",
                    keys: "空格",
                    note: "面板聚焦时"
                ),
            ]
        ),
    ]
}

// MARK: - 帮助面板视图

/// 快捷键帮助面板：帮助菜单「键盘快捷键…」（⌘/）打开的纯文档
/// 面板，只消费 `AppShortcutCatalog`；视觉按八角规范走 StudioTheme 令牌。
struct ShortcutHelpView: View {
    var onClose: () -> Void
    var groups: [ShortcutGroup] = AppShortcutCatalog.groups

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text("键盘快捷键")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer(minLength: StudioTheme.space4)
                Button("关闭") {
                    onClose()
                }
                .buttonStyle(SecondaryActionButtonStyle(cornerRadius: StudioTheme.radiusS))
                .keyboardShortcut(.cancelAction)
            }
            Text("全局与编辑器内的全部快捷键；条目按实际生效范围注明条件。")
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: StudioTheme.space5) {
                    ForEach(groups) { group in
                        section(group)
                    }
                }
                .padding(.bottom, StudioTheme.space2)
            }
        }
        .padding(StudioTheme.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.surfaceCanvas)
    }

    private func section(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            if let note = group.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: StudioTheme.space2) {
                ForEach(group.shortcuts) { shortcut in
                    row(shortcut)
                }
            }
        }
    }

    private func row(_ shortcut: AppShortcut) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: StudioTheme.space1) {
                Text(shortcut.title)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textPrimary)
                if let note = shortcut.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            Spacer(minLength: StudioTheme.space4)
            Text(shortcut.keys)
                .font(.callout.weight(.medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, StudioTheme.space3)
                .padding(.vertical, StudioTheme.space1)
                .background(StudioTheme.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                        .stroke(StudioTheme.separatorLine, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
        }
    }
}

// MARK: - 帮助窗口控制器

/// ⌘/ 帮助窗口：普通标题窗口（不抢 HUD / 提词面板的层级），复用单实例；
/// Esc（cancelAction）或关闭按钮均可关。
@MainActor
final class ShortcutHelpWindowController {
    static let shared = ShortcutHelpWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: CGSize(width: 480, height: 620)
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "键盘快捷键"
        window.isReleasedWhenClosed = false
        // 与主界面同一套浅色外观（图谱蓝线描单套浅色）
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(
            rootView: ShortcutHelpView(
                onClose: { [weak self] in self?.hide() }
            )
        )
        window.center()
        window.setFrameAutosaveName("ShortcutHelpWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
