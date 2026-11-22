import AniseRecorderCore
import SwiftUI

private enum TimelineTrimEdge {
    case start
    case end
}

private struct ClipTrimDrag {
    let clipID: UUID
    let edge: TimelineTrimEdge
    let sourceValue: Double
    let playbackRate: Double
    let timelineDuration: Double
}

private struct ZoomRegionDrag {
    let regionID: UUID
    let start: Double
    let timelineDuration: Double
}

private struct CameraSegmentDrag {
    let segmentID: UUID
    let start: Double
    let timelineDuration: Double
}

private struct RedactionRegionDrag {
    let regionID: UUID
    let start: Double
    let timelineDuration: Double
}

struct EditorTimelineView: View {
    let project: StudioProject
    let currentTime: Double
    @Binding var selectedClipID: UUID?
    var activeTrack: TimelineTrack?
    let onSelectTrack: (TimelineTrack) -> Void
    var onSelectOverlayClip: ((UUID) -> Void)?
    var selectedOverlayClipID: UUID?
    @State private var microphoneWaveform: [CGFloat] = []
    @State private var systemWaveform: [CGFloat] = []
    @State private var trimDrag: ClipTrimDrag?
    @State private var zoomRegionDrag: ZoomRegionDrag?
    @State private var cameraSegmentDrag: CameraSegmentDrag?
    @State private var redactionDrag: RedactionRegionDrag?
    @State private var hoveredTrack: TimelineTrack?
    @FocusState private var focusedTrack: TimelineTrack?
    let onSeek: (Double) -> Void
    let onScrubbingChanged: (Bool) -> Void
    let onSplit: () -> Void
    let onDelete: () -> Void
    let onTrimClipStart: (UUID, Double) -> Void
    let onTrimClipEnd: (UUID, Double) -> Void
    let onMoveZoomRegion: (UUID, Double) -> Void
    let onMoveCameraSegment: (UUID, Double) -> Void
    let onMoveRedactionRegion: (UUID, Double) -> Void
    var smartCutCandidates: [SmartCutCandidate] = []
    var smartCutSelectedIndices: Set<Int> = []
    var onSelectSmartCutCandidate: (Int) -> Void = { _ in }
    @State private var hoverCandidateIndex: Int?

    private let headerWidth: CGFloat = 58
    private let rulerHeight: CGFloat = 22
    private let trackGap: CGFloat = 4
    private let videoHeight: CGFloat = 42
    private let cameraHeight: CGFloat = 24
    private let zoomHeight: CGFloat = 22
    private let audioHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space3) {
                Text("时间线")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Button {
                    onSplit()
                } label: {
                    Label("在播放头切分", systemImage: "scissors")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .buttonStyle(GhostActionButtonStyle())
                .help("在播放头切分视频片段")

                Button {
                    onDelete()
                } label: {
                    Label("删除片段", systemImage: "trash")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(
                            selectedClipID == nil
                                || project.timeline.clips.count <= 1
                                ? StudioTheme.textTertiary
                                : StudioTheme.textSecondary
                        )
                }
                .buttonStyle(GhostActionButtonStyle())
                .disabled(
                    selectedClipID == nil
                        || project.timeline.clips.count <= 1
                )
                .help("删除选中的视频片段，后续片段自动前移")
            }
            .padding(.horizontal, StudioTheme.space1)

            GeometryReader { geometry in
                Canvas { context, size in
                    draw(
                        context: &context,
                        size: size
                    )
                }
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    trackHeaderButtons
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverCandidateIndex = smartCutCandidateHit(
                            at: location,
                            size: geometry.size
                        )
                    case .ended:
                        hoverCandidateIndex = nil
                    @unknown default:
                        break
                    }
                }
                .overlay(alignment: .top) {
                    if
                        let index = hoverCandidateIndex,
                        smartCutCandidates.indices.contains(index)
                    {
                        Text(tooltipText(smartCutCandidates[index]))
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textPrimary)
                            .padding(.horizontal, StudioTheme.space3)
                            .padding(.vertical, StudioTheme.space2)
                            .background(StudioTheme.surfaceRaised.opacity(0.96))
                            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
                            .overlay(
                                RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                                    .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
                            )
                            .padding(.top, rulerHeight + 2)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onScrubbingChanged(true)
                            if trimDrag == nil {
                                trimDrag = trimHit(
                                    at: value.startLocation,
                                    size: geometry.size
                                )
                            }
                            if trimDrag == nil, cameraSegmentDrag == nil {
                                cameraSegmentDrag = cameraSegmentHit(
                                    at: value.startLocation,
                                    size: geometry.size
                                )
                            }
                            if
                                trimDrag == nil,
                                cameraSegmentDrag == nil,
                                zoomRegionDrag == nil,
                                redactionDrag == nil
                            {
                                zoomRegionDrag = zoomRegionHit(
                                    at: value.startLocation,
                                    size: geometry.size
                                )
                            }
                            if
                                trimDrag == nil,
                                cameraSegmentDrag == nil,
                                zoomRegionDrag == nil,
                                redactionDrag == nil
                            {
                                redactionDrag = redactionHit(
                                    at: value.startLocation,
                                    size: geometry.size
                                )
                            }
                            if trimDrag == nil, cameraSegmentDrag == nil,
                                zoomRegionDrag == nil, redactionDrag == nil,
                                let hit = overlayClipHit(
                                    at: value.startLocation,
                                    size: geometry.size
                                )
                            {
                                onSelectOverlayClip?(hit)
                            }
                            if let trimDrag {
                                updateTrim(
                                    trimDrag,
                                    translation: value.translation,
                                    tracksWidth: max(
                                        1,
                                        geometry.size.width - headerWidth
                                    )
                                )
                                return
                            }
                            if let cameraSegmentDrag {
                                updateCameraSegmentDrag(
                                    cameraSegmentDrag,
                                    translation: value.translation,
                                    tracksWidth: max(
                                        1,
                                        geometry.size.width - headerWidth
                                    )
                                )
                                return
                            }
                            if let zoomRegionDrag {
                                updateZoomRegionDrag(
                                    zoomRegionDrag,
                                    translation: value.translation,
                                    tracksWidth: max(
                                        1,
                                        geometry.size.width - headerWidth
                                    )
                                )
                                return
                            }
                            if let redactionDrag {
                                updateRedactionDrag(
                                    redactionDrag,
                                    translation: value.translation,
                                    tracksWidth: max(
                                        1,
                                        geometry.size.width - headerWidth
                                    )
                                )
                                return
                            }
                            selectClipIfNeeded(
                                at: value.location,
                                size: geometry.size
                            )
                            onSeek(
                                time(
                                    at: value.location.x,
                                    size: geometry.size
                                )
                            )
                        }
                        .onEnded { value in
                            if
                                trimDrag != nil
                                    || cameraSegmentDrag != nil
                                    || zoomRegionDrag != nil
                                    || redactionDrag != nil
                            {
                                trimDrag = nil
                                cameraSegmentDrag = nil
                                zoomRegionDrag = nil
                                redactionDrag = nil
                                onScrubbingChanged(false)
                                return
                            }
                            // 原地点击候选区 = 选中并跳到删除区间前 1 秒。
                            if
                                abs(value.translation.width) < 3,
                                let index = smartCutCandidateHit(
                                    at: value.location,
                                    size: geometry.size
                                )
                            {
                                hoverCandidateIndex = nil
                                onScrubbingChanged(false)
                                onSelectSmartCutCandidate(index)
                                return
                            }
                            selectClipIfNeeded(
                                at: value.location,
                                size: geometry.size
                            )
                            onSeek(
                                time(
                                    at: value.location.x,
                                    size: geometry.size
                                )
                            )
                            onScrubbingChanged(false)
                        }
                )
            }
            .frame(height: timelineHeight)
        }
        .padding(StudioTheme.space4)
        .background(StudioTheme.surfacePanel.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusL)
                .stroke(StudioTheme.separatorLine, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusL))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("编辑时间线")
        .accessibilityValue(
            "\(project.timeline.clips.count) 个视频片段，\(formatDuration(currentTime, precise: true)) / \(formatDuration(project.trimDuration, precise: true))"
        )
        .task(id: waveformTaskID) {
            await loadWaveforms()
        }
    }

    private var summary: String {
        let clipCount = project.timeline.clips.count
        let cameraCount = project.cameraSegments.count
        let zoomCount = project.zoomRegions.count
        let markerCount = project.markers.count
        return "\(clipCount) 视频段 · \(cameraCount) 布局段 · \(zoomCount) 缩放区 · \(markerCount) 标记 · 成片 \(formatDuration(project.trimDuration))"
    }

    private var trackHeaderButtons: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: rulerHeight + trackGap)
            trackHeaderButton(.video, height: videoHeight)
            Color.clear
                .frame(height: trackGap)
            trackHeaderButton(.camera, height: cameraHeight)
            Color.clear
                .frame(height: trackGap)
            trackHeaderButton(.zoom, height: zoomHeight)
            Color.clear
                .frame(height: trackGap)
            trackHeaderButton(.audio, height: audioHeight)
        }
        .frame(width: headerWidth, alignment: .topLeading)
    }

    private func trackHeaderButton(
        _ track: TimelineTrack,
        height: CGFloat
    ) -> some View {
        Button {
            onSelectTrack(track)
        } label: {
            Color.clear
                .frame(width: headerWidth, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedTrack, equals: track)
        .onHover { hovering in
            hoveredTrack = hovering ? track : (hoveredTrack == track ? nil : hoveredTrack)
        }
        .help("打开\(track.title)属性")
        .accessibilityLabel("\(track.title)轨道属性")
        .accessibilityHint("切换到右侧对应设置")
    }

    private var waveformTaskID: String {
        [
            project.id.uuidString,
            project.microphoneURL?.path ?? "",
            project.systemAudioURL?.path ?? ""
        ].joined(separator: "|")
    }

    private var overlayHeight: CGFloat { 20 }

    private var timelineHeight: CGFloat {
        let overlay = project.overlayClips.isEmpty
            ? 0
            : overlayHeight + trackGap
        return rulerHeight
            + videoHeight
            + cameraHeight
            + zoomHeight
            + audioHeight
            + overlay
            + trackGap * 4
    }

    private func draw(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard size.width > headerWidth, project.trimDuration > 0 else {
            return
        }
        let tracksWidth = size.width - headerWidth
        let rulerTop: CGFloat = 0
        let videoTop = rulerTop + rulerHeight + trackGap
        let cameraTop = videoTop + videoHeight + trackGap
        let zoomTop = cameraTop + cameraHeight + trackGap
        let audioTop = zoomTop + zoomHeight + trackGap
        let showsOverlayLane = !project.overlayClips.isEmpty
        let overlayTop = audioTop + audioHeight + trackGap

        drawRuler(
            context: &context,
            size: size,
            tracksWidth: tracksWidth
        )
        drawMarkers(
            context: &context,
            tracksWidth: tracksWidth
        )
        drawTrackBackground(
            context: &context,
            top: videoTop,
            height: videoHeight,
            size: size
        )
        drawTrackBackground(
            context: &context,
            top: cameraTop,
            height: cameraHeight,
            size: size
        )
        drawTrackBackground(
            context: &context,
            top: zoomTop,
            height: zoomHeight,
            size: size
        )
        drawTrackBackground(
            context: &context,
            top: audioTop,
            height: audioHeight,
            size: size
        )
        if showsOverlayLane {
            drawTrackBackground(
                context: &context,
                top: overlayTop,
                height: overlayHeight,
                size: size
            )
        }

        drawTrackLabel(
            context: &context,
            title: "视频",
            top: videoTop,
            height: videoHeight,
            track: .video
        )
        drawTrackLabel(
            context: &context,
            title: "摄像头",
            top: cameraTop,
            height: cameraHeight,
            track: .camera
        )
        drawTrackLabel(
            context: &context,
            title: "缩放",
            top: zoomTop,
            height: zoomHeight,
            track: .zoom
        )
        drawTrackLabel(
            context: &context,
            title: "声音",
            top: audioTop,
            height: audioHeight,
            track: .audio
        )
        if showsOverlayLane {
            drawTrackLabel(
                context: &context,
                title: "叠加",
                top: overlayTop,
                height: overlayHeight,
                track: .overlay
            )
        }

        drawVideoClips(
            context: &context,
            top: videoTop,
            tracksWidth: tracksWidth
        )
        drawSmartCutCandidates(
            context: &context,
            top: videoTop,
            tracksWidth: tracksWidth
        )
        drawCameraTrack(
            context: &context,
            top: cameraTop,
            tracksWidth: tracksWidth
        )
        drawZoomTrack(
            context: &context,
            top: zoomTop,
            tracksWidth: tracksWidth
        )
        drawAudioTrack(
            context: &context,
            top: audioTop,
            tracksWidth: tracksWidth
        )
        if showsOverlayLane {
            drawOverlayTrack(
                context: &context,
                top: overlayTop,
                tracksWidth: tracksWidth
            )
        }
        drawPlayhead(
            context: &context,
            height: videoTop + videoHeight + 2,
            tracksWidth: tracksWidth
        )
    }

    /// 精剪候选区：淡色带 = 检测到的停顿，深色带 = 建议删除窗口；
    /// 可删除建议用警告琥珀，保护类候选用灰色（映射表 §9.2：删除建议
    /// warning 语义，与金黄播放语义不混用）。
    private func drawSmartCutCandidates(
        context: inout GraphicsContext,
        top: CGFloat,
        tracksWidth: CGFloat
    ) {
        for (index, candidate) in smartCutCandidates.enumerated() {
            let selected = smartCutSelectedIndices.contains(index)
            let protectedKind = candidate.kind.isProtected
            let baseColor = protectedKind ? StudioTheme.textTertiary : StudioTheme.accent
            let bandX = headerWidth
                + xPosition(candidate.start, width: tracksWidth)
            let bandEnd = headerWidth
                + xPosition(candidate.end, width: tracksWidth)
            let bandRect = CGRect(
                x: bandX,
                y: top + 3,
                width: max(2, bandEnd - bandX),
                height: videoHeight - 6
            )
            context.fill(
                Path(roundedRect: bandRect, cornerRadius: StudioTheme.radiusS),
                with: .color(
                    baseColor.opacity(
                        protectedKind
                            ? 0.16
                            : (selected ? 0.28 : 0.16)
                    )
                )
            )
            let cutX = headerWidth
                + xPosition(candidate.cutStart, width: tracksWidth)
            let cutEnd = headerWidth
                + xPosition(candidate.cutEnd, width: tracksWidth)
            let cutRect = CGRect(
                x: cutX,
                y: top + 3,
                width: max(2, cutEnd - cutX),
                height: videoHeight - 6
            )
            context.fill(
                Path(roundedRect: cutRect, cornerRadius: StudioTheme.radiusS),
                with: .color(
                    baseColor.opacity(
                        protectedKind
                            ? 0.32
                            : (selected ? 0.52 : 0.38)
                    )
                )
            )
            if hoverCandidateIndex == index {
                context.stroke(
                    Path(roundedRect: bandRect, cornerRadius: StudioTheme.radiusS),
                    with: .color(StudioTheme.textPrimary.opacity(0.75)),
                    lineWidth: 1
                )
            }
        }
    }

    private func smartCutCandidateHit(
        at location: CGPoint,
        size: CGSize
    ) -> Int? {
        guard !smartCutCandidates.isEmpty else { return nil }
        let videoTop = rulerHeight + trackGap
        guard
            location.y >= videoTop,
            location.y <= videoTop + videoHeight
        else {
            return nil
        }
        let value = time(at: location.x, size: size)
        return smartCutCandidates.firstIndex {
            $0.start <= value && value <= $0.end
        }
    }

    private func tooltipText(_ candidate: SmartCutCandidate) -> String {
        "停顿 " + String(format: "%.1f", candidate.pauseDuration)
            + " 秒，预计保留 "
            + String(format: "%.1f", candidate.pauseDuration - candidate.savedDuration)
            + " 秒，可节省 "
            + String(format: "%.1f", candidate.savedDuration) + " 秒"
    }

    private func drawRuler(
        context: inout GraphicsContext,
        size: CGSize,
        tracksWidth: CGFloat
    ) {
        for index in 0 ... 4 {
            let fraction = Double(index) / 4
            let x = headerWidth + tracksWidth * fraction
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerHeight - 5))
            tick.addLine(to: CGPoint(x: x, y: rulerHeight))
            context.stroke(
                tick,
                with: .color(StudioTheme.separatorLine),
                lineWidth: 1
            )
            let label = Text(formatDuration(project.trimDuration * fraction))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(StudioTheme.textSecondary)
            context.draw(
                label,
                at: CGPoint(
                    x: min(
                        size.width - 16,
                        max(headerWidth + 10, x)
                    ),
                    y: 7
                ),
                anchor: .center
            )
        }
    }

    private func drawMarkers(
        context: inout GraphicsContext,
        tracksWidth: CGFloat
    ) {
        for marker in project.markers {
            guard
                let outputTime = project.outputTime(
                    forSourceTime: marker.sourceTime
                )
            else {
                continue
            }
            let x = headerWidth + xPosition(outputTime, width: tracksWidth)
            var flag = Path()
            flag.move(to: CGPoint(x: x - 4, y: rulerHeight - 3))
            flag.addLine(to: CGPoint(x: x, y: rulerHeight - 10))
            flag.addLine(to: CGPoint(x: x + 4, y: rulerHeight - 3))
            flag.closeSubpath()
            context.fill(flag, with: .color(StudioTheme.accent))
        }
    }

    private func drawTrackBackground(
        context: inout GraphicsContext,
        top: CGFloat,
        height: CGFloat,
        size: CGSize
    ) {
        let rect = CGRect(
            x: headerWidth,
            y: top,
            width: max(0, size.width - headerWidth),
            height: height
        )
        context.fill(
            Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
            with: .color(StudioTheme.surfaceCanvas)
        )
    }

    private func drawTrackLabel(
        context: inout GraphicsContext,
        title: String,
        top: CGFloat,
        height: CGFloat,
        track: TimelineTrack
    ) {
        let isActive = activeTrack == track
        let isHovered = hoveredTrack == track
        let isFocused = focusedTrack == track
        if isActive || isHovered || isFocused {
            let rect = CGRect(
                x: 0,
                y: top,
                width: headerWidth - 3,
                height: height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
                with: .color(
                    isActive
                        ? StudioTheme.selectionTint
                        : StudioTheme.accent.opacity(0.08)
                )
            )
            if isFocused {
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
                    with: .color(StudioTheme.accent.opacity(0.8)),
                    lineWidth: 1
                )
            }
        }
        let label = Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(
                isActive
                    ? StudioTheme.accent
                    : (isHovered || isFocused
                        ? StudioTheme.textSecondary
                        : StudioTheme.textTertiary)
            )
        context.draw(
            label,
            at: CGPoint(x: 23, y: top + height / 2),
            anchor: .center
        )
    }

    private func drawVideoClips(
        context: inout GraphicsContext,
        top: CGFloat,
        tracksWidth: CGFloat
    ) {
        var cursor = 0.0
        for (index, clip) in project.timeline.clips.enumerated() {
            let startX = xPosition(cursor, width: tracksWidth)
            let width = max(
                1,
                tracksWidth
                    * CGFloat(clip.outputDuration / project.trimDuration)
                    - 1
            )
            let rect = CGRect(
                x: headerWidth + startX,
                y: top + 2,
                width: width,
                height: videoHeight - 4
            )
            let selected = clip.id == selectedClipID
            context.fill(
                Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
                with: .linearGradient(
                    Gradient(colors: [
                        StudioTheme.accent.opacity(selected ? 0.72 : 0.34),
                        StudioTheme.accent.opacity(selected ? 0.46 : 0.18)
                    ]),
                    startPoint: CGPoint(x: rect.minX, y: 0),
                    endPoint: CGPoint(x: rect.maxX, y: 0)
                )
            )
            context.stroke(
                Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
                with: .color(
                    selected
                        ? StudioTheme.accent
                        : StudioTheme.accent.opacity(0.35)
                ),
                lineWidth: selected ? 1.5 : 1
            )
            if rect.width > 12 {
                var handles = Path()
                handles.move(
                    to: CGPoint(x: rect.minX + 2, y: rect.minY + 5)
                )
                handles.addLine(
                    to: CGPoint(x: rect.minX + 2, y: rect.maxY - 5)
                )
                handles.move(
                    to: CGPoint(x: rect.maxX - 2, y: rect.minY + 5)
                )
                handles.addLine(
                    to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 5)
                )
                context.stroke(
                    handles,
                    with: .color(StudioTheme.textPrimary.opacity(0.4)),
                    lineWidth: 1.5
                )
            }
            if rect.width > 54 {
                let title = Text(
                    "\(index + 1) · \(rateLabel(clip.playbackRate))"
                )
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(
                    selected
                        ? StudioTheme.textOnAccentContainer
                        : StudioTheme.textSecondary
                )
                context.draw(
                    title,
                    at: CGPoint(x: rect.midX, y: rect.midY),
                    anchor: .center
                )
            }
            cursor += clip.outputDuration
        }
    }

    private func drawCameraTrack(
        context: inout GraphicsContext,
        top: CGFloat,
        tracksWidth: CGFloat
    ) {
        guard project.cameraURL != nil else {
            drawEmptyState(
                context: &context,
                text: "无摄像头",
                top: top,
                height: cameraHeight,
                tracksWidth: tracksWidth
            )
            return
        }
        let segments = project.sortedCameraSegments.filter {
            $0.start < project.trimDuration
        }
        var starts = [0.0]
        for segment in segments where segment.start > 0.000_001 {
            if starts.last.map({ abs($0 - segment.start) > 0.000_001 }) == true {
                starts.append(segment.start)
            }
        }
        starts.sort()
        let boundaries = starts + [project.trimDuration]
        for index in 0 ..< max(0, boundaries.count - 1) {
            let start = max(0, boundaries[index])
            let end = min(project.trimDuration, boundaries[index + 1])
            guard end > start else { continue }
            let x = headerWidth + xPosition(start, width: tracksWidth)
            let width = max(
                1,
                tracksWidth * CGFloat((end - start) / project.trimDuration)
            )
            let rect = CGRect(
                x: x,
                y: top + 2,
                width: width,
                height: cameraHeight - 4
            )
            let settings = project.cameraSettings(atOutput: start + 0.000_1)
            let enabled = settings.enabled && settings.layout != .screenOnly
            context.fill(
                Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
                with: .color(
                    enabled
                        ? StudioTheme.accent.opacity(
                            index.isMultiple(of: 2) ? 0.2 : 0.28
                        )
                        : StudioTheme.surfaceCanvas
                )
            )
            if width > 34 {
                let label = Text(
                    enabled
                        ? "\(index + 1) \(settings.layout.title)"
                        : "\(index + 1) 隐藏"
                )
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(
                    enabled
                        ? StudioTheme.textSecondary
                        : StudioTheme.textTertiary
                )
                context.draw(
                    label,
                    at: CGPoint(x: rect.midX, y: rect.midY),
                    anchor: .center
                )
            }
            if index > 0 {
                var divider = Path()
                divider.move(to: CGPoint(x: rect.minX, y: rect.minY))
                divider.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                context.stroke(
                    divider,
                    with: .color(StudioTheme.accent.opacity(0.8)),
                    lineWidth: 1
                )
            }
        }
    }

    private func drawZoomTrack(
        context: inout GraphicsContext,
        top: CGFloat,
        tracksWidth: CGFloat
    ) {
        let clicks = project.clicks.compactMap { click -> ClickEvent? in
            guard
                let time = project.timeline.outputTime(forSource: click.time)
            else {
                return nil
            }
            var mapped = click
            mapped.time = time
            return mapped
        }
        guard
            !clicks.isEmpty
                || !project.zoomRegions.isEmpty
                || !project.redactionRegions.isEmpty
        else {
            drawEmptyState(
                context: &context,
                text: "无放大点",
                top: top,
                height: zoomHeight,
                tracksWidth: tracksWidth
            )
            return
        }
        for region in project.zoomRegions {
            let start = min(project.trimDuration, max(0, region.start))
            let end = min(project.trimDuration, max(start, region.end))
            guard end > start else { continue }
            let rect = CGRect(
                x: headerWidth + xPosition(start, width: tracksWidth),
                y: top + 3,
                width: max(
                    2,
                    tracksWidth
                        * CGFloat((end - start) / project.trimDuration)
                ),
                height: zoomHeight - 6
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
                with: .color(
                    StudioTheme.accent.opacity(region.enabled ? 0.34 : 0.1)
                )
            )
            if rect.width > 50 {
                let label = Text(String(format: "%.2g×", region.scale))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(
                        region.enabled
                            ? StudioTheme.textSecondary
                            : StudioTheme.textTertiary
                    )
                context.draw(
                    label,
                    at: CGPoint(x: rect.midX, y: rect.midY),
                    anchor: .center
                )
            }
        }
        for click in clicks {
            let x = headerWidth
                + xPosition(click.time, width: tracksWidth)
            let rect = CGRect(x: x - 3, y: top + zoomHeight / 2 - 3, width: 6, height: 6)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 3),
                with: .color(
                    click.enabled
                        ? StudioTheme.accent
                        : StudioTheme.textTertiary
                )
            )
        }
        drawRedactionLane(
            context: &context,
            top: top,
            tracksWidth: tracksWidth
        )
    }

    /// 打码区域在缩放轨下缘的专属泳道（1.2 块2）：时间跨度可拖动平移，
    /// 起止时长在画布检查器里精确调整。
    private func drawRedactionLane(
        context: inout GraphicsContext,
        top: CGFloat,
        tracksWidth: CGFloat
    ) {
        guard !project.redactionRegions.isEmpty else { return }
        let laneHeight: CGFloat = 7
        let laneTop = top + zoomHeight - laneHeight - 2
        for region in project.redactionRegions {
            let start = min(project.trimDuration, max(0, region.start))
            let end = min(project.trimDuration, max(start, region.end))
            guard end > start else { continue }
            let rect = CGRect(
                x: headerWidth + xPosition(start, width: tracksWidth),
                y: laneTop,
                width: max(
                    2,
                    tracksWidth
                        * CGFloat((end - start) / project.trimDuration)
                ),
                height: laneHeight
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: laneHeight / 2),
                with: .color(
                    StudioTheme.accent.opacity(region.enabled ? 0.6 : 0.15)
                )
            )
        }
    }

    private func redactionHit(
        at location: CGPoint,
        size: CGSize
    ) -> RedactionRegionDrag? {
        guard
            location.x >= headerWidth,
            size.width > headerWidth,
            project.trimDuration > 0,
            !project.redactionRegions.isEmpty
        else {
            return nil
        }
        let videoTop = rulerHeight + trackGap
        let cameraTop = videoTop + videoHeight + trackGap
        let zoomTop = cameraTop + cameraHeight + trackGap
        let laneHeight: CGFloat = 7
        let laneTop = zoomTop + zoomHeight - laneHeight - 2
        guard
            location.y >= laneTop,
            location.y <= laneTop + laneHeight
        else {
            return nil
        }
        let time = time(at: location.x, size: size)
        guard
            let region = project.redactionRegions
                .filter({
                    $0.start <= time + 0.000_001
                        && time <= $0.end + 0.000_001
                })
                .max(by: { $0.start < $1.start })
        else {
            return nil
        }
        return RedactionRegionDrag(
            regionID: region.id,
            start: region.start,
            timelineDuration: project.trimDuration
        )
    }

    private func updateRedactionDrag(
        _ drag: RedactionRegionDrag,
        translation: CGSize,
        tracksWidth: CGFloat
    ) {
        guard drag.timelineDuration > 0 else { return }
        let deltaOutput = Double(translation.width / tracksWidth)
            * drag.timelineDuration
        onMoveRedactionRegion(drag.regionID, drag.start + deltaOutput)
    }

    private func drawAudioTrack(
        context: inout GraphicsContext,
        top: CGFloat,
        tracksWidth: CGFloat
    ) {
        let microphoneExists = project.microphoneURL != nil
        let systemExists = project.systemAudioURL != nil
        let rows: [(String, Bool, Double, Bool, [CGFloat])] = [
            (
                microphoneExists
                    ? (
                        project.audio.microphoneMuted
                            ? "麦克风 · 静音"
                            : "麦克风 · \(Int(project.audio.microphoneGain * 100))%"
                    )
                    : "麦克风（无）",
                microphoneExists,
                project.audio.microphoneGain,
                project.audio.microphoneMuted,
                microphoneWaveform
            ),
            (
                systemExists
                    ? (
                        project.audio.systemMuted
                            ? "系统 · 静音"
                            : "系统 · \(Int(project.audio.systemGain * 100))%"
                    )
                    : "系统（无）",
                systemExists,
                project.audio.systemGain,
                project.audio.systemMuted,
                systemWaveform
            )
        ]
        let rowHeight = (audioHeight - 5) / 2
        for (index, row) in rows.enumerated() {
            let rect = CGRect(
                x: headerWidth,
                y: top + 2 + CGFloat(index) * (rowHeight + 1),
                width: tracksWidth,
                height: rowHeight
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: StudioTheme.radiusS),
                with: .color(StudioTheme.surfaceCanvas)
            )
            if row.1 {
                let gainWidth = max(
                    0,
                    rect.width * CGFloat(min(1, max(0, row.2)))
                )
                context.fill(
                    Path(
                        roundedRect: CGRect(
                            x: rect.minX,
                            y: rect.minY,
                            width: gainWidth,
                            height: rect.height
                        ),
                        cornerRadius: StudioTheme.radiusS
                    ),
                    with: .color(StudioTheme.textSecondary.opacity(0.12))
                )
                drawWaveform(
                    context: &context,
                    samples: row.4,
                    rect: rect,
                    dimmed: row.3
                )
            }
            let label = Text(row.0)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
            context.draw(
                label,
                at: CGPoint(x: rect.minX + 28, y: rect.midY),
                anchor: .leading
            )
        }
    }

    private func drawWaveform(
        context: inout GraphicsContext,
        samples: [CGFloat],
        rect: CGRect,
        dimmed: Bool
    ) {
        guard samples.count > 1 else { return }
        let available = rect.insetBy(dx: 1, dy: 2)
        let midY = available.midY
        let amplitude = available.height * 0.42
        var path = Path()
        for index in samples.indices {
            let x = available.minX
                + available.width
                    * CGFloat(index)
                    / CGFloat(samples.count - 1)
            let halfHeight = amplitude * samples[index]
            path.move(to: CGPoint(x: x, y: midY - halfHeight))
            path.addLine(to: CGPoint(x: x, y: midY + halfHeight))
        }
        // 波形是音频数据可视化，保持中性不染色（映射表 §9.2）。
        context.stroke(
            path,
            with: .color(dimmed ? StudioTheme.textTertiary : StudioTheme.textSecondary),
            lineWidth: 0.8
        )
    }

    private func loadWaveforms() async {
        async let microphone = loadWaveform(
            url: project.microphoneURL
        )
        async let system = loadWaveform(
            url: project.systemAudioURL
        )
        let result = await (microphone, system)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            microphoneWaveform = result.0
            systemWaveform = result.1
        }
    }

    private func loadWaveform(url: URL?) async -> [CGFloat] {
        guard let url else { return [] }
        return await AudioWaveform.samples(for: url)
    }

    private func drawEmptyState(
        context: inout GraphicsContext,
        text: String,
        top: CGFloat,
        height: CGFloat,
        tracksWidth: CGFloat
    ) {
        let label = Text(text)
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
        context.draw(
            label,
            at: CGPoint(
                x: headerWidth + tracksWidth / 2,
                y: top + height / 2
            ),
            anchor: .center
        )
    }

    /// F2 叠加泳道：每个片段一个圆角块，选中块用 accent 描边。
    private func drawOverlayTrack(
        context: inout GraphicsContext,
        top: CGFloat,
        tracksWidth: CGFloat
    ) {
        for clip in project.overlayClips {
            let startX = headerWidth + xPosition(clip.start, width: tracksWidth)
            let endX = headerWidth + xPosition(clip.end, width: tracksWidth)
            let blockWidth = max(4, endX - startX)
            let rect = CGRect(
                x: startX,
                y: top,
                width: blockWidth,
                height: overlayHeight
            )
            let path = Path(roundedRect: rect, cornerRadius: 4)
            let isSelected = clip.id == selectedOverlayClipID
            context.fill(
                path,
                with: .color(
                    isSelected
                        ? StudioTheme.selectionTint
                        : StudioTheme.surfaceSunken
                )
            )
            context.stroke(
                path,
                with: .color(
                    isSelected ? StudioTheme.accent : StudioTheme.separatorLine
                ),
                lineWidth: isSelected ? 1.5 : 1
            )
            context.draw(
                Text(clip.kind == .image ? "图片" : "视频")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.textSecondary),
                in: CGRect(
                    x: rect.minX + 4,
                    y: rect.midY - 6,
                    width: max(10, blockWidth - 8),
                    height: 12
                )
            )
        }
    }

    /// F2 叠加泳道命中：返回点中的片段（无裁剪拖拽，点击即选中）。
    private func overlayClipHit(
        at location: CGPoint,
        size: CGSize
    ) -> UUID? {
        guard size.width > headerWidth, project.trimDuration > 0 else {
            return nil
        }
        let videoTop = rulerHeight + trackGap
        let overlayTop = videoTop
            + videoHeight + trackGap
            + cameraHeight + trackGap
            + zoomHeight + trackGap
            + audioHeight + trackGap
        guard
            location.y >= overlayTop,
            location.y <= overlayTop + overlayHeight
        else {
            return nil
        }
        let tracksWidth = max(1, size.width - headerWidth)
        for clip in project.overlayClips {
            let startX = headerWidth + xPosition(clip.start, width: tracksWidth)
            let endX = headerWidth + xPosition(clip.end, width: tracksWidth)
            if location.x >= startX - 2, location.x <= endX + 2 {
                return clip.id
            }
        }
        return nil
    }

    private func drawPlayhead(
        context: inout GraphicsContext,
        height: CGFloat,
        tracksWidth: CGFloat
    ) {
        let x = headerWidth + xPosition(currentTime, width: tracksWidth)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: height))
        // 播放头专属金黄播放语义（映射表 §9.2：playbackGold）。
        context.stroke(line, with: .color(StudioTheme.playbackGold), lineWidth: 1.25)
        context.fill(
            Path(
                roundedRect: CGRect(x: x - 2.5, y: 0, width: 5, height: 10),
                cornerRadius: 2.5
            ),
            with: .color(StudioTheme.playbackGold)
        )
    }

    private func selectClipIfNeeded(
        at location: CGPoint,
        size: CGSize
    ) {
        guard
            location.x >= headerWidth,
            size.width > headerWidth,
            project.trimDuration > 0
        else {
            return
        }
        let videoTop = rulerHeight + trackGap
        guard
            location.y >= videoTop,
            location.y <= videoTop + videoHeight
        else {
            return
        }
        let time = time(at: location.x, size: size)
        guard let index = project.timeline.clipIndex(atOutput: time) else {
            return
        }
        selectedClipID = project.timeline.clips[index].id
    }

    private func trimHit(
        at location: CGPoint,
        size: CGSize
    ) -> ClipTrimDrag? {
        guard
            location.x >= headerWidth,
            size.width > headerWidth,
            project.trimDuration > 0
        else {
            return nil
        }
        let videoTop = rulerHeight + trackGap
        guard
            location.y >= videoTop,
            location.y <= videoTop + videoHeight
        else {
            return nil
        }
        let tracksWidth = max(1, size.width - headerWidth)
        for clip in project.timeline.clips {
            guard
                let outputStart = project.timeline.outputStart(
                    forClipID: clip.id
                )
            else {
                continue
            }
            let startX = headerWidth + xPosition(
                outputStart,
                width: tracksWidth
            )
            let endX = headerWidth + xPosition(
                outputStart + clip.outputDuration,
                width: tracksWidth
            )
            if abs(location.x - startX) <= 6 {
                selectedClipID = clip.id
                return ClipTrimDrag(
                    clipID: clip.id,
                    edge: .start,
                    sourceValue: clip.sourceStart,
                    playbackRate: clip.playbackRate,
                    timelineDuration: project.trimDuration
                )
            }
            if abs(location.x - endX) <= 6 {
                selectedClipID = clip.id
                return ClipTrimDrag(
                    clipID: clip.id,
                    edge: .end,
                    sourceValue: clip.sourceEnd,
                    playbackRate: clip.playbackRate,
                    timelineDuration: project.trimDuration
                )
            }
        }
        return nil
    }

    private func updateTrim(
        _ drag: ClipTrimDrag,
        translation: CGSize,
        tracksWidth: CGFloat
    ) {
        guard drag.timelineDuration > 0 else { return }
        let deltaOutput = Double(translation.width / tracksWidth)
            * drag.timelineDuration
        let target = drag.sourceValue + deltaOutput * drag.playbackRate
        switch drag.edge {
        case .start:
            onTrimClipStart(drag.clipID, target)
        case .end:
            onTrimClipEnd(drag.clipID, target)
        }
    }

    private func cameraSegmentHit(
        at location: CGPoint,
        size: CGSize
    ) -> CameraSegmentDrag? {
        guard
            location.x >= headerWidth,
            size.width > headerWidth,
            project.trimDuration > 0
        else {
            return nil
        }
        let videoTop = rulerHeight + trackGap
        let cameraTop = videoTop + videoHeight + trackGap
        guard
            location.y >= cameraTop,
            location.y <= cameraTop + cameraHeight
        else {
            return nil
        }
        let time = time(at: location.x, size: size)
        let segments = project.sortedCameraSegments
        for (index, segment) in segments.enumerated() {
            let end = index + 1 < segments.count
                ? segments[index + 1].start
                : project.trimDuration
            guard segment.start <= end, time >= segment.start else {
                continue
            }
            guard time <= end + 0.000_001 else { continue }
            return CameraSegmentDrag(
                segmentID: segment.id,
                start: segment.start,
                timelineDuration: project.trimDuration
            )
        }
        return nil
    }

    private func updateCameraSegmentDrag(
        _ drag: CameraSegmentDrag,
        translation: CGSize,
        tracksWidth: CGFloat
    ) {
        guard drag.timelineDuration > 0 else { return }
        let deltaOutput = Double(translation.width / tracksWidth)
            * drag.timelineDuration
        onMoveCameraSegment(drag.segmentID, drag.start + deltaOutput)
    }

    private func zoomRegionHit(
        at location: CGPoint,
        size: CGSize
    ) -> ZoomRegionDrag? {
        guard
            location.x >= headerWidth,
            size.width > headerWidth,
            project.trimDuration > 0
        else {
            return nil
        }
        let videoTop = rulerHeight + trackGap
        let cameraTop = videoTop + videoHeight + trackGap
        let zoomTop = cameraTop + cameraHeight + trackGap
        guard
            location.y >= zoomTop,
            location.y <= zoomTop + zoomHeight
        else {
            return nil
        }
        let time = time(at: location.x, size: size)
        guard
            let region = project.zoomRegions
                .filter({
                    $0.start <= time + 0.000_001
                        && time <= $0.end + 0.000_001
                })
                .max(by: { $0.start < $1.start })
        else {
            return nil
        }
        return ZoomRegionDrag(
            regionID: region.id,
            start: region.start,
            timelineDuration: project.trimDuration
        )
    }

    private func updateZoomRegionDrag(
        _ drag: ZoomRegionDrag,
        translation: CGSize,
        tracksWidth: CGFloat
    ) {
        guard drag.timelineDuration > 0 else { return }
        let deltaOutput = Double(translation.width / tracksWidth)
            * drag.timelineDuration
        onMoveZoomRegion(drag.regionID, drag.start + deltaOutput)
    }

    private func time(at x: CGFloat, size: CGSize) -> Double {
        let tracksWidth = max(1, size.width - headerWidth)
        let fraction = min(
            max(Double((x - headerWidth) / tracksWidth), 0),
            1
        )
        return fraction * project.trimDuration
    }

    private func xPosition(_ time: Double, width: CGFloat) -> CGFloat {
        guard project.trimDuration > 0 else { return 0 }
        return CGFloat(
            min(max(time / project.trimDuration, 0), 1)
        ) * width
    }

    private func rateLabel(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.001 {
            return "\(Int(rate))×"
        }
        return String(format: "%.2g×", rate)
    }
}
