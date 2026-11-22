import AppKit
import SwiftUI

struct WindowPickerView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter: WindowDisplayFilter = .all
    @State private var currentDesktopOnly = false
    @State private var selectedWindowID: UInt32?
    @State private var preview: NSImage?
    @State private var previewLoading = false
    @State private var previewMessage: String?

    init(model: StudioModel) {
        self.model = model
        _selectedWindowID = State(
            initialValue: model.setup.window?.windowID
                ?? model.windows.first?.windowID
        )
    }

    private var groups: [WindowDisplayGroup] {
        WindowPickerLogic.groups(
            windows: model.windows,
            displays: model.displays,
            filter: filter,
            query: query,
            currentDesktopOnly: currentDesktopOnly
        )
    }

    private var visibleWindows: [WindowCaptureInfo] {
        groups.flatMap(\.windows)
    }

    private var selectedWindow: WindowCaptureInfo? {
        visibleWindows.first { $0.windowID == selectedWindowID }
    }

    private var counts: [UInt32: Int] {
        WindowPickerLogic.displayCounts(
            windows: model.windows,
            displays: model.displays,
            currentDesktopOnly: currentDesktopOnly
        )
    }

    private var offscreenCount: Int {
        model.windows.filter { !$0.isCurrentlyVisible }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, StudioTheme.space5)

            HStack(spacing: 0) {
                windowList
                    .frame(width: 365)

                Rectangle()
                    .fill(StudioTheme.separatorLine)
                    .frame(width: 1)
                    .padding(.horizontal, StudioTheme.space5)

                previewPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(StudioTheme.separatorLine)
                .padding(.top, StudioTheme.space5)

            footer
                .padding(.top, StudioTheme.space4)
        }
        .padding(StudioTheme.space6)
        .frame(minWidth: 790, minHeight: 590)
        .background(StudioTheme.surfaceCanvas)
        .onAppear {
            ensureVisibleSelection()
        }
        .onChange(of: query) { _, _ in
            ensureVisibleSelection()
        }
        .onChange(of: filter) { _, _ in
            ensureVisibleSelection()
        }
        .onChange(of: currentDesktopOnly) { _, _ in
            ensureVisibleSelection()
        }
        .onChange(of: model.windows) { _, _ in
            ensureVisibleSelection()
        }
        .task(id: selectedWindowID) {
            await loadPreview()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: StudioTheme.space5) {
            VStack(alignment: .leading, spacing: StudioTheme.space2) {
                Text("选择录制窗口")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(
                    "默认列出所有 macOS 桌面的窗口；当前桌面不可见的窗口会标注。切换桌面后点“刷新窗口”更新可见状态。"
                )
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            Button {
                Task {
                    await model.reloadWindowCatalog()
                    ensureVisibleSelection()
                }
            } label: {
                // P5 加载态：枚举期间按钮转圈禁用，不再静默等。
                Label(
                    model.isRefreshingWindows ? "正在刷新…" : "刷新窗口",
                    systemImage: model.isRefreshingWindows
                        ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                )
                .font(.callout)
                .padding(.horizontal, StudioTheme.space4)
                .frame(height: 28)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(model.isRefreshingWindows)
            .help("重新枚举所有桌面的窗口")

            Button {
                model.dismissWindowPicker()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("关闭窗口选择")
            .accessibilityLabel("取消选择窗口")
        }
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            TextField("搜索应用、窗口标题或显示器", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .tint(StudioTheme.accent)

            HStack(spacing: StudioTheme.space3) {
                Toggle("仅当前桌面", isOn: $currentDesktopOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(StudioTheme.accent)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: StudioTheme.space2)
                if !currentDesktopOnly, offscreenCount > 0 {
                    Text("\(offscreenCount) 个窗口当前不可见")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: StudioTheme.space2) {
                    filterButton(
                        title: "全部屏幕",
                        value: .all,
                        count: model.windows.count
                    )
                    ForEach(model.displays) { display in
                        filterButton(
                            title: display.name,
                            value: .display(display.id),
                            count: counts[display.id] ?? 0
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)

            Divider()
                .overlay(StudioTheme.separatorLine)

            if model.windows.isEmpty {
                // 列表为空的最常见根因是缺屏幕录制权限（无权限时
                // 系统枚举不到任何窗口）——空态先说权限原因，别让人照着
                // 「打开应用再刷新」死循环。
                if !model.screenPermissionGranted {
                    emptyState(
                        "拿不到窗口列表：还没有屏幕录制权限。请在“\(PrivacySettingsPane.screenRecording.pathDescription)”里允许“八角录屏”（关掉本窗口就能看到工作台顶部的引导卡，可一键打开系统设置），回来后点“重新检查”。"
                    )
                } else {
                    emptyState(
                        "没有找到可列出的窗口。请先打开要录制的应用，再点“刷新窗口”。"
                    )
                }
            } else if groups.isEmpty {
                if currentDesktopOnly {
                    emptyState(
                        "当前桌面没有匹配的窗口。关闭“仅当前桌面”可以查看其他桌面的窗口。"
                    )
                } else {
                    emptyState(
                        "没有匹配的窗口。换关键词试试，或清空搜索查看全部窗口。"
                    )
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: StudioTheme.space4) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: StudioTheme.space2) {
                                HStack {
                                    Text(group.title)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                    Spacer()
                                    Text("\(group.windows.count)")
                                        .font(.callout)
                                        .monospacedDigit()
                                        .foregroundStyle(StudioTheme.textSecondary)
                                }
                                ForEach(group.windows) { window in
                                    WindowRow(
                                        window: window,
                                        groupName: group.title,
                                        isSelected:
                                            selectedWindowID
                                            == window.windowID
                                    ) {
                                        selectedWindowID = window.windowID
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, StudioTheme.space3)
                }
            }
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            if let window = selectedWindow {
                HStack(spacing: StudioTheme.space3) {
                    WindowAppIcon(
                        bundleIdentifier: window.bundleIdentifier
                    )
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: StudioTheme.space1) {
                        Text(window.appName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text(
                            window.title.isEmpty ? "未命名窗口" : window.title
                        )
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                    }
                }

                if !window.isCurrentlyVisible {
                    Label(
                        "该窗口当前不可见（在其他桌面或已最小化），录制时会尝试单独捕获。",
                        systemImage: "eye.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                        .fill(StudioTheme.surfaceSunken)
                    if let preview {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFit()
                    } else if previewLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(StudioTheme.accent)
                    } else {
                        VStack(spacing: StudioTheme.space3) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 24))
                                .foregroundStyle(StudioTheme.textTertiary)
                            Text(previewMessage ?? "暂无预览")
                                .font(.callout)
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                        .stroke(StudioTheme.separatorLine, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))

                HStack(spacing: StudioTheme.space4) {
                    previewMetadata(
                        "尺寸",
                        "\(window.width) × \(window.height)"
                    )
                    previewMetadata(
                        "显示器",
                        displayName(for: window)
                    )
                }
            } else {
                emptyState("从左侧选择一个窗口以查看大图预览。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("确认后才会替换当前录制窗口。")
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            Spacer()
            Button {
                model.dismissWindowPicker()
                dismiss()
            } label: {
                Text("取消")
                    .padding(.horizontal, StudioTheme.space4)
                    .frame(height: 32)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .keyboardShortcut(.cancelAction)
            .font(.callout)

            Button {
                guard let selectedWindow else { return }
                model.selectWindow(selectedWindow)
                dismiss()
            } label: {
                Text("使用此窗口")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, StudioTheme.space5)
                    .frame(height: 32)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(selectedWindow == nil)
        }
    }

    private func filterButton(
        title: String,
        value: WindowDisplayFilter,
        count: Int
    ) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            HStack(spacing: StudioTheme.space2) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(
                        selected
                            ? StudioTheme.textSecondary
                            : StudioTheme.textTertiary
                    )
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, StudioTheme.space3)
            .frame(height: 25)
        }
        .buttonStyle(
            SecondaryActionButtonStyle(
                cornerRadius: StudioTheme.radiusS,
                isSelected: selected
            )
        )
    }

    private func previewMetadata(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space1) {
            Text(label)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(1)
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: StudioTheme.space3) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(StudioTheme.textTertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(StudioTheme.space5)
    }

    private func displayName(for window: WindowCaptureInfo) -> String {
        guard let displayID = window.displayID else {
            return "其他显示器"
        }
        return model.displays.first { $0.id == displayID }?.name
            ?? "其他显示器"
    }

    private func ensureVisibleSelection() {
        if visibleWindows.contains(where: {
            $0.windowID == selectedWindowID
        }) {
            return
        }
        selectedWindowID = visibleWindows.first?.windowID
    }

    private func loadPreview() async {
        guard let selectedWindow else {
            preview = nil
            previewMessage = nil
            previewLoading = false
            return
        }
        previewLoading = true
        preview = nil
        previewMessage = nil
        let image = await WindowCatalog.capturePreview(
            for: selectedWindow,
            maximumSize: CGSize(width: 960, height: 640)
        )
        guard
            !Task.isCancelled,
            selectedWindowID == selectedWindow.windowID
        else {
            return
        }
        preview = image
        previewLoading = false
        if image == nil {
            previewMessage = selectedWindow.isCurrentlyVisible
                ? "无法读取窗口预览，请刷新后重试。"
                : "该窗口当前不可见，暂时读不到预览。仍可直接使用该窗口录制。"
        }
    }
}

/// 窗口列表行（§5.4 列表选中矩阵）：rest 透明、hover 内容色 +8%、
/// selected selectionTint + 3pt leading 指示条 + 对勾图标双通道。
private struct WindowRow: View {
    let window: WindowCaptureInfo
    let groupName: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioTheme.space3) {
                WindowAppIcon(bundleIdentifier: window.bundleIdentifier)
                VStack(alignment: .leading, spacing: StudioTheme.space1) {
                    Text(
                        window.title.isEmpty ? window.appName : window.title
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    HStack(spacing: StudioTheme.space2) {
                        Text(
                            "\(window.appName) · \(window.width) × \(window.height)"
                        )
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                        if !window.isCurrentlyVisible {
                            Text("当前不可见")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .padding(.horizontal, StudioTheme.space2)
                                .frame(height: 16)
                                .background(
                                    StudioTheme.textPrimary.opacity(0.08)
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer(minLength: StudioTheme.space2)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            .padding(.horizontal, StudioTheme.space3)
            .frame(height: 43)
            .frame(maxWidth: .infinity)
            .background(
                isSelected
                    ? StudioTheme.selectionTint
                    : StudioTheme.textPrimary.opacity(isHovering ? 0.08 : 0)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(StudioTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, StudioTheme.space2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            "\(window.displayTitle)，\(window.width) × \(window.height)，"
                + "\(groupName)\(window.isCurrentlyVisible ? "" : "，当前不可见")"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WindowAppIcon: View {
    let bundleIdentifier: String?
    var size: CGFloat = 16

    var body: some View {
        if
            let bundleIdentifier,
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: size * 0.72))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(width: size, height: size)
        }
    }
}
