import AppKit
import AniseRecorderCore
import SwiftUI

/// 全文校对待应用的删除建议（UI 态，不进工程）。
struct PendingTextCut: Equatable {
    let captionID: UUID
    let cutStart: Double
    let cutEnd: Double
    let isApproximate: Bool
    var removedDuration: Double { max(0, cutEnd - cutStart) }
}

/// 字幕页视图模式——逐条卡片列表 / 文稿式全文校对。
enum CaptionViewMode: String, CaseIterable, Identifiable {
    case list
    case transcript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list:
            return "列表"
        case .transcript:
            return "全文校对"
        }
    }
}

enum EditorTab: String, CaseIterable, Identifiable {
    case canvas
    case camera
    case edit
    case smartCut
    case captions
    case export

    var id: String { rawValue }
    var title: String {
        switch self {
        case .canvas:
            return "画面"
        case .camera:
            return "摄像头"
        case .edit:
            return "剪辑"
        case .smartCut:
            return "精剪"
        case .captions:
            return "字幕"
        case .export:
            return "导出"
        }
    }

    var icon: String {
        switch self {
        case .canvas:
            return "rectangle.inset.filled"
        case .camera:
            return "person.crop.circle"
        case .edit:
            return "scissors"
        case .smartCut:
            return "wand.and.stars"
        case .captions:
            return "captions.bubble"
        case .export:
            return "square.and.arrow.up"
        }
    }
}

private struct CameraResizeDrag {
    let startSize: Double
    let startVector: CGSize
}

private struct RedactionMoveDrag {
    let id: UUID
    let startRect: NormalizedRect
    let startLocation: NormalizedPoint
}

private struct RedactionResizeDrag {
    let id: UUID
    let startRect: NormalizedRect
    let corner: CameraResizeCorner
}

struct EditorView: View {
    /// 默认展开的检查器分组（会话级，重启恢复默认）：主设置默认展开；摄像头页签下
    /// 绿幕相关组（绿幕抠像）默认展开，位置 / 外观 / 人脸居中（竖屏跟随）默认收起。
    static let defaultExpandedSections: Set<InspectorSection> = [
        .canvas,
        .cameraComposition,
        .cameraChromaKey,
        .clip,
        .captionContent
    ]

    @ObservedObject var model: StudioModel
    @AppStorage(StudioPreferences.editorOnboardingShownKey)
    private var editorOnboardingShown = false
    @State private var tab: EditorTab = .canvas
    @State private var expandedSections: Set<InspectorSection> =
        EditorView.defaultExpandedSections
    @State private var inspectorScrollRequest: InspectorScrollRequest?
    @State private var activeTimelineTrack: TimelineTrack?
    @State private var cameraSelected = false
    @State private var cameraMoveStart: NormalizedPoint?
    // 预览操作提示在用户完成第一次拖动/微调后消失（会话内）。
    @State private var hasAdjustedCameraOnce = false
    @State private var cameraResizeDrag: CameraResizeDrag?
    @State private var cameraPresetScope: CameraPresetApplicationScope =
        .fromPlayhead
    @State private var cameraKeyMonitor: Any?
    @State private var captionViewMode: CaptionViewMode = .list
    // 全文校对待应用的「删除选区片段」建议（UI 态）。
    @State private var pendingTextCut: PendingTextCut?
    /// 时间线折叠状态（全局偏好，跨工程跨重启）。
    @AppStorage(StudioPreferences.editorTimelineCollapsedKey)
    var timelineCollapsed = false
    @State private var selectedClipID: UUID?
    /// 导出卡 GIF 区折叠状态（默认收起）。
    @State private var gifSectionExpanded = false
    @State private var selectedRedactionID: UUID?
    @State private var redactionDrawMode = false
    @State private var redactionDrawOrigin: NormalizedPoint?
    @State private var redactionDrawCurrent: NormalizedPoint?
    @State private var redactionMoveDrag: RedactionMoveDrag?
    @State private var redactionResizeDrag: RedactionResizeDrag?
    @State private var glossaryWrongField = ""
    @State private var glossaryRightField = ""
    private let cameraHandleInset: CGFloat = 8
    private let redactionHandleInset: CGFloat = 7

    /// 测试缝：以指定初始页签与展开集合构造编辑器，供布局回归测试驱动
    /// 「摄像头页 + 指定展开态」。默认值与生产路径一致，RootView 的
    /// `EditorView(model:)` 调用不受影响。
    init(
        model: StudioModel,
        tab: EditorTab = .canvas,
        expandedSections: Set<InspectorSection> = EditorView.defaultExpandedSections
    ) {
        self.model = model
        _tab = State(initialValue: tab)
        _expandedSections = State(initialValue: expandedSections)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let project = model.draft {
                header(project)
                Rectangle()
                    .fill(StudioTheme.separatorLine)
                    .frame(height: 1)
                if !editorOnboardingShown {
                    editorOnboardingBanner
                }
                HStack(alignment: .top, spacing: StudioTheme.space6) {
                    previewColumn(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // 中间主编辑区优先：右栏检查器内容再长，也不改变中间区
                        // 的尺寸与位置（剪映类产品的中间栏不动）。
                        .layoutPriority(1)
                    inspector(project)
                        .frame(width: 338)
                        .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, StudioTheme.space7)
                .padding(.vertical, StudioTheme.space6)
            }
        }
        .onAppear {
            installCameraKeyMonitor()
        }
        .onDisappear {
            removeCameraKeyMonitor()
            model.endInteractiveEdit()
        }
        .onChange(of: model.draft?.id) { _, _ in
            cameraSelected = false
            cameraMoveStart = nil
            cameraResizeDrag = nil
            selectedClipID = model.draft?.timeline.clips.first?.id
            model.endInteractiveEdit()
        }
        .onChange(of: model.draft?.timeline) { _, timeline in
            if
                let selectedClipID,
                timeline?.clips.contains(where: { $0.id == selectedClipID })
                    == true
            {
                return
            }
            selectedClipID = timeline?.clips.first?.id
        }
        .onChange(of: model.draft?.camera.layout) { _, layout in
            if layout != .pictureInPicture {
                cameraSelected = false
                model.endInteractiveEdit()
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.isDesktopWallpaperPickerPresented },
                set: { presented in
                    if !presented {
                        model.dismissDesktopWallpaperPicker()
                    }
                }
            )
        ) {
            DesktopWallpaperPicker(model: model)
        }
    }

    /// 首次进入编辑器的一次性引导条：新用户给出「三步出片」路径感，
    /// 不做向导弹窗。@AppStorage 记忆关闭动作，关闭后永不再现。
    private var editorOnboardingBanner: some View {
        HStack(spacing: StudioTheme.space3) {
            Image(systemName: "lightbulb")
                .font(.callout.weight(.medium))
                .foregroundStyle(StudioTheme.accent)
            Text("三步出片：剪辑 → 字幕 → 导出")
                .font(.callout.weight(.medium))
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
            Button {
                editorOnboardingShown = true
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(StudioTheme.surfaceCanvas)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(IconButtonStyle(cornerRadius: StudioTheme.radiusM))
            .help("关闭后不再显示")
            .accessibilityLabel("关闭引导提示")
        }
        .padding(.horizontal, StudioTheme.space7)
        .padding(.vertical, StudioTheme.space3)
        .background(StudioTheme.accent.opacity(0.08))
    }

    private func header(_ project: StudioProject) -> some View {
        HStack(alignment: .center, spacing: StudioTheme.space5) {
            VStack(alignment: .leading, spacing: StudioTheme.space2) {
                TextField(
                    "工程名称",
                    text: Binding(
                        get: { model.draft?.name ?? "" },
                        set: { model.updateProjectName($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .foregroundStyle(StudioTheme.textPrimary)
                .frame(maxWidth: 540, alignment: .leading)

                HStack(spacing: StudioTheme.space3) {
                    Circle()
                        .fill(StudioTheme.accent)
                        .frame(width: 5, height: 5)
                    Text("已自动保存")
                    Text("·")
                    Text(project.source.kind.title)
                    Text("·")
                    Text(
                        "\(Int(project.canvasOutputSize.width)) × \(Int(project.canvasOutputSize.height))"
                    )
                    Text("·")
                    Text("\(project.fps) fps")
                    Text("·")
                    Text(formatDuration(project.trimDuration))
                }
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            }

            Spacer()

            Button {
                model.revealProjectFolder()
            } label: {
                Label("在访达中显示", systemImage: "folder")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, StudioTheme.space4)
                    .frame(height: 34)
            }
            .buttonStyle(SecondaryActionButtonStyle())

            Button {
                model.exportProject()
            } label: {
                HStack(spacing: StudioTheme.space3) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                    Text(exportMainButtonTitle(project))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, StudioTheme.space5)
                .frame(height: 35)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(
                model.exportProgress != nil
                    || (model.exportMode == .markerSegments
                        && model.markerSegmentPlan(for: project)
                            .segments.isEmpty)
            )
            .help(
                model.exportMode == .markerSegments
                    && model.markerSegmentPlan(for: project).segments.isEmpty
                    ? "先在下方勾选标记；标记可在剪辑页 › 录制标记添加"
                    : ""
            )
        }
        .padding(.horizontal, StudioTheme.space7)
        .padding(.top, StudioTheme.space7)
        .padding(.bottom, StudioTheme.space5)
    }

    private func previewColumn(_ project: StudioProject) -> some View {
        let cameraSettings = effectiveCameraSettings(project)
        let showsCamera = cameraSettings.enabled
            && cameraSettings.layout != .screenOnly
            && project.cameraURL != nil
        return VStack(spacing: StudioTheme.space5) {
            ZStack {
                RoundedRectangle(cornerRadius: StudioTheme.radiusL)
                    .fill(StudioTheme.surfaceSunken)
                VideoSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusL))
                if model.previewLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StudioTheme.accent)
                        .padding(StudioTheme.space4)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                if showsCamera && cameraSettings.layout == .pictureInPicture {
                    cameraInteractionLayer(project, settings: cameraSettings)
                }
                if !project.overlayClips.isEmpty {
                    overlayInteractionLayer(project)
                }
                redactionInteractionLayer(project)
            }
            .aspectRatio(project.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            // 保底尺寸：窗口再矮（页头 / 引导条 / 固定时间线占满之前）预览也不
            // 消失；名义最小窗口 1060×700 下预览约 202pt，不会触发。
            .frame(minHeight: 160)
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.radiusL)
                    .stroke(StudioTheme.separatorLine, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                HStack(spacing: StudioTheme.space2) {
                    Image(
                        systemName: showsCamera
                            ? "person.crop.circle.fill"
                            : "sparkles"
                    )
                    .font(.callout.weight(.semibold))
                    Text(showsCamera ? "摄像头已合成" : "点击放大已开启")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(StudioTheme.textOnAccentContainer)
                .padding(.horizontal, StudioTheme.space3)
                .frame(height: 23)
                .background(StudioTheme.accentContainer)
                .clipShape(Capsule())
                .padding(StudioTheme.space4)
            }

            VStack(spacing: StudioTheme.space4) {
                HStack(spacing: StudioTheme.space4) {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Image(
                            systemName: model.isPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 31, height: 31)
                    }
                    .buttonStyle(PrimaryActionButtonStyle(cornerRadius: 15.5))

                    Text(formatDuration(model.currentTime, precise: true))
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(StudioTheme.textSecondary)
                        .monospacedDigit()
                    Text("/ \(formatDuration(project.trimDuration, precise: true))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(StudioTheme.textSecondary)

                    Spacer()

                    Text("\(project.clicks.filter(\.enabled).count) 个放大点")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)

                    Button {
                        timelineCollapsed.toggle()
                    } label: {
                        Image(
                            systemName: timelineCollapsed
                                ? "rectangle.expand.vertical"
                                : "rectangle.compress.vertical"
                        )
                        .font(.callout.weight(.medium))
                        .frame(width: 26, height: 26)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(
                        timelineCollapsed
                            ? "展开时间线（⌘\\）"
                            : "收起时间线，把空间让给预览（⌘\\）"
                    )
                    .keyboardShortcut("\\", modifiers: [.command])
                }

                if timelineCollapsed {
                    HStack(spacing: StudioTheme.space3) {
                        Button {
                            timelineCollapsed = false
                        } label: {
                            Label("展开时间线", systemImage: "timeline.line.3d")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, StudioTheme.space3)
                                .frame(height: 26)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        Text("预览区已放大")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StudioTheme.space3)
                    .background(StudioTheme.surfacePanel.opacity(0.78))
                }
                if !timelineCollapsed {
                EditorTimelineView(
                    project: project,
                    currentTime: model.currentTime,
                    selectedClipID: $selectedClipID,
                    activeTrack: activeTimelineTrack,
                    onSelectTrack: navigateToTimelineTrack,
                    onSelectOverlayClip: { id in
                        model.selectOverlayClip(id)
                    },
                    selectedOverlayClipID: model.selectedOverlayClipID,
                    onSeek: { model.seek(to: $0) },
                    onScrubbingChanged: { isScrubbing in
                        model.isScrubbing = isScrubbing
                        if isScrubbing {
                            model.beginInteractiveEdit()
                        } else {
                            model.endInteractiveEdit()
                        }
                    },
                    onSplit: { model.splitTimelineAtPlayhead() },
                    onDelete: {
                        if let selectedClipID {
                            model.deleteTimelineClip(selectedClipID)
                        }
                    },
                    onTrimClipStart: { clipID, sourceTime in
                        model.setTimelineClipStart(
                            sourceTime,
                            for: clipID
                        )
                    },
                    onTrimClipEnd: { clipID, sourceTime in
                        model.setTimelineClipEnd(
                            sourceTime,
                            for: clipID
                        )
                    },
                    onMoveZoomRegion: { regionID, start in
                        model.setManualZoomRegionStart(
                            start,
                            for: regionID
                        )
                    },
                    onMoveCameraSegment: { segmentID, start in
                        model.setCameraSegmentStart(
                            start,
                            for: segmentID
                        )
                    },
                    onMoveRedactionRegion: { regionID, start in
                        model.setRedactionRegionStart(
                            start,
                            for: regionID
                        )
                    },
                    smartCutCandidates: model.smartCutAnalysis?.candidates ?? [],
                    smartCutSelectedIndices: model.smartCutSelectedIndices,
                    onSelectSmartCutCandidate: { index in
                        model.selectSmartCutCandidate(index)
                    }
                )
                }

                HStack(spacing: StudioTheme.space4) {
                    if let clip = selectedClip {
                        Text("片段 \(clipIndex + 1) / \(project.timeline.clips.count)")
                            .foregroundStyle(StudioTheme.textSecondary)
                        Text("·")
                            .foregroundStyle(StudioTheme.textTertiary)
                        Text("源 \(formatDuration(clip.sourceStart, precise: true))–\(formatDuration(clip.sourceEnd, precise: true))")
                            .foregroundStyle(StudioTheme.textSecondary)
                        Text("·")
                            .foregroundStyle(StudioTheme.textTertiary)
                        Text(String(format: "%.2g×", clip.playbackRate))
                            .foregroundStyle(StudioTheme.accent)
                    }
                    Spacer()
                }
                .font(.callout.monospacedDigit())
            }
            .padding(StudioTheme.space5)
            .background(StudioTheme.surfacePanel.opacity(0.78))
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.radiusL)
                    .stroke(StudioTheme.separatorLine, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusL))
        }
    }

    private func cameraInteractionLayer(
        _ project: StudioProject,
        settings: CameraSettings
    ) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissCanvasTextFocus()
                        cameraSelected = false
                    }

                if
                    let normalized = CanvasLayout.normalizedCameraFrame(
                        for: project,
                        settings: settings,
                        time: model.currentTime
                    ),
                    geometry.size.width > 1,
                    geometry.size.height > 1
                {
                    let frame = CGRect(
                        x: normalized.minX * geometry.size.width,
                        y: normalized.minY * geometry.size.height,
                        width: normalized.width * geometry.size.width,
                        height: normalized.height * geometry.size.height
                    )
                    cameraControl(
                        project: project,
                        settings: settings,
                        frame: frame,
                        canvasSize: geometry.size
                    )
                }
            }
        }
    }

    // MARK: F2 素材叠加画布交互（交互照抄摄像头那套：点击选中、
    // 中心拖动、四角缩放；拖动结束由 updateProject 的 groupingKey
    // 合并为一步撤销）

    @State private var overlayMoveStart: CGPoint?
    @State private var overlayResizeDrag: CameraResizeDrag?

    private func overlayInteractionLayer(
        _ project: StudioProject
    ) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissCanvasTextFocus()
                        model.selectOverlayClip(nil)
                    }
                if geometry.size.width > 1, geometry.size.height > 1 {
                    let entries = CanvasLayout.normalizedOverlayFrames(
                        for: project,
                        time: model.currentTime
                    )
                    ForEach(entries, id: \.clip.id) { entry in
                        overlayLayerEntry(
                            entry,
                            project: project,
                            canvasSize: geometry.size
                        )
                    }
                }
            }
        }
    }

    private func overlayLayerEntry(
        _ entry: (clip: OverlayClip, frame: CGRect),
        project: StudioProject,
        canvasSize: CGSize
    ) -> some View {
        let width = entry.frame.width * canvasSize.width
        let height = entry.frame.height * canvasSize.height
        let frame = CGRect(
            x: entry.frame.minX * canvasSize.width,
            y: entry.frame.minY * canvasSize.height,
            width: width,
            height: height
        )
        if entry.clip.id == model.selectedOverlayClipID {
            return AnyView(
                overlayControl(
                    project: project,
                    clip: entry.clip,
                    frame: frame,
                    canvasSize: canvasSize
                )
            )
        }
        let target = Color.clear
            .contentShape(Rectangle())
            .frame(width: width, height: height)
            .position(x: frame.midX, y: frame.midY)
            .onTapGesture {
                dismissCanvasTextFocus()
                model.selectOverlayClip(entry.clip.id)
            }
        return AnyView(target)
    }

    private func overlayControl(
        project: StudioProject,
        clip: OverlayClip,
        frame: CGRect,
        canvasSize: CGSize
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(StudioTheme.accent, lineWidth: 1.5)
            ForEach(CameraResizeCorner.allCases) { corner in
                Circle()
                    .fill(StudioTheme.textOnScrim)
                    .overlay(
                        Circle()
                            .stroke(StudioTheme.accent, lineWidth: 1.5)
                    )
                    .frame(width: 12, height: 12)
                    .shadow(
                        color: StudioTheme.scrimOverMedia.opacity(0.6),
                        radius: 2,
                        y: 1
                    )
                    .allowsHitTesting(false)
                    .position(
                        x: corner.horizontalSign < 0 ? 0 : frame.width,
                        y: corner.verticalSign < 0 ? 0 : frame.height
                    )
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .gesture(
            overlayInteractionGesture(
                project: project,
                clip: clip,
                frameSize: frame.size,
                canvasSize: canvasSize
            )
        )
        .onTapGesture {
            dismissCanvasTextFocus()
            model.selectOverlayClip(clip.id)
        }
        .position(x: frame.midX, y: frame.midY)
    }

    private func overlayInteractionGesture(
        project: StudioProject,
        clip: OverlayClip,
        frameSize: CGSize,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dismissCanvasTextFocus()
                if overlayMoveStart == nil, overlayResizeDrag == nil {
                    if
                        let corner = CanvasLayout.cameraResizeCorner(
                            at: value.startLocation,
                            frameSize: frameSize,
                            handleInset: 0,
                            hitRadius: 18
                        )
                    {
                        overlayResizeDrag = CameraResizeDrag(
                            startSize: clip.size,
                            startVector: CGSize(
                                width: corner.horizontalSign
                                    * frameSize.width / 2,
                                height: corner.verticalSign
                                    * frameSize.height / 2
                            )
                        )
                    } else {
                        overlayMoveStart = clip.effectiveCenter
                    }
                }
                if let drag = overlayResizeDrag {
                    let vector = CGSize(
                        width: drag.startVector.width
                            + value.translation.width,
                        height: drag.startVector.height
                            + value.translation.height
                    )
                    let startLength = hypot(
                        drag.startVector.width,
                        drag.startVector.height
                    )
                    let currentLength = hypot(vector.width, vector.height)
                    guard startLength > 1 else { return }
                    model.setOverlaySize(
                        clip.size * (currentLength / startLength),
                        for: clip.id
                    )
                    return
                }
                guard
                    let start = overlayMoveStart,
                    canvasSize.width > 1,
                    canvasSize.height > 1
                else {
                    return
                }
                let raw = CGPoint(
                    x: start.x + value.translation.width / canvasSize.width,
                    y: start.y + value.translation.height / canvasSize.height
                )
                model.setOverlayCustomCenter(raw, for: clip.id)
            }
            .onEnded { _ in
                overlayMoveStart = nil
                overlayResizeDrag = nil
            }
    }

    /// 1.2 定时打码画布交互层：绘制模式拖拽出新矩形（播放头时刻起 3 秒）；
    /// 已有区域点击选中、中心拖动、四角缩放——交互照抄摄像头那套，
    /// 一次拖动只占一个撤销步骤。
    private func redactionInteractionLayer(
        _ project: StudioProject
    ) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissCanvasTextFocus()
                        selectedRedactionID = nil
                        redactionDrawMode = false
                    }
                    .gesture(redactionDrawGesture(canvasSize: geometry.size))

                if redactionDrawMode, geometry.size.width > 1 {
                    let origin = redactionDrawOrigin ?? NormalizedPoint(x: 0.5, y: 0.5)
                    let current = redactionDrawCurrent ?? origin
                    let drawRect = redactionRect(
                        from: origin,
                        to: current,
                        canvasSize: geometry.size
                    )
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(
                            StudioTheme.accent,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                        .frame(
                            width: max(2, drawRect.width * geometry.size.width),
                            height: max(2, drawRect.height * geometry.size.height)
                        )
                        .position(
                            x: (drawRect.x + drawRect.width / 2) * geometry.size.width,
                            y: (drawRect.y + drawRect.height / 2) * geometry.size.height
                        )
                }

                ForEach(
                    project.activeRedactionRegions(
                        atOutput: model.currentTime
                    )
                ) { region in
                    redactionControl(
                        project: project,
                        region: region,
                        canvasSize: geometry.size
                    )
                }
            }
        }
    }

    private func redactionControl(
        project: StudioProject,
        region: RedactionRegion,
        canvasSize: CGSize
    ) -> some View {
        let frame = CGRect(
            x: region.rect.x * canvasSize.width,
            y: region.rect.y * canvasSize.height,
            width: region.rect.width * canvasSize.width,
            height: region.rect.height * canvasSize.height
        )
        let isSelected = selectedRedactionID == region.id
        return ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(StudioTheme.accent, lineWidth: 1.5)
                ForEach(CameraResizeCorner.allCases) { corner in
                    Circle()
                        .fill(StudioTheme.textOnScrim)
                        .overlay(
                            Circle()
                                .stroke(StudioTheme.accent, lineWidth: 1.5)
                        )
                        .frame(width: 10, height: 10)
                        .allowsHitTesting(false)
                        .position(
                            x: corner.horizontalSign < 0
                                ? redactionHandleInset
                                : frame.width - redactionHandleInset,
                            y: corner.verticalSign < 0
                                ? redactionHandleInset
                                : frame.height - redactionHandleInset
                        )
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(
                    isSelected
                        ? StudioTheme.accent.opacity(0.9)
                        : StudioTheme.textTertiary.opacity(0.45),
                    style: StrokeStyle(
                        lineWidth: 1,
                        dash: isSelected ? [] : [4, 3]
                    )
                )
        )
        .gesture(
            redactionRegionGesture(
                project: project,
                region: region,
                frame: frame,
                canvasSize: canvasSize
            )
        )
        .onTapGesture {
            dismissCanvasTextFocus()
            selectedRedactionID = region.id
            redactionDrawMode = false
        }
        .position(x: frame.midX, y: frame.midY)
    }

    private func redactionRegionGesture(
        project: StudioProject,
        region: RedactionRegion,
        frame: CGRect,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dismissCanvasTextFocus()
                if redactionMoveDrag == nil, redactionResizeDrag == nil {
                    selectedRedactionID = region.id
                    model.beginInteractiveEdit()
                    if
                        let corner = CanvasLayout.cameraResizeCorner(
                            at: value.startLocation,
                            frameSize: frame.size,
                            handleInset: redactionHandleInset,
                            hitRadius: 16
                        )
                    {
                        redactionResizeDrag = RedactionResizeDrag(
                            id: region.id,
                            startRect: region.rect,
                            corner: corner
                        )
                    } else {
                        redactionMoveDrag = RedactionMoveDrag(
                            id: region.id,
                            startRect: region.rect,
                            startLocation: NormalizedPoint(
                                x: Double(value.startLocation.x / max(1, canvasSize.width)),
                                y: Double(value.startLocation.y / max(1, canvasSize.height))
                            )
                        )
                    }
                }
                if let drag = redactionResizeDrag {
                    updateRedactionRect(
                        drag: drag,
                        translation: value.translation,
                        canvasSize: canvasSize
                    )
                    return
                }
                guard let drag = redactionMoveDrag else { return }
                let dx = Double(
                    value.translation.width / max(1, canvasSize.width)
                )
                let dy = Double(
                    value.translation.height / max(1, canvasSize.height)
                )
                let moved = NormalizedRect(
                    x: drag.startRect.x + dx,
                    y: drag.startRect.y + dy,
                    width: drag.startRect.width,
                    height: drag.startRect.height
                )
                model.setRedactionRegionRect(moved, for: drag.id)
            }
            .onEnded { _ in
                redactionMoveDrag = nil
                redactionResizeDrag = nil
                model.endInteractiveEdit()
            }
    }

    private func updateRedactionRect(
        drag: RedactionResizeDrag,
        translation: CGSize,
        canvasSize: CGSize
    ) {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        let dx = Double(translation.width / canvasSize.width)
        let dy = Double(translation.height / canvasSize.height)
        let start = drag.startRect
        var x = start.x
        var y = start.y
        var width = start.width
        var height = start.height
        if drag.corner.horizontalSign < 0 {
            x = start.x + dx
            width = start.width - dx
        } else {
            width = start.width + dx
        }
        if drag.corner.verticalSign < 0 {
            y = start.y + dy
            height = start.height - dy
        } else {
            height = start.height + dy
        }
        model.setRedactionRegionRect(
            NormalizedRect(x: x, y: y, width: width, height: height),
            for: drag.id
        )
    }

    private func redactionRect(
        from origin: NormalizedPoint,
        to current: NormalizedPoint,
        canvasSize: CGSize
    ) -> NormalizedRect {
        NormalizedRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
    }

    private func redactionDrawGesture(
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard redactionDrawMode else { return }
                guard canvasSize.width > 1, canvasSize.height > 1 else {
                    return
                }
                let point = NormalizedPoint(
                    x: Double(value.location.x / canvasSize.width),
                    y: Double(value.location.y / canvasSize.height)
                )
                if redactionDrawOrigin == nil {
                    redactionDrawOrigin = NormalizedPoint(
                        x: Double(value.startLocation.x / canvasSize.width),
                        y: Double(value.startLocation.y / canvasSize.height)
                    )
                }
                redactionDrawCurrent = point
            }
            .onEnded { _ in
                guard redactionDrawMode else { return }
                if
                    let origin = redactionDrawOrigin,
                    let current = redactionDrawCurrent
                {
                    let rect = redactionRect(
                        from: origin,
                        to: current,
                        canvasSize: canvasSize
                    ).clamped()
                    if rect.width >= 0.02, rect.height >= 0.02 {
                        model.addRedactionRegion(rect: rect)
                    }
                }
                redactionDrawOrigin = nil
                redactionDrawCurrent = nil
                redactionDrawMode = false
            }
    }

    private func cameraControl(
        project: StudioProject,
        settings: CameraSettings,
        frame: CGRect,
        canvasSize: CGSize
    ) -> some View {
        ZStack {
            if cameraSelected {
                cameraSelectionOutline(
                    settings: settings,
                    frame: frame
                )
            }

            if cameraSelected {
                ForEach(CameraResizeCorner.allCases) { corner in
                    Circle()
                        .fill(StudioTheme.textOnScrim)
                        .overlay(
                            Circle()
                                .stroke(StudioTheme.accent, lineWidth: 1.5)
                        )
                        .frame(width: 12, height: 12)
                        .shadow(color: StudioTheme.scrimOverMedia.opacity(0.6), radius: 2, y: 1)
                        .allowsHitTesting(false)
                        .position(
                            x: corner.horizontalSign < 0
                                ? cameraHandleInset
                                : frame.width - cameraHandleInset,
                            y: corner.verticalSign < 0
                                ? cameraHandleInset
                                : frame.height - cameraHandleInset
                        )
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .gesture(
            cameraInteractionGesture(
                project: project,
                settings: settings,
                frameSize: frame.size,
                canvasSize: canvasSize
            )
        )
        .onTapGesture {
            dismissCanvasTextFocus()
            cameraSelected = true
        }
        .position(x: frame.midX, y: frame.midY)
    }

    @ViewBuilder
    private func cameraSelectionOutline(
        settings: CameraSettings,
        frame: CGRect
    ) -> some View {
        let radius = cameraCornerRadius(settings: settings, frame: frame)
        if settings.shape == .circle {
            Circle()
                .stroke(StudioTheme.accent, lineWidth: 1.5)
        } else {
            RoundedRectangle(cornerRadius: radius)
                .stroke(StudioTheme.accent, lineWidth: 1.5)
        }
    }

    private func cameraInteractionGesture(
        project: StudioProject,
        settings: CameraSettings,
        frameSize: CGSize,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let canResize = cameraSelected
                dismissCanvasTextFocus()
                if cameraMoveStart == nil, cameraResizeDrag == nil {
                    if
                        canResize,
                        let corner = resizeCorner(
                            at: value.startLocation,
                            frameSize: frameSize
                        )
                    {
                        model.beginInteractiveEdit()
                        cameraResizeDrag = CameraResizeDrag(
                            startSize: settings.size,
                            startVector: CGSize(
                                width: corner.horizontalSign * frameSize.width / 2,
                                height: corner.verticalSign * frameSize.height / 2
                            )
                        )
                    } else {
                        cameraMoveStart = currentCameraCenter(settings)
                        model.beginInteractiveEdit()
                    }
                }

                cameraSelected = true
                hasAdjustedCameraOnce = true
                if let drag = cameraResizeDrag {
                    updateCameraSize(
                        drag: drag,
                        translation: value.translation
                    )
                    return
                }

                guard
                    let start = cameraMoveStart,
                    canvasSize.width > 1,
                    canvasSize.height > 1
                else { return }
                let raw = CGPoint(
                    x: start.x + value.translation.width / canvasSize.width,
                    y: start.y + value.translation.height / canvasSize.height
                )
                let center = CanvasLayout.snappedCameraCenter(
                    raw,
                    outputSize: project.canvasOutputSize,
                    settings: settings
                )
                model.setCameraCustomCenter(center)
            }
            .onEnded { _ in
                cameraMoveStart = nil
                cameraResizeDrag = nil
                model.endInteractiveEdit()
            }
    }

    private func resizeCorner(
        at location: CGPoint,
        frameSize: CGSize
    ) -> CameraResizeCorner? {
        CanvasLayout.cameraResizeCorner(
            at: location,
            frameSize: frameSize,
            handleInset: cameraHandleInset,
            hitRadius: 18
        )
    }

    private func updateCameraSize(
        drag: CameraResizeDrag,
        translation: CGSize
    ) {
        let vector = CGSize(
            width: drag.startVector.width + translation.width,
            height: drag.startVector.height + translation.height
        )
        let startLength = hypot(
            drag.startVector.width,
            drag.startVector.height
        )
        let currentLength = hypot(vector.width, vector.height)
        guard startLength > 1 else { return }
        let ratio = currentLength / startLength
        let size = min(0.5, max(0.1, drag.startSize * ratio))
        model.setCameraSize(size)
    }

    private func currentCameraCenter(
        _ settings: CameraSettings
    ) -> NormalizedPoint {
        settings.customCenter
            ?? NormalizedPoint(
                x: settings.anchor.normalizedCenter.x,
                y: settings.anchor.normalizedCenter.y
            )
    }

    private var selectedClip: TimelineClip? {
        guard
            let project = model.draft,
            let selectedClipID
        else {
            return nil
        }
        return project.timeline.clips.first {
            $0.id == selectedClipID
        }
    }

    private var clipIndex: Int {
        guard
            let project = model.draft,
            let selectedClipID,
            let index = project.timeline.clips.firstIndex(where: {
                $0.id == selectedClipID
            })
        else {
            return 0
        }
        return index
    }

    private func cameraCornerRadius(
        settings: CameraSettings,
        frame: CGRect
    ) -> CGFloat {
        let minimum = min(frame.width, frame.height)
        switch settings.shape {
        case .square:
            return 0
        case .circle:
            return minimum / 2
        case .roundedRectangle:
            return minimum * settings.cornerRadius
        }
    }

    private func effectiveCameraSettings(
        _ project: StudioProject
    ) -> CameraSettings {
        project.cameraSettings(atOutput: model.currentTime)
    }

    private func installCameraKeyMonitor() {
        guard cameraKeyMonitor == nil else { return }
        cameraKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard
                let project = model.draft,
                !(event.window?.firstResponder is NSTextView)
            else {
                return event
            }
            // ⌘B 在播放头切分当前片段——带 command 修饰键，
            // 必须拦在下方「无修饰键」路由之前；与按钮切分同一事务入口
            // （splitTimelineAtPlayhead，一步撤销、边界反馈齐备）。
            if
                event.keyCode == 11, // B
                event.modifierFlags.contains(.command),
                event.modifierFlags.intersection([.option, .control]).isEmpty
            {
                model.splitTimelineAtPlayhead()
                return nil
            }
            guard
                event.modifierFlags.intersection(
                    [.command, .option, .control]
                ).isEmpty
            else {
                return event
            }

            switch event.keyCode {
            case 49:
                model.togglePlayback()
                return nil
            case 34:
                model.setTrimStartToPlayhead()
                return nil
            case 31:
                model.setTrimEndToPlayhead()
                return nil
            case 46:
                model.addMarkerAtPlayhead()
                return nil
            default:
                break
            }

            // 方向键主路径改为步进播放头（方向键步进）；摄像头
            // 微调改道 Option+方向键（习惯变更已在标准/帮助/README 声明）。
            if event.modifierFlags.contains(.option) {
                guard
                    cameraSelected,
                    effectiveCameraSettings(project).enabled,
                    effectiveCameraSettings(project).layout == .pictureInPicture,
                    project.cameraURL != nil
                else {
                    return event
                }
                let step = event.modifierFlags.contains(.shift) ? 0.05 : 0.01
                hasAdjustedCameraOnce = true
                switch event.keyCode {
                case 123:
                    model.nudgeCamera(dx: -step, dy: 0)
                case 124:
                    model.nudgeCamera(dx: step, dy: 0)
                case 125:
                    model.nudgeCamera(dx: 0, dy: step)
                case 126:
                    model.nudgeCamera(dx: 0, dy: -step)
                default:
                    return event
                }
                return nil
            }

            // 无 Option：左右键步进播放头（Shift = 1 秒粗步）；上下键不占用。
            switch event.keyCode {
            case 123, 124:
                let moved = PlayheadStepper.step(
                    current: model.currentTime,
                    duration: project.trimDuration,
                    fps: Double(model.exportFrameRate),
                    isForward: event.keyCode == 124,
                    isCoarse: event.modifierFlags.contains(.shift)
                )
                model.seek(to: moved)
                return nil
            default:
                return event
            }
        }
    }

    private func removeCameraKeyMonitor() {
        guard let cameraKeyMonitor else { return }
        NSEvent.removeMonitor(cameraKeyMonitor)
        self.cameraKeyMonitor = nil
    }

    private func dismissCanvasTextFocus() {
        let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: \.isVisible)
        window?.makeFirstResponder(nil)
    }

    private func inspector(_ project: StudioProject) -> some View {
        VStack(spacing: StudioTheme.space4) {
            tabBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: StudioTheme.space4) {
                        Color.clear
                            .frame(height: 1)
                            .id("inspector.top")
                        inspectorContent(project)
                    }
                    .padding(.bottom, StudioTheme.space3)
                }
                .scrollIndicators(.visible)
                .onChange(of: inspectorScrollRequest) { _, request in
                    guard let request else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(
                                request.section?.rawValue ?? "inspector.top",
                                anchor: .top
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inspectorContent(_ project: StudioProject) -> some View {
        switch tab {
        case .canvas:
            canvasCard(project)
        case .camera:
            cameraCard(project)
        case .edit:
            editCard(project)
        case .smartCut:
            SmartCutPanel(
                model: model,
                project: project,
                expandedSections: $expandedSections
            )
        case .captions:
            captionsCard(project)
        case .export:
            exportCard(project)
        }
    }

    private var tabBar: some View {
        HStack(spacing: StudioTheme.space2) {
            ForEach(EditorTab.allCases) { item in
                Button {
                    tab = item
                    activeTimelineTrack = nil
                    inspectorScrollRequest = InspectorScrollRequest(
                        section: nil
                    )
                } label: {
                    VStack(spacing: StudioTheme.space2) {
                        Image(systemName: item.icon)
                            .font(.callout.weight(.medium))
                        Text(item.title)
                            .font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                }
                .buttonStyle(
                    SecondaryActionButtonStyle(
                        cornerRadius: StudioTheme.radiusS,
                        isSelected: tab == item,
                        transparentRest: true
                    )
                )
                .accessibilityAddTraits(
                    tab == item ? [.isSelected] : []
                )
            }
        }
        .padding(StudioTheme.space2)
        .background(StudioTheme.surfacePanel.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
    }

    private func canvasCard(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            disclosureSection(
                .canvas,
                title: "画布与背景",
                icon: "rectangle.inset.filled",
                summary: project.canvas.background.kind.title
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.space4) {
                    fieldBlock("画布比例") {
                        StudioSegmented(
                            selection: Binding(
                                get: { project.canvas.aspect },
                                set: { model.setCanvasAspect($0) }
                            ),
                            options: Array(CanvasAspect.allCases),
                            title: { $0.title }
                        )
                    }

                    fieldBlock("背景") {
                        HStack(spacing: StudioTheme.space2) {
                            ForEach(CanvasBackgroundKind.allCases) { kind in
                                Button {
                                    model.setBackgroundKind(kind)
                                } label: {
                                    Text(kind.title)
                                        .font(.callout.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 27)
                                }
                                .buttonStyle(
                                    SecondaryActionButtonStyle(
                                        cornerRadius: StudioTheme.radiusS,
                                        isSelected: project.canvas.background.kind == kind,
                                        transparentRest: true
                                    )
                                )
                            }
                        }
                    }

                    if project.canvas.background.kind == .solid {
                        ColorPicker(
                            "背景颜色",
                            selection: Binding(
                                get: {
                                    Color(
                                        hex: project.canvas.background.colorHex
                                    )
                                },
                                set: {
                                    model.setBackgroundColor($0.hexString)
                                }
                            )
                        )
                        .font(.callout)
                    } else if project.canvas.background.kind == .gradient {
                        HStack(spacing: StudioTheme.space4) {
                            ColorPicker(
                                "起点",
                                selection: Binding(
                                    get: {
                                        Color(
                                            hex: project.canvas.background
                                                .gradientStartHex
                                        )
                                    },
                                    set: {
                                        model.setGradientStartColor(
                                            $0.hexString
                                        )
                                    }
                                )
                            )
                            ColorPicker(
                                "终点",
                                selection: Binding(
                                    get: {
                                        Color(
                                            hex: project.canvas.background
                                                .gradientEndHex
                                        )
                                    },
                                    set: {
                                        model.setGradientEndColor(
                                            $0.hexString
                                        )
                                    }
                                )
                            )
                        }
                        .font(.callout)
                    } else if project.canvas.background.kind == .image {
                        VStack(alignment: .leading, spacing: StudioTheme.space3) {
                            HStack {
                                Text(
                                    project.backgroundImageURL == nil
                                        ? "尚未选择图片"
                                        : "图片已保存在工程目录"
                                )
                                .font(.callout)
                                .foregroundStyle(StudioTheme.textSecondary)
                                Spacer()
                                smallButton("选择图片") {
                                    model.chooseBackgroundImage()
                                }
                            }
                            HStack {
                                smallButton("系统壁纸…") {
                                    model.presentDesktopWallpaperPicker()
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }

            disclosureSection(
                .canvasLayout,
                title: "版式与外观",
                icon: "square.dashed",
                summary: String(
                    format: "留白 %.0f%% · 圆角 %.0f",
                    project.canvas.padding * 100,
                    project.canvas.cornerRadius * 1000
                )
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.space4) {
                    sliderBlock(
                        title: "画面留白",
                        value: String(
                            format: "%.0f%%",
                            project.canvas.padding * 100
                        ),
                        binding: Binding(
                            get: { project.canvas.padding },
                            set: { model.setPadding($0) }
                        ),
                        range: 0 ... 0.14
                    )

                    sliderBlock(
                        title: "屏幕圆角",
                        value: String(
                            format: "%.0f",
                            project.canvas.cornerRadius * 1000
                        ),
                        binding: Binding(
                            get: { project.canvas.cornerRadius },
                            set: { model.setCornerRadius($0) }
                        ),
                        range: 0 ... 0.08
                    )

                    HStack {
                        Text("屏幕阴影")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { project.canvas.shadowEnabled },
                                set: { model.setShadowEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(StudioTheme.accent)
                    }
                    if project.canvas.shadowEnabled {
                        sliderBlock(
                            title: "阴影强度",
                            value: String(
                                format: "%.0f%%",
                                project.canvas.shadowIntensity * 100
                            ),
                            binding: Binding(
                                get: { project.canvas.shadowIntensity },
                                set: { model.setShadowIntensity($0) }
                            ),
                            range: 0.05 ... 1
                        )
                    }
                }
            }

            disclosureSection(
                .canvasRedaction,
                title: "定时打码",
                icon: "eye.slash.fill",
                summary: project.redactionRegions.isEmpty
                    ? "未添加"
                    : "\(project.redactionRegions.count) 个区域"
            ) {
                redactionControls(project)
            }

            disclosureSection(
                .overlay,
                title: "素材叠加",
                icon: "square.stack.3d.up",
                summary: project.overlayClips.isEmpty
                    ? "未添加"
                    : "\(project.overlayClips.count) 个素材"
            ) {
                overlayControls(project)
            }
        }
        .studioCard()
    }

    /// F2 素材叠加：添加素材 + 逐项位置/大小调整（选中项展开编辑）。
    private func overlayControls(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Spacer()
                smallButton("添加素材") {
                    model.chooseOverlayMedia()
                }
            }

            ForEach(project.overlayClips) { clip in
                overlayClipRow(clip, project: project)
            }
        }
    }

    private func overlayClipRow(
        _ clip: OverlayClip,
        project: StudioProject
    ) -> some View {
        let isSelected = clip.id == model.selectedOverlayClipID
        return VStack(alignment: .leading, spacing: StudioTheme.space2) {
            Button {
                model.selectOverlayClip(isSelected ? nil : clip.id)
            } label: {
                HStack(spacing: StudioTheme.space2) {
                    Image(
                        systemName: clip.kind == .image ? "photo" : "video"
                    )
                    .font(.callout)
                    .foregroundStyle(
                        isSelected
                            ? StudioTheme.accent
                            : StudioTheme.textSecondary
                    )
                    Text(clip.kind == .image ? "图片素材" : "视频素材")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(
                        "\(formatDuration(clip.start, precise: true)) – \(formatDuration(clip.end, precise: true))"
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    Image(
                        systemName: isSelected
                            ? "chevron.down" : "chevron.right"
                    )
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .buttonStyle(GhostActionButtonStyle())
            .help(isSelected ? "收起调整控件" : "展开调整位置与大小")

            if isSelected {
                VStack(alignment: .leading, spacing: StudioTheme.space3) {
                    HStack(spacing: StudioTheme.space2) {
                        Text("位置")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        ForEach(CameraAnchor.allCases) { anchor in
                            Button {
                                model.setOverlayAnchor(anchor, for: clip.id)
                            } label: {
                                Circle()
                                    .fill(
                                        clip.anchor == anchor
                                            && clip.customCenter == nil
                                            ? StudioTheme.accent
                                            : StudioTheme.separatorLineStrong
                                    )
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(
                                IconButtonStyle(width: 20, height: 20)
                            )
                        }
                    }
                    sliderBlock(
                        title: "大小",
                        value: "\(Int(clip.size * 100))%",
                        binding: Binding(
                            get: { clip.size },
                            set: { model.setOverlaySize($0, for: clip.id) }
                        ),
                        range: OverlayClip.sizeRange
                    )
                    HStack {
                        Button {
                            model.deleteOverlayClip(clip.id)
                        } label: {
                            Text("删除素材")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, StudioTheme.space3)
                                .frame(height: 26)
                        }
                        .buttonStyle(
                            SecondaryActionButtonStyle(
                                cornerRadius: StudioTheme.radiusS,
                                destructive: true
                            )
                        )
                        .help("删除这条叠加（⌘Z 可还原），素材文件保留在工程目录")
                        Spacer()
                    }
                }
                .padding(.leading, StudioTheme.space4)
            }
        }
        .padding(.vertical, StudioTheme.space1)
    }

    /// 1.2 定时打码：绘制模式 + 逐项启停 / 样式 / 强度 / 起止编辑。
    /// 打码直接破坏导出像素，不可逆——不是可关的遮罩层。
    private func redactionControls(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Text("作用于最终输出像素，导出后不可恢复。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                smallButton(
                    redactionDrawMode ? "拖拽画布绘制…（点此取消）" : "绘制打码区域"
                ) {
                    redactionDrawMode.toggle()
                    if !redactionDrawMode {
                        redactionDrawOrigin = nil
                        redactionDrawCurrent = nil
                    }
                }
            }
            Text(
                "在画布上拖出矩形（从播放头时刻起 3 秒）；选中后可拖动 / 四角缩放。"
            )
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)

            if project.redactionRegions.isEmpty {
                Text("还没有打码区域。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            } else {
                ForEach(project.redactionRegions.sorted { $0.start < $1.start }) {
                    region in
                    redactionRow(project, region)
                }
            }
        }
    }

    private func redactionRow(
        _ project: StudioProject,
        _ region: RedactionRegion
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Text(
                    "\(formatDuration(region.start, precise: true)) – \(formatDuration(region.end, precise: true))"
                )
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Toggle(
                    "启用",
                    isOn: Binding(
                        get: { region.enabled },
                        set: { model.setRedactionRegionEnabled($0, for: region.id) }
                    )
                )
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                smallButton("删除") {
                    if selectedRedactionID == region.id {
                        selectedRedactionID = nil
                    }
                    model.deleteRedactionRegion(region.id)
                }
            }
            HStack(spacing: StudioTheme.space2) {
                ForEach(RedactionStyle.allCases) { style in
                    Button {
                        model.setRedactionRegionStyle(style, for: region.id)
                    } label: {
                        Text(style.title)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, StudioTheme.space3)
                            .frame(height: 22)
                    }
                    .buttonStyle(
                        SecondaryActionButtonStyle(
                            cornerRadius: StudioTheme.radiusS,
                            isSelected: region.style == style,
                            transparentRest: true
                        )
                    )
                }
                Spacer()
                Text("强度 \(Int(region.intensity * 100))%")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            sliderBlock(
                title: "强度",
                value: String(format: "%.0f%%", region.intensity * 100),
                binding: Binding(
                    get: { region.intensity },
                    set: {
                        model.setRedactionRegionIntensity($0, for: region.id)
                    }
                ),
                range: 0.2 ... 1
            )
            HStack(spacing: StudioTheme.space3) {
                numberField(
                    label: "开始",
                    value: region.start,
                    formatter: { value in
                        model.setRedactionRegionStart(value, for: region.id)
                    }
                )
                numberField(
                    label: "时长",
                    value: region.duration,
                    formatter: { value in
                        model.setRedactionRegionDuration(value, for: region.id)
                    }
                )
            }
        }
        .padding(StudioTheme.space3)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .fill(StudioTheme.surfaceCanvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .stroke(
                    selectedRedactionID == region.id
                        ? StudioTheme.accent.opacity(0.8)
                        : StudioTheme.separatorLine,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRedactionID = region.id
        }
    }

    /// 秒数输入框（打码起止等）。
    private func numberField(
        label: String,
        value: Double,
        formatter: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: StudioTheme.space2) {
            Text(label)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            TextField(
                "0.0",
                value: Binding(
                    get: { value },
                    set: { formatter($0) }
                ),
                format: .number.precision(.fractionLength(1...2))
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.mini)
            .frame(width: 58)
            .font(.callout.monospacedDigit())
        }
    }

    private func cameraCard(_ project: StudioProject) -> some View {
        let camera = effectiveCameraSettings(project)
        return VStack(alignment: .leading, spacing: StudioTheme.space4) {
            HStack {
                sectionHeader("摄像头", icon: "person.crop.circle")
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { camera.enabled },
                        set: { model.setCameraEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                .disabled(project.cameraURL == nil)
            }

            if project.cameraURL == nil {
                Text("这次录制没有保存摄像头。重新录制时打开摄像头即可使用这一页。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(2)
            } else {
                disclosureSection(
                    .cameraComposition,
                    title: "当前构图",
                    icon: "rectangle.inset.filled.and.person.filled",
                    summary: camera.layout.title
                ) {
                    cameraCompositionControls(project, camera: camera)
                }
                disclosureSection(
                    .cameraPosition,
                    title: "位置与尺寸",
                    icon: "arrow.up.left.and.arrow.down.right",
                    summary: cameraPositionSummary(camera)
                ) {
                    cameraPositionControls(project, camera: camera)
                }
                disclosureSection(
                    .cameraAppearance,
                    title: "外观",
                    icon: "paintbrush",
                    summary: cameraAppearanceSummary(camera)
                ) {
                    cameraAppearanceControls(camera)
                }
                disclosureSection(
                    .cameraChromaKey,
                    title: "绿幕抠像",
                    icon: "person.crop.rectangle",
                    summary: project.cameraChromaKey.enabled ? "已开启" : "关闭"
                ) {
                    cameraChromaKeyControls(project)
                }
            }

            if project.canvas.aspect == .portrait {
                disclosureSection(
                    .cameraFace,
                    title: "竖屏跟随",
                    icon: "arrow.left.and.right",
                    summary: model.portraitFollowEnabled ? "已开启" : "关闭"
                ) {
                    portraitFollowControls(project)
                }
            } else {
                disclosureSection(
                    .cameraFace,
                    title: "人脸居中",
                    icon: "faceid",
                    summary: model.faceCenteringEnabled ? "已开启" : "关闭"
                ) {
                    faceCenteringControls(project)
                }
            }
        }
        .studioCard()
    }

    /// C1 竖屏跟随：9:16 画布专用开关（默认关）+ 后台分析 + 建议审阅
    /// + 应用。按人脸中心平滑平移竖屏取景水平偏移（只平移不缩放）。
    /// 作用域约定：跟随管取景、人脸居中管焦点；竖屏画布下冲突以跟随
    /// 为准（共用自动段池，跟随应用整体替换）。
    private func portraitFollowControls(
        _ project: StudioProject
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Text("按人脸位置平滑平移竖屏取景（水平，不缩放）")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Toggle(
                    "",
                    isOn: $model.portraitFollowEnabled
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                .disabled(project.cameraURL == nil)
                .accessibilityLabel("启用竖屏跟随")
            }
            if model.portraitFollowEnabled {
                Text(
                    "按约 0.6 秒间隔在本机检测人脸（Vision，全离线），水平取景偏移按人脸中心分步平移：多脸取最大脸、无脸回中、远距离移动限速平移。跟随管取景；人脸居中管焦点，竖屏下冲突以跟随为准。"
                )
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(2)
                // 加深队列：灵敏度三档（慢 / 标准 / 快 → 平移速率）。
                fieldBlock("跟随灵敏度") {
                    StudioSegmented(
                        selection: $model.portraitFollowSensitivity,
                        options: Array(PortraitFollowSensitivity.allCases),
                        title: {
                            switch $0 {
                            case .slow: return "慢"
                            case .standard: return "标准"
                            case .fast: return "快"
                            }
                        }
                    )
                }
                HStack {
                    smallButton(
                        model.isAnalyzingFollow ? "分析中…" : "分析人脸位置"
                    ) {
                        model.analyzePortraitFollow()
                    }
                    .disabled(model.isAnalyzingFollow)
                    if let segments = model.portraitFollowSegments,
                       !segments.isEmpty
                    {
                        Text("\(segments.count) 个建议")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        smallButton("应用建议") {
                            model.applyPortraitFollowSegments()
                        }
                    }
                    Spacer()
                }
                if project.cameraSegments.contains(where: {
                    !project.smartCutAutoCameraSegmentIDs.contains($0.id)
                }) {
                    Text("已有手动布局段：应用前需先删除，不会被静默覆盖。")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.errorText)
                } else if !project.smartCutAutoCameraSegmentIDs.isEmpty {
                    Text("应用会替换现有自动布局段（含人脸居中 / 语音显隐段）。")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }
    }

    private func cameraCompositionControls(
        _ project: StudioProject,
        camera: CameraSettings
    ) -> some View {
        let activeSegment = project.cameraSegment(
            atOutput: model.currentTime
        )
        let isSegmentStart = activeSegment.map {
            abs($0.start - model.currentTime) < 0.03
        } ?? false
        return VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space3) {
                VStack(alignment: .leading, spacing: StudioTheme.space1) {
                    Text(
                        activeSegment == nil
                            ? "基础构图 · 覆盖整条成片"
                            : "布局段 · 从 \(formatDuration(activeSegment?.start ?? 0, precise: true)) 开始"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                if activeSegment != nil {
                    smallButton("删除布局段") {
                        cameraSelected = false
                        model.deleteCameraLayoutSegmentAtPlayhead()
                    }
                }
            }

            fieldBlock("布局") {
                Picker(
                    "",
                    selection: Binding(
                        get: { camera.layout },
                        set: { model.setCameraLayout($0) }
                    )
                ) {
                    ForEach(CameraLayoutMode.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(StudioTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isSegmentStart {
                smallButton(
                    activeSegment == nil
                        ? "在播放头新建布局段"
                        : "从此处新建布局段"
                ) {
                    cameraSelected = false
                    model.addCameraLayoutSegmentAtPlayhead()
                }
            }

            if let activeSegment {
                fieldBlock("进入过渡") {
                    StudioSegmented(
                        selection: Binding(
                            get: { activeSegment.transitionDuration },
                            set: {
                                model.setCameraSegmentTransition($0)
                            }
                        ),
                        options: [0.0, 0.3, 0.5, 0.8],
                        title: { $0 == 0 ? "无过渡" : String(format: "%.1f 秒", $0) }
                    )
                }
            }

            disclosureSection(
                .cameraPresets,
                title: "构图预设",
                icon: "rectangle.3.group",
                summary: cameraPresetScope.title
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.space3) {
                    fieldBlock("应用范围") {
                        StudioSegmented(
                            selection: $cameraPresetScope,
                            options: Array(CameraPresetApplicationScope.allCases),
                            title: { $0.title }
                        )
                    }

                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: StudioTheme.space2),
                            count: 3
                        ),
                        spacing: StudioTheme.space2
                    ) {
                        ForEach(CameraCompositionPreset.allCases) {
                            preset in
                            let isActive = preset.matches(
                                project,
                                camera: camera
                            )
                            Button {
                                cameraSelected = false
                                model.applyCameraPreset(
                                    preset,
                                    scope: cameraPresetScope
                                )
                            } label: {
                                VStack(spacing: StudioTheme.space2) {
                                    Image(systemName: preset.icon)
                                        .font(.subheadline.weight(.medium))
                                    Text(preset.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                            }
                            .buttonStyle(
                                SecondaryActionButtonStyle(
                                    cornerRadius: StudioTheme.radiusS,
                                    isSelected: isActive,
                                    transparentRest: true
                                )
                            )
                            .help(preset.title)
                        }
                    }
                    Text(
                        cameraPresetScope == .entireProject
                            ? "全片应用会替换现有布局段，可撤销；画布比例作用于全片。"
                            : "构图从当前播放头开始；画布比例作用于全片。"
                    )
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(2)
                }
            }
        }
    }

    private func cameraPositionControls(
        _ project: StudioProject,
        camera: CameraSettings
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            fieldBlock("画面适配") {
                StudioSegmented(
                    selection: Binding(
                        get: { camera.contentMode },
                        set: { model.setCameraContentMode($0) }
                    ),
                    options: Array(CameraContentMode.allCases),
                    title: { $0.title }
                )
            }

            if camera.contentMode == .fill {
                HStack(alignment: .bottom, spacing: StudioTheme.space3) {
                    fieldBlock("裁剪焦点 X") {
                        percentField(
                            value: Binding(
                                get: { camera.cropFocus.x },
                                set: {
                                    model.setCameraCropFocus(
                                        CGPoint(
                                            x: $0,
                                            y: camera.cropFocus.y
                                        ),
                                        groupingKey: "camera.cropFocusX"
                                    )
                                }
                            ),
                            range: 0 ... 1
                        )
                    }
                    fieldBlock("裁剪焦点 Y") {
                        percentField(
                            value: Binding(
                                get: { camera.cropFocus.y },
                                set: {
                                    model.setCameraCropFocus(
                                        CGPoint(
                                            x: camera.cropFocus.x,
                                            y: $0
                                        ),
                                        groupingKey: "camera.cropFocusY"
                                    )
                                }
                            ),
                            range: 0 ... 1
                        )
                    }
                    smallButton("居中") {
                        model.setCameraCropFocus(
                            CGPoint(x: 0.5, y: 0.5)
                        )
                    }
                }
            }

            if camera.layout != .sideBySide {
                fieldBlock("形状") {
                    HStack(spacing: StudioTheme.space2) {
                        ForEach(CameraShape.allCases) { shape in
                            Button {
                                model.setCameraShape(shape)
                            } label: {
                                Text(shape.title)
                                    .font(.callout.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 27)
                            }
                            .buttonStyle(
                                SecondaryActionButtonStyle(
                                    cornerRadius: StudioTheme.radiusS,
                                    isSelected: camera.shape == shape,
                                    transparentRest: true
                                )
                            )
                        }
                    }
                }

                fieldBlock("九宫格位置") {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: StudioTheme.space2),
                            count: 3
                        ),
                        spacing: StudioTheme.space2
                    ) {
                        ForEach(CameraAnchor.allCases) { anchor in
                            Button {
                                model.setCameraAnchor(anchor)
                            } label: {
                                Circle()
                                    .fill(
                                        camera.customCenter == nil
                                            && camera.anchor == anchor
                                            ? StudioTheme.accent
                                            : StudioTheme.textTertiary
                                    )
                                    .frame(width: 14, height: 14)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 27)
                            }
                            .buttonStyle(
                                SecondaryActionButtonStyle(
                                    cornerRadius: StudioTheme.radiusS,
                                    isSelected: camera.customCenter == nil
                                        && camera.anchor == anchor,
                                    transparentRest: true
                                )
                            )
                            .help(anchor.title)
                        }
                    }
                }

                HStack {
                    Text("方向键微调 1%，Shift + 方向键 5%")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    smallButton("重置位置") {
                        cameraSelected = false
                        model.setCameraAnchor(camera.anchor)
                    }
                }

                HStack(alignment: .bottom, spacing: StudioTheme.space3) {
                    let center = currentCameraCenter(camera)
                    fieldBlock("位置 X") {
                        percentField(
                            value: Binding(
                                get: { center.x },
                                set: {
                                    model.setCameraCustomCenter(
                                        CGPoint(x: $0, y: center.y)
                                    )
                                }
                            ),
                            range: 0 ... 1
                        )
                    }
                    fieldBlock("位置 Y") {
                        percentField(
                            value: Binding(
                                get: { center.y },
                                set: {
                                    model.setCameraCustomCenter(
                                        CGPoint(x: center.x, y: $0)
                                    )
                                }
                            ),
                            range: 0 ... 1
                        )
                    }
                    fieldBlock("大小") {
                        percentField(
                            value: Binding(
                                get: { camera.size },
                                set: { model.setCameraSize($0) }
                            ),
                            range: 0.1 ... 0.5
                        )
                    }
                }

                sliderBlock(
                    title: "摄像头大小",
                    value: String(format: "%.0f%%", camera.size * 100),
                    binding: Binding(
                        get: { camera.size },
                        set: { model.setCameraSize($0) }
                    ),
                    range: 0.1 ... 0.5
                )

                Toggle(
                    "缩放时避让屏幕焦点",
                    isOn: Binding(
                        get: { camera.avoidsZoomFocus },
                        set: { model.setCameraAvoidsZoomFocus($0) }
                    )
                )
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
            } else {
                sliderBlock(
                    title: "画面占比",
                    value: String(format: "%.0f%%", camera.splitRatio * 100),
                    binding: Binding(
                        get: { camera.splitRatio },
                        set: { model.setCameraSplitRatio($0) }
                    ),
                    range: 0.5 ... 0.8
                )
            }
        }
    }

    private func cameraAppearanceControls(
        _ camera: CameraSettings
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            Toggle(
                "水平镜像",
                isOn: Binding(
                    get: { camera.mirrored },
                    set: { model.setCameraMirrored($0) }
                )
            )
            .font(.callout)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(StudioTheme.accent)

            HStack {
                Toggle(
                    "边框",
                    isOn: Binding(
                        get: { camera.borderWidth > 0.01 },
                        set: { model.setCameraBorderWidth($0 ? 2 : 0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                Spacer()
                if camera.borderWidth > 0.01 {
                    ColorPicker(
                        "颜色",
                        selection: Binding(
                            get: { Color(hex: camera.borderColorHex) },
                            set: { model.setCameraBorderColor($0.hexString) }
                        )
                    )
                }
            }
            .font(.callout)

            if camera.borderWidth > 0.01 {
                sliderBlock(
                    title: "边框宽度",
                    value: String(format: "%.0f px", camera.borderWidth),
                    binding: Binding(
                        get: { camera.borderWidth },
                        set: { model.setCameraBorderWidth($0) }
                    ),
                    range: 0.5 ... 12
                )
            }

            Toggle(
                "摄像头阴影",
                isOn: Binding(
                    get: { camera.shadowEnabled },
                    set: { model.setCameraShadowEnabled($0) }
                )
            )
            .font(.callout)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(StudioTheme.accent)

            if camera.shadowEnabled {
                sliderBlock(
                    title: "阴影强度",
                    value: String(
                        format: "%.0f%%",
                        camera.shadowIntensity * 100
                    ),
                    binding: Binding(
                        get: { camera.shadowIntensity },
                        set: { model.setCameraShadowIntensity($0) }
                    ),
                    range: 0.05 ... 0.8
                )
            }
        }
    }

    private func cameraPositionSummary(_ camera: CameraSettings) -> String {
        if camera.layout == .sideBySide {
            return "并排 · \(Int((camera.splitRatio * 100).rounded()))%"
        }
        let position = camera.customCenter == nil
            ? camera.anchor.title
            : "自定义位置"
        return "\(position) · \(Int((camera.size * 100).rounded()))%"
    }

    private func cameraAppearanceSummary(_ camera: CameraSettings) -> String {
        var items: [String] = []
        if camera.mirrored {
            items.append("镜像")
        }
        if camera.borderWidth > 0.01 {
            items.append("边框")
        }
        if camera.shadowEnabled {
            items.append("阴影")
        }
        return items.isEmpty ? "默认" : items.joined(separator: " · ")
    }

    private func cameraChromaKeyControls(
        _ project: StudioProject
    ) -> some View {
        let settings = project.cameraChromaKey
        return VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Text("启用抠像")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { settings.enabled },
                        set: { model.setCameraChromaKeyEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                .accessibilityLabel("启用摄像头绿幕抠像")
            }

            HStack(spacing: StudioTheme.space3) {
                ColorPicker(
                    "幕布颜色",
                    selection: Binding(
                        get: {
                            Color(hex: settings.keyColorHex)
                        },
                        set: {
                            model.setCameraChromaKeyColor($0.hexString)
                        }
                    )
                )
                .font(.callout)
                Spacer()
                smallButton(
                    model.isSamplingChromaKey
                        ? "正在取色…"
                        : "取色"
                ) {
                    model.sampleCameraChromaKeyColor()
                }
                .disabled(model.isSamplingChromaKey)
                if
                    let data = settings.backgroundFieldData,
                    let field = ChromaKeyField(data: data),
                    let cgImage = field.previewCGImage()
                {
                    // 加深队列：色场预览小图（机器估的背景对不对，一眼可见）。
                    Image(
                        cgImage,
                        scale: 1,
                        label: Text("背景色场预览")
                    )
                    .resizable()
                    .aspectRatio(
                        CGFloat(ChromaKeyField.columns)
                            / CGFloat(ChromaKeyField.rows),
                        contentMode: .fit
                    )
                    .frame(width: 66)
                    .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                            .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
                    )
                    .accessibilityLabel("背景色场预览")
                }
            }


            // C3 抠像模式三态：关闭 / 绿幕 / 自动分割（Vision 本机）。
            fieldBlock("抠像模式") {
                StudioSegmented(
                    selection: Binding(
                        get: {
                            if !settings.enabled {
                                return CameraChromaKeyMode.off
                            }
                            return settings.personSegmentation
                                ? .personSegment : .greenScreen
                        },
                        set: { model.setCameraChromaKeyMode($0) }
                    ),
                    options: Array(CameraChromaKeyMode.allCases),
                    title: { $0.title }
                )
            }

            if settings.enabled && settings.personSegmentation {
                Text(
                    "自动分割用本机 Vision（accurate）逐帧生成人像遮罩，边缘收缩 / 羽化同样生效；背景可透明或重模糊。真实发丝与检出率需人工复核。"
                )
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(2)
                Toggle(
                    "背景重模糊（关闭则背景透明）",
                    isOn: Binding(
                        get: { settings.segmentationBackgroundBlurred },
                        set: {
                            model.setCameraSegmentationBackgroundBlurred($0)
                        }
                    )
                )
                .font(.callout)
                .toggleStyle(.checkbox)
                .controlSize(.mini)
            }

            if settings.enabled {
                // 加深队列：三套成套预设，一键套用后可微调。
                HStack(spacing: StudioTheme.space3) {
                    Text("预设")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                    ForEach(CameraChromaKeyPreset.allCases) { preset in
                        smallButton(preset.title) {
                            model.applyCameraChromaKeyPreset(preset)
                        }
                    }
                    Spacer()
                }
                sliderBlock(
                    title: "颜色容差",
                    value: String(
                        format: "%.0f%%",
                        settings.tolerance * 100
                    ),
                    binding: Binding(
                        get: { settings.tolerance },
                        set: {
                            model.setCameraChromaKeyTolerance($0)
                        }
                    ),
                    range: 0.02 ... 0.35
                )
                sliderBlock(
                    title: "边缘柔化",
                    value: String(
                        format: "%.0f%%",
                        settings.softness * 100
                    ),
                    binding: Binding(
                        get: { settings.softness },
                        set: {
                            model.setCameraChromaKeySoftness($0)
                        }
                    ),
                    range: 0.01 ... 0.2
                )
                sliderBlock(
                    title: "哑光内收",
                    value: String(
                        format: "%.1f px",
                        settings.edgeShrinkPixels
                    ),
                    binding: Binding(
                        get: { settings.edgeShrinkPixels },
                        set: {
                            model.setCameraChromaKeyEdgeShrink($0)
                        }
                    ),
                    range: 0 ... 3
                )
                sliderBlock(
                    title: "边缘羽化",
                    value: String(
                        format: "%.1f px",
                        settings.edgeFeatherPixels
                    ),
                    binding: Binding(
                        get: { settings.edgeFeatherPixels },
                        set: {
                            model.setCameraChromaKeyEdgeFeather($0)
                        }
                    ),
                    range: 0 ... 4
                )
                sliderBlock(
                    title: "去绿溢色",
                    value: String(
                        format: "%.0f%%",
                        settings.spillSuppression * 100
                    ),
                    binding: Binding(
                        get: { settings.spillSuppression },
                        set: {
                            model.setCameraChromaKeySpillSuppression($0)
                        }
                    ),
                    range: 0 ... 1
                )
                sliderBlock(
                    title: "边缘光包裹",
                    value: String(
                        format: "%.0f%%",
                        settings.lightWrap * 100
                    ),
                    binding: Binding(
                        get: { settings.lightWrap },
                        set: {
                            model.setCameraChromaKeyLightWrap($0)
                        }
                    ),
                    range: 0 ... 1
                )
            }
        }
    }

    /// 1.2 人脸居中：开关（默认关）+ 后台分析 + 建议审阅 + 应用。
    /// 只在没有手动布局段时生成；与语音显隐共用自动段位，应用会整体
    /// 替换自动段。真机摄像头效果需要人工验收。
    private func faceCenteringControls(
        _ project: StudioProject
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Text("人脸居中")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Toggle(
                    "",
                    isOn: $model.faceCenteringEnabled
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                .disabled(project.cameraURL == nil)
                .accessibilityLabel("启用人脸居中")
            }
            if model.faceCenteringEnabled {
                HStack {
                    smallButton(
                        model.isAnalyzingFaces ? "分析中…" : "分析人脸位置"
                    ) {
                        model.analyzeFaceFocus()
                    }
                    .disabled(model.isAnalyzingFaces)
                    if let segments = model.faceFocusSegments,
                       !segments.isEmpty
                    {
                        Text("\(segments.count) 个建议")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        smallButton("应用建议") {
                            model.applyFaceFocusSegments()
                        }
                    }
                    Spacer()
                }
                if project.cameraSegments.contains(where: {
                    !project.smartCutAutoCameraSegmentIDs.contains($0.id)
                }) {
                    Text("已有手动布局段：应用前需先删除，不会被静默覆盖。")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.errorText)
                } else if !project.smartCutAutoCameraSegmentIDs.isEmpty {
                    Text("应用会替换现有自动布局段（含语音显隐段）。")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }
    }

    private func editCard(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            disclosureSection(
                .clip,
                title: "当前片段",
                icon: "film",
                summary: selectedClip.map {
                    "\(formatDuration($0.outputDuration, precise: true)) · \(rateLabel($0.playbackRate))"
                } ?? "未选择"
            ) {
                clipControls(project)
            }
            disclosureSection(
                .markers,
                title: "录制标记",
                icon: "flag.fill",
                summary: "\(project.markers.count) 个"
            ) {
                markerControls(project)
            }
            disclosureSection(
                .cursor,
                title: "光标",
                icon: "cursorarrow",
                summary: project.rawCursor.isEmpty
                    ? "视频内光标"
                    : project.cursor.enabled ? "已重绘" : "已隐藏"
            ) {
                cursorControls(project)
            }
            disclosureSection(
                .audio,
                title: "声音",
                icon: "waveform",
                summary: audioSummary(project)
            ) {
                audioControls(project)
            }
            disclosureSection(
                .zoom,
                title: "缩放与点击",
                icon: "plus.magnifyingglass",
                summary: zoomSummary(project)
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.space4) {
                    manualZoomControls(project)
                    Divider()
                        .overlay(StudioTheme.separatorLine)
                    autoZoomControls(project)
                }
            }
        }
        .studioCard()
    }

    private func clipControls(_ project: StudioProject) -> some View {
        Group {
            if let clip = selectedClip {
                VStack(alignment: .leading, spacing: StudioTheme.space4) {
                    HStack {
                        Text(
                            "源 \(formatDuration(clip.sourceStart, precise: true)) – \(formatDuration(clip.sourceEnd, precise: true))"
                        )
                        Spacer()
                        Text(formatDuration(clip.outputDuration, precise: true))
                            .foregroundStyle(StudioTheme.accent)
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)

                    sliderBlock(
                        title: "片段起点",
                        value: formatDuration(clip.sourceStart, precise: true),
                        binding: Binding(
                            get: { clip.sourceStart },
                            set: {
                                model.setTimelineClipStart($0, for: clip.id)
                            }
                        ),
                        range: 0
                            ... max(
                                0,
                                clip.sourceEnd
                                    - TimelineClip.minimumSourceDuration
                            )
                    )
                    sliderBlock(
                        title: "片段终点",
                        value: formatDuration(clip.sourceEnd, precise: true),
                        binding: Binding(
                            get: { clip.sourceEnd },
                            set: {
                                model.setTimelineClipEnd($0, for: clip.id)
                            }
                        ),
                        range: min(
                            clip.sourceStart
                                + TimelineClip.minimumSourceDuration,
                            project.duration
                        ) ... max(project.duration, 0.25)
                    )

                    fieldBlock("片段速度") {
                        HStack(spacing: StudioTheme.space2) {
                            ForEach(
                                TimelineClip.allowedPlaybackRates,
                                id: \.self
                            ) { rate in
                                Button {
                                    model.setTimelinePlaybackRate(
                                        rate,
                                        for: clip.id
                                    )
                                } label: {
                                    Text(rateLabel(rate))
                                        .font(.callout.weight(.medium).monospacedDigit())
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 25)
                                }
                                .buttonStyle(
                                    SecondaryActionButtonStyle(
                                        cornerRadius: StudioTheme.radiusS,
                                        isSelected: abs(clip.playbackRate - rate) < 0.001,
                                        transparentRest: true
                                    )
                                )
                            }
                        }
                    }

                    HStack(spacing: StudioTheme.space3) {
                        smallButton("在播放头切分") {
                            model.splitTimelineAtPlayhead()
                        }
                        // destructive：§5.1 rest 行，走 Secondary 的 destructive
                        // 变体（errorText 内容 + 同色描边），几何与次按钮一致。
                        Button {
                            model.deleteTimelineClip(clip.id)
                        } label: {
                            Text("删除片段")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, StudioTheme.space3)
                                .frame(height: 26)
                        }
                        .buttonStyle(
                            SecondaryActionButtonStyle(
                                cornerRadius: StudioTheme.radiusS,
                                destructive: true
                            )
                        )
                        .disabled(project.timeline.clips.count <= 1)
                        Spacer()
                        Text("成片 \(formatDuration(project.trimDuration))")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }
            }
        }
    }

    private func autoZoomControls(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            HStack {
                Text("点击放大")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { project.autoZoom },
                        set: { model.setAutoZoom($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
            }
            sliderBlock(
                title: "倍率",
                value: String(format: "%.2f×", project.zoomScale),
                binding: Binding(
                    get: { project.zoomScale },
                    set: { model.setZoomScale($0) }
                ),
                range: 1.15 ... 2.8
            )
            sliderBlock(
                title: "停留",
                value: String(format: "%.1f 秒", project.zoomDuration),
                binding: Binding(
                    get: { project.zoomDuration },
                    set: { model.setZoomDuration($0) }
                ),
                range: 0.6 ... 3.5
            )
            HStack {
                Text("点击位置")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Button("全开") {
                    model.setAllClicks(enabled: true)
                }
                .buttonStyle(GhostActionButtonStyle())
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                Text("·")
                    .foregroundStyle(StudioTheme.textTertiary)
                Button("全关") {
                    model.setAllClicks(enabled: false)
                }
                .buttonStyle(GhostActionButtonStyle())
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            }
            if project.clicks.isEmpty {
                Text("这次录制没有检测到点击。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            } else {
                ScrollView {
                    VStack(spacing: StudioTheme.space2) {
                        ForEach(project.clicks) { click in
                            clickRow(click, project: project)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func audioSummary(_ project: StudioProject) -> String {
        let microphone = project.audio.microphoneMuted
            ? "麦克风静音"
            : "麦克风 \(Int((project.audio.microphoneGain * 100).rounded()))%"
        let system = project.audio.systemMuted
            ? "系统声静音"
            : "系统声 \(Int((project.audio.systemGain * 100).rounded()))%"
        return "\(microphone) · \(system)"
    }

    private func zoomSummary(_ project: StudioProject) -> String {
        "手动 \(project.zoomRegions.count) 个 · 点击 \(project.clicks.filter(\.enabled).count) 个"
    }

    private func markerControls(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                sectionHeader("录制标记", icon: "flag.fill")
                Spacer()
                Text("\(project.markers.count) 个")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                smallButton("在播放头添加") {
                    model.addMarkerAtPlayhead()
                }
            }

            if project.markers.isEmpty {
                Text("录制时点 HUD 的“标记”，或按 M，即可在这里整理重点。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            } else {
                ScrollView {
                    VStack(spacing: StudioTheme.space2) {
                        ForEach(project.markers) { marker in
                            markerRow(marker, project: project)
                        }
                    }
                }
                .frame(maxHeight: 146)
            }
        }
    }

    private func markerRow(
        _ marker: RecordingMarker,
        project: StudioProject
    ) -> some View {
        let outputTime = project.outputTime(
            forSourceTime: marker.sourceTime
        )
        return HStack(spacing: StudioTheme.space3) {
            Button {
                guard let outputTime else { return }
                model.seek(to: outputTime)
            } label: {
                Image(systemName: "flag.fill")
                    .font(.callout)
                    .foregroundStyle(
                        outputTime == nil
                            ? StudioTheme.textTertiary
                            : StudioTheme.errorText
                    )
            }
            .buttonStyle(IconButtonStyle())
            .disabled(outputTime == nil)
            .help(
                outputTime == nil
                    ? "该标记所在片段已被移除"
                    : "跳到标记"
            )

            TextField(
                "标记名称",
                text: Binding(
                    get: { marker.name },
                    set: { model.renameMarker(marker.id, name: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, StudioTheme.space3)
            .frame(height: 26)
            .background(StudioTheme.surfaceCanvas)
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                    .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))

            Text(
                outputTime.map {
                    formatDuration($0, precise: true)
                } ?? "已移除"
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(StudioTheme.textSecondary)
            .lineLimit(1)
            .frame(width: 62, alignment: .trailing)
            .monospacedDigit()

            Button {
                model.deleteMarker(marker.id)
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("删除标记")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "标记 \(marker.name)，\(outputTime.map { formatDuration($0, precise: true) } ?? "已不在成片中")"
        )
    }

    private func cursorControls(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                sectionHeader("光标", icon: "cursorarrow")
                Spacer()
                Text(
                    project.rawCursor.isEmpty
                        ? "视频内光标"
                        : "已记录 \(project.rawCursor.count) 个光标位置"
                )
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            }
            if !project.keyStrokes.isEmpty {
                Toggle(
                    "显示按键提示",
                    isOn: Binding(
                        get: { project.keyStripEnabled },
                        set: { model.setKeyStripEnabled($0) }
                    )
                )
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                .help("把录制时按下的键显示在画面左下角小条上")
            }
            if project.rawCursor.isEmpty {
                Text("这是旧工程或兼容录制，光标已包含在画面中。新录制会单独保存光标，可在这里调整。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            } else {
                Toggle(
                    "显示重绘光标",
                    isOn: Binding(
                        get: { project.cursor.enabled },
                        set: { model.setCursorEnabled($0) }
                    )
                )
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)

                sliderBlock(
                    title: "大小",
                    value: String(
                        format: "%.2f×",
                        project.cursor.size
                    ),
                    binding: Binding(
                        get: { project.cursor.size },
                        set: { model.setCursorSize($0) }
                    ),
                    range: 0.75 ... 2.5
                )
                sliderBlock(
                    title: "平滑",
                    value: String(
                        format: "%.0f%%",
                        project.cursor.smoothing * 100
                    ),
                    binding: Binding(
                        get: { project.cursor.smoothing },
                        set: { model.setCursorSmoothing($0) }
                    ),
                    range: 0 ... 0.95
                )
                HStack {
                    cursorToggle(
                        "静止隐藏",
                        value: project.cursor.hideWhenIdle
                    ) {
                        model.setCursorHideWhenIdle($0)
                    }
                    cursorToggle(
                        "点击提示",
                        value: project.cursor.clickHighlight
                    ) {
                        model.setCursorClickHighlight($0)
                    }
                }
                if project.cursor.hideWhenIdle {
                    sliderBlock(
                        title: "静止后隐藏",
                        value: String(
                            format: "%.1f 秒",
                            project.cursor.idleDelay
                        ),
                        binding: Binding(
                            get: { project.cursor.idleDelay },
                            set: { model.setCursorIdleDelay($0) }
                        ),
                        range: 0.4 ... 4
                    )
                }
            }
        }
    }

    private func cursorToggle(
        _ title: String,
        value: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { value },
                set: onChange
            )
        )
        .font(.callout)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(StudioTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 通用开关行（1.2 音频优化等区块使用）。
    private func toggleRow(
        _ title: String,
        value: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        cursorToggle(title, value: value, onChange: onChange)
    }

    private func audioControls(_ project: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            HStack {
                sectionHeader("声音混合", icon: "waveform")
                Spacer()
                Text("预览 / 导出一致")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            HStack {
                Text("麦克风")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(
                        project.microphoneURL == nil
                            ? StudioTheme.textTertiary
                            : StudioTheme.textSecondary
                    )
                Spacer()
                Toggle(
                    "静音",
                    isOn: Binding(
                        get: { project.audio.microphoneMuted },
                        set: { model.setMicrophoneMuted($0) }
                    )
                )
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
            }
            sliderBlock(
                title: "麦克风增益",
                value: project.microphoneURL == nil
                    ? "无音轨"
                    : String(
                        format: "%.0f%%",
                        project.audio.microphoneGain * 100
                    ),
                binding: Binding(
                    get: { project.audio.microphoneGain },
                    set: { model.setMicrophoneGain($0) }
                ),
                range: 0 ... 1
            )
            .disabled(
                project.microphoneURL == nil
                    || project.audio.microphoneMuted
            )
            .opacity(
                project.microphoneURL == nil
                    || project.audio.microphoneMuted
                    ? 0.38
                    : 1
            )

            HStack {
                Text("系统声音")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Toggle(
                    "静音",
                    isOn: Binding(
                        get: { project.audio.systemMuted },
                        set: { model.setSystemMuted($0) }
                    )
                )
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
            }
            sliderBlock(
                title: "系统声音增益",
                value: String(
                    format: "%.0f%%",
                    project.audio.systemGain * 100
                ),
                binding: Binding(
                    get: { project.audio.systemGain },
                    set: { model.setSystemGain($0) }
                ),
                range: 0 ... 1
            )
            .disabled(project.audio.systemMuted)
            .opacity(project.audio.systemMuted ? 0.38 : 1)

            audioOptimizationControls(project)
        }
    }

    /// 1.2 音频一键优化：四个独立开关 + 原声 A/B 试听 + 分析建议。
    /// 处理作用于预览与导出同一条混合链；A/B 只旁路预览参数，不改工程。
    private func audioOptimizationControls(
        _ project: StudioProject
    ) -> some View {
        let processing = project.audio.processing
        let duckingAvailable = project.microphoneURL != nil
            && project.systemAudioURL != nil
        return VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                sectionHeader("音频优化", icon: "slider.horizontal.3")
                Spacer()
                if !processing.isEffectivelyEmpty {
                    Text(
                        model.audioProcessingReady
                            ? "已就绪"
                            : "处理准备中…"
                    )
                    .font(.callout)
                    .foregroundStyle(
                        model.audioProcessingReady
                            ? StudioTheme.textTertiary
                            : StudioTheme.accent
                    )
                }
            }

            // 原声 A/B：即时切换预览链的处理旁路，工程数据不变。
            fieldBlock("原声试听") {
                StudioSegmented(
                    selection: Binding(
                        get: { model.audioPreviewBypassed },
                        set: { model.setAudioPreviewBypassed($0) }
                    ),
                    options: [true, false],
                    title: { $0 ? "处理前" : "处理后" }
                )
            }
            .disabled(processing.isEffectivelyEmpty)

            toggleRow(
                "自动电平（对齐 -14 LUFS 近似值）",
                value: processing.autoLevelEnabled
            ) { enabled in
                model.updateAudioProcessing {
                    $0.autoLevelEnabled = enabled
                }
            }
            if processing.autoLevelEnabled {
                Text(
                    "当前增益 \(String(format: "%+.1f", processing.autoLevelGainDB)) dB（±12 dB，峰值留 -1 dBFS）"
                )
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            }

            toggleRow(
                "人声增强（存在感频段 + 轻压缩）",
                value: processing.voiceEnhanceEnabled
            ) { enabled in
                model.updateAudioProcessing {
                    $0.voiceEnhanceEnabled = enabled
                }
            }

            toggleRow(
                "轻量降噪（80 Hz 高通 + 噪声门）",
                value: processing.noiseReductionEnabled
            ) { enabled in
                model.updateAudioProcessing {
                    $0.noiseReductionEnabled = enabled
                }
            }

            toggleRow(
                "说话时压低系统声（ducking）",
                value: processing.duckingEnabled
            ) { enabled in
                model.updateAudioProcessing {
                    $0.duckingEnabled = enabled
                }
            }
            .disabled(!duckingAvailable)
            if !duckingAvailable {
                Text("需要独立的麦克风轨和系统声音轨；当前工程不可用。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            } else if processing.duckingEnabled {
                sliderBlock(
                    title: "压低量",
                    value: String(
                        format: "%.0f dB",
                        processing.duckingAmountDB
                    ),
                    binding: Binding(
                        get: { processing.duckingAmountDB },
                        set: { value in
                            model.updateAudioProcessing {
                                $0.duckingAmountDB = value
                            }
                        }
                    ),
                    range: 1 ... 12
                )
            }

            HStack {
                smallButton(model.isAnalyzingAudio ? "分析中…" : "分析电平") {
                    model.analyzeAudioOptimization()
                }
                .disabled(model.isAnalyzingAudio || project.microphoneURL == nil && project.systemAudioURL == nil)
                if let proposal = model.audioOptimizationProposal {
                    Text(
                        "实测 \(proposal.loudness.map { String(format: "%.1f", $0) } ?? "—") LUFS·峰值 \(String(format: "%.1f", proposal.peak)) dBFS → 建议 \(String(format: "%+.1f", proposal.suggestedGainDB)) dB"
                    )
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    smallButton("应用建议") {
                        model.applyAudioOptimizationProposal()
                    }
                }
            }
            Text("响度为 K 加权近似值，不是精确 LUFS；处理预览与导出一致。")
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .padding(.top, StudioTheme.space2)
    }

    private func manualZoomControls(_ project: StudioProject) -> some View {
        let activeRegion = project.zoomRegion(
            atOutput: model.currentTime
        )
        return VStack(alignment: .leading, spacing: StudioTheme.space4) {
            HStack {
                sectionHeader("手动缩放", icon: "plus.magnifyingglass")
                Spacer()
                if activeRegion == nil {
                    smallButton("在播放头添加") {
                        model.addManualZoomRegionAtPlayhead()
                    }
                } else {
                    Text("当前有缩放区")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            if let region = activeRegion {
                HStack {
                    Text(
                        "\(formatDuration(region.start, precise: true)) – \(formatDuration(region.end, precise: true))"
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    Toggle(
                        "启用",
                        isOn: Binding(
                            get: { region.enabled },
                            set: {
                                model.setManualZoomRegionEnabled(
                                    $0,
                                    for: region.id
                                )
                            }
                        )
                    )
                    .font(.callout)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(StudioTheme.accent)
                }
                sliderBlock(
                    title: "区域倍率",
                    value: String(format: "%.2f×", region.scale),
                    binding: Binding(
                        get: { region.scale },
                        set: {
                            model.setManualZoomRegionScale(
                                $0,
                                for: region.id
                            )
                        }
                    ),
                    range: 1 ... 4
                )
                sliderBlock(
                    title: "区域时长",
                    value: String(
                        format: "%.1f 秒",
                        region.duration
                    ),
                    binding: Binding(
                        get: { region.duration },
                        set: {
                            model.setManualZoomRegionDuration(
                                $0,
                                for: region.id
                            )
                        }
                    ),
                    range: 0.2 ... 6
                )
                HStack(spacing: StudioTheme.space3) {
                    fieldBlock("焦点 X") {
                        percentField(
                            value: Binding(
                                get: { region.center.x },
                                set: {
                                    model.setManualZoomRegionCenter(
                                        CGPoint(
                                            x: $0,
                                            y: region.center.y
                                        ),
                                        for: region.id
                                    )
                                }
                            ),
                            range: 0 ... 1
                        )
                    }
                    fieldBlock("焦点 Y") {
                        percentField(
                            value: Binding(
                                get: { region.center.y },
                                set: {
                                    model.setManualZoomRegionCenter(
                                        CGPoint(
                                            x: region.center.x,
                                            y: $0
                                        ),
                                        for: region.id
                                    )
                                }
                            ),
                            range: 0 ... 1
                        )
                    }
                    smallButton("删除") {
                        model.deleteManualZoomRegion(region.id)
                    }
                }
            } else {
                Text("添加后会在播放头附近产生独立缩放区；手动区域优先于点击建议。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(2)
            }
        }
    }

    /// 1.2 双语字幕：第二份 SRT 作为副字幕轨，主副按时间对齐同屏显示。
    /// 本产品不做机器翻译、不联网——文案只写「导入第二语言字幕」。
    private func secondaryCaptionControls(
        _ project: StudioProject
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            if !project.secondaryCaptionCues.isEmpty {
                HStack {
                    Spacer()
                    Toggle(
                        "显示",
                        isOn: Binding(
                            get: { project.captions.secondaryEnabled },
                            set: {
                                model.setSecondaryCaptionsEnabled($0)
                            }
                        )
                    )
                    .font(.callout)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(StudioTheme.accent)
                }
            }
            if project.secondaryCaptionCues.isEmpty {
                Text(
                    "导入第二份 SRT（例如人工翻译稿），与主字幕按时间对齐同屏显示；不会自动翻译。"
                )
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(2)
            } else {
                Text("副字幕 \(project.secondaryCaptionCues.count) 条")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            HStack {
                smallButton("导入副字幕 SRT") {
                    model.importSecondaryCaptionsSRT()
                }
                if !project.secondaryCaptionCues.isEmpty {
                    smallButton("移除副字幕") {
                        model.removeSecondaryCaptions()
                    }
                }
                Spacer()
            }
            if !project.secondaryCaptionCues.isEmpty {
                fieldBlock("副字幕位置") {
                    StudioSegmented(
                        selection: Binding(
                            get: { project.captions.secondaryPosition },
                            set: { model.setCaptionSecondaryPosition($0) }
                        ),
                        options: Array(CaptionSecondaryPosition.allCases),
                        title: { $0.title }
                    )
                }
                .font(.callout)
            }
        }
    }

    /// 1.2 术语表：错词 → 正词对照表（存应用偏好），新生成字幕与导入
    /// SRT 入工程时自动套用，套用结果在字幕列表可见可改。
    private func glossaryControls(
        _ project: StudioProject
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Spacer()
                Toggle(
                    "自动套用",
                    isOn: Binding(
                        get: { model.glossaryAutoApply },
                        set: { model.setGlossaryAutoApply($0) }
                    )
                )
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
            }
            Text(
                "生成字幕与导入 SRT 时自动把错词替换为正词（产品名 / 人名 / 术语）；英文词条按整词匹配，中文按最长优先替换。替换结果可直接在字幕条目里修改。"
            )
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            .lineSpacing(2)

            if !model.glossaryEntries.isEmpty {
                ForEach(
                    Array(model.glossaryEntries.enumerated()),
                    id: \.offset
                ) { _, entry in
                    HStack(spacing: StudioTheme.space3) {
                        Text(entry.wrong)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(StudioTheme.errorText)
                        Image(systemName: "arrow.right")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        Text(entry.right.isEmpty ? "（删除）" : entry.right)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        smallButton("删除") {
                            model.removeGlossaryEntry(entry)
                        }
                    }
                }
            }

            HStack(spacing: StudioTheme.space3) {
                TextField(
                    "错词",
                    text: $glossaryWrongField
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .font(.callout)
                TextField(
                    "正词（留空即删除该词）",
                    text: $glossaryRightField
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .font(.callout)
                smallButton("添加") {
                    model.addGlossaryEntry(
                        wrong: glossaryWrongField,
                        right: glossaryRightField
                    )
                    glossaryWrongField = ""
                    glossaryRightField = ""
                }
                .disabled(
                    glossaryWrongField
                        .trimmingCharacters(in: .whitespaces)
                        .isEmpty
                )
            }
            if !model.glossaryEntries.isEmpty {
                smallButton("对现有字幕重新套用") {
                    model.applyGlossaryToCaptions()
                }
            }
        }
    }

    private func captionsCard(_ project: StudioProject) -> some View {
        let activeCue = project.captionCues
            .filter {
                $0.start <= model.currentTime + 0.000_001
                    && model.currentTime < $0.end
            }
            .max { $0.start < $1.start }
        let chapters = ChapterBuilder.build(
            from: project.captionCues,
            totalDuration: project.trimDuration
        )
        return VStack(alignment: .leading, spacing: StudioTheme.space4) {
            HStack {
                sectionHeader("字幕设置", icon: "captions.bubble")
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { project.captions.enabled },
                        set: { model.setCaptionsEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StudioTheme.accent)
                .accessibilityLabel("显示字幕")
            }

            HStack(spacing: StudioTheme.space3) {
                Button {
                    model.generateCaptionsOffline()
                } label: {
                    Label(
                        model.isTranscribingCaptions
                            ? "生成中…"
                            : "本机生成",
                        systemImage: "waveform.badge.mic"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 29)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(model.isTranscribingCaptions)

                smallButton("导入 SRT") {
                    model.importCaptionsSRT()
                }
                smallButton("导出 SRT") {
                    model.exportCaptionsSRT()
                }
                .disabled(project.captionCues.isEmpty)
                .help(
                    project.captionCues.isEmpty
                        ? "还没有字幕：先点「本机生成」或导入 SRT"
                        : ""
                )
            }

            if model.isTranscribingCaptions {
                HStack(spacing: StudioTheme.space3) {
                    // P4 防卡死：转写有进度可取消——百分比随识别分段推进
                    // 更新，「取消」终止整条识别链，不把等待当唯一出路。
                    ProgressView()
                        .controlSize(.small)
                        .tint(StudioTheme.accent)
                    Text(model.captionStatus ?? "正在本机识别…")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                    if let progress = model.captionTranscriptionProgress {
                        Text("\(Int(progress * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    smallButton("取消") {
                        model.cancelCaptionTranscription()
                    }
                }
            } else if let status = model.captionStatus {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(2)
            }
            Text("自动字幕只使用 macOS 本机离线识别；识别失败会给原因和下一步（如导入 SRT），录音不会上传。")
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(2)

            disclosureSection(
                .captionContent,
                title: "字幕与条目",
                icon: "text.bubble",
                summary: "\(project.captionCues.count) 条 · \(project.captions.effectiveBurnMode.title)"
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.space4) {
                    HStack {
                        Text("导出烧录")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        StudioSegmented(
                            selection: Binding(
                                get: {
                                    project.captions.effectiveBurnMode
                                },
                                set: { model.setCaptionBurnMode($0) }
                            ),
                            options: Array(CaptionBurnMode.allCases),
                            title: { $0.title }
                        )
                        .disabled(!project.captions.enabled)
                    }
                    Text(
                        "烧录模式只影响导出 MP4；SRT 始终按主字幕随视频一起导出，章节文本不变。"
                    )
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(2)

                    Divider()
                        .overlay(StudioTheme.separatorLine)

                    HStack {
                        Text("字幕条目")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        Text("\(project.captionCues.count) 条")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        smallButton("在播放头添加") {
                            model.addCaptionAtPlayhead()
                        }
                    }
                    if !project.captionCues.isEmpty {
                        StudioSegmented(
                            selection: $captionViewMode,
                            options: Array(CaptionViewMode.allCases),
                            title: { $0.title }
                        )
                        .accessibilityLabel("字幕视图模式")
                    }

                    if project.captionCues.isEmpty {
                        Text(
                            "导入 SRT、先生成本机初稿，或在播放头添加一条字幕。"
                        )
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineSpacing(2)
                    } else if captionViewMode == .transcript {
                        transcriptProofreadView(project, activeCue: activeCue)
                    } else {
                        ScrollView {
                            VStack(spacing: StudioTheme.space3) {
                                ForEach(project.captionCues) { cue in
                                    captionRow(
                                        cue,
                                        isActive: cue.id == activeCue?.id,
                                        project: project
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }

            disclosureSection(
                .captionStyle,
                title: "样式",
                icon: "textformat",
                summary: String(
                    format: "字号 %.2f× · 背景 %.0f%%",
                    project.captions.fontScale,
                    project.captions.backgroundOpacity * 100
                )
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.space4) {
                    VStack(alignment: .leading, spacing: StudioTheme.space3) {
                        Text("样式预设")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(StudioTheme.textSecondary)
                        HStack(spacing: StudioTheme.space3) {
                            ForEach(CaptionStylePreset.allCases) {
                                preset in
                                Button {
                                    model.applyCaptionStylePreset(preset)
                                } label: {
                                    Text(preset.title)
                                        .font(.callout.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 25)
                                }
                                .buttonStyle(
                                    SecondaryActionButtonStyle(
                                        cornerRadius: StudioTheme.radiusS,
                                        isSelected: preset.matches(project.captions),
                                        transparentRest: true
                                    )
                                )
                            }
                        }
                    }
                    sliderBlock(
                        title: "字号",
                        value: String(
                            format: "%.2f×",
                            project.captions.fontScale
                        ),
                        binding: Binding(
                            get: { project.captions.fontScale },
                            set: { model.setCaptionFontScale($0) }
                        ),
                        range: 0.75 ... 2.5
                    )
                    sliderBlock(
                        title: "背景浓度",
                        value: String(
                            format: "%.0f%%",
                            project.captions.backgroundOpacity * 100
                        ),
                        binding: Binding(
                            get: { project.captions.backgroundOpacity },
                            set: { model.setCaptionBackgroundOpacity($0) }
                        ),
                        range: 0 ... 0.9
                    )
                }
            }

            disclosureSection(
                .captionSecondary,
                title: "第二语言字幕",
                icon: "globe.asia.australia",
                summary: project.secondaryCaptionCues.isEmpty
                    ? "未导入"
                    : "\(project.secondaryCaptionCues.count) 条"
            ) {
                secondaryCaptionControls(project)
            }

            disclosureSection(
                .captionGlossary,
                title: "术语表",
                icon: "character.book.closed",
                summary: model.glossaryEntries.isEmpty
                    ? "未设置"
                    : "\(model.glossaryEntries.count) 条"
            ) {
                glossaryControls(project)
            }

            disclosureSection(
                .captionChapters,
                title: "章节",
                icon: "list.number",
                summary: "\(chapters.count) 个"
            ) {
                VStack(alignment: .leading, spacing: StudioTheme.space3) {
                    HStack {
                        Text("\(chapters.count) 个章节")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        smallButton("导出章节") {
                            model.exportChapters()
                        }
                        .disabled(chapters.isEmpty)
                    }
                    Toggle(
                        "章节起始处显示标题卡（约 2 秒，样式跟随字幕预设）",
                        isOn: Binding(
                            get: { project.captions.chapterCardsEnabled },
                            set: { model.setChapterCardsEnabled($0) }
                        )
                    )
                    .font(.callout)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(StudioTheme.accent)
                    .disabled(chapters.isEmpty)

                    if chapters.isEmpty {
                        Text(
                            "章节从字幕自动合并；字幕积累到可读长度后会出现在这里。"
                        )
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineSpacing(2)
                    } else {
                        ScrollView {
                            VStack(spacing: StudioTheme.space2) {
                                ForEach(
                                    Array(chapters.enumerated()),
                                    id: \.offset
                                ) { index, chapter in
                                    Button {
                                        model.seek(to: chapter.start)
                                    } label: {
                                        HStack(spacing: StudioTheme.space3) {
                                            Text("\(index + 1)")
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(
                                                    StudioTheme.accent
                                                )
                                                .frame(width: 18)
                                            Text(
                                                formatDuration(
                                                    chapter.start,
                                                    precise: true
                                                )
                                            )
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(
                                                StudioTheme.textTertiary
                                            )
                                            .monospacedDigit()
                                            Text(chapter.title)
                                                .font(.callout)
                                                .foregroundStyle(
                                                    StudioTheme.textSecondary
                                                )
                                                .lineLimit(1)
                                            Spacer()
                                            Image(
                                                systemName: "arrow.right"
                                            )
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(
                                                StudioTheme.textTertiary
                                            )
                                        }
                                        .padding(.horizontal, StudioTheme.space3)
                                        .frame(height: 28)
                                        .background(
                                            StudioTheme.surfaceCanvas
                                        )
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 130)
                    }
                }
            }
        }
        .studioCard()
    }

    /// 字幕全文校对（第 1 层核心）：文稿式连续阅读视图。
    /// 编辑与跳转复用列表页同一组 model 方法（updateCaptionText /
    /// seek），保证字幕列表、SRT 导出、烧录预览、章节文本四处一致。
    private func transcriptProofreadView(
        _ project: StudioProject,
        activeCue: CaptionCue?
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            // 待应用的删除建议条（近似模式原地标注）
            if let pending = pendingTextCut {
                textCutSuggestionBar(pending)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: StudioTheme.space2) {
                        ForEach(project.captionCues) { cue in
                            transcriptRow(
                                cue,
                                isActive: cue.id == activeCue?.id
                            )
                            .id(cue.id)
                        }
                    }
                    .padding(.vertical, StudioTheme.space1)
                }
                .frame(maxHeight: 360)
                .onChange(of: model.currentTime) { _, time in
                    // 播放推进时跟随当前条滚动（仅在校对模式，静默滚动）
                    guard
                        let active = activeCue,
                        abs(active.start - time) < 0.5
                    else { return }
                    proxy.scrollTo(active.id, anchor: .center)
                }
            }
        }
    }

    /// 删除建议条——预计剪掉秒数 + 近似标注 + 应用/取消。
    private func textCutSuggestionBar(_ pending: PendingTextCut) -> some View {
        HStack(spacing: StudioTheme.space3) {
            Image(systemName: "scissors")
                .font(.callout)
                .foregroundStyle(StudioTheme.accent)
            Text(
                "将剪掉选区对应的 \(formatDuration(pending.removedDuration))"
                + (pending.isApproximate
                    ? "（按字数比例估算，可再手动微调）" : "")
            )
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            .lineSpacing(2)
            Spacer(minLength: StudioTheme.space2)
            Button("应用") {
                model.applyTextCut(
                    cutStart: pending.cutStart,
                    cutEnd: pending.cutEnd
                )
                pendingTextCut = nil
            }
            .buttonStyle(
                PrimaryActionButtonStyle(cornerRadius: StudioTheme.radiusS)
            )
            Button("取消") {
                pendingTextCut = nil
            }
            .buttonStyle(
                SecondaryActionButtonStyle(cornerRadius: StudioTheme.radiusS)
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(StudioTheme.space3)
        .background(StudioTheme.selectionTint)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
    }

    private func transcriptRow(
        _ cue: CaptionCue,
        isActive: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: StudioTheme.space3) {
            Button {
                model.seek(to: cue.start)
            } label: {
                Text(formatDuration(cue.start, precise: true))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(
                        isActive
                            ? StudioTheme.accent
                            : StudioTheme.textSecondary
                    )
            }
            .buttonStyle(GhostActionButtonStyle())
            .frame(width: 72, alignment: .leading)
            .help("跳到字幕开始")
            .accessibilityLabel("跳到字幕 \(formatDuration(cue.start, precise: true))")

            VStack(alignment: .leading, spacing: StudioTheme.space1) {
                TextField(
                    "字幕文本",
                    text: Binding(
                        get: { cue.text },
                        set: { model.updateCaptionText(cue.id, text: $0) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(isActive ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .lineLimit(1 ... 4)
                .padding(.horizontal, StudioTheme.space2)
                .padding(.vertical, StudioTheme.space1)
                .background(
                    isActive
                        ? StudioTheme.selectionTint
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
                // 回车 = 在光标处拆条（字幕是单条文本，换行
                // 无语义）。onSubmit 无光标偏移，从当前第一响应者的
                // NSTextField selectedRange 取。
                .onSubmit {
                    splitTranscriptAtCursor(cue)
                }
                // 清空即删条——updateCaptionText 走删条事务，
                // 这里给原地可撤销提示（复用 8s 自动消失 toast）。
                .onChange(of: cue.text) { oldText, newText in
                    if !oldText.isEmpty,
                        newText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    {
                        model.errorMessage = "已删除这条字幕 · 按 ⌘Z 可还原"
                    }
                }

                HStack(spacing: StudioTheme.space2) {
                    Text("\(cue.text.count) 字")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(StudioTheme.textSecondary)
                    if cue.text.count >= 500 {
                        // 500 字符截断可见（R2-2 会上定案：不放开上限）
                        Text("已达 500 字上限，超出部分不会被保存")
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.recText)
                    }
                    // 选中一段文本后点它，出「删除选区对应片段」
                    // 建议（选区读取沿用 R2-2 的第一响应者机制——SwiftUI
                    // 不暴露 TextField 选区）。
                    Button {
                        requestTextCut(cue)
                    } label: {
                        Label("删除选区片段", systemImage: "scissors")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(GhostActionButtonStyle())
                    .help("先在文本里选中一段，再点它删除对应的音视频区间")
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, StudioTheme.space1)
    }

    /// 读当前第一响应者选区 → 查询删除建议 → 挂起待应用条。
    private func requestTextCut(_ cue: CaptionCue) {
        guard
            let textField = NSApp.keyWindow?.firstResponder as? NSTextField,
            let editor = textField.currentEditor()
        else {
            model.errorMessage = "请先在字幕文本里选中一段，再点“删除选区片段”。"
            return
        }
        let selection = editor.selectedRange
        switch model.textCutSuggestion(
            for: cue.id,
            selection: selection.lowerBound ..< selection.upperBound
        ) {
        case .success(let suggestion):
            pendingTextCut = PendingTextCut(
                captionID: cue.id,
                cutStart: suggestion.cutStart,
                cutEnd: suggestion.cutEnd,
                isApproximate: suggestion.isApproximate
            )
        case .failure(let rejection):
            switch rejection {
            case .emptySelection:
                model.errorMessage =
                    "请先在字幕文本里选中一段（整条选中请用清空删除整条）。"
            case .tooShort:
                model.errorMessage = "选区太短，删除后会留下过短片段。"
            case .remainderTooShort:
                model.errorMessage = "删除后剩下的部分太短，换一段选区试试。"
            }
        }
    }

    /// 回车拆条。从当前第一响应者的 NSTextField 取光标位置；
    /// 取不到（或光标在两端）时不动。成功拆条给原地可撤销提示
    /// （复用 8 秒自动消失 toast）。
    private func splitTranscriptAtCursor(_ cue: CaptionCue) {
        guard
            let textField = NSApp.keyWindow?.firstResponder as? NSTextField,
            let editor = textField.currentEditor()
        else {
            return
        }
        if model.splitCaption(cue.id, atTextOffset: editor.selectedRange.location) {
            model.errorMessage = "已拆分为两条 · 按 ⌘Z 可完整还原"
        }
    }

    private func captionRow(
        _ cue: CaptionCue,
        isActive: Bool,
        project: StudioProject
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space3) {
                Button {
                    model.seek(to: cue.start)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(
                            isActive
                                ? StudioTheme.accent
                                : StudioTheme.textSecondary
                        )
                }
                .buttonStyle(IconButtonStyle())
                .help("跳到字幕开始")
                .accessibilityLabel(
                    "跳到字幕 \(formatDuration(cue.start, precise: true))"
                )

                captionTimeField(
                    label: "开始",
                    value: Binding(
                        get: { cue.start },
                        set: {
                            model.updateCaptionStart($0, for: cue.id)
                        }
                    ),
                    range: 0 ... max(0, project.trimDuration - 0.05)
                )
                Text("→")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                captionTimeField(
                    label: "结束",
                    value: Binding(
                        get: { cue.end },
                        set: {
                            model.updateCaptionEnd($0, for: cue.id)
                        }
                    ),
                    range: 0.05 ... max(0.05, project.trimDuration)
                )
                Spacer()
                Button {
                    model.deleteCaption(cue.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .buttonStyle(IconButtonStyle())
                .help("删除这条字幕")
                .accessibilityLabel("删除这条字幕")
            }

            TextField(
                "字幕文本",
                text: Binding(
                    get: { cue.text },
                    set: { model.updateCaptionText(cue.id, text: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(StudioTheme.textPrimary)
            .lineLimit(1 ... 3)
            .padding(.horizontal, StudioTheme.space3)
            .padding(.vertical, StudioTheme.space2)
            .background(StudioTheme.surfacePanel)
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                    .stroke(
                        isActive
                            ? StudioTheme.accent.opacity(0.6)
                            : StudioTheme.separatorLineStrong,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
        }
        .padding(StudioTheme.space3)
        .background(
            isActive
                ? StudioTheme.selectionTint
                : StudioTheme.surfaceCanvas
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
    }

    private func captionTimeField(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        TextField(
            "",
            value: Binding(
                get: { value.wrappedValue },
                set: {
                    value.wrappedValue = min(
                        range.upperBound,
                        max(range.lowerBound, $0)
                    )
                }
            ),
            format: .number.precision(.fractionLength(2))
        )
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .font(.callout.monospacedDigit())
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, StudioTheme.space2)
        .frame(width: 54, height: 24)
        .background(StudioTheme.surfacePanel)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
        .accessibilityLabel("字幕\(label)时间，秒")
    }

    private func exportCard(_ project: StudioProject) -> some View {
        let outputSize = model.exportResolution.outputSize(for: project)
        return VStack(alignment: .leading, spacing: StudioTheme.space4) {
            sectionHeader("导出", icon: "square.and.arrow.up")
            HStack {
                Text(
                    "\(Int(outputSize.width)) × \(Int(outputSize.height))"
                )
                Spacer()
                Text(
                    "\(model.exportFrameRate) fps · \(model.exportCodec.title)"
                )
            }
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)

            fieldBlock("预设") {
                Picker(
                    "",
                    selection: Binding(
                        get: { model.selectedExportPresetID },
                        set: { model.applyExportPreset($0) }
                    )
                ) {
                    ForEach(ExportPreset.all) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(StudioTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(
                ExportPreset.preset(id: model.selectedExportPresetID)?.note ?? ""
            )
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            .lineSpacing(2)

            fieldBlock("导出分辨率") {
                StudioSegmented(
                    selection: $model.exportResolution,
                    options: Array(ExportResolution.allCases),
                    title: { $0.title }
                )
            }
            fieldBlock("帧率") {
                StudioSegmented(
                    selection: $model.exportFrameRate,
                    options: [30, 60],
                    title: { "\($0) fps" }
                )
            }
            fieldBlock("编码") {
                StudioSegmented(
                    selection: $model.exportCodec,
                    options: Array(ExportCodec.allCases),
                    title: { $0.title }
                )
            }
            Text(model.exportCodec.detail)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)

            HStack {
                Text("成片时长")
                Spacer()
                Text(formatDuration(project.trimDuration, precise: true))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            HStack {
                Text("声音")
                Spacer()
                Text(
                    StudioProject.audioTrackSummary(
                        mic: project.microphoneFile,
                        system: project.systemAudioFile
                    )
                )
                .foregroundStyle(StudioTheme.textSecondary)
            }
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            HStack {
                Text("字幕")
                Spacer()
                Text(
                    project.captionCues.isEmpty
                        ? "无"
                        : project.captions.burnIn
                            ? "\(project.captionCues.count) 条 · 烧录 + SRT"
                            : "\(project.captionCues.count) 条 · 仅 SRT"
                )
                .foregroundStyle(StudioTheme.textSecondary)
            }
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)

            if let progress = model.exportProgress {
                VStack(alignment: .leading, spacing: StudioTheme.space3) {
                    ProgressView(value: progress)
                        .tint(StudioTheme.playbackGold)
                    HStack {
                        Text(model.exportMessage ?? "正在导出…")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        if progress < 1 {
                            Button("取消") {
                                model.cancelExport()
                            }
                            .buttonStyle(GhostActionButtonStyle())
                            .font(.callout.weight(.medium))
                            .foregroundStyle(StudioTheme.textSecondary)
                        }
                    }
                }
            } else {
                exportModeControls(project)

                Button {
                    model.exportProject()
                } label: {
                    Text(exportMainButtonTitle(project))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(
                    model.exportMode == .markerSegments
                        && model.markerSegmentPlan(for: project)
                            .segments.isEmpty
                )
                .help(
                    model.exportMode == .markerSegments
                        && model.markerSegmentPlan(for: project)
                            .segments.isEmpty
                        ? "先在下方勾选标记；标记可在剪辑页 › 录制标记添加"
                        : ""
                )

                // GIF 折进独立 disclosure（默认收起）——导出面板按
                // 「常用直出、次要折叠」排层级，主 MP4 链路不再被 GIF
                // 控件区拉长。
                InspectorDisclosureSection(
                    title: "GIF 导出",
                    icon: "photo.on.rectangle.angled",
                    summary: model.gifSizePreset.title
                        + " · 15 fps · 最长边 \(Int(model.gifSizePreset.maximumWidth))",
                    isExpanded: $gifSectionExpanded
                ) {
                    gifExportControls(project)
                }
            }

        }
        .studioCard()
    }

    /// 卡内主按钮与页头导出按钮共用同一文案（导出方式三选一）。
    private func exportMainButtonTitle(_ project: StudioProject) -> String {
        if model.exportMode == .markerSegments {
            let segments = model.markerSegmentPlan(for: project).segments
            return segments.isEmpty
                ? "按标记分段导出"
                : "导出 \(segments.count) 段 MP4"
        }
        return project.captionCues.isEmpty ? "导出为 MP4" : "导出 MP4 与 SRT"
    }

    /// 导出方式三选一——整片 / 入出点 / 按标记分段（互斥），
    /// 页头导出按钮与卡内主按钮共用同一行为。
    private func exportModeControls(
        _ project: StudioProject
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            fieldBlock("导出方式") {
                StudioSegmented(
                    selection: $model.exportMode,
                    options: Array(StudioModel.ExportMode.allCases),
                    title: { $0.title }
                )
            }
            switch model.exportMode {
            case .full:
                EmptyView()
            case .range:
                exportRangeControls(project)
            case .markerSegments:
                markerSegmentControls(project)
            }
        }
    }

    /// 按标记分段确认区——标记勾选（默认全选）、段清单（段数 /
    /// 标记名 / 时间段 / 文件名）、跳过清单、基名与目标文件夹。
    private func markerSegmentControls(
        _ project: StudioProject
    ) -> some View {
        let plan = model.markerSegmentPlan(for: project)
        return VStack(alignment: .leading, spacing: StudioTheme.space2) {
            if project.markers.isEmpty {
                Text("暂无标记：录制时按 M，或在剪辑页 › 录制标记添加后再分段导出。")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(2)
            } else {
                ForEach(project.markers) { marker in
                    Toggle(isOn: markerSelectionBinding(marker.id)) {
                        HStack {
                            Text(
                                marker.name.isEmpty
                                    ? "未命名标记" : marker.name
                            )
                            Spacer()
                            Text(markerTimeLabel(project, marker))
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                    }
                    .font(.callout)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                }
                ForEach(Array(plan.segments.enumerated()), id: \.element.id) {
                    segment in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            "段 \(segment.offset + 1) · \(segment.element.markerName) · \(formatDuration(segment.element.start, precise: true)) – \(formatDuration(segment.element.end, precise: true)) · \(formatDuration(segment.element.end - segment.element.start, precise: true))"
                        )
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                        Text(segment.element.fileName)
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                ForEach(plan.skipped) { skipped in
                    Text("跳过 · \(skipped.markerName)：\(skipped.reason)")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                Text(
                    "分段从每个标记开始，到下一标记或片尾；首个标记之前的内容不在分段内（可在 0 处补一个标记包含它）。"
                )
                .font(.subheadline)
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(2)
                HStack(spacing: StudioTheme.space3) {
                    Text("文件名前缀")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                    TextField(
                        "前缀",
                        text: $model.markerSegmentBaseName,
                        prompt: Text(project.name)
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
                HStack(spacing: StudioTheme.space3) {
                    Text(
                        model.markerSegmentFolder?.path
                            ?? "保存到上次导出目录（或工程目录）"
                    )
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    Spacer()
                    smallButton("选择文件夹") {
                        model.chooseMarkerSegmentFolder()
                    }
                }
                if let failed = model.markerSegmentFailedIndex,
                   model.markerSegmentResume != nil
                {
                    smallButton("重试剩余段（从第 \(failed + 1) 段）") {
                        model.retryMarkerSegmentExport()
                    }
                }
            }
        }
    }

    /// 标记勾选行的成片时间标签；落在已剪除区间的标记注明「已剪除」。
    private func markerTimeLabel(
        _ project: StudioProject,
        _ marker: RecordingMarker
    ) -> String {
        guard
            let output = project.outputTime(forSourceTime: marker.sourceTime)
        else {
            return "已剪除"
        }
        return formatDuration(output, precise: true)
    }

    private func markerSelectionBinding(
        _ id: UUID
    ) -> Binding<Bool> {
        Binding(
            get: { !model.markerSegmentExcludedIDs.contains(id) },
            set: { selected in
                if selected {
                    model.markerSegmentExcludedIDs.remove(id)
                } else {
                    model.markerSegmentExcludedIDs.insert(id)
                }
            }
        )
    }

    /// 1.2 导出区间：非破坏地只导出 [入点, 出点]（复用剪切事务做副本）。
    /// 仅在导出方式 = 入出点时由 exportModeControls 展示。
    private func exportRangeControls(
        _ project: StudioProject
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space3) {
                smallButton(
                    "入点=播放头"
                        + (model.exportInPoint.map {
                            "（\(formatDuration($0, precise: true))）"
                        } ?? "")
                ) {
                    model.setExportInPointToPlayhead()
                }
                smallButton(
                    "出点=播放头"
                        + (model.exportOutPoint.map {
                            "（\(formatDuration($0, precise: true))）"
                        } ?? "")
                ) {
                    model.setExportOutPointToPlayhead()
                }
                Spacer()
                smallButton("清除") {
                    model.clearExportRange()
                }
            }
            Text(
                model.exportInPoint != nil && model.exportOutPoint != nil
                    ? "将导出 \(formatDuration(model.exportInPoint!, precise: true)) – \(formatDuration(model.exportOutPoint!, precise: true))；字幕 / 缩放 / 布局 / 打码按成片时间裁剪平移，工程数据不变。"
                    : "把播放头移到想要的起点，点“入点=播放头”；再移到终点，点“出点=播放头”。"
            )
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            .lineSpacing(2)
        }
    }

    /// GIF 导出：15fps；尺寸档位 小 / 中 / 大 → 最长边
    /// 360 / 720 / 1080（默认中档 720），体积估算随档位实时刷新，
    /// 长片给警告。
    private func gifExportControls(
        _ project: StudioProject
    ) -> some View {
        let estimate = GifExporter.estimate(
            for: project,
            outputSize: project.canvasOutputSize,
            maximumWidth: model.gifSizePreset.maximumWidth
        )
        return VStack(alignment: .leading, spacing: StudioTheme.space2) {
            HStack(spacing: StudioTheme.space3) {
                Text("尺寸")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                StudioSegmented(
                    selection: $model.gifSizePreset,
                    options: Array(GifSizePreset.allCases),
                    title: { "\($0.title) \(Int($0.maximumWidth))" }
                )
                .accessibilityLabel("GIF 尺寸档位")
            }
            Button {
                model.exportGif()
            } label: {
                Text(
                    "导出 GIF（15 fps · 最长边 \(Int(model.gifSizePreset.maximumWidth))）"
                )
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }
            .buttonStyle(SecondaryActionButtonStyle(cornerRadius: StudioTheme.radiusS))
            // P5：导出进行中禁用 GIF 按钮（此前点击被 guard 静默吞掉，
            // 看起来像「点了没反应」）。
            .disabled(model.exportProgress != nil)
            .help(
                model.exportProgress != nil
                    ? "导出进行中，等它完成或先取消"
                    : ""
            )
            Text(
                "预计约 \(estimate.frameCount) 帧 · ≈\(formatFileSize(estimate.estimatedBytes))"
            )
            .font(.callout)
            .foregroundStyle(
                estimate.isLong ? StudioTheme.textSecondary : StudioTheme.textTertiary
            )
            .lineSpacing(2)
        }
    }

    private func clickRow(
        _ click: ClickEvent,
        project: StudioProject
    ) -> some View {
        let outputTime = project.outputTime(forSourceTime: click.time)
        return HStack(spacing: StudioTheme.space3) {
            Button {
                if let outputTime {
                    model.seek(to: outputTime)
                }
            } label: {
                HStack(spacing: StudioTheme.space3) {
                    Image(systemName: "play.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(
                            click.enabled ? StudioTheme.accent : StudioTheme.textTertiary
                        )
                    Text(
                        outputTime.map {
                            formatDuration($0, precise: true)
                        } ?? "已剪除"
                    )
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(
                            outputTime == nil
                                ? StudioTheme.textTertiary
                                : StudioTheme.textSecondary
                        )
                        .monospacedDigit()
                    Text(
                        String(
                            format: "%.0f%%, %.0f%%",
                            click.x * 100,
                            click.y * 100
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(outputTime == nil)
            Spacer()
            Button {
                model.toggleClick(click.id)
            } label: {
                Image(
                    systemName: click.enabled
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.callout)
                .foregroundStyle(
                    click.enabled ? StudioTheme.accent : StudioTheme.textTertiary
                )
            }
            .buttonStyle(IconButtonStyle())
        }
        .padding(.horizontal, StudioTheme.space3)
        .frame(height: 27)
        .background(StudioTheme.surfaceCanvas)
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
    }

    private func rateLabel(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.001 {
            return "\(Int(rate))×"
        }
        return String(format: "%.2g×", rate)
    }

    private func fieldBlock<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(StudioTheme.textSecondary)
            content()
        }
    }

    private func sliderBlock(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Text(value)
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
                    .monospacedDigit()
            }
            StudioSlider(value: binding, range: range)
        }
    }

    private func percentField(
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        TextField(
            "",
            value: Binding(
                get: {
                    value.wrappedValue * 100
                },
                set: { entered in
                    let fraction = entered / 100
                    value.wrappedValue = min(
                        range.upperBound,
                        max(range.lowerBound, fraction)
                    )
                }
            ),
            format: .number.precision(.fractionLength(0))
        )
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .font(.callout.weight(.medium).monospacedDigit())
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, StudioTheme.space3)
        .frame(height: 27)
        .background(StudioTheme.surfaceCanvas)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: StudioTheme.space2) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(StudioTheme.textPrimary)
        }
    }

    /// 描边次按钮（§5.1）：surfacePanel 底 + separatorLine 描边，hover/pressed
    /// 状态层与 disabled 38% 由 SecondaryActionButtonStyle 统一承担。
    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, StudioTheme.space3)
                .frame(height: 26)
        }
        .buttonStyle(SecondaryActionButtonStyle(cornerRadius: StudioTheme.radiusS))
    }

    private func navigateToTimelineTrack(_ track: TimelineTrack) {
        let destination = track.inspectorDestination
        activeTimelineTrack = track
        expandedSections.insert(destination.section)
        tab = destination.tab
        inspectorScrollRequest = InspectorScrollRequest(
            section: destination.section
        )
    }

    private func disclosureSection<Content: View>(
        _ section: InspectorSection,
        title: String,
        icon: String,
        summary: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        InspectorDisclosureSection(
            title: title,
            icon: icon,
            summary: summary,
            isExpanded: Binding(
                get: { expandedSections.contains(section) },
                set: { isExpanded in
                    if isExpanded {
                        expandedSections.insert(section)
                    } else {
                        expandedSections.remove(section)
                    }
                }
            ),
            content: content
        )
        .id(section.rawValue)
    }

    private func trimLabel(_ title: String, value: Double, color: Color) -> some View {
        HStack(spacing: StudioTheme.space2) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(title)
                .foregroundStyle(StudioTheme.textSecondary)
            Text(formatDuration(value, precise: true))
                .foregroundStyle(StudioTheme.textSecondary)
                .monospacedDigit()
        }
        .font(.callout.monospacedDigit())
    }
}
