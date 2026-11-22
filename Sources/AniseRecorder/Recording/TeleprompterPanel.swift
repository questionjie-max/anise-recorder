import AppKit
import AniseRecorderCore
import SwiftUI

/// 提词面板几何（提词器）：默认位置靠近摄像头悬浮窗区域，全部为纯函数，
/// 便于注入屏幕矩形做单测。
enum TeleprompterPanelGeometry {
    static let defaultSize = CGSize(width: 340, height: 300)
    static let screenMargin: CGFloat = 24
    /// 面板与摄像头悬浮窗之间的间隔。
    static let cameraGap: CGFloat = 12
    /// 无摄像头时的参考区：主屏可视区右下 30% × 28%（近似默认摄像头
    /// 画中画的位置，面板放在它上方）。
    private static let referenceZoneWidthRatio: CGFloat = 0.3
    private static let referenceZoneHeightRatio: CGFloat = 0.28

    static let fontSizeRange: ClosedRange<Double> = 16 ... 64

    static func clampedFontSize(_ size: Double) -> Double {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// 默认面板位置：有摄像头悬浮窗时右对齐并放在其上方；否则按参考区
    /// （右下 30% × 28%）上方放置。
    static func defaultFrame(
        visibleFrame: CGRect,
        cameraFrame: CGRect?
    ) -> CGRect {
        let size = fittedSize(for: visibleFrame)
        var origin: CGPoint
        if
            let camera = cameraFrame,
            camera.width > 0,
            camera.height > 0,
            visibleFrame.intersects(camera)
        {
            origin = CGPoint(
                x: camera.maxX - size.width,
                y: camera.maxY + cameraGap
            )
        } else {
            let zoneHeight = visibleFrame.height * referenceZoneHeightRatio
            origin = CGPoint(
                x: visibleFrame.maxX - size.width - screenMargin,
                y: visibleFrame.minY + zoneHeight + cameraGap
            )
        }
        return clampedFrame(
            CGRect(origin: origin, size: size),
            visibleFrame: visibleFrame
        )
    }

    /// 把任意位置钳制回可视区（工程记忆恢复时防 off-screen），过大则缩小。
    static func clampedFrame(
        _ frame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        var size = frame.size
        size.width = min(max(size.width, 160), visibleFrame.width)
        size.height = min(max(size.height, 120), visibleFrame.height)
        var origin = frame.origin
        origin.x = min(
            max(origin.x, visibleFrame.minX),
            visibleFrame.maxX - size.width
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY),
            visibleFrame.maxY - size.height
        )
        return CGRect(origin: origin, size: size)
    }

    private static func fittedSize(for visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(defaultSize.width, visibleFrame.width),
            height: min(defaultSize.height, visibleFrame.height)
        )
    }
}

/// 面板会话：滚动状态、文稿与设置的可观察容器。tick 由视图的时间线驱动。
@MainActor
final class TeleprompterPanelSession: ObservableObject {
    @Published var settings: TeleprompterSettings {
        didSet {
            if settings.script != oldValue.script {
                document = TeleprompterDocument(text: settings.script)
                scrollState = TeleprompterScrollState()
                segmentHeights = [:]
                recomputeSegmentOffsets()
            }
        }
    }
    @Published private(set) var scrollState = TeleprompterScrollState()
    /// 预演模式：面板在不录制时打开（录制准备页排练文稿）。
    @Published var isRehearsal = true
    @Published var contentHeight: Double = 0
    @Published var viewportHeight: Double = 0
    @Published private(set) var document: TeleprompterDocument

    /// 上一次 tick 的时间，用于计算帧间隔。
    private(set) var lastTick = Date()
    /// 视图测得的各段高度（点），键为段索引。
    private(set) var segmentHeights: [Int: Double] = [:]
    /// 各段在内容坐标中的起点 / 结束位置（与视图布局同参计算）。
    private(set) var segmentStartOffsets: [Double] = []
    private(set) var segmentEndOffsets: [Double] = []

    /// 内容上下内边距（与视图保持一致）。
    static let contentVerticalPadding: Double = 14
    /// 阅读线在视口内的位置（偏上 40%），当前段 / 减速边界按它折算。
    static let readingLeadRatio: Double = 0.4
    /// 段尾减速区长度（点）。
    static let decelerationZoneFactor: Double = 3
    static let decelerationFloor: Double = 0.35

    private var engine: TeleprompterScrollEngine {
        TeleprompterScrollEngine(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            speed: settings.speed
        )
    }

    var segmentSpacing: Double {
        settings.fontSize * 1.2
    }

    var readingOffset: Double {
        scrollState.offset + viewportHeight * Self.readingLeadRatio
    }

    init(settings: TeleprompterSettings) {
        self.settings = settings
        self.document = TeleprompterDocument(text: settings.script)
        recomputeSegmentOffsets()
    }

    /// 视图测量段高后重算各段位置。
    func updateSegmentHeights(_ heights: [Int: Double]) {
        guard heights != segmentHeights else { return }
        segmentHeights = heights
        recomputeSegmentOffsets()
    }

    private func recomputeSegmentOffsets() {
        var starts: [Double] = []
        var ends: [Double] = []
        var y = Self.contentVerticalPadding
        for index in document.segments.indices {
            let height = segmentHeights[index] ?? 0
            starts.append(y)
            y += height
            ends.append(y)
            y += segmentSpacing
        }
        segmentStartOffsets = starts
        segmentEndOffsets = ends
    }

    /// 阅读线所在段（最后一个起点不超过阅读线的段）。
    var currentSegmentIndex: Int? {
        guard !segmentStartOffsets.isEmpty else { return nil }
        var index = 0
        for candidate in segmentStartOffsets.indices {
            if segmentStartOffsets[candidate] <= readingOffset {
                index = candidate
            } else {
                break
            }
        }
        return index
    }

    /// 下一段预告文本（当前段的下一段，截前 24 字）。
    var nextSegmentPreview: String? {
        guard
            let current = currentSegmentIndex,
            document.segments.indices.contains(current + 1)
        else { return nil }
        let text = document.segments[current + 1].text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(24))
    }

    /// 段尾减速参数：阅读线前方最近且已进入减速区的段尾；区外 / 已越过为 nil。
    var activeDeceleration: TeleprompterScrollEngine.Deceleration? {
        guard !segmentEndOffsets.isEmpty, viewportHeight > 0 else { return nil }
        let lead = viewportHeight * Self.readingLeadRatio
        let zone = settings.fontSize * Self.decelerationZoneFactor
        guard
            let boundary = segmentEndOffsets.first(where: { $0 > readingOffset })
        else { return nil }
        let boundaryOffset = max(boundary - lead, 0)
        let remaining = boundaryOffset - scrollState.offset
        guard remaining > 0, remaining < zone else { return nil }
        return TeleprompterScrollEngine.Deceleration(
            boundaryOffset: boundaryOffset,
            zone: zone,
            floor: Self.decelerationFloor
        )
    }

    func tick(at date: Date) {
        let interval = date.timeIntervalSince(lastTick)
        lastTick = date
        scrollState = engine.advanced(
            from: scrollState,
            by: interval,
            deceleration: activeDeceleration
        )
    }

    /// 视图出现或重置时同步 tick 基准，避免用陈旧时间算出大跳步。
    func resetTiming(from date: Date) {
        lastTick = date
    }

    func togglePause() {
        scrollState = scrollState.isPaused
            ? engine.resumed(scrollState)
            : engine.paused(scrollState)
    }

    func seek(to offset: Double) {
        scrollState = engine.seek(to: offset, in: scrollState)
    }

    func reset() {
        scrollState = engine.reset()
        lastTick = Date()
    }

    /// 回退 / 前进约一行（行高按字号 × 1.45 估算，钳制在有效范围）。
    func stepOffset(_ delta: Double) {
        let line = settings.fontSize * 1.45
        scrollState = engine.seek(
            to: scrollState.offset + delta * line,
            in: scrollState
        )
        lastTick = Date()
    }

    func stepSpeed(_ delta: Double) {
        settings.speed = TeleprompterScrollEngine.clampedSpeed(
            settings.speed + delta
        )
        lastTick = Date()
    }

    func stepFontSize(_ delta: Double) {
        settings.fontSize = TeleprompterPanelGeometry.clampedFontSize(
            settings.fontSize + delta
        )
    }
}

/// 录制准备与录制中可用的提词面板（提词器）。独立 NSPanel：
/// - `sharingType = .none`：窗口内容不参与窗口服务器共享，ScreenCaptureKit
///   整屏 / 区域采集（已按 bundle ID 排除本 App）与任何窗口枚举都拿不到它；
/// - 不被 `hideMainWindows()` 影响（该方法只隐藏非 Panel 主窗口），
///   录制期间保持可见；
/// - 可拖动（位置写入提词设置做工程记忆）。
@MainActor
final class TeleprompterPanelController: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel?
    private(set) var session: TeleprompterPanelSession?
    private var onCommit: ((TeleprompterSettings) -> Void)?
    private var keyMonitor: Any?

    var isVisible: Bool { panel != nil }

    var panelForTesting: NSPanel? { panel }
    var sessionForTesting: TeleprompterPanelSession? { session }

    func show(
        settings: TeleprompterSettings,
        visibleFrame: CGRect,
        cameraFrame: CGRect?,
        isRecording: Bool = false,
        onCommit: @escaping (TeleprompterSettings) -> Void
    ) {
        hide()
        let session = TeleprompterPanelSession(settings: settings)
        session.isRehearsal = !isRecording
        self.session = session
        self.onCommit = onCommit
        let panel = KeyableNonActivatingPanel(
            contentRect: NSRect(
                origin: .zero,
                size: TeleprompterPanelGeometry.defaultSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // 核心检核：提词面板绝不能出现在录像里。
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: TeleprompterPanelView(
                session: session,
                onClose: { [weak self] in
                    self?.hide()
                },
                onCommit: { [weak self] settings in
                    self?.onCommit?(settings)
                }
            )
        )
        let frame = TeleprompterPanelGeometry.defaultFrame(
            visibleFrame: visibleFrame,
            cameraFrame: cameraFrame
        )
        panel.setFrame(
            session.settings.panelFrame.map {
                TeleprompterPanelGeometry.clampedFrame($0, visibleFrame: visibleFrame)
            } ?? frame,
            display: true
        )
        panel.orderFrontRegardless()
        self.panel = panel
        installKeyMonitor()
    }

    func updateSettings(_ settings: TeleprompterSettings) {
        guard let session else { return }
        session.settings = settings
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel = nil
        session = nil
        onCommit = nil
    }

    // MARK: 空格暂停 / 继续（本地监听，仅面板可见期间生效）

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            guard event.keyCode == 49 else { return event } // 空格
            // P5 键盘习惯修复：只在面板窗口为 key、且焦点不在文本输入
            // 或按钮上时接管空格——面板开着时，字幕框/工程名/文稿编辑器
            // 里打字不能被吞成暂停（与 ShortcutHelp 目录口径一致）。
            guard NSApp.keyWindow === self.panel else { return event }
            let responder = NSApp.keyWindow?.firstResponder
            if responder is NSTextView || responder is NSTextField
                || responder is NSButton
            {
                return event
            }
            self.session?.togglePause()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: NSWindowDelegate（拖动结束记录位置）

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard
                let self,
                let panel = self.panel,
                let session = self.session
            else { return }
            var settings = session.settings
            settings.panelFrame = panel.frame
            session.settings = settings
            self.onCommit?(settings)
        }
    }
}

/// 面板内容视图：文稿自动滚动（引擎驱动）、暂停 / 继续、进度拖回、
/// 字号 / 速度调节与位置记忆提交。
private struct TeleprompterPanelView: View {
    @ObservedObject var session: TeleprompterPanelSession
    let onClose: () -> Void
    let onCommit: (TeleprompterSettings) -> Void

    private var engine: TeleprompterScrollEngine {
        TeleprompterScrollEngine(
            contentHeight: session.contentHeight,
            viewportHeight: session.viewportHeight,
            speed: session.settings.speed
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StudioTheme.separatorLine)
            if session.settings.hasScript {
                scriptArea
            } else {
                emptyState
            }
            controls
        }
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: StudioTheme.radiusL)
                .fill(StudioTheme.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.radiusL)
                        .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusL))
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
            Text("提词器")
                .font(.callout.weight(.semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            if session.isRehearsal {
                Text("预演")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(StudioTheme.selectionTint)
                    .clipShape(Capsule())
            }
            if !session.document.segments.isEmpty {
                Text(segmentIndicator)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .buttonStyle(IconButtonStyle(cornerRadius: StudioTheme.radiusM))
            .help("关闭提词面板")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var segmentIndicator: String {
        let total = session.document.segments.count
        if let index = session.currentSegmentIndex {
            if let preview = session.nextSegmentPreview {
                return "段 \(index + 1)/\(total) · 下一段 \(preview)…"
            }
            return "段 \(index + 1)/\(total) · 最后一段"
        }
        return "段 1/\(total)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("还没有文稿")
                .font(.callout.weight(.medium))
                .foregroundStyle(StudioTheme.textSecondary)
            Text("在录制工作台粘贴或导入 .txt / .md 文稿")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.textSecondary)
            Spacer()
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
    }

    private var scriptArea: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.clear
                    scriptContent
                        .offset(y: -session.scrollState.offset)
                }
                .onAppear {
                    session.viewportHeight = geometry.size.height
                    session.resetTiming(from: context.date)
                }
                .onChange(of: geometry.size.height) { _, newValue in
                    session.viewportHeight = newValue
                }
                .onChange(of: context.date) { _, date in
                    session.tick(at: date)
                }
                .onPreferenceChange(TeleprompterSegmentHeightKey.self) { heights in
                    session.updateSegmentHeights(heights)
                }
                .clipped()
            }
        }
        .frame(height: 170)
    }

    private var scriptContent: some View {
        VStack(alignment: .leading, spacing: session.segmentSpacing) {
            if session.document.segments.isEmpty {
                Text(session.document.normalizedText)
                    .font(scriptFont)
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            ForEach(
                Array(session.document.segments.enumerated()),
                id: \.offset
            ) { index, segment in
                Text(segment.text)
                    .font(scriptFont)
                    .lineSpacing(session.settings.fontSize * 0.45)
                    .foregroundStyle(segmentOpacity(for: index))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        segmentHeightReader(index: index)
                    )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, TeleprompterPanelSession.contentVerticalPadding)
        .background(contentHeightReader)
    }

    private var scriptFont: Font {
        .system(
            size: session.settings.fontSize,
            weight: .regular,
            design: .rounded
        )
    }

    private func segmentOpacity(for index: Int) -> Color {
        switch session.currentSegmentIndex {
        case .some(index):
            StudioTheme.textPrimary
        case .some(let current) where index < current:
            StudioTheme.textTertiary
        default:
            StudioTheme.textSecondary
        }
    }

    private func segmentHeightReader(index: Int) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TeleprompterSegmentHeightKey.self,
                value: [index: geometry.size.height]
            )
        }
    }

    private var contentHeightReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TeleprompterContentHeightKey.self,
                value: geometry.size.height
            )
        }
        .onPreferenceChange(TeleprompterContentHeightKey.self) { value in
            session.contentHeight = value
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            StudioSlider(
                value: Binding(
                    get: { session.scrollState.offset },
                    set: { session.seek(to: $0) }
                ),
                range: 0 ... max(engine.maxOffset, 0.001)
            )
            .padding(.horizontal, 14)

            HStack(spacing: 10) {
                Button {
                    session.togglePause()
                } label: {
                    Image(
                        systemName: session.scrollState.isPaused
                            ? "play.fill" : "pause.fill"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                }
                .buttonStyle(IconButtonStyle())
                .help(session.scrollState.isPaused ? "继续（空格）" : "暂停（空格）")

                stepperBlock(
                    label: "速度",
                    value: String(format: "%.0f", session.settings.speed),
                    onMinus: {
                        session.stepSpeed(-1)
                        onCommit(session.settings)
                    },
                    onPlus: {
                        session.stepSpeed(1)
                        onCommit(session.settings)
                    }
                )

                stepperBlock(
                    label: "字号",
                    value: String(
                        format: "%.0f",
                        session.settings.fontSize
                    ),
                    onMinus: {
                        session.stepFontSize(-2)
                        onCommit(session.settings)
                    },
                    onPlus: {
                        session.stepFontSize(2)
                        onCommit(session.settings)
                    }
                )

                Button {
                    session.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                }
                .buttonStyle(IconButtonStyle())
                .help("回到开头")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

        }
    }

    private func stepperBlock(
        label: String,
        value: String,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(StudioTheme.textSecondary)
            Button(action: onMinus) {
                Image(systemName: "minus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            .buttonStyle(IconButtonStyle())
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(StudioTheme.textPrimary)
                .frame(width: 18)
            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}

private struct TeleprompterContentHeightKey: PreferenceKey {
    static var defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) {
        nextValue()
    }
}

private struct TeleprompterSegmentHeightKey: PreferenceKey {
    static var defaultValue: [Int: Double] = [:]
    static func reduce(
        value: inout [Int: Double],
        nextValue: () -> [Int: Double]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// P5 键盘习惯修复：borderless 面板默认 cannotBecomeKey，空格接管守卫
/// （keyWindow === panel）会永假。工具窗标准做法——子类放行 key 状态
/// （仍不激活 App），让「面板聚焦时空格暂停/继续」与目录口径一致；
/// 面板未聚焦时守卫让空格直通，不再吞别处输入。
final class KeyableNonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
