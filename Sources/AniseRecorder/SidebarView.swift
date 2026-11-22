import AppKit
import ImageIO
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: StudioModel
    let collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: StudioTheme.space4) {
                brandMark
                    .accessibilityLabel("八角录屏")

                VStack(alignment: .leading, spacing: StudioTheme.space1) {
                    if !collapsed {
                        Text("八角录屏")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text("为生活添点滋味")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                }
            }
            // top 44 与 RootView 折叠按钮 top 76 同为窗口标题栏对位锚点，非内容间距
            .padding(.top, 44)
            .padding(.horizontal, collapsed ? StudioTheme.space3 : StudioTheme.space5)

            Button {
                model.showRecorder()
            } label: {
                HStack(spacing: StudioTheme.space3) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.medium))
                    if !collapsed {
                        Text("新建录制")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .help("新建录制")
            .padding(.horizontal, collapsed ? StudioTheme.space3 : StudioTheme.space4)
            .padding(.top, StudioTheme.space7)

            if !collapsed {
                Text("录制")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .padding(.horizontal, StudioTheme.space5)
                    .padding(.top, StudioTheme.space6)
                    .padding(.bottom, StudioTheme.space3)
            } else {
                Spacer().frame(height: StudioTheme.space5)
            }

            ScrollView {
                LazyVStack(spacing: StudioTheme.space2) {
                    if model.isScanningProjects, model.projects.isEmpty,
                        !collapsed
                    {
                        // P4 防卡死：启动扫描已下沉后台，扫描期间给读取
                        // 占位，避免短暂误显「还没有录制」空态。
                        HStack(spacing: StudioTheme.space2) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(StudioTheme.accent)
                            Text("正在读取工程…")
                                .font(.subheadline)
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, StudioTheme.space3)
                        .padding(.vertical, StudioTheme.space4)
                    }
                    if model.projects.isEmpty, !model.isScanningProjects,
                        !collapsed
                    {
                        VStack(alignment: .leading, spacing: StudioTheme.space3) {
                            Text("还没有录制")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Text("右侧已准备好录制：选好画面来源，点“开始录制”。")
                                .font(.callout)
                                .foregroundStyle(StudioTheme.textSecondary)
                                .lineSpacing(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, StudioTheme.space3)
                        .padding(.vertical, StudioTheme.space4)
                    }

                    ForEach(model.projects) { project in
                        ProjectRow(
                            project: project,
                            selected: project.id == model.selectedProjectID,
                            collapsed: collapsed,
                            actions: { projectActions(project) }
                        ) {
                            model.selectProject(project)
                        }
                        .contextMenu {
                            projectActions(project)
                        }
                    }
                }
                .padding(.horizontal, collapsed ? StudioTheme.space2 : StudioTheme.space3)
                .padding(.bottom, StudioTheme.space4)
            }
            Spacer(minLength: StudioTheme.space3)

            if !collapsed {
                HStack {
                    Spacer()
                    Text(AppVersion.display())
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.textTertiary)
                        .help(AppVersion.detailedDescription())
                        .accessibilityLabel(
                            AppVersion.detailedDescription()
                        )
                }
                .padding(.horizontal, StudioTheme.space5)
                .padding(.bottom, StudioTheme.space4)
            }
        }
        .frame(width: collapsed ? 56 : 228)
        .background(StudioTheme.surfacePanel)
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand(perform: removeSelectedProject)
    }

    private func removeSelectedProject() {
        guard
            let project = model.projects.first(where: {
                $0.id == model.selectedProjectID
            })
        else {
            return
        }
        model.requestProjectRemoval(project)
    }

    /// 工程管理动作：右键菜单与行内「…」按钮共用同一份，
    /// 管理入口不再只藏在右键里。
    @ViewBuilder
    private func projectActions(_ project: StudioProject) -> some View {
        Button("在访达中显示") {
            model.revealProjectInFinder(project)
        }
        .disabled(!model.canManageProjects)

        // 重命名入口——页头工程名本就可编辑，侧栏补同等入口。
        // 只对当前打开的工程可用（updateProjectName 作用于 draft）。
        Button("重命名工程…") {
            renameProject(project)
        }
        .disabled(
            !model.canManageProjects || project.id != model.selectedProjectID
        )

        if ProjectStore.isHidden(project) {
            Button("恢复到列表") {
                model.restoreProjectToList(project)
            }
            .disabled(!model.canManageProjects)
        } else {
            Button("从列表移除") {
                model.removeProjectFromList(project)
            }
            .disabled(!model.canManageProjects)
        }

        Button("归档") {
            model.archiveProject(project)
        }
        .disabled(!model.canManageProjects)

        Divider()

        Button("删除工程和原视频…", role: .destructive) {
            model.deleteProject(project)
        }
        .disabled(!model.canManageProjects)
    }

    /// 侧栏重命名入口——AppKit 输入框弹窗，确认后走
    /// `updateProjectName`（撤销一步、立即落盘、空名拒绝）。
    private func renameProject(_ project: StudioProject) {
        let alert = NSAlert()
        alert.messageText = "重命名工程"
        alert.informativeText = "新名字会同步给导出文件、随视频导出的 .srt 字幕与分段导出的默认文件名（工程文件夹名不变）。"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = project.name
        input.placeholderString = "工程名"
        alert.accessoryView = input
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        model.updateProjectName(input.stringValue)
    }

    /// 品牌线描 Logo（八角、白底、图谱蓝线条）。打包 App 的图在
    /// Contents/Resources（Bundle.main 解析）；开发期构建回退
    /// `Bundle.module` 资源包；都拿不到时回退波形标记，不留空白。
    /// 不用 SwiftUI `Image(name, bundle:)`——它走 `NSImage(named:)`
    /// 语义，找不到资源包里的散图。
    /// P4 防卡死：`let` 缓存单次解码（1024×1024 PNG），不再随侧栏每次
    /// 重绘重读盘。
    private static let brandLogo: NSImage? = {
        if
            let url = Bundle.main.url(
                forResource: "anise-logo",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return Bundle.module.image(forResource: "anise-logo")
    }()

    private var brandMark: some View {
        Group {
            if let logo = Self.brandLogo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                        .fill(StudioTheme.accent)
                    Image(systemName: "waveform.path")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(StudioTheme.textOnAccentContainer)
                }
            }
        }
        .frame(width: 34, height: 34)
    }
}

private struct ProjectRow<Actions: View>: View {
    let project: StudioProject
    let selected: Bool
    let collapsed: Bool
    @ViewBuilder let actions: () -> Actions
    let action: () -> Void

    @State private var isHovering = false
    @State private var menuHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: collapsed ? 0 : StudioTheme.space3) {
                thumbnail
                    .frame(
                        width: collapsed ? 38 : 54,
                        height: collapsed ? 38 : 34
                    )
                    .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))

                if !collapsed {
                    VStack(alignment: .leading, spacing: StudioTheme.space2) {
                        Text(project.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(project.name)
                        HStack(spacing: StudioTheme.space2) {
                            Text(formatDuration(project.trimDuration))
                            Text("·")
                            Text("\(project.clicks.count) 次点击")
                        }
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // 行内管理入口——hover 时出现「…」菜单，
                // 与右键菜单同一份动作；折叠态空间不足仍走右键。
                if !collapsed {
                    Menu {
                        actions()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .frame(
                                width: StudioTheme.minHitTarget,
                                height: StudioTheme.minHitTarget
                            )
                            .background(
                                StudioTheme.textPrimary.opacity(
                                    menuHovering ? 0.08 : 0
                                )
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: StudioTheme.radiusS
                                )
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .onHover { menuHovering = $0 }
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityLabel("工程管理操作")
                    .accessibilityHint("在访达中显示、移除、归档或删除工程")
                }
            }
            .padding(collapsed ? StudioTheme.space2 : StudioTheme.space3)
            .background(
                selected
                    ? StudioTheme.selectionTint
                    : StudioTheme.textPrimary.opacity(isHovering ? 0.08 : 0)
            )
            .overlay(alignment: .leading) {
                // §5.4 选中第二通道：3pt 宽 leading 指示条（形状）
                if selected {
                    Capsule()
                        .fill(StudioTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, StudioTheme.space3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(project.name)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if
            let url = project.thumbnailURL,
            let image = ProjectThumbnailCache.image(for: url)
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                StudioTheme.surfaceSunken
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
    }
}

enum ProjectThumbnailCache {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let maxPixelSize = 216

    static func image(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard
            let source = CGImageSourceCreateWithURL(key, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
            )
        else {
            return nil
        }
        let image = NSImage(cgImage: thumbnail, size: .zero)
        cache.setObject(
            image,
            forKey: key,
            cost: thumbnail.width * thumbnail.height * 4
        )
        return image
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}
