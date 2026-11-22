import SwiftUI

/// 1118 Loop：录制中主窗口的兜底操作页。HUD 悬浮条是常驻入口，但用户
/// 可能把它拖到别的屏、被其他窗口盖住，或场景里根本没看到它；点 Dock /
/// ⌘Tab 把 App 带回前台时，这页保证「再次进入软件」永远能暂停 / 继续 /
/// 标记 / 提词 / 停止。主窗口自身同样被本 App 排除机制挡在录像之外
/// （`excludingApplications` + `sharingType = .none`）。
@MainActor
struct RecordingStatusView: View {
    @ObservedObject var model: StudioModel
    @StateObject private var session: RecordingHUDSession
    @State private var markerCount = 0
    private let timer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common
    ).autoconnect()

    init(model: StudioModel) {
        self.model = model
        let startedSession = RecordingHUDSession(
            startedAt: model.recordingStartedAt ?? Date()
        )
        if model.isRecordingPaused {
            startedSession.setPaused(true)
        }
        _session = StateObject(wrappedValue: startedSession)
    }

    var body: some View {
        VStack(spacing: StudioTheme.space5) {
            Image(systemName: "record.circle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(StudioTheme.recIndicator)
                .accessibilityHidden(true)

            VStack(spacing: StudioTheme.space1) {
                Text(session.isPaused ? "已暂停" : "正在录制")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(elapsedText)
                    .font(
                        .system(size: 44, weight: .semibold, design: .rounded)
                    )
                    .monospacedDigit()
                    .foregroundStyle(StudioTheme.accent)
            }

            Text("悬浮操作条与本窗口都不会被录入画面")
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)

            HStack(spacing: StudioTheme.space3) {
                Button {
                    if session.isPaused {
                        Task { await model.resumeRecording() }
                    } else {
                        Task { await model.pauseRecording() }
                    }
                } label: {
                    Label(
                        session.isPaused ? "继续" : "暂停",
                        systemImage: session.isPaused
                            ? "play.fill" : "pause.fill"
                    )
                    .padding(.horizontal, StudioTheme.space4)
                    .frame(height: 32)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(model.isRecordingTransitioning)

                Button {
                    guard !session.isPaused else { return }
                    markerCount += 1
                    model.addRecordingMarker()
                } label: {
                    Label(
                        markerCount == 0 ? "标记" : "标记 \(markerCount)",
                        systemImage: "flag.fill"
                    )
                    .padding(.horizontal, StudioTheme.space4)
                    .frame(height: 32)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(session.isPaused || model.isRecordingTransitioning)

                Button {
                    model.toggleTeleprompterPanel()
                } label: {
                    Label("提词器", systemImage: "text.quote")
                        .padding(.horizontal, StudioTheme.space4)
                        .frame(height: 32)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("提词器面板（不会进入录像）")
            }

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("停止录制", systemImage: "stop.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, StudioTheme.space6)
                    .frame(height: 38)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(model.isRecordingTransitioning)
            .help("停止录制（⌘⇧R）")
        }
        .padding(StudioTheme.space7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioTheme.surfaceCanvas)
        .onReceive(timer) { _ in
            session.tick()
        }
        .onChange(of: model.isRecordingPaused) { _, paused in
            session.setPaused(paused)
        }
    }

    private var elapsedText: String {
        let total = Int(session.elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
