import SwiftUI

struct RecorderSetupView: View {
    @ObservedObject var model: StudioModel
    @State private var advancedExpanded = false
    @State private var scriptDraft = ""
    @State private var isScriptEditorPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: StudioTheme.space6) {
                sourcePreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                setupPanel
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, StudioTheme.space7)
            .padding(.top, StudioTheme.space6)
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .onAppear {
            model.recheckScreenPermission()
            if model.setup.captureCamera && !model.cameraPreviewActive {
                Task { await model.activateCameraPreview() }
            }
            // 工作台可见即开预览电平（只在工作台运行）
            model.startMicrophonePreviewLevel()
            // 权限在系统设置里改过也能跟上（摄像头/麦克风引导卡两态）
            model.refreshDeviceAuthorizations()
            model.presentWindowPickerIfNeeded()
        }
        .onDisappear {
            model.stopMicrophonePreviewLevel()
        }
        // 麦克风开关切换同步预览电平会话
        .onChange(of: model.setup.captureMicrophone) { _, enabled in
            if enabled {
                model.startMicrophonePreviewLevel()
            } else {
                model.stopMicrophonePreviewLevel()
            }
        }
        .task(id: model.sourcePreviewRequestKey) {
            await model.refreshSourcePreview()
        }
        .sheet(
            isPresented: Binding(
                get: { model.isWindowPickerPresented },
                set: { presented in
                    if !presented {
                        model.dismissWindowPicker()
                    }
                }
            )
        ) {
            WindowPickerView(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: StudioTheme.space5) {
            VStack(alignment: .leading, spacing: StudioTheme.space2) {
                Text("录制工作台")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            Spacer()
            Button {
                refreshSources()
            } label: {
                Label("刷新来源", systemImage: "arrow.clockwise")
                    .font(.callout)
                    .padding(.horizontal, StudioTheme.space4)
                    .frame(height: 30)
            }
            .buttonStyle(SecondaryActionButtonStyle())
        }
        .padding(.horizontal, StudioTheme.space7)
        .padding(.top, StudioTheme.space6)
        .padding(.bottom, StudioTheme.space6)
    }

    /// 屏幕录制权限预检引导卡可见性（纯逻辑见 ScreenPermissionGuide）。
    private var showsScreenPermissionGuide: Bool {
        ScreenPermissionGuide.shouldShowCard(
            permissionGranted: model.screenPermissionGranted,
            isPreparing: model.isPreparing,
            isRecording: model.isRecording
        )
    }

    private var screenPermissionGuideCard: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.warning)
                Text("需要屏幕录制权限")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            Text(
                "现在拿不到任何屏幕画面。请在“\(PrivacySettingsPane.screenRecording.pathDescription)”里允许“八角录屏”，回来后点“重新检查”。"
            )
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: StudioTheme.space3) {
                Button {
                    openScreenPermissionSettings()
                } label: {
                    Label("打开系统设置", systemImage: "gearshape")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, StudioTheme.space3)
                        .frame(height: 26)
                }
                .buttonStyle(
                    PrimaryActionButtonStyle(cornerRadius: StudioTheme.radiusS)
                )
                .help("打开隐私与安全性里的屏幕录制设置")

                Button {
                    model.recheckScreenPermission()
                } label: {
                    Label("重新检查", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, StudioTheme.space3)
                        .frame(height: 26)
                }
                .buttonStyle(
                    SecondaryActionButtonStyle(
                        cornerRadius: StudioTheme.radiusS
                    )
                )
                .accessibilityLabel("重新检查屏幕录制权限")
            }
        }
        .padding(StudioTheme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.warningSurface)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .stroke(StudioTheme.warningBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
    }

    private func openScreenPermissionSettings() {
        PrivacySettingsPane.screenRecording.open()
    }

    private var sourcePreview: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            if showsScreenPermissionGuide {
                screenPermissionGuideCard
            }

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                        .fill(StudioTheme.surfaceSunken)
                    if let image = model.sourcePreviewImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                        regionOverlay(
                            imageSize: image.size,
                            containerSize: geometry.size
                        )
                    } else if model.sourcePreviewLoading {
                        VStack(spacing: StudioTheme.space3) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(StudioTheme.accent)
                            Text("正在读取当前画面…")
                                .font(.callout)
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                    } else {
                        sourcePreviewPlaceholder
                    }
                }
                // 图鉴图版：外细内稍强的双线框（纪律 9 唯一签名式结构；
                // 内框同心：圆角 = 外框圆角 − 内缩 5）
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                        .stroke(StudioTheme.separatorLine, lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: StudioTheme.radiusM - 5
                    )
                    .inset(by: 5)
                    .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
                )
                .overlay(alignment: .bottomLeading) {
                    sourcePlate
                        .padding(StudioTheme.space4)
                }
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
            }
            .frame(maxHeight: .infinity)

            HStack(alignment: .top, spacing: StudioTheme.space3) {
                Image(systemName: previewStatusIcon)
                    .font(.subheadline)
                    .foregroundStyle(
                        previewStatusIsWarning
                            ? StudioTheme.warning
                            : StudioTheme.accent
                    )
                    .padding(.top, StudioTheme.space1)
                Text(previewStatusText)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28, alignment: .top)
        }
        .studioCard()
    }

    /// 图版标牌：左下角一枚小牌显示当前来源（如「来源预览 · 屏幕」）。
    private var sourcePlate: some View {
        Text("来源预览 · \(model.setup.sourceKind.title)")
            .font(.callout.weight(.medium))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, StudioTheme.space3)
            .frame(height: 22)
            .background(StudioTheme.surfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                    .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
    }

    /// 纪律 5：权限警告只在顶部告示卡说一次——占位区只留一句短话。
    private var sourcePreviewPlaceholder: some View {
        VStack(spacing: StudioTheme.space3) {
            Image(systemName: model.setup.sourceKind.icon)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(StudioTheme.textTertiary)
            Text("暂无可预览画面")
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 360)
        }
        .padding(StudioTheme.space6)
    }

    /// 纪律 5：告示卡可见时，底部状态行不再重复同一警告，回落到来源摘要。
    private var previewStatusText: String {
        if showsScreenPermissionGuide {
            return sourceDetail
        }
        return model.sourcePreviewMessage ?? sourceDetail
    }

    private var previewStatusIsWarning: Bool {
        !showsScreenPermissionGuide && model.sourcePreviewMessage != nil
    }

    private var previewStatusIcon: String {
        previewStatusIsWarning ? "exclamationmark.circle" : "checkmark.circle"
    }

    /// 预览电平条——与 HUD 电平同一视觉语言（4pt 细轨 +
    /// 图谱蓝填充随值生长）。
    private var previewLevelBar: some View {
        Capsule()
            .fill(StudioTheme.separatorLine)
            .frame(width: 120, height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(StudioTheme.accent)
                        .frame(
                            width: geometry.size.width
                                * min(max(model.previewMicrophoneLevel, 0), 1)
                        )
                }
            }
            .clipShape(Capsule())
    }

    private var setupPanel: some View {
        VStack(spacing: StudioTheme.space5) {
            ScrollView {
                VStack(spacing: StudioTheme.space5) {
                    sourceCard
                    teleprompterCard
                    cameraAudioCard
                    advancedCard
                }
                .padding(.bottom, StudioTheme.space3)
            }
            .scrollIndicators(.visible)
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            sectionHeader("来源", icon: "rectangle.inset.filled")
            sourcePicker
            sourceControls
        }
        .studioCard()
    }

    private var sourcePicker: some View {
        HStack(spacing: StudioTheme.space2) {
            ForEach(CaptureSourceKind.allCases) { kind in
                Button {
                    model.setSourceKind(kind)
                } label: {
                    VStack(spacing: StudioTheme.space2) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(kind.title)
                            .font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 45)
                }
                .buttonStyle(
                    SecondaryActionButtonStyle(
                        cornerRadius: StudioTheme.radiusS,
                        isSelected: model.setup.sourceKind == kind,
                        transparentRest: true
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var sourceControls: some View {
        switch model.setup.sourceKind {
        case .display:
            displayPicker
        case .window:
            windowSummary
        case .region:
            VStack(alignment: .leading, spacing: StudioTheme.space3) {
                displayPicker
                HStack(spacing: StudioTheme.space3) {
                    VStack(alignment: .leading, spacing: StudioTheme.space1) {
                        Text(regionDescription)
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    Spacer()
                    if model.setup.region != nil {
                        smallButton("清除区域", icon: "xmark.rectangle") {
                            model.clearRegion()
                        }
                        smallButton("重新框选", icon: "rectangle.dashed") {
                            model.chooseRegion()
                        }
                    } else {
                        smallButton("框选区域", icon: "rectangle.dashed") {
                            model.chooseRegion()
                        }
                    }
                }
            }
        }
    }

    private var displayPicker: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space2) {
            fieldLabel("显示器")
            Picker("", selection: $model.setup.displayID) {
                ForEach(model.displays) { display in
                    Text("\(display.name) · \(display.resolution)")
                        .tag(display.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(StudioTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var windowSummary: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space3) {
            HStack(spacing: StudioTheme.space3) {
                if let window = model.setup.window {
                    WindowAppIcon(
                        bundleIdentifier: window.bundleIdentifier,
                        size: 24
                    )
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 16))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: StudioTheme.space1) {
                    Text(
                        model.setup.window?.displayTitle
                            ?? "尚未选择窗口"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    if let window = model.setup.window {
                        Text(
                            "\(window.width) × \(window.height) · \(displayName(for: window))"
                        )
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                    }
                }
                Spacer()
            }
            HStack {
                smallButton(
                    model.setup.window == nil ? "选择窗口…" : "更换窗口…",
                    icon: "macwindow"
                ) {
                    model.presentWindowPicker()
                }
                Spacer()
            }
        }
        .padding(StudioTheme.space3)
        .background(StudioTheme.surfaceCanvas)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                .stroke(StudioTheme.separatorLine, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))
    }

    private var cameraAudioCard: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            sectionHeader("镜头与声音", icon: "person.crop.circle")

            Toggle(
                isOn: Binding(
                    get: { model.setup.captureCamera },
                    set: { model.setCaptureCamera($0) }
                )
            ) {
                optionLabel(
                    "person.crop.circle",
                    title: "摄像头",
                    detail: "单独保存，录制后可调整"
                )
            }
            .toggleStyle(.switch)
            .tint(StudioTheme.accent)

            if model.setup.captureCamera {
                cameraPermissionGuide
            }

            if model.setup.captureCamera {
                HStack(alignment: .top, spacing: StudioTheme.space3) {
                    ZStack {
                        RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                            .fill(StudioTheme.surfaceSunken)
                        if
                            model.cameraPreviewActive,
                            !model.isPreparing,
                            !model.isRecording
                        {
                            CameraPreviewView(
                                session: model.cameraRecorder.session,
                                mirrored: true
                            )
                            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
                        } else if model.cameraAuthorization != .authorized {
                            Image(systemName: "video.slash")
                                .font(.system(size: 16))
                                .foregroundStyle(StudioTheme.textTertiary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .tint(StudioTheme.accent)
                        }
                    }
                    .frame(width: 86, height: 52)

                    VStack(spacing: StudioTheme.space2) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { model.setup.cameraDeviceID ?? "" },
                                set: {
                                    model.setCameraDevice(
                                        $0.isEmpty ? nil : $0
                                    )
                                }
                            )
                        ) {
                            ForEach(model.cameraDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(StudioTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        StudioSegmented(
                            selection: Binding(
                                get: { model.setup.cameraResolution },
                                set: { model.setCameraResolution($0) }
                            ),
                            options: Array(CameraResolution.allCases),
                            title: { $0.title }
                        )
                    }
                }
            }

            Divider()
                .overlay(StudioTheme.separatorLine)

            Toggle(
                isOn: $model.setup.captureMicrophone
            ) {
                optionLabel(
                    "microphone.fill",
                    title: "麦克风",
                    detail: "录下你的讲解"
                )
            }
            .toggleStyle(.switch)
            .tint(StudioTheme.accent)

            microphonePermissionHint

            if model.setup.captureMicrophone {
                // 预览电平条（开录前确认设备有信号；失败降级
                // 时不出现、零报错）。与 HUD 电平同一视觉语言。
                HStack(spacing: StudioTheme.space2) {
                    Image(systemName: "waveform")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textTertiary)
                    previewLevelBar
                }
                .accessibilityLabel("麦克风输入电平")
                .accessibilityValue(
                    "\(Int((model.previewMicrophoneLevel * 100).rounded()))%"
                )
                Picker(
                    "",
                    selection: Binding(
                        get: { model.setup.microphoneDeviceID ?? "" },
                        set: {
                            model.setMicrophoneDevice(
                                $0.isEmpty ? nil : $0
                            )
                        }
                    )
                ) {
                    Text("系统默认").tag("")
                    ForEach(model.microphoneDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(StudioTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("麦克风输入")
            }

            Toggle(
                isOn: $model.setup.captureSystemAudio
            ) {
                optionLabel(
                    "speaker.wave.2.fill",
                    title: "系统声音",
                    detail: "应用播放的声音"
                )
            }
            .toggleStyle(.switch)
            .tint(StudioTheme.accent)
        }
        .studioCard()
    }

    private var teleprompterScriptCount: Int {
        model.setup.teleprompter.script
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count
    }

    /// 已设置文稿时的首行预览（跳过空行，截断过长行）。
    private var teleprompterScriptPreview: String {
        let firstLine = model.setup.teleprompter.script
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return "空文稿" }
        return String(firstLine.prefix(40))
    }

    private func clearTeleprompterScript() {
        model.setup.teleprompter.script = ""
        model.syncTeleprompterPanel()
    }

    private var teleprompterCard: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            sectionHeader("提词器", icon: "text.quote")

            if model.setup.teleprompter.hasScript {
                HStack(spacing: StudioTheme.space3) {
                    Text("\(teleprompterScriptCount) 字")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(StudioTheme.accent)
                        .padding(.horizontal, StudioTheme.space3)
                        .frame(height: 20)
                        .background(StudioTheme.accent.opacity(0.1))
                        .clipShape(Capsule())

                    Text(teleprompterScriptPreview)
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: StudioTheme.space2)

                    Button {
                        clearTeleprompterScript()
                    } label: {
                        Text("清除")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(StudioTheme.errorText)
                    }
                    .buttonStyle(GhostActionButtonStyle())
                    .help("清除已设置的提词文稿")
                }
            }

            HStack(spacing: StudioTheme.space3) {
                Button {
                    scriptDraft = model.setup.teleprompter.script
                    isScriptEditorPresented = true
                } label: {
                    Label("编辑文稿", systemImage: "text.cursor")
                        .font(.callout)
                        .padding(.horizontal, StudioTheme.space4)
                        .frame(height: 28)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("打开文稿编辑，可粘贴或输入讲稿")

                Button {
                    model.importTeleprompterScript()
                } label: {
                    Label("导入文件", systemImage: "doc.text")
                        .font(.callout)
                        .padding(.horizontal, StudioTheme.space4)
                        .frame(height: 28)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("导入 .txt / .md 文稿，上限 1 MB")

                Spacer(minLength: StudioTheme.space2)

                Button {
                    model.toggleTeleprompterPanel()
                } label: {
                    Label(
                        model.isTeleprompterVisible
                            ? "关闭面板" : "打开提词面板",
                        systemImage: model.isTeleprompterVisible
                            ? "rectangle.portrait.slash"
                            : "rectangle.portrait"
                    )
                    .font(.callout)
                    .padding(.horizontal, StudioTheme.space4)
                    .frame(height: 28)
                }
                .buttonStyle(
                    SecondaryActionButtonStyle(
                        isSelected: model.isTeleprompterVisible
                    )
                )
                .help("打开面板预演文稿，录制中保持可用")
            }

            HStack(spacing: StudioTheme.space4) {
                fontSpeedSlider(
                    label: "字号",
                    value: Binding(
                        get: { model.setup.teleprompter.fontSize },
                        set: {
                            model.setup.teleprompter.fontSize = $0
                            model.syncTeleprompterPanel()
                        }
                    ),
                    range: 16 ... 64,
                    step: 2
                )
                fontSpeedSlider(
                    label: "速度",
                    value: Binding(
                        get: { model.setup.teleprompter.speed },
                        set: {
                            model.setup.teleprompter.speed = $0
                            model.syncTeleprompterPanel()
                        }
                    ),
                    range: 1 ... 10,
                    step: 1
                )
            }

        }
        .studioCard()
        .sheet(isPresented: $isScriptEditorPresented) {
            scriptEditorSheet
        }
    }

    /// 文稿编辑 sheet：沿用卡片原有 TextEditor 能力，不另造编辑器。
    private var scriptEditorSheet: some View {
        VStack(alignment: .leading, spacing: StudioTheme.space4) {
            HStack(spacing: StudioTheme.space4) {
                Text("提词文稿")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Button("取消") {
                    isScriptEditorPresented = false
                }
                .font(.callout)
                .padding(.horizontal, StudioTheme.space4)
                .frame(height: 28)
                .buttonStyle(SecondaryActionButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button {
                    model.setup.teleprompter.script = scriptDraft
                    model.syncTeleprompterPanel()
                    isScriptEditorPresented = false
                } label: {
                    Text("保存")
                        .padding(.horizontal, StudioTheme.space4)
                        .frame(height: 28)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .keyboardShortcut(.defaultAction)
                .font(.callout)
            }

            TextEditor(text: $scriptDraft)
                .font(.body)
                .foregroundStyle(StudioTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(StudioTheme.space2)
                .background(StudioTheme.surfaceCanvas)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTheme.radiusS)
                        .stroke(StudioTheme.separatorLineStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusS))

        }
        .padding(StudioTheme.space5)
        .frame(width: 520, height: 400)
        .background(StudioTheme.surfaceCanvas)
    }

    private func fontSpeedSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack {
            fieldLabel(label)
            StudioSlider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        let stepped = (newValue / step).rounded() * step
                        value.wrappedValue = min(
                            max(stepped, range.lowerBound),
                            range.upperBound
                        )
                    }
                ),
                range: range
            )
            Text(
                label == "速度"
                    ? "\(Int(value.wrappedValue)) 档"
                    : "\(Int(value.wrappedValue))"
            )
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(StudioTheme.textSecondary)
            .frame(width: 42, alignment: .trailing)
        }
    }

    /// 点击放大参数滑条：与编辑器检查器同一量程，值显示一位小数。
    private func clickZoomSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack {
            fieldLabel(label)
            StudioSlider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        let stepped = (newValue / step).rounded() * step
                        value.wrappedValue = min(
                            max(stepped, range.lowerBound),
                            range.upperBound
                        )
                    }
                ),
                range: range
            )
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// 摄像头权限引导：未询问 → 一键请求授权（系统弹窗会把本应用
    /// 登记进系统列表）；已拒绝 → 打开对应面板＋重新检查。
    @ViewBuilder
    private var cameraPermissionGuide: some View {
        if model.cameraAuthorization == .notDetermined {
            permissionGuideCard(
                title: "开启摄像头需要授权",
                message: "点“请求授权”，在系统弹窗里选“允许”。如果没看到弹窗，"
                    + "再点“打开系统设置”，在“\(PrivacySettingsPane.camera.pathDescription)”里允许“八角录屏”。",
                primaryTitle: "请求授权",
                primaryIcon: "checkmark.shield",
                primaryHelp: "请求摄像头权限并登记到系统设置列表",
                primaryAction: {
                    Task { await model.requestCameraAuthorization() }
                },
                secondaryTitle: "打开系统设置",
                secondaryIcon: "gearshape",
                secondaryHelp: "打开隐私与安全性里的摄像头设置",
                secondaryAction: {
                    PrivacySettingsPane.camera.open()
                }
            )
        } else if model.cameraPermissionDenied {
            permissionGuideCard(
                title: "摄像头权限已关闭",
                message: "请在“\(PrivacySettingsPane.camera.pathDescription)”里打开“八角录屏”，"
                    + "回来后点“重新检查”。",
                primaryTitle: "打开系统设置",
                primaryIcon: "gearshape",
                primaryHelp: "打开隐私与安全性里的摄像头设置",
                primaryAction: {
                    PrivacySettingsPane.camera.open()
                },
                secondaryTitle: "重新检查",
                secondaryIcon: "arrow.clockwise",
                secondaryHelp: "重新检查摄像头权限",
                secondaryAction: {
                    Task { await model.recheckCameraPermission() }
                }
            )
        }
    }

    /// 麦克风权限提示（开启麦克风但尚未授权时出现）。
    @ViewBuilder
    private var microphonePermissionHint: some View {
        if model.setup.captureMicrophone,
            model.microphoneAuthorization != .authorized
        {
            permissionGuideCard(
                title: model.microphoneAuthorization == .notDetermined
                    ? "开启麦克风需要授权"
                    : "麦克风权限已关闭",
                message: model.microphoneAuthorization == .notDetermined
                    ? "点“请求授权”，在系统弹窗里选“允许”。如果没看到弹窗，"
                        + "再点“打开系统设置”，在“\(PrivacySettingsPane.microphone.pathDescription)”里允许“八角录屏”。"
                    : "请在“\(PrivacySettingsPane.microphone.pathDescription)”里打开“八角录屏”，回来后点“重新检查”。",
                primaryTitle: model.microphoneAuthorization == .notDetermined
                    ? "请求授权" : "打开系统设置",
                primaryIcon: model.microphoneAuthorization == .notDetermined
                    ? "checkmark.shield" : "gearshape",
                primaryHelp: model.microphoneAuthorization == .notDetermined
                    ? "请求麦克风权限并登记到系统设置列表"
                    : "打开隐私与安全性里的麦克风设置",
                primaryAction: {
                    if model.microphoneAuthorization == .notDetermined {
                        Task { await model.requestMicrophoneAuthorization() }
                    } else {
                        PrivacySettingsPane.microphone.open()
                    }
                },
                secondaryTitle: model.microphoneAuthorization == .notDetermined
                    ? "打开系统设置" : "重新检查",
                secondaryIcon: model.microphoneAuthorization == .notDetermined
                    ? "gearshape" : "arrow.clockwise",
                secondaryHelp: "重新检查麦克风权限",
                secondaryAction: {
                    if model.microphoneAuthorization == .notDetermined {
                        PrivacySettingsPane.microphone.open()
                    } else {
                        Task {
                            await model.requestMicrophoneAuthorization()
                        }
                    }
                }
            )
        }
    }

    /// 统一的权限引导卡（与屏幕录制权限卡同一视觉语言）。
    private func permissionGuideCard(
        title: String,
        message: String,
        primaryTitle: String,
        primaryIcon: String,
        primaryHelp: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryIcon: String,
        secondaryHelp: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space2) {
            HStack(spacing: StudioTheme.space2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.warning)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: StudioTheme.space3) {
                Button(action: primaryAction) {
                    Label(primaryTitle, systemImage: primaryIcon)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, StudioTheme.space3)
                        .frame(height: 26)
                }
                .buttonStyle(
                    PrimaryActionButtonStyle(cornerRadius: StudioTheme.radiusS)
                )
                .help(primaryHelp)
                Button(action: secondaryAction) {
                    Label(secondaryTitle, systemImage: secondaryIcon)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, StudioTheme.space3)
                        .frame(height: 26)
                }
                .buttonStyle(
                    SecondaryActionButtonStyle(
                        cornerRadius: StudioTheme.radiusS
                    )
                )
                .help(secondaryHelp)
            }
        }
        .padding(StudioTheme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.warningSurface)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.radiusM)
                .stroke(StudioTheme.warningBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.radiusM))
    }

    private var advancedCard: some View {
        InspectorDisclosureSection(
            title: "高级选项",
            icon: "slider.horizontal.3",
            summary: "\(model.setup.quality.title) · \(model.setup.fps) fps · \(countdownSummary)",
            isExpanded: $advancedExpanded
        ) {
            VStack(alignment: .leading, spacing: StudioTheme.space4) {
                fieldBlock("画质") {
                    StudioSegmented(
                        selection: $model.setup.quality,
                        options: Array(CaptureQuality.allCases),
                        title: { $0.title }
                    )
                }

                HStack(spacing: StudioTheme.space4) {
                    fieldBlock("帧率") {
                        StudioSegmented(
                            selection: $model.setup.fps,
                            options: [30, 60],
                            title: { "\($0)" }
                        )
                    }
                    fieldBlock("倒计时") {
                        StudioSegmented(
                            selection: $model.setup.countdown,
                            options: [0, 3, 5],
                            title: { $0 == 0 ? "关闭" : "\($0) 秒" }
                        )
                    }
                }

                HStack(alignment: .top, spacing: StudioTheme.space3) {
                    VStack(alignment: .leading, spacing: StudioTheme.space1) {
                        Text("记录按键")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.textPrimary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.setup.captureKeyStrokes },
                            set: { model.setup.captureKeyStrokes = $0 }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(StudioTheme.accent)
                    .help("录制期记录按键，用于画面角落的小条显示")
                }

                // 1118 Loop：点击放大前置配置——开关、停留时长与倍率
                // 随新工程写入，录制后仍可在编辑器检查器调整。
                VStack(alignment: .leading, spacing: StudioTheme.space2) {
                    HStack(alignment: .top, spacing: StudioTheme.space3) {
                        VStack(alignment: .leading, spacing: StudioTheme.space1) {
                            Text("点击放大")
                                .font(.callout)
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text("每个点击自动放大并回弹，可在编辑器逐条调整")
                                .font(.callout)
                                .foregroundStyle(StudioTheme.textSecondary)
                        }
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.setup.captureClickZoom },
                                set: { model.setup.captureClickZoom = $0 }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(StudioTheme.accent)
                        .help("开启后点击触发的自动放大随新工程写入")
                    }
                    if model.setup.captureClickZoom {
                        HStack(spacing: StudioTheme.space4) {
                            clickZoomSlider(
                                label: "停留",
                                value: Binding(
                                    get: { model.setup.clickZoomDuration },
                                    set: { model.setup.clickZoomDuration = $0 }
                                ),
                                range: 0.6 ... 3.5,
                                step: 0.1
                            )
                            clickZoomSlider(
                                label: "倍率",
                                value: Binding(
                                    get: { model.setup.clickZoomScale },
                                    set: { model.setup.clickZoomScale = $0 }
                                ),
                                range: 1.15 ... 2.8,
                                step: 0.05
                            )
                        }
                    }
                }

                Divider()
                    .overlay(StudioTheme.separatorLine)

                Text("录制期摄像头构图")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioTheme.textSecondary)

                if model.setup.captureCamera {
                    HStack(spacing: StudioTheme.space3) {
                        fieldBlock("位置") {
                            Picker(
                                "",
                                selection: Binding(
                                    get: {
                                        model.recordingCameraComposition.anchor
                                    },
                                    set: {
                                        model.setRecordingCameraAnchor($0)
                                    }
                                )
                            ) {
                                ForEach(CameraAnchor.allCases) { anchor in
                                    Text(anchor.title).tag(anchor)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(StudioTheme.accent)
                        }
                        fieldBlock("形状") {
                            Picker(
                                "",
                                selection: Binding(
                                    get: {
                                        model.recordingCameraComposition.shape
                                    },
                                    set: {
                                        model.setRecordingCameraShape($0)
                                    }
                                )
                            ) {
                                ForEach(CameraShape.allCases) { shape in
                                    Text(shape.title).tag(shape)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(StudioTheme.accent)
                        }
                    }

                    HStack {
                        fieldLabel("大小")
                        StudioSlider(
                            value: Binding(
                                get: {
                                    model.recordingCameraComposition.size
                                },
                                set: {
                                    model.setRecordingCameraSize($0)
                                }
                            ),
                            range: 0.1 ... 0.5
                        )
                        Text(
                            "\(Int((model.recordingCameraComposition.size * 100).rounded()))%"
                        )
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 34, alignment: .trailing)
                    }
                } else {
                    Text("打开摄像头后可设置录制期位置、形状和大小。")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .padding(.vertical, StudioTheme.space1)
        }
        .studioCard()
    }

    private var bottomBar: some View {
        HStack(spacing: StudioTheme.space5) {
            VStack(alignment: .leading, spacing: StudioTheme.space1) {
                Text(bottomSummary)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await model.startRecording() }
            } label: {
                HStack(spacing: StudioTheme.space3) {
                    if model.isPreparing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(StudioTheme.textOnAccentContainer)
                    } else {
                        Circle()
                            .fill(StudioTheme.textOnAccentContainer)
                            .frame(width: 8, height: 8)
                    }
                    Text(model.isPreparing ? "正在准备…" : "开始录制")
                        .font(.body.weight(.semibold))
                }
                .frame(width: 176)
                .frame(height: 38)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(model.isPreparing)
        }
        .padding(.horizontal, StudioTheme.space7)
        .padding(.vertical, StudioTheme.space4)
        .background(StudioTheme.surfacePanel.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudioTheme.separatorLine)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func regionOverlay(
        imageSize: NSSize,
        containerSize: CGSize
    ) -> some View {
        if
            model.setup.sourceKind == .region,
            let region = model.setup.region
        {
            let fitted = fittedRect(
                imageSize: imageSize,
                containerSize: containerSize
            )
            let rect = CGRect(
                x: fitted.minX + fitted.width * region.x,
                y: fitted.minY + fitted.height * region.y,
                width: fitted.width * region.width,
                height: fitted.height * region.height
            )
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(StudioTheme.surfaceSunken.opacity(0.45))
                    .frame(
                        width: containerSize.width,
                        height: max(0, rect.minY)
                    )
                    .position(
                        x: containerSize.width / 2,
                        y: max(0, rect.minY) / 2
                    )
                Rectangle()
                    .fill(StudioTheme.surfaceSunken.opacity(0.45))
                    .frame(
                        width: containerSize.width,
                        height: max(0, containerSize.height - rect.maxY)
                    )
                    .position(
                        x: containerSize.width / 2,
                        y: (rect.maxY + containerSize.height) / 2
                    )
                Rectangle()
                    .fill(StudioTheme.surfaceSunken.opacity(0.45))
                    .frame(
                        width: max(0, rect.minX),
                        height: rect.height
                    )
                    .position(
                        x: max(0, rect.minX) / 2,
                        y: rect.midY
                    )
                Rectangle()
                    .fill(StudioTheme.surfaceSunken.opacity(0.45))
                    .frame(
                        width: max(0, containerSize.width - rect.maxX),
                        height: rect.height
                    )
                    .position(
                        x: (rect.maxX + containerSize.width) / 2,
                        y: rect.midY
                    )

                Rectangle()
                    .stroke(
                        StudioTheme.accent,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Text("录制区域")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(StudioTheme.textOnAccentContainer)
                    .padding(.horizontal, StudioTheme.space2)
                    .frame(height: 19)
                    .background(StudioTheme.accentContainer)
                    .clipShape(Capsule())
                    .position(
                        x: rect.minX + 37,
                        y: max(rect.minY + StudioTheme.space4, StudioTheme.space4)
                    )
            }
            .allowsHitTesting(false)
        }
    }

    private func fittedRect(
        imageSize: NSSize,
        containerSize: CGSize
    ) -> CGRect {
        guard
            imageSize.width > 0,
            imageSize.height > 0,
            containerSize.width > 0,
            containerSize.height > 0
        else {
            return .zero
        }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private var sourceDetail: String {
        switch model.setup.sourceKind {
        case .display:
            let display = model.displays.first {
                $0.id == model.setup.displayID
            }
            return display.map {
                "\($0.name) · \($0.resolution)"
            } ?? "当前屏幕"
        case .window:
            guard let window = model.setup.window else {
                return "尚未选择窗口"
            }
            return "\(window.displayTitle) · \(window.width) × \(window.height)"
        case .region:
            return "\(displayNameForCurrentDisplay()) · \(regionDescription)"
        }
    }

    private var bottomSummary: String {
        let source = model.setup.sourceKind.title
        let audio = [
            model.setup.captureMicrophone ? "麦克风" : nil,
            model.setup.captureSystemAudio ? "系统声音" : nil
        ].compactMap { $0 }.joined(separator: " + ")
        let audioText = audio.isEmpty ? "无声音" : audio
        let camera = model.setup.captureCamera ? " · 摄像头" : ""
        return "\(source) · \(audioText)\(camera) · \(model.setup.quality.title)"
    }

    private var regionDescription: String {
        guard let region = model.setup.region else {
            return "还没有选择区域"
        }
        return String(
            format: "%.0f%% × %.0f%% 的显示器区域",
            region.width * 100,
            region.height * 100
        )
    }

    private var countdownSummary: String {
        model.setup.countdown == 0
            ? "无倒计时"
            : "\(model.setup.countdown) 秒倒计时"
    }

    private func displayName(for window: WindowCaptureInfo) -> String {
        guard let displayID = window.displayID else {
            return "其他显示器"
        }
        return model.displays.first { $0.id == displayID }?.name
            ?? "其他显示器"
    }

    private func displayNameForCurrentDisplay() -> String {
        model.displays.first { $0.id == model.setup.displayID }?.name
            ?? "当前屏幕"
    }

    private func refreshSources() {
        model.recheckScreenPermission()
        model.refreshDisplays()
        model.refreshMicrophoneDevices()
        Task {
            await model.refreshWindows()
            if model.setup.sourceKind != .window {
                await model.refreshSourcePreview(force: true)
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: StudioTheme.space2) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(StudioTheme.textPrimary)
        }
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value)
            .font(.callout)
            .foregroundStyle(StudioTheme.textSecondary)
    }

    private func fieldBlock<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: StudioTheme.space2) {
            fieldLabel(title)
            content()
        }
    }

    private func optionLabel(
        _ icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: StudioTheme.space3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 19)
            VStack(alignment: .leading, spacing: StudioTheme.space1) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
    }

    private func smallButton(
        _ title: String,
        icon: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: StudioTheme.space2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                }
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, StudioTheme.space3)
            .frame(height: 26)
        }
        .buttonStyle(
            SecondaryActionButtonStyle(cornerRadius: StudioTheme.radiusS)
        )
    }
}
