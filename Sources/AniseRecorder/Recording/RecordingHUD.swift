import AppKit
import Combine
import SwiftUI

/// borderless 面板默认不能成为 key window，HUD 的 Esc 停止
/// （`.keyboardShortcut(.escape)`）因此基本失效。此子类允许成为 key——
/// 配合 `makeKeyAndOrderFront`（`.nonactivatingPanel` 不激活本 App，
/// 不打扰用户当前应用）。边界：用户点开其他应用后 key 归该应用，
/// Esc 归当前应用——不全局抢键（Esc 是当前应用的取消键，强行拦截
/// 反而危险）。
@MainActor
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// 拖动时把面板钳在目标屏可见区内——borderless 默认可以拖出屏幕，
    /// 拖丢的 HUD 等于没有停止按钮。
    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        guard let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame else {
            return super.constrainFrameRect(frameRect, to: screen)
        }
        var frame = super.constrainFrameRect(frameRect, to: screen)
        frame.origin = FloatingPanelLayout.clampedOrigin(
            origin: frame.origin,
            panelSize: frame.size,
            visibleFrame: visibleFrame
        )
        return frame
    }
}

/// 浮层布局纯函数（可单测）。尺寸常量与 SwiftUI 内容共用同一来源，
/// 避免「面板 680 / 内容 800」这种两端裁切的错位；位置以**被录屏**的
/// visibleFrame 为基准——录副屏时 HUD 不能出现在主屏上。
enum FloatingPanelLayout {
    static let hudTopInset: CGFloat = 28
    static let hudWidthCompact: CGFloat = 570
    static let hudWidthWithCamera: CGFloat = 800
    static let hudHeight: CGFloat = 60
    static let countdownSize: CGFloat = 190

    static func hudContentSize(hasCamera: Bool) -> CGSize {
        CGSize(
            width: hasCamera ? hudWidthWithCamera : hudWidthCompact,
            height: hudHeight
        )
    }

    /// HUD：目标屏顶部居中，距顶 hudTopInset。
    static func topCenteredOrigin(
        visibleFrame: CGRect,
        panelSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - hudTopInset
        )
    }

    /// 倒计时：目标屏正中。
    static func centeredOrigin(
        visibleFrame: CGRect,
        panelSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2
        )
    }

    /// 拖动钳制：整体不出可见区；面板比屏幕还宽时贴住左 / 下缘。
    static func clampedOrigin(
        origin: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let maxX = max(
            visibleFrame.minX,
            visibleFrame.maxX - panelSize.width
        )
        let maxY = max(
            visibleFrame.minY,
            visibleFrame.maxY - panelSize.height
        )
        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }
}

@MainActor
final class RecordingHUDSession: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var isBusy = false
    @Published private(set) var isAdjustingCamera = false
    // 摄像头启动失败在录制期对用户可见的唯一出口。
    @Published private(set) var cameraFailed = false
    // 麦克风输入电平（0...1）与静音告警可见性——HUD 只读
    // session 属性，不含任何采样逻辑。
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var silentAlarmVisible = false

    private var accumulated: TimeInterval = 0
    private var activeSince: Date

    init(startedAt: Date) {
        activeSince = startedAt
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        if paused {
            accumulated += Date().timeIntervalSince(activeSince)
            elapsed = accumulated
            isPaused = true
        } else {
            activeSince = Date()
            isPaused = false
        }
    }

    func tick() {
        guard !isPaused else { return }
        elapsed = accumulated + Date().timeIntervalSince(activeSince)
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
    }

    /// 主窗口已隐藏，摄像头启动失败由 HUD 状态行代为广播。
    func setCameraFailed() {
        cameraFailed = true
    }

    /// 电平与告警由 StudioModel 上抛后转发（单一入口）。
    func setMicrophoneLevel(_ level: Double) {
        microphoneLevel = level
    }

    func setSilentAlarmVisible(_ visible: Bool) {
        silentAlarmVisible = visible
    }

    @discardableResult
    func toggleCameraAdjusting() -> Bool {
        isAdjustingCamera.toggle()
        return isAdjustingCamera
    }
}

/// Esc / 停止按钮防误触确认状态机（纯函数，HUD 只消费）。
/// 默认关 = 任何一次按键立即停止（现状逐字节一致）；开 = 窗口内
/// 第二次按键才真正停止，第一次给提示，超时回到待机。
enum StopConfirmation {
    /// 待确认相位携带窗口截止时刻；超过截止的按键不停止，重新起一轮。
    enum Phase: Equatable {
        case idle
        case awaiting(deadline: Date)
    }

    enum Action: Equatable {
        /// 进入待确认，HUD 显示「再按一次确认停止」。
        case prompt
        /// 真正调用停止。
        case stop
    }

    /// 按键事件（Esc 或停止按钮共用同一入口）推进状态机。
    static func press(
        enabled: Bool,
        phase: Phase,
        now: Date,
        window: TimeInterval
    ) -> (Phase, Action) {
        guard enabled else {
            return (.idle, .stop)
        }
        switch phase {
        case .idle:
            return (.awaiting(deadline: now.addingTimeInterval(window)), .prompt)
        case let .awaiting(deadline):
            // 含端点：恰好压在截止时刻仍算窗口内确认。
            guard now <= deadline else {
                return (
                    .awaiting(deadline: now.addingTimeInterval(window)),
                    .prompt
                )
            }
            return (.idle, .stop)
        }
    }

    /// 确认窗口时长；状态机测试注入任意窗口，HUD 固定用规格值 0.5 秒。
    static let window: TimeInterval = 0.5
}

struct RecordingHUDView: View {
    @ObservedObject var session: RecordingHUDSession
    let hasCamera: Bool
    let stopRequiresConfirmation: Bool
    let onMarker: () -> Void
    let onToggleTeleprompter: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onToggleCameraAdjust: () -> Void
    let onToggleCameraShape: () -> Void

    @State private var markerCount = 0
    @State private var confirmPhase = StopConfirmation.Phase.idle
    @State private var confirmTimeoutTask: Task<Void, Never>?
    private let timer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        HStack(spacing: StudioTheme.space4) {
            ZStack {
                Circle()
                    .fill(StudioTheme.recIndicator.opacity(0.18))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(
                        session.isPaused
                            ? StudioTheme.textPrimary
                            : StudioTheme.recIndicator
                    )
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: StudioTheme.space1) {
                Text(session.isPaused ? "已暂停" : "正在录制")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        session.isPaused
                            ? StudioTheme.textPrimary
                            : StudioTheme.recText
                    )
                HStack(spacing: StudioTheme.space2) {
                    Text(timeText(session.elapsed))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(StudioTheme.recText)
                        .monospacedDigit()
                    // 微型输入电平条（4pt 细轨 + 图谱蓝填充）
                    levelBar
                }
            }

            // 静音一次性告警——只提示不干预录制。
            if session.silentAlarmVisible {
                HStack(spacing: StudioTheme.space1) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.recText)
                    Text("麦克风几乎没有声音")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(StudioTheme.recText)
                }
                .fixedSize()
                .padding(.horizontal, StudioTheme.space3)
                .frame(height: 26)
                .background(StudioTheme.recIndicator.opacity(0.14))
                .clipShape(Capsule())
                .accessibilityLabel("麦克风几乎没有声音，请检查设备")
            }

            if hasCamera {
                ZStack {
                    RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                        .fill(StudioTheme.textPrimary.opacity(0.08))
                    Image(systemName: "video.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(StudioTheme.accent)
                }
                .frame(width: 76, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                        .stroke(StudioTheme.separatorLine, lineWidth: 1)
                )

                Button(action: onToggleCameraAdjust) {
                    Text(
                        session.isAdjustingCamera
                            ? "完成"
                            : "调整镜头"
                    )
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, StudioTheme.space3)
                    .frame(height: 29)
                }
                .buttonStyle(
                    HUDChipButtonStyle(isActive: session.isAdjustingCamera)
                )
                .disabled(session.isBusy)

                Button(action: onToggleCameraShape) {
                    Image(systemName: "circle.dashed")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 29, height: 29)
                }
                .buttonStyle(HUDChipButtonStyle())
                .help("切换圆角 / 圆形")
                .disabled(session.isBusy)
            }

            Spacer(minLength: StudioTheme.space4)
            Button(action: onToggleTeleprompter) {
                Image(systemName: "text.quote")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 29, height: 29)
            }
            .buttonStyle(HUDChipButtonStyle())
            .help("提词器面板（不会进入录像）")
            Text(statusText)
                .font(.callout)
                .foregroundStyle(
                    isAwaitingConfirm
                        ? StudioTheme.recText
                        : StudioTheme.textSecondary
                )
            Button {
                guard !session.isPaused else { return }
                markerCount += 1
                onMarker()
            } label: {
                HStack(spacing: StudioTheme.space2) {
                    Image(systemName: "flag.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(markerCount == 0 ? "标记" : "标记 \(markerCount)")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, StudioTheme.space3)
                .frame(height: 29)
            }
            .buttonStyle(HUDChipButtonStyle())
            .disabled(session.isPaused || session.isBusy)
            Button {
                if session.isPaused {
                    onResume()
                } else {
                    onPause()
                }
            } label: {
                HStack(spacing: StudioTheme.space2) {
                    if session.isBusy {
                        ProgressView()
                            .controlSize(.mini)
                        Text("处理中")
                            .font(.callout.weight(.medium))
                    } else {
                        Image(
                            systemName: session.isPaused
                                ? "play.fill"
                                : "pause.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        Text(session.isPaused ? "继续" : "暂停")
                            .font(.callout.weight(.medium))
                    }
                }
                .padding(.horizontal, StudioTheme.space3)
                .frame(height: 29)
            }
            .buttonStyle(
                HUDChipButtonStyle(
                    isActive: session.isPaused,
                    activeTint: StudioTheme.recIndicator,
                    activeForeground: StudioTheme.textPrimary
                )
            )
            .disabled(session.isBusy)
            Button(action: handleStopRequest) {
                HStack(spacing: StudioTheme.space2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StudioTheme.recIndicator)
                        .frame(width: 8, height: 8)
                    Text("停止")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, StudioTheme.space4)
                .frame(height: 31)
            }
            .buttonStyle(
                HUDChipButtonStyle(
                    isActive: true,
                    activeTint: StudioTheme.textPrimary,
                    activeForeground: StudioTheme.surfaceCanvas
                )
            )
            .disabled(session.isBusy)
            .keyboardShortcut(.escape, modifiers: [])
            .help("停止录制（Esc）")
        }
        .padding(.horizontal, StudioTheme.space5)
        .frame(
            width: hasCamera
                ? FloatingPanelLayout.hudWidthWithCamera
                : FloatingPanelLayout.hudWidthCompact,
            height: FloatingPanelLayout.hudHeight
        )
        .background(.ultraThinMaterial)
        .background(StudioTheme.surfaceRaised.opacity(0.9))
        .overlay(
            Capsule().stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
        )
        .clipShape(Capsule())
        .studioFloatingShadow()
        .onReceive(timer) { _ in
            session.tick()
        }
    }

    private var isAwaitingConfirm: Bool {
        if case .awaiting = confirmPhase { return true }
        return false
    }

    /// 微型电平条——轨道底边框线色、图谱蓝填充随值生长。
    private var levelBar: some View {
        Capsule()
            .fill(StudioTheme.separatorLine)
            .frame(width: 44, height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(StudioTheme.accent)
                        .frame(
                            width: geometry.size.width
                                * min(max(session.microphoneLevel, 0), 1)
                        )
                }
            }
            .clipShape(Capsule())
            .accessibilityLabel("输入电平")
            .accessibilityValue(
                "\(Int((min(max(session.microphoneLevel, 0), 1) * 100).rounded()))%"
            )
    }

    /// 复用现有状态文案槽位：确认提示不新增占位、不遮挡计时与标记。
    private var statusText: String {
        if isAwaitingConfirm { return "再按一次确认停止" }
        if session.isBusy { return "正在切换录制状态…" }
        // 摄像头启动失败不能只写进已隐藏的主窗口 toast——
        // 录制期间唯一可见的是 HUD，状态行必须把这件事说出口。
        if session.cameraFailed { return "摄像头未启用，本次只录屏幕" }
        return hasCamera
            ? "摄像头正在单独录制"
            : "点击位置会自动放大"
    }

    /// Esc 与停止按钮共用同一入口：设置关 = 一次即停（现状）；
    /// 设置开 = 窗口内第二次确认才停，超时由延时任务回退待机。
    private func handleStopRequest() {
        let (phase, action) = StopConfirmation.press(
            enabled: stopRequiresConfirmation,
            phase: confirmPhase,
            now: Date(),
            window: StopConfirmation.window
        )
        confirmPhase = phase
        switch action {
        case .prompt:
            if case let .awaiting(deadline) = phase {
                scheduleConfirmTimeout(deadline: deadline)
            }
        case .stop:
            confirmTimeoutTask?.cancel()
            confirmTimeoutTask = nil
            onStop()
        }
    }

    private func scheduleConfirmTimeout(deadline: Date) {
        confirmTimeoutTask?.cancel()
        confirmTimeoutTask = Task {
            try? await Task.sleep(
                for: .seconds(max(0, deadline.timeIntervalSinceNow))
            )
            guard !Task.isCancelled else { return }
            guard case .awaiting = confirmPhase else { return }
            confirmPhase = .idle
            confirmTimeoutTask = nil
        }
    }

    private func timeText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?
    private var session: RecordingHUDSession?

    func show(
        startedAt: Date,
        hasCamera: Bool,
        stopRequiresConfirmation: Bool,
        screen: NSScreen?,
        onMarker: @escaping () -> Void,
        onToggleTeleprompter: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onToggleCameraAdjust: @escaping () -> Void,
        onToggleCameraShape: @escaping () -> Void
    ) {
        hide()
        let session = RecordingHUDSession(startedAt: startedAt)
        self.session = session
        // 用 HUDPanel（canBecomeKey）＋ makeKeyAndOrderFront，
        // 让 Esc 停止快捷键真正可达。面板尺寸与内容同源，避免裁掉端部按钮。
        let contentSize = FloatingPanelLayout.hudContentSize(hasCamera: hasCamera)
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        // 令牌随窗口外观解析；图谱蓝线描为单套浅色，浮层同样锁浅色，
        // 与主界面同一套观感。
        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: RecordingHUDView(
                session: session,
                hasCamera: hasCamera,
                stopRequiresConfirmation: stopRequiresConfirmation,
                onMarker: onMarker,
                onToggleTeleprompter: onToggleTeleprompter,
                onPause: onPause,
                onResume: onResume,
                onStop: onStop,
                onToggleCameraAdjust: onToggleCameraAdjust,
                onToggleCameraShape: onToggleCameraShape
            )
        )
        // 放在被录屏的顶部居中（主窗口隐藏时 NSScreen.main 不一定
        // 是用户盯着的那块屏）。
        if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(
                FloatingPanelLayout.topCenteredOrigin(
                    visibleFrame: visibleFrame,
                    panelSize: contentSize
                )
            )
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func setPaused(_ paused: Bool) {
        session?.setPaused(paused)
    }

    func setBusy(_ busy: Bool) {
        session?.setBusy(busy)
    }

    /// 摄像头启动失败时由 StudioModel 调用，HUD 状态行代播。
    func setCameraFailed() {
        session?.setCameraFailed()
    }

    /// 电平与静音告警转发（会话未展示时安全忽略）。
    func setMicrophoneLevel(_ level: Double) {
        session?.setMicrophoneLevel(level)
    }

    func setSilentAlarmVisible(_ visible: Bool) {
        session?.setSilentAlarmVisible(visible)
    }

    @discardableResult
    func toggleCameraAdjusting() -> Bool {
        session?.toggleCameraAdjusting() ?? false
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        session = nil
    }
}

struct CountdownHUDView: View {
    let seconds: Int
    let onFinished: () -> Void

    @State private var remaining: Int

    init(seconds: Int, onFinished: @escaping () -> Void) {
        self.seconds = seconds
        self.onFinished = onFinished
        _remaining = State(initialValue: seconds)
    }

    private let timer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        ZStack {
            Circle()
                .fill(StudioTheme.surfaceRaised.opacity(0.9))
                .overlay(
                    Circle().stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
                )
            VStack(spacing: StudioTheme.space2) {
                Text("\(remaining)")
                    .font(.system(size: 76, weight: .semibold, design: .rounded))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .contentTransition(.numericText())
                Text("准备录制")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                // Esc 取消早已实现（keyMonitor keyCode 53），
                // 但浮层上没有任何提示——补一行说明。
                Text("按 Esc 取消")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .frame(width: 190, height: 190)
        .onReceive(timer) { _ in
            if remaining > 1 {
                remaining -= 1
            } else {
                onFinished()
            }
        }
    }
}

@MainActor
final class CountdownHUDController {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var didFinish = false

    func show(seconds: Int, screen: NSScreen?) async -> Bool {
        guard seconds > 0 else { return true }
        hide()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.didFinish = false
            let panel = HUDPanel(
                contentRect: NSRect(
                    origin: .zero,
                    size: CGSize(
                        width: FloatingPanelLayout.countdownSize,
                        height: FloatingPanelLayout.countdownSize
                    )
                ),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.appearance = NSAppearance(named: .aqua)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(
                rootView: CountdownHUDView(
                    seconds: seconds,
                    onFinished: { [weak self] in
                        self?.finish(true)
                    }
                )
            )
            // 与 HUD 同屏：出现在被录屏的正中，而不是 NSScreen.main。
            if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
                panel.setFrameOrigin(
                    FloatingPanelLayout.centeredOrigin(
                        visibleFrame: visibleFrame,
                        panelSize: CGSize(
                            width: FloatingPanelLayout.countdownSize,
                            height: FloatingPanelLayout.countdownSize
                        )
                    )
                )
            }
            panel.makeKeyAndOrderFront(nil)
            self.panel = panel
            self.keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                if event.keyCode == 53 {
                    self?.finish(false)
                    return nil
                }
                return event
            }
        }
    }

    func hide() {
        finish(false)
    }

    private func finish(_ success: Bool) {
        guard !didFinish else { return }
        didFinish = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: success)
    }
}
