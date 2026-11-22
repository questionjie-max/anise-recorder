import AppKit
import AVFoundation
import Combine
import Foundation
import AniseRecorderCore
import OSLog
import UniformTypeIdentifiers

/// 精剪扫描状态（路线图 4.6）：未扫描 → 扫描中（可取消）→ 有候选 / 无候选
/// → 应用所选 → 未扫描；失败时给出原因。
enum SmartCutScanPhase: Equatable {
    case idle
    case scanning
    case ready
    case failed
}

private enum ChromaKeySampleError: LocalizedError {
    case noGreenKey

    var errorDescription: String? {
        switch self {
        case .noGreenKey:
            return "当前帧没有找到足够明显的绿色幕布，请换一帧或手动选色。"
        }
    }
}

/// 导出目录记忆：上次导出目录是应用偏好（UserDefaults），不进工程
/// 数据（Schema 不变，不迁移旧偏好）。MP4 / GIF / SRT 与章节文本四个
/// 导出面板共用一个键——用户心智是「我导出的地方」。
enum ExportDirectoryPreference {
    /// 历史标识：偏好 key 前缀保持旧名，改名会丢用户已有设置。
    static let key = "LocalStudio.lastExportDirectory"

    /// 目录仍存在、是目录且可写才算可用；删除、移走或变成文件都视为失效。
    static func isUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    /// 纯决策逻辑：记录目录仍可用则复用，否则回退 fallback（现有
    /// folderURL 行为）。校验器注入便于单测「存在可写 / 失效 / 无记录」。
    static func resolvedPanelDirectory(
        recorded: URL?,
        fallback: URL,
        isUsable: (URL) -> Bool
    ) -> URL {
        if let recorded, isUsable(recorded) {
            return recorded
        }
        return fallback
    }
}

/// 屏幕录制权限预检布尔 → 来源预览卡顶部引导卡可见性。
/// 已授权不出卡；未授权时只在空闲态出卡——准备中 / 录制中由
/// 「开始录制」的 ScreenRecorder.checkAccess 最终闸门负责，
/// 预检只是提示，不叠加抢注意力。
enum ScreenPermissionGuide {
    static func shouldShowCard(
        permissionGranted: Bool,
        isPreparing: Bool,
        isRecording: Bool
    ) -> Bool {
        !permissionGranted && !isPreparing && !isRecording
    }
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var projects: [StudioProject] = []
    @Published var selectedProjectID: UUID?
    @Published var draft: StudioProject?
    @Published var showHiddenProjects = StudioPreferences.showHiddenProjects
    @Published var defaultProjectRemovalAction =
        StudioPreferences.projectRemovalAction
    /// Esc 停止前需确认（应用偏好，默认关 = 直接停止的现状）。
    @Published var stopRequiresConfirmation =
        StudioPreferences.stopRequiresConfirmation
    @Published var displays: [DisplayOption] = []
    @Published var windows: [WindowCaptureInfo] = []
    @Published var windowPreview: NSImage?
    @Published var isWindowPickerPresented = false
    @Published var isDesktopWallpaperPickerPresented = false
    @Published private(set) var desktopWallpaperOptions:
        [DesktopWallpaperOption] = []
    @Published private(set) var sourcePreviewImage: NSImage?
    @Published private(set) var sourcePreviewLoading = false
    @Published private(set) var sourcePreviewMessage: String?
    @Published var cameraDevices: [CameraDeviceOption] = []
    @Published var microphoneDevices: [MicrophoneDeviceOption] = []
    @Published var setup: RecordSetup {
        didSet { persistSetup() }
    }
    @Published var isPreparing = false
    @Published var isRecording = false
    @Published var isRecordingPaused = false
    @Published private(set) var isRecordingTransitioning = false
    @Published var cameraPreviewActive = false
    @Published private(set) var cameraPermissionDenied = false
    /// 摄像头/麦克风当前授权状态（权限引导卡按它分「未询问/已拒绝」两态）。
    @Published private(set) var cameraAuthorization =
        AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var microphoneAuthorization =
        AVCaptureDevice.authorizationStatus(for: .audio)
    /// 屏幕录制权限预检结果；初始按已授权处理，避免已授权用户
    /// 首帧闪引导卡，onAppear / 刷新来源时再预检纠偏。
    @Published private(set) var screenPermissionGranted = true
    var cameraAccessChecker: () async -> Bool = {
        await CameraRecorder.requestAccess()
    }
    @Published var errorMessage: String?

    // 会话级麦克风电平与静音告警（不进 project.json）。
    /// 归一化输入电平 0...1（InputLevelMeter 换算）。
    @Published private(set) var microphoneLevel: Double = 0
    /// 静音告警可见（SilentAlarm 一次性状态机置位）。
    @Published private(set) var silentAlarmVisible = false
    private var silentAlarm = SilentAlarm()
    // 工作台预览电平（独立会话级写者，与录制中 microphoneLevel
    // 不共用——两个写者不串话；不进 project.json）。
    @Published private(set) var previewMicrophoneLevel: Double = 0
    private let microphonePreviewMonitor = MicrophonePreviewMonitor()
    /// 录制起始时刻（静音告警窗口的时间基准）；录制状态页读取它计时。
    @Published private(set) var recordingStartedAt: Date?
    @Published var previewLoading = false
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published var exportProgress: Double?
    @Published var exportMessage: String?
    @Published var captionStatus: String?
    @Published var isTranscribingCaptions = false
    /// P4 防卡死：本机转写进度（0…1）。nil = 未在转写。
    @Published private(set) var captionTranscriptionProgress: Double?
    /// P4 防卡死：启动工程扫描进行中（侧栏显示读取占位，避免误显空态）。
    @Published private(set) var isScanningProjects = false
    /// P4 防卡死：壁纸选择器加载中（壁纸全量解码下沉后台后填充）。
    @Published private(set) var isDesktopWallpaperLoading = false
    /// P5 加载态：窗口目录刷新进行中（窗口选择器「刷新窗口」按钮）。
    @Published private(set) var isRefreshingWindows = false
    /// P4 防卡死：转写 Task 句柄（供「取消」按钮终止识别链）。
    private var captionTranscriptionTask: Task<Void, Never>?
    /// P4 防卡死：落盘串行链——后台写盘仍保持与主线程发起顺序一致，
    /// 防止旧快照晚于新快照落盘（ProjectStore.saveLock 非 FIFO）。
    private var saveChain: Task<Void, Never>?
    @Published var exportResolution: ExportResolution = .fullHD
    @Published var exportFrameRate = 30
    @Published var exportCodec: ExportCodec = .h264
    /// 导出预设选中项（应用偏好记忆：选中即填充，可继续手调）。
    @Published var selectedExportPresetID: String =
        ExportPresetPreferences.loadSelectionID()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var smartCutMode: SmartCutMode = .natural
    @Published var smartCutProtectScreenActivity = true
    @Published var smartCutProtectSystemSound = true
    @Published private(set) var smartCutScanPhase: SmartCutScanPhase = .idle
    @Published private(set) var smartCutScanProgress: Double = 0
    @Published private(set) var smartCutAnalysis: SmartCutAnalysis?
    @Published private(set) var smartCutSelectedIndices: Set<Int> = []
    @Published private(set) var smartCutMessage: String?
    @Published private(set) var fillerSuggestions: [SmartCutFillerSuggestion] = []
    @Published private(set) var fillerSelectedIndices: Set<Int> = []
    /// 最近一次本机识别的原始分段（会话数据，不进 project.json）。
    /// 时间与当前时间线对齐；时间线或字幕一变即随建议一起失效清空。
    @Published private(set) var rawCaptionSegments: [SpeechSegment] = []
    /// 音频优化分析建议（会话数据，用户确认后才写入工程设置）。
    @Published private(set) var audioOptimizationProposal:
        AudioOptimizationAnalyzer.Proposal?
    @Published private(set) var isAnalyzingAudio = false
    /// 已处理音频缓存是否就绪；未就绪时预览回落原始音轨。
    @Published private(set) var audioProcessingReady = true
    /// A/B 试听旁路：只切换预览链参数，不写工程数据（1.2 块1）。
    @Published var audioPreviewBypassed = false
    /// 导出方式三选一——整片 / 入出点区间 / 按标记分段
    /// （三者互斥；默认整片，会话级选择不进 project.json）。
    enum ExportMode: String, CaseIterable, Identifiable {
        case full
        case range
        case markerSegments

        var id: String { rawValue }

        var title: String {
            switch self {
            case .full: return "整片"
            case .range: return "入出点"
            case .markerSegments: return "按标记分段"
            }
        }
    }
    @Published var exportMode: ExportMode = .full
    /// 1.2 导出区间：现由导出方式派生（导出方式 = 入出点时开启，
    /// 非破坏，工程不变）。
    var exportRangeEnabled: Bool { exportMode == .range }
    @Published private(set) var exportInPoint: Double?
    @Published private(set) var exportOutPoint: Double?
    /// 按标记分段导出的确认状态（会话级，不进工程数据）。
    /// 文件名基名默认取工程名，可编辑；未勾选的标记不参与分段。
    @Published var markerSegmentBaseName = ""
    @Published var markerSegmentExcludedIDs: Set<UUID> = []
    /// 分段目标文件夹；nil 时用上次导出目录（或工程目录）。
    @Published var markerSegmentFolder: URL?
    /// 分段导出失败 / 取消后保留的执行现场，供「重试剩余段」；
    /// 导出全部完成后清空。含确认时的工程快照，重试不受后续编辑影响。
    @Published private(set) var markerSegmentResume: MarkerSegmentResume?
    /// 失败 / 取消发生的段下标（重试起点）。
    @Published private(set) var markerSegmentFailedIndex: Int?
    /// 1.2 GIF 导出进行中（与 MP4 导出共用进度条）。
    @Published private(set) var isExportingGif = false
    /// GIF 尺寸档位：小 / 中 / 大 → 最长边 360 / 720 / 1080，
    /// 默认中档 720（沿用既有默认，会话级选择不进 project.json）。
    @Published var gifSizePreset: GifSizePreset = .medium
    /// 1.2 人脸居中：会话开关（默认关）+ 后台分析建议。
    @Published var faceCenteringEnabled = false
    @Published private(set) var isAnalyzingFaces = false
    @Published private(set) var faceFocusSegments: [FaceFocusPlanner.Segment]?
    /// C1 竖屏跟随：9:16 画布专用会话开关（默认关）+ 后台分析建议。
    /// 与人脸居中共用自动段池，竖屏画布下冲突时以竖屏跟随为准。
    @Published var portraitFollowEnabled = false
    /// 加深队列：竖屏跟随灵敏度三档（会话开关，默认标准）。
    @Published var portraitFollowSensitivity: PortraitFollowSensitivity =
        .standard
    @Published private(set) var isAnalyzingFollow = false
    @Published private(set) var portraitFollowSegments:
        [PortraitFollowPlanner.Segment]?
    @Published private(set) var isSamplingChromaKey = false
    /// 1.2 字幕术语表（应用偏好，不进单个工程）。
    @Published private(set) var glossaryEntries: [GlossaryEntry] =
        GlossaryPreferences.loadEntries()
    @Published private(set) var glossaryAutoApply: Bool =
        GlossaryPreferences.loadAutoApply()

    let player = AVPlayer()
    let cameraRecorder = CameraRecorder()

    private let recorder = ScreenRecorder()
    private let hud = RecordingHUDController()
    private let countdown = CountdownHUDController()
    /// 1118 Loop：录制中菜单栏状态项（暂停 / 标记 / 停止的第三入口）。
    private let statusItem = RecordingStatusItemController()
    private let regionSelector = RegionSelectorController()
    private let cameraOverlay = CameraRecordingOverlayController()
    private let teleprompterPanel = TeleprompterPanelController()
    private var timeObserver: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var previewTask: Task<Void, Never>?
    private var auditionTask: Task<Void, Never>?
    private var auditionPreviewEndTime: Double?
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var smartCutTask: Task<Void, Never>?
    private var audioAnalysisTask: Task<Void, Never>?
    private var audioPreparationTask: Task<Void, Never>?
    private var faceAnalysisTask: Task<Void, Never>?
    /// C1 竖屏跟随的后台分析任务（会话数据，建议不写工程）。
    private var followAnalysisTask: Task<Void, Never>?
    private var chromaKeySampleTask: Task<Void, Never>?
    private var chromaKeySampleID: UUID?
    private var isStopping = false
    private var screenRecordingStart: RecordingStartInfo?
    private var cameraSessions: [CameraRecordingResult] = []
    private var cameraEnabledForRecording = false
    private var undoHistory = ProjectUndoHistory()
    private var interactiveUndoSnapshot: StudioProject?
    private var rawRecordingMarkers: [(hostTime: Double, name: String)] = []
    private var sourcePreviewLoadedKey: String?
    private var sourceKindBeforeWindowPicker: CaptureSourceKind?
    /// 历史标识：偏好 key 前缀保持旧名，改名会丢用户已有设置。
    private let setupKey = "LocalStudio.recordSetup"
    private let previewLog = Logger(
        subsystem: "com.localstudio.recorder",
        category: "Preview"
    )

    init() {
        if
            let data = UserDefaults.standard.data(forKey: setupKey),
            let saved = try? JSONDecoder().decode(RecordSetup.self, from: data)
        {
            setup = saved
        } else {
            setup = RecordSetup()
        }
        displays = DisplayOption.current()
        if !displays.contains(where: { $0.id == setup.displayID }) {
            setup.displayID = displays.first(where: \.isMain)?.id
                ?? displays.first?.id
                ?? CGMainDisplayID()
        }
        cameraDevices = []
        microphoneDevices = []
        // P4 防卡死：AVCaptureDevice DiscoverySession 首访常见 50–300ms，
        // 不在首帧前的主线程做；空表期间设置页显示系统空态，发现完成后
        // 再做设备 ID 的对账。
        Task.detached { [weak self] in
            let cameras = CameraDeviceOption.available()
            let microphones = MicrophoneDeviceOption.available()
            await MainActor.run {
                guard let self else { return }
                self.cameraDevices = cameras
                self.microphoneDevices = microphones
                if
                    self.setup.cameraDeviceID == nil
                        || !cameras.contains(where: { $0.id == self.setup.cameraDeviceID })
                {
                    self.setup.cameraDeviceID = cameras.first?.id
                }
                if
                    let microphoneDeviceID = self.setup.microphoneDeviceID,
                    !microphones.contains(where: { $0.id == microphoneDeviceID })
                {
                    self.setup.microphoneDeviceID = nil
                }
            }
        }
        // P4 防卡死：启动扫描（逐目录读 project.json + 解码，随工程数量
        // 与 rawCursor 体积线性增长）不再在首帧前的主线程做；扫描+中断
        // 恢复合并成一个后台任务，完成后一次性合并进列表并聚合提示。
        isScanningProjects = true
        let includeHidden = showHiddenProjects
        Task.detached { [weak self] in
            let loaded = ProjectStore.loadAllWithIssues(includeHidden: includeHidden)
            let recovered = await ProjectStore.recoverInterruptedRecordings()
            await MainActor.run {
                guard let self else { return }
                let knownIDs = Set(loaded.projects.map(\.id))
                var merged = loaded.projects
                merged.append(
                    contentsOf: recovered.projects.filter {
                        !knownIDs.contains($0.id)
                    }
                )
                merged.sort { $0.createdAt > $1.createdAt }
                // 扫描窗口护栏：会话中用户新插入的工程（录制完成、新建）
                // 不被扫描快照覆盖掉；扫描已知集合之外的现有条目保留。
                let scanKnownIDs = Set(merged.map(\.id))
                let sessionAdditions = self.projects.filter {
                    !scanKnownIDs.contains($0.id)
                }
                merged.append(contentsOf: sessionAdditions)
                merged.sort { $0.createdAt > $1.createdAt }
                self.projects = merged
                // #59 的 init 路径补全：与 reloadProjects 一致走
                // issueSummary 聚合，不再把多条 issue 堆成错误墙。
                if
                    let summary = ProjectStore.issueSummary(
                        recovered.issues + loaded.issues
                    )
                {
                    self.errorMessage = summary
                }
                self.isScanningProjects = false
            }
        }
        player.actionAtItemEnd = .pause
        installTimeObserver()
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard
                    let self,
                    notification.object as? AVPlayerItem
                        === self.player.currentItem
                else {
                    return
                }
                self.isPlaying = false
                if self.auditionPreviewEndTime != nil {
                    self.auditionPreviewEndTime = nil
                    self.schedulePreviewRefresh(immediately: true)
                } else if let project = self.draft {
                    self.seek(to: project.trimDuration)
                }
            }
        }
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                await self?.handleUnexpectedStop(error)
            }
        }
        // 麦克风电平上抛（captureQueue → 主线程）→ 会话级发布
        // 属性 + 静音告警状态机。HUD 只读这两个属性，不含采样逻辑。
        recorder.onMicrophoneLevel = { [weak self] rms in
            Task { @MainActor in
                self?.ingestMicrophoneLevel(rms)
            }
        }
        // 工作台预览电平（独立写者；UI 只读 previewMicrophoneLevel）。
        microphonePreviewMonitor.onLevel = { [weak self] level in
            self?.previewMicrophoneLevel = level
        }
        cameraRecorder.onUnexpectedFinish = { [weak self] error in
            Task { @MainActor in
                guard
                    let self,
                    self.isRecording,
                    self.cameraEnabledForRecording
                else {
                    return
                }
                self.cameraEnabledForRecording = false
                self.cameraOverlay.hide()
                self.errorMessage =
                    "摄像头已中断：\(error.localizedDescription)。屏幕录制仍在继续。"
            }
        }
        Task {
            await refreshWindows()
            if setup.captureCamera {
                await activateCameraPreview()
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
    }

    func refreshDisplays() {
        displays = DisplayOption.current()
        if !displays.contains(where: { $0.id == setup.displayID }) {
            setup.displayID = displays.first(where: \.isMain)?.id
                ?? displays.first?.id
                ?? CGMainDisplayID()
        }
    }

    func refreshWindows() async {
        windows = await WindowCatalog.loadWindows()
        guard setup.sourceKind == .window else {
            windowPreview = nil
            return
        }
        if
            let selected = setup.window,
            let refreshed = windows.first(where: {
                $0.windowID == selected.windowID
            })
        {
            setup.window = refreshed
            if let displayID = refreshed.displayID {
                setup.displayID = displayID
            }
        } else {
            setup.window = nil
        }
        await refreshSourcePreview(force: true)
    }

    func refreshWindowPreview() async {
        await refreshSourcePreview(force: true)
    }

    func setSourceKind(_ kind: CaptureSourceKind) {
        if kind == .window {
            sourceKindBeforeWindowPicker = setup.sourceKind
        }
        setup.sourceKind = kind
        if kind == .window {
            Task {
                await refreshWindows()
                if setup.window == nil {
                    isWindowPickerPresented = true
                } else {
                    sourceKindBeforeWindowPicker = nil
                }
            }
        } else {
            sourceKindBeforeWindowPicker = nil
            isWindowPickerPresented = false
            windowPreview = nil
        }
    }

    func presentWindowPicker() {
        if sourceKindBeforeWindowPicker == nil {
            sourceKindBeforeWindowPicker = setup.sourceKind
        }
        refreshDisplays()
        Task {
            await reloadWindowCatalog()
            isWindowPickerPresented = true
        }
    }

    func reloadWindowCatalog() async {
        // P5 加载态：窗口枚举可能要几秒（多桌面/多屏幕），给按钮 busy。
        isRefreshingWindows = true
        defer { isRefreshingWindows = false }
        windows = await WindowCatalog.loadWindows()
    }

    func presentWindowPickerIfNeeded() {
        guard setup.sourceKind == .window, setup.window == nil else {
            return
        }
        sourceKindBeforeWindowPicker = .display
        isWindowPickerPresented = true
    }

    func dismissWindowPicker() {
        if setup.window == nil, let fallback = sourceKindBeforeWindowPicker {
            setup.sourceKind = fallback
        }
        sourceKindBeforeWindowPicker = nil
        isWindowPickerPresented = false
    }

    func selectWindow(_ window: WindowCaptureInfo) {
        setup.sourceKind = .window
        setup.window = window
        if let displayID = window.displayID {
            setup.displayID = displayID
        }
        sourceKindBeforeWindowPicker = nil
        isWindowPickerPresented = false
        Task {
            await refreshSourcePreview(force: true)
        }
    }

    func chooseRegion() {
        let targetID = setup.sourceKind == .window
            ? (setup.window?.displayID ?? setup.displayID)
            : setup.displayID
        guard let screen = screen(for: targetID) ?? NSScreen.main else {
            errorMessage = RecorderError.displayUnavailable.localizedDescription
            return
        }
        let initialRegion = setup.sourceKind == .region ? setup.region : nil
        regionSelector.present(
            on: screen,
            initialRegion: initialRegion
        ) { [weak self] region in
            guard let self, let region else { return }
            self.setup.sourceKind = .region
            self.setup.region = region
            self.setup.displayID = targetID
            Task {
                await self.refreshSourcePreview(force: true)
            }
        }
    }

    func clearRegion() {
        regionSelector.cancel()
        setup.region = nil
        if setup.sourceKind == .region {
            setup.sourceKind = .display
        }
        Task {
            await refreshSourcePreview(force: true)
        }
    }

    var sourcePreviewRequestKey: String {
        let region = setup.region.map {
            String(
                format: "%.5f,%.5f,%.5f,%.5f",
                $0.x,
                $0.y,
                $0.width,
                $0.height
            )
        } ?? "none"
        return [
            setup.sourceKind.rawValue,
            String(setup.displayID),
            String(setup.window?.windowID ?? 0),
            region
        ].joined(separator: "|")
    }

    func refreshSourcePreview(force: Bool = false) async {
        let key = sourcePreviewRequestKey
        if
            !force,
            key == sourcePreviewLoadedKey,
            sourcePreviewImage != nil
        {
            return
        }
        sourcePreviewLoading = true
        sourcePreviewMessage = nil
        defer {
            if key == sourcePreviewRequestKey {
                sourcePreviewLoading = false
            }
        }

        var image: NSImage?
        var message: String?
        switch setup.sourceKind {
        case .display, .region:
            do {
                image = try await WindowCatalog.captureDisplayPreview(
                    displayID: setup.displayID
                )
            } catch {
                message = error.localizedDescription
            }
            if setup.sourceKind == .region, setup.region == nil {
                message = "还没有框选区域。当前显示的是整块屏幕预览。"
            }
        case .window:
            if let window = setup.window {
                image = await WindowCatalog.capturePreview(for: window)
                if image == nil {
                    message = "无法读取窗口预览，请刷新来源后重新选择窗口。"
                }
            } else {
                message = "还没有选择窗口。点击“选择窗口”查看当前桌面窗口。"
            }
        }

        guard !Task.isCancelled, key == sourcePreviewRequestKey else {
            return
        }
        sourcePreviewImage = image
        windowPreview = setup.sourceKind == .window ? image : nil
        sourcePreviewMessage = message
        sourcePreviewLoadedKey = key
    }

    func refreshCameraDevices() {
        cameraDevices = CameraDeviceOption.available()
        if
            setup.cameraDeviceID == nil
                || !cameraDevices.contains(where: { $0.id == setup.cameraDeviceID })
        {
            setup.cameraDeviceID = cameraDevices.first?.id
        }
    }

    func refreshMicrophoneDevices() {
        microphoneDevices = MicrophoneDeviceOption.available()
        if
            let microphoneDeviceID = setup.microphoneDeviceID,
            !microphoneDevices.contains(where: { $0.id == microphoneDeviceID })
        {
            setup.microphoneDeviceID = nil
        }
    }

    func setMicrophoneDevice(_ deviceID: String?) {
        setup.microphoneDeviceID = deviceID
    }

    /// 工作台预览电平会话管理——只在录制工作台可见时运行
    /// （编辑器 / 录制中 / 麦克风开关关闭即拆除，不做后台常驻）。
    /// 失败降级由 MicrophonePreviewMonitor 内部静默处理（零报错）。
    func startMicrophonePreviewLevel() {
        guard !isRecording, setup.captureMicrophone, draft == nil else { return }
        microphonePreviewMonitor.start()
    }

    func stopMicrophonePreviewLevel() {
        microphonePreviewMonitor.stop()
        previewMicrophoneLevel = 0
    }

    func setCaptureCamera(_ enabled: Bool) {
        setup.captureCamera = enabled
        if enabled {
            if setup.cameraComposition == nil {
                setup.cameraComposition = .recordingDefault
            }
            Task {
                await activateCameraPreview()
            }
        } else {
            CameraPreviewRegistry.detachAll()
            cameraPreviewActive = false
            Task {
                await cameraRecorder.stopPreview()
            }
        }
    }

    func setCameraDevice(_ deviceID: String?) {
        setup.cameraDeviceID = deviceID
        guard setup.captureCamera else { return }
        Task {
            await activateCameraPreview()
        }
    }

    func setCameraResolution(_ resolution: CameraResolution) {
        setup.cameraResolution = resolution
        guard setup.captureCamera else { return }
        Task {
            await activateCameraPreview()
        }
    }

    func setRecordingCameraComposition(_ settings: CameraSettings) {
        var settings = settings
        settings.enabled = setup.captureCamera
        settings.layout = .pictureInPicture
        setup.cameraComposition = settings
        cameraOverlay.updateSettings(settings)
    }

    func setRecordingCameraAnchor(_ anchor: CameraAnchor) {
        var settings = recordingCameraComposition
        settings.anchor = anchor
        settings.customCenter = nil
        setRecordingCameraComposition(settings)
    }

    func setRecordingCameraShape(_ shape: CameraShape) {
        var settings = recordingCameraComposition
        settings.shape = shape
        setRecordingCameraComposition(settings)
    }

    func setRecordingCameraSize(_ size: Double) {
        var settings = recordingCameraComposition
        settings.size = min(0.5, max(0.1, size))
        setRecordingCameraComposition(settings)
    }

    var recordingCameraComposition: CameraSettings {
        setup.cameraComposition ?? .recordingDefault
    }

    func activateCameraPreview() async {
        guard setup.captureCamera else {
            await stopCameraPreview()
            return
        }
        // 权限被拒不翻转用户的 captureCamera 选择，只置会话态标记
        // 供设置界面警示；录制开始时经 prepareRecordingCameraPreview
        // 仍按无摄像头降级继续。
        cameraPermissionDenied = false
        refreshDeviceAuthorizations()
        guard await cameraAccessChecker() else {
            guard setup.captureCamera else { return }
            refreshDeviceAuthorizations()
            cameraPermissionDenied = true
            await stopCameraPreview()
            errorMessage = CameraRecorderError.permission.localizedDescription
            return
        }
        guard setup.captureCamera else {
            await stopCameraPreview()
            return
        }
        do {
            try await cameraRecorder.configure(
                deviceID: setup.cameraDeviceID,
                resolution: setup.cameraResolution
            )
            guard setup.captureCamera else {
                await stopCameraPreview()
                return
            }
            try await cameraRecorder.startPreview()
            guard setup.captureCamera else {
                await stopCameraPreview()
                return
            }
            cameraPreviewActive = true
        } catch {
            await stopCameraPreview()
            errorMessage = "启动摄像头预览失败：\(error.localizedDescription)"
        }
    }

    /// 刷新两项设备权限状态（工作台出现时调用，权限在系统设置里改过也能跟上）。
    func refreshDeviceAuthorizations() {
        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(
            for: .audio
        )
    }

    /// 主动请求摄像头授权：系统弹窗会同时把「八角录屏」登记进
    /// 系统设置 › 隐私与安全性 › 摄像头 列表（此前从未请求过时，
    /// 用户在列表里根本找不到本应用）。
    func requestCameraAuthorization() async {
        let granted = await cameraAccessChecker()
        refreshDeviceAuthorizations()
        if granted {
            cameraPermissionDenied = false
            await activateCameraPreview()
        } else {
            cameraPermissionDenied = true
        }
    }

    /// 主动请求麦克风授权（同上：请求后才会出现在系统列表里）。
    func requestMicrophoneAuthorization() async {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if current == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        refreshDeviceAuthorizations()
    }

    func recheckCameraPermission() async {
        guard setup.captureCamera else { return }
        await activateCameraPreview()
    }

    /// 屏幕录制权限预检（只读不弹窗，不请求授权）；引导卡依据，
    /// 开始录制的 ScreenRecorder.checkAccess 仍是最终闸门。
    func recheckScreenPermission() {
        screenPermissionGranted = CGPreflightScreenCaptureAccess()
    }

    private func prepareRecordingCameraPreview() async -> Bool {
        await activateCameraPreview()
        return cameraPreviewActive && setup.captureCamera
    }

    private func estimatedRecordingSourceFrame() -> CGRect? {
        guard let screen = screenForCurrentSource() else { return nil }
        let frame: CGRect
        switch setup.sourceKind {
        case .display:
            frame = screen.frame
        case .window:
            if let windowFrame = setup.window?.screenFrame {
                frame = windowFrame
            } else if let window = setup.window {
                frame = CGRect(
                    x: screen.frame.midX - CGFloat(window.width) / 2,
                    y: screen.frame.midY - CGFloat(window.height) / 2,
                    width: CGFloat(window.width),
                    height: CGFloat(window.height)
                )
            } else {
                return nil
            }
        case .region:
            guard let region = setup.region, region.isValid else {
                return nil
            }
            frame = region.screenRect(in: screen.frame)
        }
        guard frame.width >= 64, frame.height >= 64 else { return nil }
        return frame
    }

    private func toggleRecordingCameraAdjustment() {
        guard isRecording, cameraEnabledForRecording else { return }
        let adjusting = hud.toggleCameraAdjusting()
        cameraOverlay.setAdjusting(adjusting)
    }

    private func toggleRecordingCameraShape() {
        guard isRecording, cameraEnabledForRecording else { return }
        var settings = recordingCameraComposition
        settings.shape = settings.shape == .circle
            ? .roundedRectangle
            : .circle
        setRecordingCameraComposition(settings)
    }

    func showRecorder() {
        saveDraftNow()
        cancelChromaKeySampling()
        player.pause()
        isPlaying = false
        selectedProjectID = nil
        draft = nil
        refreshDisplays()
        refreshCameraDevices()
        refreshMicrophoneDevices()
        Task {
            await refreshWindows()
            if setup.captureCamera {
                await activateCameraPreview()
            }
        }
    }

    var canManageProjects: Bool {
        !isPreparing && !isRecording && !isStopping
    }

    func setDefaultProjectRemovalAction(_ action: ProjectRemovalAction) {
        defaultProjectRemovalAction = action
        UserDefaults.standard.set(
            action.rawValue,
            forKey: StudioPreferences.projectRemovalActionKey
        )
    }

    func setShowHiddenProjects(_ show: Bool) {
        guard showHiddenProjects != show else { return }
        showHiddenProjects = show
        UserDefaults.standard.set(
            show,
            forKey: StudioPreferences.showHiddenProjectsKey
        )
        reloadProjects()
    }

    func setStopRequiresConfirmation(_ enabled: Bool) {
        guard stopRequiresConfirmation != enabled else { return }
        stopRequiresConfirmation = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: StudioPreferences.stopRequiresConfirmationKey
        )
    }

    func reloadProjects() {
        let loaded = ProjectStore.loadAllWithIssues(
            includeHidden: showHiddenProjects
        )
        projects = loaded.projects
        if let summary = ProjectStore.issueSummary(loaded.issues) {
            errorMessage = summary
        }
        if
            let selectedProjectID,
            !projects.contains(where: { $0.id == selectedProjectID }),
            draft?.id != selectedProjectID
        {
            self.selectedProjectID = nil
        }
    }

    func revealProjectInFinder(_ project: StudioProject) {
        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
    }

    func revealArchiveFolder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [ProjectStore.archiveURL]
        )
    }

    func requestProjectRemoval(_ project: StudioProject) {
        guard canManageProjects else { return }
        switch defaultProjectRemovalAction {
        case .ask:
            let alert = NSAlert()
            alert.messageText = "“\(project.name)”要怎么处理？"
            alert.informativeText =
                "从列表移除会保留全部文件；归档会把完整工程目录移到 Archive。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "从列表移除")
            alert.addButton(withTitle: "归档")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                removeProjectFromList(project)
            case .alertSecondButtonReturn:
                archiveProject(project)
            default:
                break
            }
        case .hide:
            removeProjectFromList(project)
        case .archive:
            archiveProject(project)
        }
    }

    func removeProjectFromList(_ project: StudioProject) {
        guard canManageProjects else { return }
        do {
            try ProjectStore.setHidden(project, hidden: true)
            reloadProjects()
        } catch {
            errorMessage = "从列表移除工程失败：\(error.localizedDescription)"
        }
    }

    func restoreProjectToList(_ project: StudioProject) {
        guard canManageProjects else { return }
        do {
            try ProjectStore.setHidden(project, hidden: false)
            reloadProjects()
        } catch {
            errorMessage = "恢复工程到列表失败：\(error.localizedDescription)"
        }
    }

    func archiveProject(_ project: StudioProject) {
        guard canManageProjects else { return }
        guard canMoveProjectFiles(project) else { return }
        let wasCurrent = selectedProjectID == project.id
        let currentDraft = wasCurrent ? (draft ?? project) : nil
        let currentPosition = currentTime
        guard prepareCurrentProjectForMove(project, save: true) else {
            return
        }
        do {
            _ = try ProjectStore.archive(project)
            projects.removeAll { $0.id == project.id }
            if wasCurrent {
                showRecorder()
            }
        } catch {
            if let currentDraft {
                restoreCurrentProjectAfterFailure(
                    currentDraft,
                    time: currentPosition
                )
            }
            errorMessage = "归档工程失败：\(error.localizedDescription)"
        }
    }

    func deleteProject(_ project: StudioProject) {
        guard canManageProjects else { return }
        guard canMoveProjectFiles(project) else { return }
        let alert = NSAlert()
        alert.messageText = "删除“\(project.name)”？"
        alert.informativeText =
            "整个工程目录会移到废纸篓，包括屏幕、摄像头、声音和该目录内的导出文件。工程目录外你自己导出的成片不会被删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wasCurrent = selectedProjectID == project.id
        let currentDraft = wasCurrent ? (draft ?? project) : nil
        let currentPosition = currentTime
        guard prepareCurrentProjectForMove(project, save: false) else {
            return
        }
        do {
            _ = try ProjectStore.trash(project)
            projects.removeAll { $0.id == project.id }
            if wasCurrent {
                showRecorder()
            }
        } catch {
            if let currentDraft {
                restoreCurrentProjectAfterFailure(
                    currentDraft,
                    time: currentPosition
                )
            }
            errorMessage = "删除工程失败：\(error.localizedDescription)"
        }
    }

    func chooseProjectToImport() {
        guard canManageProjects else { return }
        let panel = NSOpenPanel()
        panel.title = "导入八角录屏工程"
        panel.prompt = "导入"
        panel.message = "选择包含 project.json 的工程目录。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = ProjectStore.archiveURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importProject(from: url)
    }

    func importProject(from url: URL) {
        guard canManageProjects else { return }
        do {
            let project = try ProjectStore.importProject(from: url)
            reloadProjects()
            selectProject(project)
        } catch {
            errorMessage = "导入工程失败：\(error.localizedDescription)"
        }
    }

    private func canMoveProjectFiles(_ project: StudioProject) -> Bool {
        guard selectedProjectID == project.id else { return true }
        guard exportProgress == nil, exportTask == nil else {
            errorMessage = "导出进行中，不能移动当前工程目录。请等待导出完成或取消导出。"
            return false
        }
        return true
    }

    private func prepareCurrentProjectForMove(
        _ project: StudioProject,
        save: Bool
    ) -> Bool {
        guard selectedProjectID == project.id else { return true }
        if save {
            do {
                try ProjectStore.save(draft ?? project)
            } catch {
                errorMessage = "保存工程失败：\(error.localizedDescription)"
                return false
            }
        }
        saveTask?.cancel()
        saveTask = nil
        previewTask?.cancel()
        previewTask = nil
        auditionTask?.cancel()
        auditionTask = nil
        smartCutTask?.cancel()
        smartCutTask = nil
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        audioPreparationTask?.cancel()
        audioPreparationTask = nil
        faceAnalysisTask?.cancel()
        faceAnalysisTask = nil
        cancelChromaKeySampling()
        resetSmartCutResults()
        resetFillerSuggestions()
        resetAudioOptimizationSession()
        clearExportRange()
        isAnalyzingFaces = false
        faceFocusSegments = nil
        faceCenteringEnabled = false
        isAnalyzingFollow = false
        portraitFollowSegments = nil
        portraitFollowEnabled = false
        portraitFollowSensitivity = .standard
        captionStatus = nil
        CameraPreviewRegistry.detachAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        previewLoading = false
        selectedProjectID = nil
        draft = nil
        currentTime = 0
        return true
    }

    private func restoreCurrentProjectAfterFailure(
        _ project: StudioProject,
        time: Double
    ) {
        guard draft == nil else { return }
        selectedProjectID = project.id
        draft = project
        currentTime = time
        Task {
            await preparePreview(for: project, preserveTime: time)
        }
    }

    func startRecording() async {
        guard !isPreparing, !isRecording else { return }
        regionSelector.cancel()
        errorMessage = nil
        refreshDisplays()
        refreshCameraDevices()
        refreshMicrophoneDevices()
        guard validateSource() else { return }
        let screen = screenForCurrentSource()
        guard screen != nil || setup.sourceKind == .window else {
            errorMessage = RecorderError.displayUnavailable.localizedDescription
            return
        }

        isPreparing = true
        isRecordingTransitioning = false
        rawRecordingMarkers.removeAll()
        cameraSessions.removeAll()
        cameraEnabledForRecording = false
        isRecordingPaused = false
        defer { isPreparing = false }
        do {
            try await ScreenRecorder.checkAccess(
                includeMicrophone: setup.captureMicrophone
            )
        } catch {
            errorMessage = "开始录制失败：\(error.localizedDescription)"
            return
        }

        let source = setup.source
        let canvas = CanvasSettings.forNewProject(source: source)
        if
            setup.sourceKind == .window,
            let windowID = setup.window?.windowID,
            let frame = await WindowCatalog.screenFrame(for: windowID)
        {
            setup.window?.screenFrame = frame
        }
        let initialSourceFrame = estimatedRecordingSourceFrame()
        var cameraReady = false
        if setup.captureCamera {
            cameraReady = await prepareRecordingCameraPreview()
        }

        hideMainWindows()
        if
            cameraReady,
            let initialSourceFrame,
            cameraPreviewActive
        {
            cameraOverlay.show(
                cameraSession: cameraRecorder.session,
                settings: recordingCameraComposition,
                sourceFrame: initialSourceFrame,
                sourceSize: initialSourceFrame.size,
                canvas: canvas
            ) { [weak self] settings in
                self?.setRecordingCameraComposition(settings)
            }
        }
        if setup.countdown > 0 {
            let finished = await countdown.show(
                seconds: setup.countdown,
                screen: screen
            )
            guard finished else {
                cameraOverlay.hide()
                showMainWindows()
                return
            }
        }

        let folder = ProjectStore.newFolder()
        var cameraStart: CameraRecordingStart?
        // 摄像头启动失败时主窗口即将隐藏，toast 录制期间不可见；
        // 记下标志，HUD 弹出后由状态行代播。
        var cameraStartFailed = false
        if cameraReady {
            do {
                cameraStart = try await cameraRecorder.startRecording(
                    folder: folder.url
                )
            } catch {
                cameraStart = nil
                cameraReady = false
                cameraStartFailed = true
                cameraRecorder.cancelRecording()
                cameraOverlay.hide()
                await stopCameraPreview()
                errorMessage = "摄像头未启用：\(error.localizedDescription)"
            }
        }

        do {
            let info = try await recorder.start(
                setup: setup,
                screen: screen,
                folder: folder
            )
            screenRecordingStart = info
            if let cameraStart {
                cameraSessions.append(
                    CameraRecordingResult(
                        fileURL: cameraStart.fileURL,
                        startedAtHostTime: cameraStart.startedAtHostTime
                    )
                )
                cameraEnabledForRecording = true
            }
            cameraOverlay.updateSource(
                frame: info.sourceFrame,
                size: CGSize(
                    width: CGFloat(info.width),
                    height: CGFloat(info.height)
                ),
                canvas: canvas
            )
            isRecording = true
            // 开录即拆预览会话（两个写者不串话；录制中电平
            // 由 ScreenRecorder 写链上抛）
            stopMicrophonePreviewLevel()
            // 会话级电平/告警态随每次开录复位
            microphoneLevel = 0
            silentAlarmVisible = false
            silentAlarm = SilentAlarm()
            recordingStartedAt = info.startedAt
            hud.show(
                startedAt: info.startedAt,
                hasCamera: cameraStart != nil,
                stopRequiresConfirmation: stopRequiresConfirmation,
                screen: screen
            ) { [weak self] in
                Task { @MainActor in
                    self?.addRecordingMarker()
                }
            } onToggleTeleprompter: { [weak self] in
                Task { @MainActor in
                    self?.toggleTeleprompterPanel()
                }
            } onPause: { [weak self] in
                Task { @MainActor in
                    await self?.pauseRecording()
                }
            } onResume: { [weak self] in
                Task { @MainActor in
                    await self?.resumeRecording()
                }
            } onStop: { [weak self] in
                Task { @MainActor in
                    await self?.stopRecording()
                }
            } onToggleCameraAdjust: { [weak self] in
                Task { @MainActor in
                    self?.toggleRecordingCameraAdjustment()
                }
            } onToggleCameraShape: { [weak self] in
                Task { @MainActor in
                    self?.toggleRecordingCameraShape()
                }
            }
            // 1118 Loop：菜单栏第三入口与 HUD 同步出现。
            statusItem.show(
                onPauseToggle: { [weak self] in
                    Task { @MainActor in
                        if self?.isRecordingPaused == true {
                            await self?.resumeRecording()
                        } else {
                            await self?.pauseRecording()
                        }
                    }
                },
                onMarker: { [weak self] in
                    Task { @MainActor in
                        self?.addRecordingMarker()
                    }
                },
                onStop: { [weak self] in
                    Task { @MainActor in
                        await self?.stopRecording()
                    }
                }
            )
            if cameraStartFailed {
                hud.setCameraFailed()
            }
        } catch {
            cameraRecorder.cancelRecording()
            cameraOverlay.hide()
            await stopCameraPreview()
            showMainWindows()
            errorMessage = "开始录制失败：\(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard isRecording, !isStopping, !isRecordingTransitioning else {
            return
        }
        isStopping = true
        isRecording = false
        isRecordingPaused = false
        hud.hide()
        statusItem.hide()
        // 停止即清（会话态不残留；保存重开无痕）
        microphoneLevel = 0
        silentAlarmVisible = false
        recordingStartedAt = nil
        // 回到工作台则恢复预览电平（按麦克风开关状态）
        startMicrophonePreviewLevel()
        cameraOverlay.hide()
        teleprompterPanel.hide()
        isPreparing = true
        do {
            let result = try await recorder.stop()
            let cameraStop = await cameraRecorder.stopRecording()
            if let cameraResult = cameraStop.result {
                cameraSessions.append(cameraResult)
            } else if let failure = cameraStop.failure {
                errorMessage = "摄像头录制未完成：\(failure.localizedDescription)"
            }
            await adoptRecording(result: result, cameraSessions: cameraSessions)
            showMainWindows()
            await stopCameraPreview()
        } catch {
            cameraRecorder.cancelRecording()
            await stopCameraPreview()
            showMainWindows()
            errorMessage = "停止录制失败：\(error.localizedDescription)"
        }
        screenRecordingStart = nil
        cameraSessions.removeAll()
        cameraEnabledForRecording = false
        isRecordingTransitioning = false
        isStopping = false
        isPreparing = false
    }

    func addRecordingMarker() {
        guard isRecording, !isRecordingPaused else { return }
        rawRecordingMarkers.append((
            hostTime: CACurrentMediaTime(),
            name: "标记 \(rawRecordingMarkers.count + 1)"
        ))
    }

    // MARK: 提词器（提词器）

    var isTeleprompterVisible: Bool {
        teleprompterPanel.isVisible
    }

    /// 打开 / 关闭提词面板。录制准备与录制中都可开；面板是独立 NSPanel
    /// 且 `sharingType = .none`，不会被 hideMainWindows 隐藏，也不会进入录像。
    func toggleTeleprompterPanel() {
        if teleprompterPanel.isVisible {
            hideTeleprompterPanel()
        } else {
            showTeleprompterPanel()
        }
    }

    func showTeleprompterPanel() {
        guard !isRecordingTransitioning else { return }
        let screen = screenForCurrentSource() ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? (NSScreen.main?.visibleFrame ?? .zero)
        teleprompterPanel.show(
            settings: setup.teleprompter,
            visibleFrame: visibleFrame,
            cameraFrame: cameraOverlay.currentPanelFrame,
            isRecording: isRecording
        ) { [weak self] settings in
            guard let self else { return }
            self.commitTeleprompterSettings(settings)
        }
    }

    func hideTeleprompterPanel() {
        teleprompterPanel.hide()
    }

    /// 录制准备页编辑文稿 / 设置后刷新已打开的面板。
    func syncTeleprompterPanel() {
        guard teleprompterPanel.isVisible else { return }
        teleprompterPanel.updateSettings(setup.teleprompter)
    }

    /// 选中工程时按工程记忆恢复提词面板偏好（字号 / 速度 / 上次位置）。
    private func restoreTeleprompterPreferences(from project: StudioProject) {
        let remembered = project.teleprompter
        setup.teleprompter.fontSize = remembered.fontSize
        setup.teleprompter.speed = remembered.speed
        setup.teleprompter.panelFrame = remembered.panelFrame
        syncTeleprompterPanel()
    }

    /// 提词面板是否处于暂停（菜单标题用）。
    var isTeleprompterPaused: Bool {
        teleprompterPanel.session?.scrollState.isPaused ?? false
    }

    /// 快捷键入口：暂停 / 继续滚动（面板未开时无动作）。
    func toggleTeleprompterPause() {
        guard teleprompterPanel.isVisible else { return }
        teleprompterPanel.session?.togglePause()
    }

    /// 快捷键入口：加速 / 减速一档。
    func stepTeleprompterSpeed(_ delta: Double) {
        guard
            let session = teleprompterPanel.session,
            teleprompterPanel.isVisible
        else { return }
        session.stepSpeed(delta)
        commitTeleprompterSettings(session.settings)
    }

    /// 快捷键入口：回退 / 前进一行。
    func stepTeleprompterLine(_ delta: Double) {
        guard teleprompterPanel.isVisible else { return }
        teleprompterPanel.session?.stepOffset(delta)
    }

    private func commitTeleprompterSettings(_ settings: TeleprompterSettings) {
        setup.teleprompter = settings
        if isRecording {
            recorder.updateTeleprompter(settings)
        }
    }

    /// 导入 .txt / .md 文稿到提词设置（纯本地读取，不上传）。
    func importTeleprompterScript() {
        let panel = NSOpenPanel()
        panel.title = "导入提词文稿"
        panel.prompt = "导入"
        panel.allowedContentTypes = [
            .plainText,
            UTType(filenameExtension: "md") ?? .plainText
        ]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000 else {
                errorMessage = "文稿超过 1 MB，请拆分后再导入。"
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = "文稿不是 UTF-8 文本，无法导入。"
                return
            }
            setup.teleprompter.script = text
            syncTeleprompterPanel()
        } catch {
            errorMessage = "无法读取文稿：\(error.localizedDescription)"
        }
    }

    func pauseRecording() async {
        guard
            isRecording,
            !isRecordingPaused,
            !isStopping,
            !isRecordingTransitioning
        else {
            return
        }
        isRecordingTransitioning = true
        hud.setBusy(true)
        defer {
            isRecordingTransitioning = false
            hud.setBusy(false)
        }
        await recorder.pause()
        if cameraEnabledForRecording {
            let cameraStop = await cameraRecorder.stopRecording()
            if let result = cameraStop.result {
                cameraSessions.append(result)
            } else {
                cameraEnabledForRecording = false
                cameraOverlay.hide()
                if let failure = cameraStop.failure {
                    errorMessage = "摄像头已停止：\(failure.localizedDescription)。继续录制后只录制屏幕。"
                } else {
                    errorMessage = "摄像头已停止，继续录制后只录制屏幕。"
                }
            }
        }
        isRecordingPaused = true
        hud.setPaused(true)
        statusItem.setPaused(true)
    }

    func resumeRecording() async {
        guard
            isRecording,
            isRecordingPaused,
            !isStopping,
            !isRecordingTransitioning
        else {
            return
        }
        isRecordingTransitioning = true
        hud.setBusy(true)
        defer {
            isRecordingTransitioning = false
            hud.setBusy(false)
        }
        if cameraEnabledForRecording, let folder = screenRecordingStart?.folderURL {
            do {
                let cameraStart = try await cameraRecorder.startRecording(
                    folder: folder
                )
                cameraSessions.append(
                    CameraRecordingResult(
                        fileURL: cameraStart.fileURL,
                        startedAtHostTime: cameraStart.startedAtHostTime
                    )
                )
            } catch {
                cameraEnabledForRecording = false
                cameraOverlay.hide()
                errorMessage = "摄像头未能继续录制：\(error.localizedDescription)"
            }
        }
        await recorder.resume()
        isRecordingPaused = false
        hud.setPaused(false)
        statusItem.setPaused(false)
    }

    func addMarkerAtPlayhead() {
        guard
            var project = draft,
            let sourceTime = project.timeline.sourceTime(
                atOutput: currentTime
            )
        else {
            return
        }
        let previous = project
        guard project.addMarker(sourceTime: sourceTime) != nil else { return }
        recordUndo(for: previous)
        draft = project
        scheduleSave()
    }

    func renameMarker(_ markerID: UUID, name: String) {
        updateProject(groupingKey: "marker.name.\(markerID)") { project in
            project.renameMarker(id: markerID, name: name)
        }
    }

    func deleteMarker(_ markerID: UUID) {
        updateProject { project in
            project.deleteMarker(id: markerID)
        }
    }

    func setCaptionsEnabled(_ enabled: Bool) {
        updateProject { $0.captions.enabled = enabled }
    }

    func setCaptionBurnIn(_ enabled: Bool) {
        updateProject { $0.captions.burnIn = enabled }
    }

    func setCaptionFontScale(_ value: Double) {
        updateProject(groupingKey: "caption.fontScale") {
            $0.captions.fontScale = min(2.5, max(0.75, value))
        }
    }

    func setCaptionBackgroundOpacity(_ value: Double) {
        updateProject(groupingKey: "caption.backgroundOpacity") {
            $0.captions.backgroundOpacity = min(0.9, max(0, value))
        }
    }

    func addCaptionAtPlayhead() {
        guard
            var project = draft,
            project.trimDuration > 0
        else {
            return
        }
        let previous = project
        let start = min(
            max(0, currentTime),
            max(0, project.trimDuration - 0.05)
        )
        let end = min(
            project.trimDuration,
            max(start + 0.05, start + 3)
        )
        project.captionCues.append(
            CaptionCue(
                start: start,
                end: end,
                text: "新字幕"
            )
        )
        project.captionCues.sort { $0.start < $1.start }
        project.captions.enabled = true
        recordUndo(for: previous)
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    /// 清空删条的首次确认（默认弹 NSAlert，可勾选「不再
    /// 提示」持久化到应用偏好；测试/自动化可注入替身，不弹模态）。
    /// 返回 true = 确认删除。
    var captionDeleteConfirmHandler: (String) -> Bool = { _ in
        let alert = NSAlert()
        alert.messageText = "删除这条字幕？"
        alert.informativeText =
            "清空字幕文本会删除这条字幕，并剪掉它对应的画面与声音区间。"
            + "\n\n一次 ⌘Z 可完整还原；原始素材不变。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提示（此后清空即直接删除）"
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(
                true,
                forKey: StudioPreferences.captionDeleteConfirmSuppressedKey
            )
        }
        return confirmed
    }

    func updateCaptionText(_ captionID: UUID, text: String) {
        // 清空即删条（全文校对第 2 层第 1 步）——复用
        // deleteCaption 的现有事务与撤销分组，给原地可撤销提示。
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 清空即删条会连画面一起剪掉——首次执行弹一次
            // 确认（可勾选「不再提示」，应用偏好持久化）；取消则把文本
            // 还原为原值，不删条。撤销能力不变（⌘Z 仍可完整还原）。
            let previousText = draft?.captionCues.first(where: {
                $0.id == captionID
            })?.text
            let suppressed = UserDefaults.standard.bool(
                forKey: StudioPreferences.captionDeleteConfirmSuppressedKey
            )
            if !suppressed {
                let confirmed = captionDeleteConfirmHandler(
                    previousText ?? ""
                )
                guard confirmed else {
                    if let previousText {
                        updateCaptionText(captionID, text: previousText)
                    }
                    return
                }
            }
            deleteCaption(captionID)
            return
        }
        updateProject(groupingKey: "caption.text.\(captionID)") { project in
            guard
                let index = project.captionCues.firstIndex(where: {
                    $0.id == captionID
                })
            else {
                return
            }
            project.captionCues[index].text = String(text.prefix(500))
        }
    }

    func updateCaptionStart(_ value: Double, for captionID: UUID) {
        guard let project = draft else { return }
        let currentEnd = project.captionCues.first(where: {
            $0.id == captionID
        })?.end ?? project.trimDuration
        updateProject(groupingKey: "caption.start.\(captionID)") { project in
            guard
                let index = project.captionCues.firstIndex(where: {
                    $0.id == captionID
                })
            else {
                return
            }
            let latestStart = max(0, currentEnd - 0.05)
            project.captionCues[index].start = min(
                max(0, value),
                latestStart
            )
        }
    }

    func updateCaptionEnd(_ value: Double, for captionID: UUID) {
        guard let project = draft else { return }
        let currentStart = project.captionCues.first(where: {
            $0.id == captionID
        })?.start ?? 0
        updateProject(groupingKey: "caption.end.\(captionID)") { project in
            guard
                let index = project.captionCues.firstIndex(where: {
                    $0.id == captionID
                })
            else {
                return
            }
            project.captionCues[index].end = min(
                project.trimDuration,
                max(currentStart + 0.05, value)
            )
        }
    }

    func deleteCaption(_ captionID: UUID) {
        updateProject { project in
            project.captionCues.removeAll { $0.id == captionID }
        }
    }

    /// 全文校对视图的拆条事务——按文本偏移把一条字幕拆成
    /// 两条（时间按字数比例近似分配，见 CaptionSplitter）。走
    /// `updateProject` 现有撤销分组，一次 ⌘Z 完整还原（含时间分配）。
    /// 返回是否真的拆了（偏移在两端 / 一侧空白 / 原条过短时不动）。
    @discardableResult
    func splitCaption(_ captionID: UUID, atTextOffset offset: Int) -> Bool {
        guard let project = draft else { return false }
        guard
            let index = project.captionCues.firstIndex(where: {
                $0.id == captionID
            })
        else {
            return false
        }
        let cue = project.captionCues[index]
        let characters = Array(cue.text)
        guard
            let pieces = CaptionSplitter.splitText(cue.text, at: offset),
            let split = CaptionSplitter.split(
                start: cue.start,
                end: cue.end,
                splitOffset: offset,
                textCount: characters.count
            )
        else {
            return false
        }
        let first = CaptionCue(
            id: UUID(),
            start: split.firstStart,
            end: split.firstEnd,
            text: pieces.first
        )
        let second = CaptionCue(
            id: UUID(),
            start: split.secondStart,
            end: split.secondEnd,
            text: pieces.second
        )
        updateProject(groupingKey: "caption.split.\(captionID)") { project in
            project.captionCues.replaceSubrange(
                index ... index,
                with: [first, second]
            )
        }
        return true
    }

    func importCaptionsSRT() {
        guard let project = draft else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 SRT 字幕"
        panel.prompt = "导入"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .plainText,
            .plainText
        ]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // T3：SRT 上限 8MB（正常字幕几 KB）——病态大文件不再在主线程
            // 整读整解析。
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let size = (attributes[.size] as? Int) ?? 0
            guard size <= 8 * 1024 * 1024 else {
                errorMessage =
                    "这个 SRT 文件超过 8MB，不像是正常字幕文件。请检查是否选错文件。"
                return
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let cues = SubtitleFile.parse(
                source,
                duration: project.trimDuration
            )
            guard !cues.isEmpty else {
                errorMessage = "没有在这个 SRT 文件里找到有效字幕。"
                return
            }
            replaceCaptions(
                cues,
                language: nil
            )
            captionStatus = "已导入 \(cues.count) 条字幕"
        } catch {
            errorMessage = "无法读取 SRT 字幕：\(error.localizedDescription)"
        }
    }

    // MARK: 导出目录记忆（导出目录记忆）

    /// 上次导出目录（应用偏好，读写 UserDefaults；不进工程数据）。
    /// 只在导出成功后写入；四个导出面板共用。
    private var lastExportDirectoryURL: URL? {
        get {
            UserDefaults.standard.url(forKey: ExportDirectoryPreference.key)
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: ExportDirectoryPreference.key
            )
        }
    }

    /// save panel 默认打开目录：上次导出目录仍存在且可写则复用，
    /// 否则回退工程目录（原有行为）。
    private func exportPanelDirectory(fallback: URL) -> URL {
        ExportDirectoryPreference.resolvedPanelDirectory(
            recorded: lastExportDirectoryURL,
            fallback: fallback,
            isUsable: ExportDirectoryPreference.isUsable
        )
    }

    /// 导出成功后记录所选目录（panel.url 去掉文件名）。
    private func rememberExportDirectory(_ url: URL) {
        lastExportDirectoryURL = url.deletingLastPathComponent()
    }

    func exportCaptionsSRT() {
        guard let project = draft else { return }
        let panel = NSSavePanel()
        panel.title = "导出 SRT 字幕"
        panel.prompt = "导出"
        panel.nameFieldStringValue =
            "\(safeFilename(project.name)).srt"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .plainText,
            .plainText
        ]
        panel.canCreateDirectories = true
        panel.directoryURL = exportPanelDirectory(
            fallback: project.folderURL
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubtitleFile.write(project.captionCues, to: url)
            rememberExportDirectory(url)
            captionStatus = "SRT 已导出"
        } catch {
            errorMessage = "无法导出 SRT：\(error.localizedDescription)"
        }
    }

    func exportChapters() {
        guard let project = draft else { return }
        let chapters = ChapterBuilder.build(
            from: project.captionCues,
            totalDuration: project.trimDuration
        )
        guard !chapters.isEmpty else {
            captionStatus = "还没有足够字幕可生成章节"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出章节"
        panel.prompt = "导出"
        panel.nameFieldStringValue =
            "\(safeFilename(project.name))-chapters.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = exportPanelDirectory(
            fallback: project.folderURL
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(ChapterBuilder.text(from: chapters).utf8).write(
                to: url,
                options: .atomic
            )
            rememberExportDirectory(url)
            captionStatus = "章节已导出"
        } catch {
            errorMessage = "无法导出章节：\(error.localizedDescription)"
        }
    }

    func generateCaptionsOffline() {
        guard
            let project = draft,
            !isTranscribingCaptions
        else {
            return
        }
        if !project.captionCues.isEmpty {
            let alert = NSAlert()
            alert.messageText = "替换现有字幕？"
            alert.informativeText =
                "本机识别会生成一份新字幕并替换当前列表。这个操作可以撤销。"
            alert.addButton(withTitle: "生成并替换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        isTranscribingCaptions = true
        captionTranscriptionProgress = nil
        captionStatus = "正在准备本机音频…"
        let language = project.captionCues.compactMap(\.language).first
            ?? Locale.current.identifier
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "anise-recorder-caption-\(UUID().uuidString).m4a"
            )
        // P4 防卡死：转写整链保留 Task 句柄，「取消」按钮可中途终止
        // （识别内部经 withTaskCancellationHandler 终结 SF 任务）；进度
        // 由识别分段位置/总时长估算，回主线程只更新一个 Double。
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: audioURL)
                self.isTranscribingCaptions = false
                self.captionTranscriptionProgress = nil
                // 取消/失败路径不再残留等待文案（审查发现：取消后
                // 「正在本机识别…」会一直挂着）。
                if Task.isCancelled {
                    self.captionStatus = nil
                }
            }
            do {
                try await CompositionBuilder.makeTranscriptionAudio(
                    for: project,
                    outputURL: audioURL
                )
                guard !Task.isCancelled else { return }
                self.captionStatus = "正在本机识别，不会上传音频…"
                let transcription = try await OfflineCaptionTranscriber
                    .transcribeWithSegments(
                        audioURL: audioURL,
                        totalDuration: project.trimDuration,
                        preferredLanguage: language,
                        progress: { fraction in
                            Task { @MainActor in
                                self.captionTranscriptionProgress = min(
                                    max(fraction, 0), 0.99
                                )
                            }
                        }
                    )
                guard self.draft?.id == project.id else {
                    self.captionStatus = nil
                    return
                }
                self.replaceCaptions(transcription.cues, language: language)
                // replaceCaptions 触发字幕变化 → 会话态失效清空；原始分段
                // 必须在其后写入。术语表改写过的 cue 文本无法由分段重建，
                // 句内手术对它们自动跳过（重建校验）。
                self.rawCaptionSegments = transcription.segments
                self.captionStatus =
                    "已在本机生成 \(transcription.cues.count) 条字幕，请校对"
            } catch {
                // 用户主动取消：静默退出，不当作错误弹提示。
                guard !Task.isCancelled else { return }
                self.captionStatus = nil
                errorMessage = "生成本机字幕失败：\(error.localizedDescription)"
            }
        }
        captionTranscriptionTask = task
    }

    /// P4 防卡死：取消进行中的本机转写（字幕页「取消」按钮）。立即回
    /// UI 状态——makeTranscriptionAudio 组装阶段不可协作中断，等它走完
    /// 后 Task 的 defer 再清一次临时文件；识别阶段的取消经
    /// withTaskCancellationHandler 即时生效。
    func cancelCaptionTranscription() {
        captionTranscriptionTask?.cancel()
        captionTranscriptionTask = nil
        isTranscribingCaptions = false
        captionTranscriptionProgress = nil
        captionStatus = nil
    }

    /// 点击工程行的语义判定（可测试纯函数）——只有编辑器当前
    /// 就是这条工程时才是重复点击（无操作）；已选中但尚未进入编辑器
    /// （fresh launch，draft 为空）或切到别的工程，都应进入编辑器。
    nonisolated static func shouldOpenProjectOnRowClick(
        draftID: UUID?,
        clickedID: UUID
    ) -> Bool {
        draftID != clickedID
    }

    func selectProject(_ project: StudioProject) {
        // 修复：旧守卫按 selectedProjectID 拦截——fresh launch 时
        // 上次会话的选中 id 已恢复但 draft 为空，点击该行直接 return，
        // 「进入编辑器」的路径被挡死（必须先点别的工程再点回来）。
        // 现在只拦真正的重复点击。
        guard Self.shouldOpenProjectOnRowClick(
            draftID: draft?.id,
            clickedID: project.id
        ) else {
            return
        }
        cancelChromaKeySampling()
        saveTask?.cancel()
        saveTask = nil
        saveDraftNow()
        errorMessage = nil
        selectedProjectID = project.id
        selectedOverlayClipID = nil
        draft = project
        // 进入编辑器上下文时关闭提词面板（避免与编辑器空格监听叠加）。
        teleprompterPanel.hide()
        currentTime = 0
        auditionPreviewEndTime = nil
        resetSmartCutResults()
        smartCutMessage = nil
        fillerSuggestions = []
        fillerSelectedIndices = []
        rawCaptionSegments = []
        resetAudioOptimizationSession()
        clearExportRange()
        faceAnalysisTask?.cancel()
        faceAnalysisTask = nil
        isAnalyzingFaces = false
        faceFocusSegments = nil
        faceCenteringEnabled = false
        isAnalyzingFollow = false
        portraitFollowSegments = nil
        portraitFollowEnabled = false
        portraitFollowSensitivity = .standard
        // 1.2 块6：精剪设置从工程恢复（缺省回退默认）。
        smartCutMode = project.smartCutSettings.mode
        smartCutProtectScreenActivity = project.smartCutSettings.protectScreenActivity
        smartCutProtectSystemSound = project.smartCutSettings.protectSystemSound
        // 提词面板偏好按工程记忆恢复（字号 / 速度 / 面板位置）。
        // 文稿不自动覆盖准备中的文稿，避免浏览工程时静默改稿。
        restoreTeleprompterPreferences(from: project)
        updateExportDefaults(for: project)
        interactiveUndoSnapshot = nil
        undoHistory.removeAll()
        publishUndoState()
        CameraPreviewRegistry.detachAll()
        cameraPreviewActive = false
        Task {
            await cameraRecorder.stopPreview()
            await preparePreview(for: project, preserveTime: 0)
            await generateThumbnailIfNeeded(for: project)
            scheduleAudioProcessingPreparation()
        }
    }

    func updateProjectName(_ name: String) {
        guard var project = draft else { return }
        // 空名（或全空白）禁止提交——保持原名，等同「恢复原名」。
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = project
        project.name = String(trimmed.prefix(120))
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: "project.name")
        draft = project
        scheduleSave()
    }

    func setTrimStart(_ value: Double) {
        guard var project = draft else { return }
        guard let first = project.timeline.clips.first else { return }
        let previous = project
        let start = min(
            max(0, value),
            max(
                first.sourceStart,
                first.sourceEnd - TimelineClip.minimumSourceDuration
            )
        )
        project.timeline.clips[0] = TimelineClip(
            id: first.id,
            sourceStart: start,
            sourceEnd: first.sourceEnd,
            playbackRate: first.playbackRate
        )
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: "trim.start")
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        if currentTime > project.trimDuration {
            seek(to: project.trimDuration)
        }
        scheduleSave()
        schedulePreviewRefresh()
    }

    func setTrimEnd(_ value: Double) {
        guard var project = draft else { return }
        guard let lastIndex = project.timeline.clips.indices.last else {
            return
        }
        let last = project.timeline.clips[lastIndex]
        let previous = project
        let end = max(
            min(project.duration, value),
            min(
                project.duration,
                last.sourceStart + TimelineClip.minimumSourceDuration
            )
        )
        project.timeline.clips[lastIndex] = TimelineClip(
            id: last.id,
            sourceStart: last.sourceStart,
            sourceEnd: end,
            playbackRate: last.playbackRate
        )
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: "trim.end")
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        if currentTime > project.trimDuration {
            seek(to: project.trimDuration)
        }
        scheduleSave()
        schedulePreviewRefresh()
    }

    func setTrimStartToPlayhead() {
        guard let project = draft else { return }
        guard let sourceTime = project.timeline.sourceTime(atOutput: currentTime) else {
            return
        }
        setTrimStart(sourceTime)
    }

    func setTrimEndToPlayhead() {
        guard let project = draft else { return }
        guard let sourceTime = project.timeline.sourceTime(atOutput: currentTime) else {
            return
        }
        setTrimEnd(sourceTime)
    }

    func splitTimelineAtPlayhead() {
        guard var project = draft else { return }
        guard project.timeline.split(atOutput: currentTime) else {
            errorMessage = "播放头离片段边缘太近，无法切分。"
            return
        }
        commitTimelineProject(project)
    }

    func deleteTimelineClip(_ clipID: UUID) {
        guard var project = draft else { return }
        guard project.timeline.clips.count > 1 else {
            errorMessage = "至少保留一个视频片段。"
            return
        }
        guard project.timeline.deleteClip(id: clipID) else { return }
        commitTimelineProject(project)
    }

    func setTimelinePlaybackRate(_ rate: Double, for clipID: UUID) {
        guard var project = draft else { return }
        let previous = project
        guard project.timeline.setPlaybackRate(rate, for: clipID) else {
            return
        }
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: "timeline.rate.\(clipID)")
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        currentTime = min(currentTime, project.trimDuration)
        scheduleSave()
        schedulePreviewRefresh()
    }

    func setTimelineClipStart(_ value: Double, for clipID: UUID) {
        updateTimelineClipRange(
            clipID: clipID,
            sourceStart: value,
            groupingKey: "timeline.clipStart.\(clipID)"
        )
    }

    func setTimelineClipEnd(_ value: Double, for clipID: UUID) {
        updateTimelineClipRange(
            clipID: clipID,
            sourceEnd: value,
            groupingKey: "timeline.clipEnd.\(clipID)"
        )
    }

    func setAutoZoom(_ enabled: Bool) {
        updateProject { $0.autoZoom = enabled }
    }

    func setZoomScale(_ value: Double) {
        updateProject(groupingKey: "zoom.scale") {
            $0.zoomScale = min(3.0, max(1.1, value))
        }
    }

    func setZoomDuration(_ value: Double) {
        updateProject(groupingKey: "zoom.duration") {
            $0.zoomDuration = min(4.0, max(0.5, value))
        }
    }

    func addManualZoomRegionAtPlayhead() {
        guard var project = draft else { return }
        let time = min(
            max(0, currentTime),
            max(0, project.trimDuration - 0.1)
        )
        guard project.zoomRegion(atOutput: time) == nil else {
            errorMessage = "播放头处已有手动缩放区。"
            return
        }
        let previous = project
        project.zoomRegions.append(
            ZoomRegion(
                start: time,
                duration: project.zoomDuration,
                scale: project.zoomScale
            )
        )
        recordUndo(for: previous)
        draft = project
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    func deleteManualZoomRegion(_ regionID: UUID) {
        guard var project = draft else { return }
        guard project.zoomRegions.contains(where: { $0.id == regionID }) else {
            return
        }
        let previous = project
        project.zoomRegions.removeAll { $0.id == regionID }
        recordUndo(for: previous)
        draft = project
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    func setManualZoomRegionDuration(
        _ value: Double,
        for regionID: UUID
    ) {
        updateManualZoomRegion(
            regionID,
            groupingKey: "zoom.region.duration.\(regionID)"
        ) {
            $0.duration = min(10, max(0.1, value))
        }
    }

    func setManualZoomRegionStart(
        _ value: Double,
        for regionID: UUID
    ) {
        guard let project = draft else { return }
        updateManualZoomRegion(
            regionID,
            groupingKey: "zoom.region.start.\(regionID)"
        ) {
            $0.start = min(
                max(0, value),
                max(0, project.trimDuration - 0.1)
            )
        }
    }

    func setManualZoomRegionScale(
        _ value: Double,
        for regionID: UUID
    ) {
        updateManualZoomRegion(
            regionID,
            groupingKey: "zoom.region.scale.\(regionID)"
        ) {
            $0.scale = min(4, max(1, value))
        }
    }

    func setManualZoomRegionCenter(
        _ point: CGPoint,
        for regionID: UUID
    ) {
        updateManualZoomRegion(
            regionID,
            groupingKey: "zoom.region.center.\(regionID)"
        ) {
            $0.center = NormalizedPoint(
                x: min(1, max(0, point.x)),
                y: min(1, max(0, point.y))
            )
        }
    }

    func setManualZoomRegionEnabled(
        _ enabled: Bool,
        for regionID: UUID
    ) {
        updateManualZoomRegion(regionID) { $0.enabled = enabled }
    }

    private func updateManualZoomRegion(
        _ regionID: UUID,
        groupingKey: String? = nil,
        _ mutate: (inout ZoomRegion) -> Void
    ) {
        guard var project = draft else { return }
        guard let index = project.zoomRegions.firstIndex(where: {
            $0.id == regionID
        }) else {
            return
        }
        let previous = project
        mutate(&project.zoomRegions[index])
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: groupingKey)
        draft = project
        scheduleSave()
        schedulePreviewRefresh()
    }

    // MARK: 定时区域打码（1.2 块2）

    /// 在播放头时刻添加打码区域（默认 3 秒）。所有编辑进入统一撤销栈。
    func addRedactionRegion(rect: NormalizedRect) {
        guard var project = draft else { return }
        let clamped = rect.clamped()
        guard clamped.isValid else { return }
        let previous = project
        let start = min(
            max(0, currentTime),
            max(0, project.trimDuration - 0.1)
        )
        project.redactionRegions.append(
            RedactionRegion(
                start: start,
                duration: 3,
                rect: clamped
            )
        )
        guard project != previous else { return }
        recordUndo(for: previous)
        draft = project
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    func deleteRedactionRegion(_ regionID: UUID) {
        updateRedactionRegion(regionID) { project in
            project.redactionRegions.removeAll { $0.id == regionID }
        }
    }

    func setRedactionRegionEnabled(
        _ enabled: Bool,
        for regionID: UUID
    ) {
        updateRedactionRegion(regionID) { project in
            if let index = project.redactionRegions.firstIndex(where: {
                $0.id == regionID
            }) {
                project.redactionRegions[index].enabled = enabled
            }
        }
    }

    func setRedactionRegionStyle(
        _ style: RedactionStyle,
        for regionID: UUID
    ) {
        updateRedactionRegion(regionID) { project in
            if let index = project.redactionRegions.firstIndex(where: {
                $0.id == regionID
            }) {
                project.redactionRegions[index].style = style
            }
        }
    }

    func setRedactionRegionIntensity(
        _ intensity: Double,
        for regionID: UUID
    ) {
        updateRedactionRegion(
            regionID,
            groupingKey: "redaction.intensity.\(regionID)"
        ) { project in
            if let index = project.redactionRegions.firstIndex(where: {
                $0.id == regionID
            }) {
                project.redactionRegions[index].intensity = min(
                    1, max(0.2, intensity)
                )
            }
        }
    }

    func setRedactionRegionStart(
        _ start: Double,
        for regionID: UUID
    ) {
        updateRedactionRegion(
            regionID,
            groupingKey: "redaction.start.\(regionID)"
        ) { project in
            guard
                let index = project.redactionRegions.firstIndex(where: {
                    $0.id == regionID
                })
            else {
                return
            }
            let latest = max(0, project.trimDuration - 0.1)
            project.redactionRegions[index].start = min(
                max(0, start), latest
            )
        }
    }

    func setRedactionRegionDuration(
        _ duration: Double,
        for regionID: UUID
    ) {
        updateRedactionRegion(
            regionID,
            groupingKey: "redaction.duration.\(regionID)"
        ) { project in
            guard
                let index = project.redactionRegions.firstIndex(where: {
                    $0.id == regionID
                })
            else {
                return
            }
            let start = project.redactionRegions[index].start
            let maxDuration = max(0.1, project.trimDuration - start)
            project.redactionRegions[index].duration = min(
                max(0.1, duration), maxDuration
            )
        }
    }

    /// 画布拖动 / 缩放：更新归一化矩形（钳制在 0...1，最小 0.005）。
    func setRedactionRegionRect(
        _ rect: NormalizedRect,
        for regionID: UUID
    ) {
        updateRedactionRegion(
            regionID,
            groupingKey: "redaction.rect.\(regionID)"
        ) { project in
            if let index = project.redactionRegions.firstIndex(where: {
                $0.id == regionID
            }) {
                project.redactionRegions[index].rect = rect.clamped()
            }
        }
    }

    private func updateRedactionRegion(
        _ regionID: UUID,
        groupingKey: String? = nil,
        _ mutate: (inout StudioProject) -> Void
    ) {
        guard var project = draft else { return }
        guard project.redactionRegions.contains(where: { $0.id == regionID })
        else {
            return
        }
        let previous = project
        mutate(&project)
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: groupingKey)
        draft = project
        scheduleSave()
        schedulePreviewRefresh()
    }

    func toggleClick(_ clickID: UUID) {
        updateProject { project in
            guard let index = project.clicks.firstIndex(where: { $0.id == clickID }) else {
                return
            }
            project.clicks[index].enabled.toggle()
        }
    }

    func setAllClicks(enabled: Bool) {
        updateProject { project in
            for index in project.clicks.indices {
                project.clicks[index].enabled = enabled
            }
        }
    }

    func setCursorEnabled(_ enabled: Bool) {
        updateProject { project in
            project.cursor.enabled = enabled
        }
    }

    func setCursorSize(_ size: Double) {
        updateProject(groupingKey: "cursor.size") { project in
            project.cursor.size = min(2.5, max(0.75, size))
        }
    }

    func setCursorSmoothing(_ smoothing: Double) {
        updateProject(groupingKey: "cursor.smoothing") { project in
            project.cursor.smoothing = min(0.95, max(0, smoothing))
        }
    }

    func setCursorHideWhenIdle(_ enabled: Bool) {
        updateProject { project in
            project.cursor.hideWhenIdle = enabled
        }
    }

    func setCursorIdleDelay(_ delay: Double) {
        updateProject(groupingKey: "cursor.idleDelay") { project in
            project.cursor.idleDelay = min(4, max(0.4, delay))
        }
    }

    func setCursorClickHighlight(_ enabled: Bool) {
        updateProject { project in
            project.cursor.clickHighlight = enabled
        }
    }

    func setCanvasAspect(_ aspect: CanvasAspect) {
        updateProject { $0.canvas.aspect = aspect }
    }

    func setBackgroundKind(_ kind: CanvasBackgroundKind) {
        updateProject { $0.canvas.background.kind = kind }
    }

    func setBackgroundColor(_ hex: String) {
        updateProject(groupingKey: "background.color") {
            $0.canvas.background.colorHex = hex
        }
    }

    func setGradientStartColor(_ hex: String) {
        updateProject(groupingKey: "background.gradientStart") {
            $0.canvas.background.gradientStartHex = hex
        }
    }

    func setGradientEndColor(_ hex: String) {
        updateProject(groupingKey: "background.gradientEnd") {
            $0.canvas.background.gradientEndHex = hex
        }
    }

    func setPadding(_ value: Double) {
        updateProject(groupingKey: "canvas.padding") {
            $0.canvas.padding = min(0.16, max(0, value))
        }
    }

    func setCornerRadius(_ value: Double) {
        updateProject(groupingKey: "canvas.cornerRadius") {
            $0.canvas.cornerRadius = min(0.12, max(0, value))
        }
    }

    func setShadowEnabled(_ enabled: Bool) {
        updateProject { $0.canvas.shadowEnabled = enabled }
    }

    func setShadowIntensity(_ value: Double) {
        updateProject(groupingKey: "canvas.shadowIntensity") {
            $0.canvas.shadowIntensity = min(1, max(0.05, value))
        }
    }

    func chooseBackgroundImage() {
        guard let project = draft else { return }
        let panel = NSOpenPanel()
        panel.title = "选择画布背景"
        panel.prompt = "使用图片"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // P4 防卡死：整图复制 + 可读性解码验证（大图数百 ms）下沉后台；
        // 目标工程校验在回主线程后做。
        Task.detached { [weak self] in
            do {
                let filename = try CanvasBackgroundImageInstaller.install(
                    from: url,
                    into: project.folderURL,
                    replacing: project.canvas.background.imageFile
                )
                await MainActor.run {
                    guard let self, self.draft?.id == project.id else {
                        return
                    }
                    self.updateProject { p in
                        p.canvas.background.kind = .image
                        p.canvas.background.imageFile = filename
                    }
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = "导入背景图失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func presentDesktopWallpaperPicker() {
        guard draft != nil else { return }
        // P4 防卡死：每屏一张系统壁纸需全量解码（5K JPEG/HEIC 常见
        // 100–300ms+/张），下沉后台——选择器先以加载态弹出，读完填充。
        isDesktopWallpaperLoading = true
        isDesktopWallpaperPickerPresented = true
        Task { [weak self] in
            // 屏幕信息查询必须在主线程（毫秒级）；解码下沉后台。
            let entries = DesktopWallpaperCatalog.screenEntries()
            Task.detached { [weak self] in
                let options = DesktopWallpaperCatalog.decodedOptions(
                    from: entries
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isDesktopWallpaperLoading = false
                    guard !options.isEmpty else {
                        self.isDesktopWallpaperPickerPresented = false
                        self.errorMessage =
                            "无法读取当前系统壁纸。请确认系统已设置静态桌面图片后再试。"
                        return
                    }
                    self.desktopWallpaperOptions = options
                }
            }
        }
    }

    func chooseDesktopWallpaper(_ option: DesktopWallpaperOption) {
        guard let project = draft else { return }
        // P4 防卡死：整图复制 + 可读性解码验证下沉后台；目标工程校验
        // 在回主线程后做（期间切换工程不误改新工程）。
        Task.detached { [weak self] in
            do {
                let filename = try CanvasBackgroundImageInstaller.install(
                    from: option.imageURL,
                    into: project.folderURL,
                    replacing: project.canvas.background.imageFile
                )
                await MainActor.run {
                    guard let self, self.draft?.id == project.id else {
                        return
                    }
                    self.updateProject { p in
                        p.canvas.background.kind = .image
                        p.canvas.background.imageFile = filename
                    }
                    self.isDesktopWallpaperPickerPresented = false
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = "应用桌面壁纸失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func dismissDesktopWallpaperPicker() {
        isDesktopWallpaperPickerPresented = false
    }

    func setCameraLayout(_ layout: CameraLayoutMode) {
        updateCameraAtPlayhead(
            createSegment: true,
            groupingKey: nil
        ) { $0.layout = layout }
    }

    func setCameraEnabled(_ enabled: Bool) {
        updateCameraAtPlayhead(
            createSegment: true,
            groupingKey: nil
        ) { $0.enabled = enabled }
    }

    func setCameraAnchor(_ anchor: CameraAnchor) {
        updateCameraAtPlayhead { camera in
            camera.anchor = anchor
            camera.customCenter = nil
        }
    }

    func setCameraCustomCenter(_ point: CGPoint) {
        guard let project = draft else { return }
        updateCameraAtPlayhead(groupingKey: "camera.center") { camera in
            let center = CanvasLayout.clampedCameraCenter(
                point,
                outputSize: project.canvasOutputSize,
                settings: camera
            )
            camera.customCenter = NormalizedPoint(
                x: center.x,
                y: center.y
            )
        }
    }

    func nudgeCamera(dx: CGFloat, dy: CGFloat) {
        guard let project = draft else { return }
        let settings = project.cameraSettings(atOutput: currentTime)
        let current = settings.customCenter
            ?? NormalizedPoint(
                x: settings.anchor.normalizedCenter.x,
                y: settings.anchor.normalizedCenter.y
            )
        setCameraCustomCenter(
            CGPoint(x: current.x + dx, y: current.y + dy)
        )
    }

    func setCameraSize(_ value: Double) {
        updateCameraAtPlayhead(groupingKey: "camera.size") {
            $0.size = min(0.5, max(0.1, value))
        }
    }

    // MARK: F2 素材叠加轨

    /// 画布/时间线选中的叠加片段（选中即显示调整控件）。
    @Published var selectedOverlayClipID: UUID?

    /// 素材叠加片段添加后的引导提示（复用 info toast）。
    private static let overlayAddedHint =
        "已添加叠加素材：在时间线「叠加」轨或画面页调整位置、大小与时长"

    /// 添加素材叠加：NSOpenPanel 选图/视频 → 复制进工程目录 → 在播放头
    /// 插入片段（视频时长取素材时长，图片默认 3 秒）。
    func chooseOverlayMedia() {
        guard let project = draft else { return }
        let panel = NSOpenPanel()
        panel.title = "添加叠加素材"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.image, .movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let start = currentTime
        // P4 口径延续：复制/探测（视频时长、图片宽高比）在后台做，
        // 完成后回主线程落模型。
        Task.detached { [weak self] in
            do {
                let installed = try OverlayMediaInstaller.install(
                    from: url,
                    into: project.folderURL
                )
                let mediaURL = project.folderURL
                    .appendingPathComponent(installed.fileName)
                var duration = 3.0
                var aspect = 16.0 / 9.0
                if installed.kind == .video {
                    let asset = AVURLAsset(url: mediaURL)
                    let seconds = try await asset.load(.duration).seconds
                    if seconds.isFinite, seconds > 0 {
                        duration = min(max(seconds, 0.1), 60)
                    }
                    // 视频/图片一律钳到成片结尾内（防导出尾部无画面帧）。
                    let maxDuration = max(
                        OverlayClip.minimumDuration,
                        project.trimDuration - start
                    )
                    duration = min(duration, maxDuration)
                    // 宽高比按显示方向算：结合 preferredTransform 折算
                    // 旋转元数据（竖拍视频不取反）。
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    if let track = tracks.first {
                        let size = try await track.load(.naturalSize)
                        let transform = try await track.load(.preferredTransform)
                        let display = size.applying(transform)
                        let width = abs(display.width)
                        let height = abs(display.height)
                        if width > 1, height > 1 {
                            aspect = Double(width / height)
                        }
                    }
                } else {
                    if
                        let source = CGImageSourceCreateWithURL(
                            mediaURL as CFURL, nil
                        ),
                        let properties = CGImageSourceCopyPropertiesAtIndex(
                            source, 0, nil
                        ) as? [CFString: Any],
                        let width = properties[kCGImagePropertyPixelWidth]
                            as? CGFloat,
                        let height = properties[kCGImagePropertyPixelHeight]
                            as? CGFloat,
                        height > 0
                    {
                        aspect = Double(width / height)
                    }
                }
                await MainActor.run {
                    guard let self, self.draft?.id == project.id else {
                        return
                    }
                    self.addOverlayClip(
                        fileName: installed.fileName,
                        kind: installed.kind,
                        start: start,
                        duration: duration,
                        aspect: aspect
                    )
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage =
                        "添加叠加素材失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func addOverlayClip(
        fileName: String,
        kind: OverlayClip.Kind,
        start: Double,
        duration: Double,
        aspect: Double
    ) {
        var clipID: UUID?
        updateProject {
            let clip = OverlayClip(
                start: max(0, start),
                duration: duration,
                kind: kind,
                fileName: fileName,
                aspect: aspect
            )
            clipID = clip.id
            $0.overlayClips.append(clip)
        }
        selectedOverlayClipID = clipID
        errorMessage = Self.overlayAddedHint
    }

    func deleteOverlayClip(_ id: UUID) {
        updateProject { project in
            project.overlayClips.removeAll { $0.id == id }
        }
        if selectedOverlayClipID == id {
            selectedOverlayClipID = nil
        }
        errorMessage = "已删除叠加素材 · 按 ⌘Z 可还原"
    }

    func selectOverlayClip(_ id: UUID?) {
        selectedOverlayClipID = id
    }

    /// 开关画面角落的按键小条（有录制数据时才显示开关）。
    func setKeyStripEnabled(_ enabled: Bool) {
        updateProject { $0.keyStripEnabled = enabled }
    }

    func setOverlayAnchor(_ anchor: CameraAnchor, for id: UUID) {
        updateProject(groupingKey: "overlay.anchor.\(id)") { project in
            guard
                let index = project.overlayClips.firstIndex(where: {
                    $0.id == id
                })
            else {
                return
            }
            project.overlayClips[index].anchor = anchor
            project.overlayClips[index].customCenter = nil
        }
    }

    func setOverlayCustomCenter(_ point: CGPoint, for id: UUID) {
        guard let project = draft else { return }
        guard
            let clip = project.overlayClips.first(where: { $0.id == id })
        else {
            return
        }
        let snapped = CanvasLayout.snappedOverlayCenter(
            point,
            outputSize: project.canvasOutputSize,
            aspect: CGFloat(clip.aspect),
            size: clip.size
        )
        updateProject(groupingKey: "overlay.center.\(id)") { project in
            guard
                let index = project.overlayClips.firstIndex(where: {
                    $0.id == id
                })
            else {
                return
            }
            project.overlayClips[index].customCenter = NormalizedPoint(
                x: snapped.x,
                y: snapped.y
            )
        }
    }

    func setOverlaySize(_ value: Double, for id: UUID) {
        guard let project = draft else { return }
        let size = min(
            OverlayClip.sizeRange.upperBound,
            max(OverlayClip.sizeRange.lowerBound, value)
        )
        updateProject(groupingKey: "overlay.size.\(id)") { project in
            guard
                let index = project.overlayClips.firstIndex(where: {
                    $0.id == id
                })
            else {
                return
            }
            project.overlayClips[index].size = size
            // 尺寸变化后中心点重新钳制，矩形不出边距。
            let clip = project.overlayClips[index]
            let clamped = CanvasLayout.clampedOverlayCenter(
                clip.effectiveCenter,
                outputSize: project.canvasOutputSize,
                aspect: CGFloat(clip.aspect),
                size: size
            )
            project.overlayClips[index].customCenter = NormalizedPoint(
                x: clamped.x,
                y: clamped.y
            )
        }
    }



    func setCameraShape(_ shape: CameraShape) {
        updateCameraAtPlayhead { $0.shape = shape }
    }

    func setCameraMirrored(_ mirrored: Bool) {
        updateCameraAtPlayhead { $0.mirrored = mirrored }
    }

    func setCameraContentMode(_ mode: CameraContentMode) {
        updateCameraAtPlayhead { $0.contentMode = mode }
    }

    func setCameraCropFocus(_ point: CGPoint, groupingKey: String? = nil) {
        updateCameraAtPlayhead(groupingKey: groupingKey) { camera in
            camera.cropFocus = NormalizedPoint(
                x: min(1, max(0, point.x)),
                y: min(1, max(0, point.y))
            )
        }
    }

    func setCameraBorderColor(_ hex: String) {
        updateCameraAtPlayhead(groupingKey: "camera.borderColor") {
            $0.borderColorHex = hex
        }
    }

    func setCameraBorderWidth(_ width: Double) {
        updateCameraAtPlayhead(groupingKey: "camera.borderWidth") {
            $0.borderWidth = min(20, max(0, width))
        }
    }

    func setCameraShadowEnabled(_ enabled: Bool) {
        updateCameraAtPlayhead { $0.shadowEnabled = enabled }
    }

    func setCameraShadowIntensity(_ intensity: Double) {
        updateCameraAtPlayhead(groupingKey: "camera.shadowIntensity") {
            $0.shadowIntensity = min(0.8, max(0.05, intensity))
        }
    }

    func setCameraAvoidsZoomFocus(_ enabled: Bool) {
        updateCameraAtPlayhead { $0.avoidsZoomFocus = enabled }
    }

    func setCameraSplitRatio(_ value: Double) {
        updateCameraAtPlayhead(groupingKey: "camera.splitRatio") {
            $0.splitRatio = min(0.8, max(0.5, value))
        }
    }

    func setCameraChromaKeyEnabled(_ enabled: Bool) {
        updateProject { $0.cameraChromaKey.enabled = enabled }
    }

    func setCameraChromaKeyColor(_ hex: String) {
        updateProject(groupingKey: "camera.chromaKey.color") {
            $0.cameraChromaKey.keyColorHex = hex
            // 手动取色保留单点模式：清除估计色场，退回均匀单色参照。
            $0.cameraChromaKey.backgroundFieldData = nil
        }
    }

    /// C2 边缘三件套：哑光内收与 alpha 柔化（像素）。
    func setCameraChromaKeyEdgeShrink(_ value: Double) {
        updateProject(groupingKey: "camera.chromaKey.edgeShrink") {
            $0.cameraChromaKey.edgeShrinkPixels = min(3, max(0, value))
        }
    }

    func setCameraChromaKeyEdgeFeather(_ value: Double) {
        updateProject(groupingKey: "camera.chromaKey.edgeFeather") {
            $0.cameraChromaKey.edgeFeatherPixels = min(4, max(0, value))
        }
    }

    func setCameraChromaKeyTolerance(_ value: Double) {
        updateProject(groupingKey: "camera.chromaKey.tolerance") {
            $0.cameraChromaKey.tolerance = min(0.35, max(0.02, value))
        }
    }

    func setCameraChromaKeySoftness(_ value: Double) {
        updateProject(groupingKey: "camera.chromaKey.softness") {
            $0.cameraChromaKey.softness = min(0.2, max(0.01, value))
        }
    }

    func setCameraChromaKeySpillSuppression(_ value: Double) {
        updateProject(groupingKey: "camera.chromaKey.spill") {
            $0.cameraChromaKey.spillSuppression = min(1, max(0, value))
        }
    }

    /// 边缘光包裹强度（0...1，0 = 关闭）。
    func setCameraChromaKeyLightWrap(_ value: Double) {
        updateProject(groupingKey: "camera.chromaKey.lightWrap") {
            $0.cameraChromaKey.lightWrap = min(1, max(0, value))
        }
    }

    /// C3 抠像模式三态：关闭 / 绿幕 / 自动分割（Vision 本机）。
    func setCameraChromaKeyMode(_ mode: CameraChromaKeyMode) {
        updateProject(groupingKey: "camera.chromaKey.mode") {
            $0.cameraChromaKey.enabled = mode != .off
            $0.cameraChromaKey.personSegmentation = mode == .personSegment
        }
    }

    /// C3 分割背景呈现：透明 / 摄像头自身重模糊。
    func setCameraSegmentationBackgroundBlurred(_ value: Bool) {
        updateProject(groupingKey: "camera.chromaKey.segBackground") {
            $0.cameraChromaKey.segmentationBackgroundBlurred = value
        }
    }

    /// 加深队列：一键套用绿幕参数预设（只改键控参数，幕布色 / 色场
    /// 不动），套用后可继续微调，占一个撤销步骤。
    func applyCameraChromaKeyPreset(_ preset: CameraChromaKeyPreset) {
        updateProject(groupingKey: "camera.chromaKey.preset") {
            $0.cameraChromaKey.tolerance = preset.tolerance
            $0.cameraChromaKey.softness = preset.softness
            $0.cameraChromaKey.spillSuppression = preset.spillSuppression
            $0.cameraChromaKey.edgeShrinkPixels = preset.edgeShrinkPixels
            $0.cameraChromaKey.edgeFeatherPixels = preset.edgeFeatherPixels
        }
    }

    /// 从播放头对应的摄像头帧自动取绿幕颜色。时间映射与导出一致：
    /// 成片时间 → 工程源时间 → 摄像头文件时间。
    func sampleCameraChromaKeyColor() {
        guard
            let project = draft,
            let cameraURL = project.cameraURL,
            let sourceTime = project.timeline.sourceTime(
                atOutput: currentTime
            )
        else {
            errorMessage = "当前播放头没有可用的摄像头画面，无法自动取色。"
            return
        }
        let cameraTime = sourceTime - project.cameraOffset
        guard cameraTime >= 0 else {
            errorMessage = "当前播放头在摄像头开始录制之前，无法自动取色。"
            return
        }

        cancelChromaKeySampling()
        errorMessage = nil
        let sampleID = UUID()
        chromaKeySampleID = sampleID
        isSamplingChromaKey = true
        chromaKeySampleTask = Task {
            defer {
                if chromaKeySampleID == sampleID {
                    chromaKeySampleID = nil
                    chromaKeySampleTask = nil
                    isSamplingChromaKey = false
                }
            }
            do {
                let asset = AVURLAsset(url: cameraURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(
                    seconds: 0.1,
                    preferredTimescale: 600
                )
                generator.requestedTimeToleranceAfter = CMTime(
                    seconds: 0.1,
                    preferredTimescale: 600
                )
                try Task.checkCancellation()
                let frame = try await generator.image(
                    at: CMTime(
                        seconds: cameraTime,
                        preferredTimescale: 600
                    )
                ).image
                try Task.checkCancellation()
                guard draft?.id == project.id else { return }
                // 自动取色升级为多点取色 + 背景色场估计（12×7 网格，
                // 边框多点采样 + 内插 + 重模糊）；边框绿系格不足时与旧
                // 行为一致地明确失败，不静默改色。
                guard
                    let sampled = ChromaKeyRenderer.sampleBackgroundField(
                        from: frame
                    )
                else {
                    throw ChromaKeySampleError.noGreenKey
                }
                updateProject {
                    $0.cameraChromaKey.keyColorHex = sampled.keyColorHex
                    $0.cameraChromaKey.backgroundFieldData = sampled.field
                        .data
                    $0.cameraChromaKey.enabled = true
                }
            } catch is CancellationError {
            } catch {
                guard
                    !Task.isCancelled,
                    draft?.id == project.id
                else {
                    return
                }
                errorMessage = "自动取色失败：\(error.localizedDescription)"
            }
        }
    }

    func applyCameraPreset(
        _ preset: CameraCompositionPreset,
        scope: CameraPresetApplicationScope = .fromPlayhead
    ) {
        guard var project = draft else { return }
        if preset != .screenOnly, project.cameraURL == nil {
            errorMessage = "这次录制没有摄像头，无法使用该构图预设。"
            return
        }
        let previous = project
        let previewTime: Double?
        if let aspect = preset.canvasAspectOverride {
            project.canvas.aspect = aspect
        }
        switch scope {
        case .fromPlayhead:
            let time = cameraEditTime(in: project)
            previewTime = time
            if time <= 0.001, project.cameraSegments.isEmpty {
                project.camera = preset.camera(applyingTo: project.camera)
            } else {
                let index = cameraSegmentIndex(
                    in: &project,
                    at: time,
                    reuseExactStart: true
                )
                let segmentID = project.cameraSegments[index].id
                project.cameraSegments[index].camera = preset.camera(
                    applyingTo: project.cameraSegments[index].camera
                )
                project.cameraSegments[index].transitionDuration = 0
                project.smartCutAutoCameraSegmentIDs.removeAll {
                    $0 == segmentID
                }
            }
        case .entireProject:
            previewTime = nil
            project.camera = preset.camera(applyingTo: project.camera)
            project.cameraSegments.removeAll()
            project.smartCutAutoCameraSegmentIDs.removeAll()
        }
        normalizeCameraSettings(&project)
        guard project != previous else { return }
        recordUndo(for: previous)
        draft = project
        if let previewTime {
            currentTime = previewTime
        }
        scheduleSave()
        schedulePreviewRefresh(immediately: true, at: previewTime)
    }

    func addCameraLayoutSegmentAtPlayhead() {
        guard var project = draft else { return }
        guard project.cameraURL != nil else {
            errorMessage = "这次录制没有摄像头，无法添加布局段。"
            return
        }
        let previous = project
        let time = cameraEditTime(in: project)
        guard !project.cameraSegments.contains(where: {
            abs($0.start - time) < 0.03
        }) else {
            errorMessage = "播放头处已经有摄像头布局段。"
            return
        }
        let segment = CameraLayoutSegment(
            start: time,
            camera: project.cameraSettings(atOutput: time)
        )
        project.cameraSegments.append(segment)
        recordUndo(for: previous)
        draft = project
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    func deleteCameraLayoutSegmentAtPlayhead() {
        guard var project = draft else { return }
        guard
            let segment = project.cameraSegment(atOutput: currentTime),
            let index = project.cameraSegments.firstIndex(where: {
                $0.id == segment.id
            })
        else {
            return
        }
        let previous = project
        project.cameraSegments.remove(at: index)
        recordUndo(for: previous)
        draft = project
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    func setCameraSegmentStart(_ value: Double, for segmentID: UUID) {
        guard var project = draft else { return }
        let previous = project
        guard project.setCameraSegmentStart(value, for: segmentID) else {
            return
        }
        recordUndo(
            for: previous,
            groupingKey: "camera.segment.start.\(segmentID)"
        )
        draft = project
        scheduleSave()
        schedulePreviewRefresh()
    }

    func setCameraSegmentTransition(_ duration: Double) {
        guard var project = draft else { return }
        guard
            let segment = project.cameraSegment(atOutput: currentTime),
            let index = project.cameraSegments.firstIndex(where: {
                $0.id == segment.id
            })
        else {
            return
        }
        let previous = project
        project.cameraSegments[index].transitionDuration = min(
            2,
            max(0, duration)
        )
        guard project != previous else { return }
        recordUndo(for: previous)
        draft = project
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    func setMicrophoneGain(_ value: Double) {
        updateProject(groupingKey: "audio.microphoneGain") {
            $0.audio.microphoneGain = min(1, max(0, value))
        }
    }

    func setSystemGain(_ value: Double) {
        updateProject(groupingKey: "audio.systemGain") {
            $0.audio.systemGain = min(1, max(0, value))
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        updateProject { $0.audio.microphoneMuted = muted }
    }

    func setSystemMuted(_ muted: Bool) {
        updateProject { $0.audio.systemMuted = muted }
    }

    private func updateCameraAtPlayhead(
        createSegment: Bool = false,
        groupingKey: String? = nil,
        _ mutate: (inout CameraSettings) -> Void
    ) {
        guard var project = draft else { return }
        let previous = project
        let time = cameraEditTime(in: project)
        let index: Int?
        if createSegment {
            index = cameraSegmentIndex(
                in: &project,
                at: time,
                reuseExactStart: true
            )
        } else if let segment = project.cameraSegment(atOutput: time) {
            index = project.cameraSegments.firstIndex(where: {
                $0.id == segment.id
            })
        } else {
            index = nil
        }
        if let index {
            mutate(&project.cameraSegments[index].camera)
        } else {
            mutate(&project.camera)
        }
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: groupingKey)
        draft = project
        scheduleSave()
        schedulePreviewRefresh()
    }

    private func cameraSegmentIndex(
        in project: inout StudioProject,
        at time: Double,
        reuseExactStart: Bool
    ) -> Int {
        if
            reuseExactStart,
            let index = project.cameraSegments.firstIndex(where: {
                abs($0.start - time) < 0.03
            })
        {
            return index
        }
        let segment = CameraLayoutSegment(
            start: time,
            camera: project.cameraSettings(atOutput: time)
        )
        project.cameraSegments.append(segment)
        return project.cameraSegments.count - 1
    }

    private func cameraEditTime(in project: StudioProject) -> Double {
        min(
            max(0, currentTime),
            max(0, project.trimDuration - 0.001)
        )
    }

    private func normalizeCameraSettings(_ project: inout StudioProject) {
        project.cameraSegments.sort {
            if abs($0.start - $1.start) > 0.000_001 {
                return $0.start < $1.start
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        let outputSize = project.canvasOutputSize
        for index in project.cameraSegments.indices {
            let camera = project.cameraSegments[index].camera
            if camera.layout == .pictureInPicture {
                let center = CanvasLayout.clampedCameraCenter(
                    CGPoint(
                        x: camera.customCenter?.x
                            ?? camera.anchor.normalizedCenter.x,
                        y: camera.customCenter?.y
                            ?? camera.anchor.normalizedCenter.y
                    ),
                    outputSize: outputSize,
                    settings: camera
                )
                if camera.customCenter != nil {
                    project.cameraSegments[index].camera.customCenter =
                        NormalizedPoint(
                        x: center.x,
                        y: center.y
                    )
                }
            }
        }
    }

    func beginInteractiveEdit() {
        guard interactiveUndoSnapshot == nil, let project = draft else { return }
        interactiveUndoSnapshot = project
        undoHistory.breakGrouping()
    }

    func endInteractiveEdit() {
        guard let snapshot = interactiveUndoSnapshot else { return }
        interactiveUndoSnapshot = nil
        if snapshot != draft {
            undoHistory.record(snapshot)
            publishUndoState()
            schedulePreviewRefresh(immediately: true)
        }
    }

    func undoProjectEdit() {
        endInteractiveEdit()
        guard
            let current = draft,
            let previous = undoHistory.undo(current: current)
        else {
            return
        }
        applyHistoryProject(previous)
    }

    func redoProjectEdit() {
        endInteractiveEdit()
        guard
            let current = draft,
            let next = undoHistory.redo(current: current)
        else {
            return
        }
        applyHistoryProject(next)
    }

    // MARK: 精剪

    func setSmartCutMode(_ mode: SmartCutMode) {
        guard smartCutMode != mode else { return }
        smartCutMode = mode
        // 1.2 块6：模式与保护开关持久化进工程设置（时间线变化后重开
        // 工程，扫描参数仍保留）。
        updateProject { $0.smartCutSettings.mode = mode }
        resetSmartCutResults()
    }

    func setSmartCutProtectScreenActivity(_ enabled: Bool) {
        guard smartCutProtectScreenActivity != enabled else { return }
        smartCutProtectScreenActivity = enabled
        updateProject { $0.smartCutSettings.protectScreenActivity = enabled }
        resetSmartCutResults()
    }

    func setSmartCutProtectSystemSound(_ enabled: Bool) {
        guard smartCutProtectSystemSound != enabled else { return }
        smartCutProtectSystemSound = enabled
        updateProject { $0.smartCutSettings.protectSystemSound = enabled }
        resetSmartCutResults()
    }

    /// 清除当前扫描结果并回到未扫描状态；用于精剪页的“重置”。
    func clearSmartCutResults() {
        resetSmartCutResults()
    }

    func startSmartCutScan() {
        guard let project = draft else { return }
        guard smartCutScanPhase != .scanning else { return }
        smartCutTask?.cancel()
        smartCutMessage = nil
        smartCutScanPhase = .scanning
        smartCutScanProgress = 0
        // 结束试听状态：扫描期间恢复正常预览。
        schedulePreviewRefresh()
        let mode = smartCutMode
        let protectScreen = smartCutProtectScreenActivity
        let protectSystem = smartCutProtectSystemSound
        smartCutTask = Task {
            do {
                let outcome = try await SmartCutAnalyzer.scan(
                    project: project,
                    mode: mode,
                    protectScreenActivity: protectScreen,
                    protectSystemSound: protectSystem,
                    progress: { value in
                        Task { @MainActor in
                            guard self.smartCutScanPhase == .scanning else {
                                return
                            }
                            self.smartCutScanProgress = value
                        }
                    },
                    isCancelled: { Task.isCancelled }
                )
                guard !Task.isCancelled else { return }
                finishSmartCutScan(outcome)
            } catch is CancellationError {
                // 取消扫描：保留已有结果；没有结果时回到未扫描状态。
                if smartCutScanPhase == .scanning {
                    smartCutScanPhase = smartCutAnalysis == nil ? .idle : .ready
                    smartCutMessage = "扫描已取消。"
                }
            } catch {
                smartCutScanPhase = .failed
                smartCutMessage = error.localizedDescription
            }
        }
    }

    func cancelSmartCutScan() {
        guard smartCutScanPhase == .scanning else { return }
        smartCutTask?.cancel()
        smartCutTask = nil
        smartCutScanPhase = smartCutAnalysis == nil ? .idle : .ready
        smartCutMessage = "扫描已取消。"
    }

    /// 勾选 / 取消勾选一条候选；只影响应用范围，不移动播放头。
    func toggleSmartCutCandidate(_ index: Int) {
        guard
            let analysis = smartCutAnalysis,
            analysis.candidates.indices.contains(index)
        else {
            return
        }
        if smartCutSelectedIndices.contains(index) {
            smartCutSelectedIndices.remove(index)
        } else {
            smartCutSelectedIndices.insert(index)
        }
    }

    /// 选中候选并跳到删除区间前 1 秒（路线图第 3 节）。
    func selectSmartCutCandidate(_ index: Int) {
        guard
            let analysis = smartCutAnalysis,
            analysis.candidates.indices.contains(index)
        else {
            return
        }
        seek(to: max(0, analysis.candidates[index].cutStart - 1))
    }

    func selectAllSafeSmartCutCandidates() {
        guard let analysis = smartCutAnalysis else { return }
        smartCutSelectedIndices = Set(
            analysis.candidates.indices.filter {
                analysis.candidates[$0].isDefaultSelected
            }
        )
    }

    func deselectAllSmartCutCandidates() {
        smartCutSelectedIndices = []
    }

    /// “试听剪切后”：把该候选应用到工程副本并临时替换预览，从删除区间前
    /// 1 秒的新位置开始播放；应用 / 重新扫描或下一次预览刷新会恢复正常预览。
    func auditionSmartCutCandidate(_ index: Int) {
        guard
            let project = draft,
            let analysis = smartCutAnalysis,
            analysis.candidates.indices.contains(index)
        else {
            return
        }
        let candidate = analysis.candidates[index]
        let outcome = smartCutOutcome(apply: [candidate], to: project)
        guard let outcome else { return }
        let preview = project.applyingCutTransaction(outcome)
        let jump = outcome.mappedTimeSnappingAfterCut(
            max(0, candidate.cutStart - 1)
        ) ?? 0
        auditionTask?.cancel()
        auditionTask = Task {
            await preparePreview(for: preview, preserveTime: jump)
            guard !Task.isCancelled else { return }
            auditionPreviewEndTime = preview.trimDuration
            player.play()
            isPlaying = true
        }
    }

    func applySmartCutSelection() {
        guard
            let analysis = smartCutAnalysis,
            smartCutScanPhase == .ready
        else {
            return
        }
        let selected = analysis.candidates.enumerated()
            .filter { smartCutSelectedIndices.contains($0.offset) }
            .map(\.element)
        applySmartCut(selected)
    }

    /// 原子应用多个剪切：一次应用只占一个撤销步骤；无法安全应用的候选
    /// 整条跳过并给出可见说明（路线图 4.4 / 4.5）。
    func applySmartCut(_ candidates: [SmartCutCandidate]) {
        guard let project = draft, !candidates.isEmpty else { return }
        guard let outcome = smartCutOutcome(apply: candidates, to: project) else {
            smartCutMessage = "所选候选会留下过短片段，已全部跳过。"
            return
        }
        let updated = project.applyingCutTransaction(outcome)
        guard updated != project else { return }
        // commitTimelineProject 记录应用前完整快照并只占用一个撤销步骤。
        commitTimelineProject(updated)
        smartCutAnalysis = nil
        smartCutSelectedIndices = []
        smartCutScanPhase = .idle
        smartCutScanProgress = 0
        // 成片时间已变化，基于旧时间的口头禅建议一并失效。
        fillerSuggestions = []
        fillerSelectedIndices = []
        rawCaptionSegments = []
        if !outcome.skippedCandidates.isEmpty {
            smartCutMessage =
                "已应用 \(outcome.deletions.count) 处剪切；"
                + "\(outcome.skippedCandidates.count) 条候选因会留下过短片段被跳过。"
        } else {
            smartCutMessage =
                "已应用 \(outcome.deletions.count) 处剪切，节省 "
                + formatDuration(outcome.removedDuration) + "。"
        }
    }

    // MARK: 语音驱动摄像头

    /// 基于最近一次扫描的语音活动生成摄像头显隐布局段。手动布局段存在时
    /// 给出提示并拒绝；重复生成按 ID 幂等替换，不叠加。
    func applyVoiceCameraSegments() {
        guard let project = draft else { return }
        guard
            let analysis = smartCutAnalysis,
            smartCutScanPhase == .ready
        else {
            smartCutMessage = "请先扫描停顿，再生成语音显隐段。"
            return
        }
        guard project.supportsVoiceCamera else {
            smartCutMessage = "当前工程没有可用的摄像头画面，无法使用语音驱动摄像头。"
            return
        }
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: analysis.speechActivity,
            analyzedDuration: analysis.analyzedDuration
        )
        guard !plan.intervals.isEmpty else {
            smartCutMessage =
                "没有可容纳隐藏和提前恢复的长静默，未生成语音显隐段。"
            return
        }
        guard let updated = project.applyingVoiceCameraPlan(plan) else {
            smartCutMessage =
                "已有手动摄像头布局段，未生成语音显隐；如需使用请先删除手动布局段。"
            return
        }
        guard updated != project else {
            smartCutMessage = "没有可用的语音显隐段，工程未改动。"
            return
        }
        // 一次生成只占一个撤销步骤。
        commitTimelineProject(updated)
        if plan.intervals.isEmpty {
            smartCutMessage = "没有超过 1.5 秒的长静默，未生成语音显隐段。"
        } else {
            smartCutMessage =
                "已生成 \(updated.smartCutAutoCameraSegmentIDs.count) 个语音显隐布局段；"
                + "重复生成会替换而不是叠加，一次 ⌘Z 可全部恢复。"
        }
    }

    // MARK: 口头禅与重说建议

    /// 分析现有字幕的填充词、重复句和重说。只依赖已有字幕 cue；没有字幕
    /// 时明确降级，不影响停顿清理（路线图第 6 节）。
    func analyzeFillerSuggestions() {
        guard let project = draft else { return }
        guard !project.captionCues.isEmpty else {
            fillerSuggestions = []
            fillerSelectedIndices = []
            smartCutMessage =
                "当前工程没有字幕：请先在“字幕”页生成本机字幕或导入 SRT。"
                + "口头禅分析不可用不影响停顿清理。"
            return
        }
        let fragments = project.captionCues.map { cue in
            SmartCutCaptionFragment(
                id: cue.id,
                start: cue.start,
                end: cue.end,
                text: cue.text
            )
        }
        // 有原始分段时增加句内检测（独立成词的填充词 segment）；
        // 没有分段（SRT 导入、旧会话）时行为与原来完全一致。
        let segmentFragments = rawCaptionSegments.isEmpty
            ? nil
            : rawCaptionSegments.map { segment in
                SmartCutCaptionFragment(
                    id: UUID(),
                    start: segment.start,
                    end: segment.start + segment.duration,
                    text: segment.text
                )
            }
        let suggestions = SmartCutFillerDetector.suggestions(
            in: fragments,
            segmentFragments: segmentFragments
        )
        fillerSuggestions = suggestions
        fillerSelectedIndices = Set(
            suggestions.indices.filter { suggestions[$0].isRecommended }
        )
        if suggestions.isEmpty {
            smartCutMessage = "没有发现明显口头禅或重复句。"
        } else {
            smartCutMessage =
                "发现 \(suggestions.count) 条口头禅 / 重说建议，默认只删除"
                + "勾选项，一次 ⌘Z 可全部恢复。"
        }
    }

    func toggleFillerSuggestion(_ index: Int) {
        guard fillerSuggestions.indices.contains(index) else { return }
        if fillerSelectedIndices.contains(index) {
            fillerSelectedIndices.remove(index)
        } else {
            fillerSelectedIndices.insert(index)
        }
    }

    /// 当前勾选建议预计剪掉的成片秒数（未吸附帧网格的近似值）。
    var selectedFillerEstimatedDuration: Double {
        fillerSuggestions.estimatedSavedDuration(
            selectedIndices: fillerSelectedIndices
        )
    }

    /// 重复 / 重说建议的“保留最后一遍”切换：勾选的删除区间随之切换。
    func toggleKeepLastFillerInstance(_ index: Int) {
        guard fillerSuggestions.indices.contains(index) else { return }
        fillerSuggestions[index].keepLastInstance.toggle()
    }

    func selectAllSafeFillerSuggestions() {
        fillerSelectedIndices = Set(
            fillerSuggestions.indices.filter { fillerSuggestions[$0].isRecommended }
        )
    }

    func deselectAllFillerSuggestions() {
        fillerSelectedIndices = []
    }

    /// 跳到建议删除区间前 1 秒。
    func selectFillerSuggestion(_ index: Int) {
        guard fillerSuggestions.indices.contains(index) else { return }
        seek(to: max(0, fillerSuggestions[index].activeRange().lowerBound - 1))
    }

    /// 试听剪切后：把该建议作为单条候选应用在工程副本上临时播放。
    func auditionFillerSuggestion(_ index: Int) {
        guard
            let project = draft,
            fillerSuggestions.indices.contains(index)
        else {
            return
        }
        let suggestion = fillerSuggestions[index]
        let range = suggestion.activeRange()
        let candidate = SmartCutCandidate(
            start: range.lowerBound,
            end: range.upperBound,
            kind: fillerCandidateKind(suggestion.kind),
            keepEachSide: 0
        )
        guard
            let outcome = smartCutOutcome(apply: [candidate], to: project)
        else {
            smartCutMessage = "该建议会留下过短片段，无法应用。"
            return
        }
        let preview = project.applyingCutTransaction(outcome)
        let jump = outcome.mappedTimeSnappingAfterCut(
            max(0, range.lowerBound - 1)
        ) ?? 0
        auditionTask?.cancel()
        auditionTask = Task {
            await preparePreview(for: preview, preserveTime: jump)
            guard !Task.isCancelled else { return }
            auditionPreviewEndTime = preview.trimDuration
            player.play()
            isPlaying = true
        }
    }

    /// 应用所选建议：复用精剪的原子剪切事务，一次应用占一个撤销步骤；
    /// 字幕 cue 随删除区间同步 ripple；句内填充词再按 segment 边界做
    /// 文本手术（句内填充词重写）。
    func applyFillerSuggestions() {
        guard let project = draft else { return }
        let selectedSuggestions = fillerSuggestions.enumerated()
            .filter { fillerSelectedIndices.contains($0.offset) }
            .map(\.element)
        guard !selectedSuggestions.isEmpty else { return }
        // 句内手术所需：被选 segment 的旧成片时间精确区间。
        let removedSegmentRanges = selectedSuggestions.compactMap(
            \.sourceSegmentRange
        )
        let selected = selectedSuggestions.map { suggestion in
            let range = suggestion.activeRange()
            return SmartCutCandidate(
                start: range.lowerBound,
                end: range.upperBound,
                kind: fillerCandidateKind(suggestion.kind),
                keepEachSide: 0
            )
        }
        guard
            let outcome = smartCutOutcome(apply: selected, to: project)
        else {
            smartCutMessage = "所选建议会留下过短片段，无法应用。"
            return
        }
        var updated = project.applyingCutTransaction(outcome)
        var surgeryHint = ""
        if !removedSegmentRanges.isEmpty, !rawCaptionSegments.isEmpty {
            // 主字幕轨文本手术：时间裁剪规则与 ripple 一致，文本按
            // segment 边界重写；校验不过的 cue 文本原样保留。
            let surgery = CaptionSegmentSurgery.rewritten(
                cues: project.captionCues,
                segments: rawCaptionSegments,
                removedSegmentRanges: removedSegmentRanges,
                outcome: outcome
            )
            updated.captionCues = surgery.cues
            surgeryHint =
                "字幕文本手术：重写 \(surgery.report.rewrittenCues) 条"
                + (surgery.report.deletedCues > 0
                    ? "、删除 \(surgery.report.deletedCues) 条" : "")
                + (surgery.report.skippedUnverifiedCues > 0
                    ? "、\(surgery.report.skippedUnverifiedCues) 条无法核对原文保持原样"
                    : "")
                + "。"
        }
        guard updated != project else { return }
        // commitTimelineProject 记录应用前完整快照并只占用一个撤销步骤。
        commitTimelineProject(updated)
        smartCutAnalysis = nil
        smartCutSelectedIndices = []
        smartCutScanPhase = .idle
        smartCutScanProgress = 0
        // 成片时间已变化，基于旧时间的口头禅建议一并失效。
        fillerSuggestions = []
        fillerSelectedIndices = []
        rawCaptionSegments = []
        if !outcome.skippedCandidates.isEmpty {
            smartCutMessage =
                "已应用 \(outcome.deletions.count) 处剪切；"
                + "\(outcome.skippedCandidates.count) 条候选因会留下过短片段被跳过。"
                + surgeryHint
        } else {
            smartCutMessage =
                "已应用 \(outcome.deletions.count) 处剪切，节省 "
                + formatDuration(outcome.removedDuration) + "。" + surgeryHint
        }
    }

    private func fillerCandidateKind(
        _ kind: SmartCutFillerSuggestion.Kind
    ) -> SmartCutCandidateKind {
        switch kind {
        case .fillerWord, .inSentenceFiller:
            return .fillerWord
        case .repeatedPhrase, .restart:
            return .repeatedTake
        }
    }

    // MARK: 音频一键优化（1.2）

    /// 后台分析成片人声响度 / 峰值，给出自动电平增益建议。
    /// 建议只进会话状态；用户点「应用建议」才写入工程设置（建议而非独裁）。
    func analyzeAudioOptimization() {
        guard let project = draft, !isAnalyzingAudio else { return }
        audioAnalysisTask?.cancel()
        isAnalyzingAudio = true
        audioAnalysisTask = Task {
            defer { isAnalyzingAudio = false }
            do {
                let proposal = try await AudioOptimizationAnalyzer.analyze(
                    project: project
                )
                guard !Task.isCancelled, draft?.id == project.id else { return }
                audioOptimizationProposal = proposal
            } catch is CancellationError {
            } catch {
                guard draft?.id == project.id else { return }
                audioOptimizationProposal = nil
                errorMessage = "音频分析失败：\(error.localizedDescription)"
            }
        }
    }

    /// 应用分析建议：自动电平按建议增益开启。一次设置修改占一个撤销步骤。
    func applyAudioOptimizationProposal() {
        guard
            let proposal = audioOptimizationProposal,
            draft != nil
        else {
            return
        }
        updateProject { project in
            project.audio.processing.autoLevelEnabled = true
            project.audio.processing.autoLevelGainDB = proposal.suggestedGainDB
        }
        audioOptimizationProposal = nil
    }

    /// 修改音频优化设置（各开关 / 压低量）。触发后台处理与预览刷新。
    func updateAudioProcessing(
        _ mutate: (inout AudioEnhanceSettings) -> Void
    ) {
        updateProject { project in
            mutate(&project.audio.processing)
        }
    }

    /// A/B 试听：只旁路预览链的音频处理，工程数据不变。
    func setAudioPreviewBypassed(_ bypassed: Bool) {
        guard audioPreviewBypassed != bypassed else { return }
        audioPreviewBypassed = bypassed
        schedulePreviewRefresh(immediately: true)
    }

    /// 切换工程时清空音频优化的会话状态。
    private func resetAudioOptimizationSession() {
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        audioPreparationTask?.cancel()
        audioPreparationTask = nil
        audioOptimizationProposal = nil
        isAnalyzingAudio = false
        audioPreviewBypassed = false
        audioProcessingReady = true
    }

    /// 设置或时间线变化后，后台准备已处理音频缓存；完成后刷新预览。
    /// 处理在后台执行、可取消，不阻塞 UI（性能预算约束）。
    private func scheduleAudioProcessingPreparation() {
        audioPreparationTask?.cancel()
        guard let project = draft else { return }
        guard !project.audio.processing.isEffectivelyEmpty else {
            audioProcessingReady = true
            return
        }
        audioProcessingReady = false
        audioPreparationTask = Task {
            do {
                _ = try await AudioOptimizer.resolve(
                    project: project,
                    mode: .ensure
                )
                guard !Task.isCancelled, draft?.id == project.id else { return }
                audioProcessingReady = true
                schedulePreviewRefresh(immediately: true)
            } catch is CancellationError {
            } catch {
                guard draft?.id == project.id else { return }
                audioProcessingReady = true
                errorMessage = "音频优化处理失败：\(error.localizedDescription)"
            }
        }
    }

    private func smartCutOutcome(
        apply candidates: [SmartCutCandidate],
        to project: StudioProject
    ) -> TimelineCutTransaction.Outcome? {
        let outcome = TimelineCutTransaction.apply(
            candidates,
            to: project.timeline,
            frameDuration: project.fps > 0 ? 1.0 / Double(project.fps) : nil
        )
        return outcome.deletions.isEmpty ? nil : outcome
    }

    /// 仅供测试：直接进入「扫描完成」状态。
    func finishSmartCutScanForTesting(_ outcome: SmartCutScanOutcome) {
        finishSmartCutScan(outcome)
    }

    private func finishSmartCutScan(_ outcome: SmartCutScanOutcome) {
        smartCutAnalysis = outcome.analysis
        smartCutSelectedIndices = Set(
            outcome.analysis.candidates.indices.filter {
                outcome.analysis.candidates[$0].isDefaultSelected
            }
        )
        smartCutScanPhase = .ready
        smartCutScanProgress = 1
        var hints: [String] = []
        if let reliabilityHint = outcome.audioSource.reliabilityHint {
            hints.append(reliabilityHint)
        }
        if smartCutProtectSystemSound, !outcome.systemSoundProtected {
            hints.append(
                "系统声音轨全程静音或不可分析，“保护系统声音”本次未生效。"
            )
        }
        if outcome.analysis.candidates.isEmpty {
            hints.append("没有发现可清理的停顿 / 气口。")
        }
        smartCutMessage = hints.isEmpty ? nil : hints.joined(separator: " ")
    }

    private func resetSmartCutResults() {
        smartCutTask?.cancel()
        smartCutTask = nil
        smartCutScanPhase = .idle
        smartCutScanProgress = 0
        smartCutAnalysis = nil
        smartCutSelectedIndices = []
        smartCutMessage = nil
    }

    private func resetFillerSuggestions() {
        fillerSuggestions = []
        fillerSelectedIndices = []
        rawCaptionSegments = []
    }

    /// 时间线、屏幕操作或字幕变化后，让依赖成片时间的扫描结果失效，
    /// 避免把旧候选应用到已经移位的内容上。
    private func invalidateDerivedAnalysis(
        from previous: StudioProject,
        to project: StudioProject
    ) {
        let timelineChanged = previous.timeline != project.timeline
        if
            timelineChanged
                || previous.clicks != project.clicks
                || previous.rawCursor != project.rawCursor
                || previous.cursor != project.cursor
        {
            let hadResults = smartCutScanPhase == .ready
            resetSmartCutResults()
            // 1.2 块6：旧候选不再静默留在界面上（本就整体清除），
            // 并给出明确的「请重新扫描」提示。
            if hadResults {
                smartCutMessage = "时间线已变化，候选已失效，请重新扫描。"
            }
        }
        if
            timelineChanged
                || previous.captionCues != project.captionCues
        {
            resetFillerSuggestions()
        }
    }

    // 按字幕文本删片段——选区 → 建议查询与应用入口。
    /// 查询某条字幕内选区的删除建议（选区单位 UTF-16 offset）。
    /// 复用 `rawCaptionSegments`（本机识别当次会话）走精确模式；
    /// SRT / 保存重开工程无分段 → 近似模式（UI 侧标注）。
    func textCutSuggestion(
        for captionID: UUID,
        selection: Range<Int>
    ) -> Result<CaptionTextCutMapper.Suggestion, CaptionTextCutMapper.Rejection> {
        guard let project = draft else { return .failure(.emptySelection) }
        guard
            let cue = project.captionCues.first(where: { $0.id == captionID })
        else {
            return .failure(.emptySelection)
        }
        let segments = rawCaptionSegments.map {
            (text: $0.text, start: $0.start, duration: $0.duration)
        }
        return CaptionTextCutMapper.suggest(
            cueStart: cue.start,
            cueEnd: cue.end,
            text: cue.text,
            selection: selection,
            segments: segments
        )
    }

    /// 应用一条「删除选区对应音视频区间」建议：复用 TimelineCutTransaction
    /// 原子剪切 + ripple + 主字幕文本手术（与精剪应用同一条事务链），
    /// 一次应用只占一个撤销步。
    func applyTextCut(cutStart: Double, cutEnd: Double) {
        guard let project = draft else { return }
        guard
            let outcome = smartCutOutcome(
                apply: [
                    SmartCutCandidate(
                        start: cutStart,
                        end: cutEnd,
                        kind: .fillerWord,
                        keepEachSide: 0
                    )
                ],
                to: project
            )
        else {
            errorMessage = "这段会留下过短片段，无法删除。"
            return
        }
        var updated = project.applyingCutTransaction(outcome)
        var surgeryHint = ""
        if !rawCaptionSegments.isEmpty {
            let surgery = CaptionSegmentSurgery.rewritten(
                cues: project.captionCues,
                segments: rawCaptionSegments,
                removedSegmentRanges: [cutStart ... cutEnd],
                outcome: outcome
            )
            updated.captionCues = surgery.cues
            surgeryHint =
                "字幕文本手术：重写 \(surgery.report.rewrittenCues) 条"
                + (surgery.report.deletedCues > 0
                    ? "、删除 \(surgery.report.deletedCues) 条" : "")
                + (surgery.report.skippedUnverifiedCues > 0
                    ? "、\(surgery.report.skippedUnverifiedCues) 条无法核对原文保持原样"
                    : "")
                + "。"
        }
        guard updated != project else { return }
        commitTimelineProject(updated)
        // 成片时间已变化，基于旧时间的原始分段一并失效（与精剪同口径）。
        rawCaptionSegments = []
        errorMessage =
            "已删除选区对应的片段，节省 \(formatDuration(outcome.removedDuration))。"
            + surgeryHint
            + "按 ⌘Z 可完整还原。"
    }

    func seek(to seconds: Double) {
        guard let project = draft else { return }
        let target = min(max(0, seconds), max(0, project.trimDuration))
        currentTime = target
        guard player.currentItem != nil else { return }
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // T3：拖动播放头期间放宽容差（60Hz 零容差 seek 压解码管线，
        // 长 GOP 素材预览掉帧）；松手后的单次 seek 仍走零容差保精确。
        let tolerance: CMTime = isScrubbing
            ? CMTime(seconds: 0.08, preferredTimescale: 600)
            : .zero
        player.seek(
            to: time,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance,
            completionHandler: { _ in }
        )
    }

    func togglePlayback() {
        guard player.currentItem != nil, let project = draft else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
            if auditionPreviewEndTime != nil {
                auditionPreviewEndTime = nil
                schedulePreviewRefresh(immediately: true)
            }
            return
        }
        if currentTime < 0 || currentTime >= project.trimDuration - 0.05 {
            let start = CMTime(
                seconds: 0,
                preferredTimescale: 600
            )
            currentTime = 0
            player.seek(
                to: start,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] finished in
                guard finished else { return }
                Task { @MainActor in
                    self?.player.play()
                    self?.isPlaying = true
                }
            }
            return
        }
        player.play()
        isPlaying = true
    }

    // MARK: 人脸居中（1.2 块5）

    /// 后台分析摄像头轨的人脸位置并生成 cropFocus 建议。
    /// 建议不自动应用；用户点「应用」才生成布局段（一个撤销步骤）。
    func analyzeFaceFocus() {
        guard let project = draft, !isAnalyzingFaces else { return }
        guard project.cameraURL != nil else {
            smartCutMessage = "当前工程没有摄像头文件，无法做人脸居中。"
            return
        }
        faceAnalysisTask?.cancel()
        isAnalyzingFaces = true
        let cameraURL = project.cameraURL!
        let cameraOffset = project.cameraOffset
        faceAnalysisTask = Task {
            defer { isAnalyzingFaces = false }
            do {
                let segments = try await FaceFocusAnalyzer.analyze(
                    cameraURL: cameraURL,
                    cameraOffset: cameraOffset,
                    project: project
                )
                guard !Task.isCancelled, draft?.id == project.id else {
                    return
                }
                faceFocusSegments = segments
                smartCutMessage = segments.isEmpty
                    ? "没有在摄像头画面里稳定检出人脸，未生成建议。"
                    : "检测到 \(segments.count) 个人脸居中位置建议，请审阅后应用。"
            } catch is CancellationError {
            } catch {
                guard draft?.id == project.id else { return }
                smartCutMessage = "人脸分析失败：\(error.localizedDescription)"
            }
        }
    }

    /// 应用人脸居中建议：替换自动布局段（一次撤销步骤）；手动布局段
    /// 存在时拒绝，绝不静默覆盖。
    func applyFaceFocusSegments() {
        guard
            let project = draft,
            let segments = faceFocusSegments,
            !segments.isEmpty
        else {
            return
        }
        guard let updated = project.applyingFaceFocusPlan(segments) else {
            smartCutMessage =
                "已有手动摄像头布局段，未应用人脸居中；如需使用请先删除手动布局段。"
            return
        }
        commitTimelineProject(updated)
        smartCutMessage =
            "已生成 \(updated.smartCutAutoCameraSegmentIDs.count) 个人脸居中段；"
            + "重复分析会替换而不是叠加，一次 ⌘Z 可全部恢复。"
    }

    // MARK: 竖屏跟随

    /// 竖屏跟随分析：复用人脸居中的采样与检测（Vision，全离线），
    /// 产出仅水平偏移的取景建议。建议不自动应用；用户点「应用」才生成
    /// 自动布局段（一个撤销步骤）。只在竖屏画布入口可见。
    func analyzePortraitFollow() {
        guard let project = draft, !isAnalyzingFollow else { return }
        guard project.cameraURL != nil else {
            smartCutMessage = "当前工程没有摄像头文件，无法做竖屏跟随。"
            return
        }
        followAnalysisTask?.cancel()
        isAnalyzingFollow = true
        let cameraURL = project.cameraURL!
        let cameraOffset = project.cameraOffset
        followAnalysisTask = Task {
            defer { isAnalyzingFollow = false }
            do {
                let segments = try await FaceFocusAnalyzer.analyzePortraitFollow(
                    cameraURL: cameraURL,
                    cameraOffset: cameraOffset,
                    project: project,
                    sensitivity: portraitFollowSensitivity
                )
                guard !Task.isCancelled, draft?.id == project.id else {
                    return
                }
                portraitFollowSegments = segments
                smartCutMessage = segments.isEmpty
                    ? "没有在摄像头画面里稳定检出人脸，未生成竖屏跟随建议。"
                    : "检测到 \(segments.count) 个竖屏跟随取景建议，请审阅后应用。"
            } catch is CancellationError {
            } catch {
                guard draft?.id == project.id else { return }
                smartCutMessage =
                    "竖屏跟随分析失败：\(error.localizedDescription)"
            }
        }
    }

    /// 应用竖屏跟随建议：与语音显隐 / 人脸居中共用自动段池（一次撤销
    /// 步骤）；竖屏画布下冲突以跟随为准（整体替换自动段）；手动布局段
    /// 存在时拒绝，绝不静默覆盖。
    func applyPortraitFollowSegments() {
        guard
            let project = draft,
            let segments = portraitFollowSegments,
            !segments.isEmpty
        else {
            return
        }
        guard let updated = project.applyingPortraitFollowPlan(segments) else {
            smartCutMessage =
                "已有手动摄像头布局段，未应用竖屏跟随；如需使用请先删除手动布局段。"
            return
        }
        commitTimelineProject(updated)
        smartCutMessage =
            "已生成 \(updated.smartCutAutoCameraSegmentIDs.count) 个竖屏跟随段；"
            + "重复分析会替换而不是叠加，一次 ⌘Z 可全部恢复。"
    }

    /// 1.2 导出区间：入点 / 出点 = 播放头（成片时间）；出点必须晚于入点。
    func setExportInPointToPlayhead() {        exportInPoint = currentTime
        if let out = exportOutPoint, let inValue = exportInPoint,
           out <= inValue
        {
            exportOutPoint = nil
        }
    }

    func setExportOutPointToPlayhead() {
        exportOutPoint = currentTime
        if let inValue = exportInPoint, let out = exportOutPoint,
           out <= inValue
        {
            exportInPoint = nil
        }
    }

    func clearExportRange() {
        exportInPoint = nil
        exportOutPoint = nil
    }

    /// GIF 导出：走与 MP4 相同的合成链（RenderPlan 统一渲染），
    /// ImageIO 编码 GIF（15fps，最长边按尺寸档位，默认 720）。
    func exportGif() {
        guard
            let project = draft,
            exportTask == nil,
            exportProgress == nil,
            !isExportingGif
        else {
            return
        }
        let rangeProject = exportRangeEnabled
            ? project.clippedToOutputRange(
                inPoint: exportInPoint,
                outPoint: exportOutPoint
            )
            : nil
        let target = rangeProject ?? project
        let panel = NSSavePanel()
        panel.title = "导出 GIF"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "\(safeFilename(target.name)).gif"
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.directoryURL = exportPanelDirectory(
            fallback: target.folderURL
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingGif = true
        exportProgress = 0
        exportMessage = "正在准备 GIF…"
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.exportTask = nil
                self.isExportingGif = false
            }
            do {
                try await GifExporter.makeGif(
                    for: target,
                    outputURL: url,
                    maximumWidth: gifSizePreset.maximumWidth
                ) { [weak self] progress in
                    guard let self else { return }
                    self.exportProgress = min(0.98, max(0, progress))
                    self.exportMessage =
                        "正在渲染 GIF \(Int(progress * 100))%"
                }
                exportProgress = 1
                exportMessage = "GIF 导出完成"
                rememberExportDirectory(url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                try? await Task.sleep(for: .seconds(1.2))
                exportProgress = nil
                exportMessage = nil
            } catch {
                exportProgress = nil
                exportMessage = nil
                errorMessage = "导出 GIF 失败：\(error.localizedDescription)"
            }
        }
    }

    func exportProject() {
        // 导出方式 = 按标记分段时走逐段导出链（页头与卡内主
        // 按钮共用本入口，行为一致）。
        if exportMode == .markerSegments {
            exportMarkerSegments()
            return
        }
        guard
            let project = draft,
            exportTask == nil,
            exportProgress == nil
        else {
            return
        }
        // 1.2 导出区间：开启时用「只保留入出点区间」的工程副本导出
        // （复用剪切事务，工程数据本身不变）。
        let rangeProject = exportRangeEnabled
            ? project.clippedToOutputRange(
                inPoint: exportInPoint,
                outPoint: exportOutPoint
            )
            : nil
        if exportRangeEnabled, rangeProject == nil {
            errorMessage = "请先在导出面板设置有效的入点和出点。"
            return
        }
        let target = rangeProject ?? project
        let panel = NSSavePanel()
        panel.title = "导出录屏"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "\(safeFilename(target.name)).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = exportPanelDirectory(
            fallback: target.folderURL
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let configuration = ExportConfiguration(
            outputSize: exportResolution.outputSize(for: target),
            frameRate: exportFrameRate,
            codec: exportCodec
        )
        exportProgress = 0
        exportMessage = "正在准备导出…"
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.exportTask = nil }
            do {
                try await CompositionBuilder.makeExport(
                    for: target,
                    outputURL: url,
                    configuration: configuration
                ) { [weak self] progress in
                    guard let self else { return }
                    self.exportProgress = min(0.98, max(0, progress))
                    self.exportMessage = progress < 0.98
                        ? "正在渲染 \(Int(progress * 100))%"
                        : "正在写入文件…"
                }
                let sidecarIssue = writeCaptionSidecar(
                    for: target,
                    nextTo: url
                )
                exportProgress = 1
                exportMessage = "导出完成"
                rememberExportDirectory(url)
                if let sidecarIssue {
                    errorMessage = sidecarIssue
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                try? await Task.sleep(for: .seconds(1.2))
                exportProgress = nil
                exportMessage = nil
            } catch {
                let wasCancelled = error is CancellationError
                    || (error as? ExportError) == .cancelled
                exportProgress = nil
                exportMessage = nil
                errorMessage = wasCancelled
                    ? ExportError.cancelled.localizedDescription
                    : error.localizedDescription
            }
        }
    }

    func cancelExport() {
        guard exportTask != nil else { return }
        exportMessage = "正在取消…"
        exportTask?.cancel()
    }

    // MARK: 按标记分段导出（按标记分段）

    /// 分段导出的执行现场：确认时的段清单、目标文件夹、覆盖策略与
    /// 工程快照。重试复用快照，不受确认后的工程编辑影响。
    struct MarkerSegmentResume {
        let segments: [MarkerSegmentPlan.Segment]
        let directory: URL
        let overwrite: Bool
        let project: StudioProject
    }

    /// 分段确认区的当前规划（导出卡与执行入口共用同一纯函数结果）。
    func markerSegmentPlan(
        for project: StudioProject
    ) -> MarkerSegmentPlan {
        MarkerSegmentPlanner.plan(
            markers: project.markers,
            excludedIDs: markerSegmentExcludedIDs,
            baseName: markerSegmentBaseName.isEmpty
                ? project.name
                : markerSegmentBaseName,
            trimDuration: project.trimDuration,
            outputTime: { project.outputTime(forSourceTime: $0) }
        )
    }

    /// 分段目标文件夹选择（目录面板，默认上次导出目录 / 工程目录）。
    func chooseMarkerSegmentFolder() {
        guard let project = draft else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择分段导出的保存文件夹"
        panel.prompt = "选择"
        panel.directoryURL = markerSegmentFolder
            ?? exportPanelDirectory(fallback: project.folderURL)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        markerSegmentFolder = url
    }

    /// 按标记分段逐段导出。确认区列出段数 / 跳过 / 文件名；
    /// 目标文件夹已有同名文件时询问覆盖或新建子文件夹；逐段复用
    /// 区间导出链（clippedToOutputRange + CompositionBuilder），任一段
    /// 失败保留已完成段并可从失败段重试。
    private func exportMarkerSegments() {
        guard
            let project = draft,
            exportTask == nil,
            exportProgress == nil
        else {
            return
        }
        let plan = markerSegmentPlan(for: project)
        guard !plan.segments.isEmpty else {
            errorMessage =
                "没有可导出的分段：请添加标记，或勾选至少一个不在已剪除区间内的标记。"
            return
        }
        let folder = markerSegmentFolder
            ?? exportPanelDirectory(fallback: project.folderURL)
        let existing = plan.segments.filter {
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent($0.fileName).path
            )
        }
        var directory = folder
        var overwrite = false
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "目标文件夹已有同名文件"
            alert.informativeText =
                "以下文件将被影响：\n"
                + existing.map(\.fileName).joined(separator: "\n")
            alert.addButton(withTitle: "新建子文件夹")
            alert.addButton(withTitle: "覆盖已有文件")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let base = MarkerSegmentPlanner.sanitizeFilenameComponent(
                    markerSegmentBaseName.isEmpty
                        ? project.name
                        : markerSegmentBaseName,
                    fallback: "分段导出"
                )
                directory = uniqueMarkerSegmentDirectory(
                    named: "\(base)-分段",
                    in: folder
                )
            } else if response == .alertSecondButtonReturn {
                overwrite = true
            } else {
                return
            }
        }
        startMarkerSegmentExport(
            resume: MarkerSegmentResume(
                segments: plan.segments,
                directory: directory,
                overwrite: overwrite,
                project: project
            ),
            fromIndex: 0
        )
    }

    /// 目标子文件夹名已存在时追加序号（-分段、-分段 2、-分段 3…）。
    private func uniqueMarkerSegmentDirectory(
        named name: String,
        in parent: URL
    ) -> URL {
        var candidate = parent.appendingPathComponent(name)
        var sequence = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(sequence)")
            sequence += 1
        }
        return candidate
    }

    /// 失败 / 取消后从失败段继续（使用确认时的现场）。
    func retryMarkerSegmentExport() {
        guard
            let resume = markerSegmentResume,
            let index = markerSegmentFailedIndex,
            exportTask == nil,
            exportProgress == nil,
            !isExportingGif
        else {
            return
        }
        startMarkerSegmentExport(resume: resume, fromIndex: index)
    }

    private func startMarkerSegmentExport(
        resume: MarkerSegmentResume,
        fromIndex index: Int
    ) {
        let segments = resume.segments
        let total = segments.count
        let project = resume.project
        exportProgress = Double(index) / Double(total)
        exportMessage = "准备分段导出（第 \(index + 1)/\(total) 段）…"
        markerSegmentFailedIndex = nil
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.exportTask = nil }
            var currentIndex = index
            do {
                try FileManager.default.createDirectory(
                    at: resume.directory,
                    withIntermediateDirectories: true
                )
                for (offset, segment) in segments[index...].enumerated() {
                    let position = index + offset
                    currentIndex = position
                    try Task.checkCancellation()
                    // 复用区间导出链：每段 = 只保留 [start, end] 的工程
                    // 副本（字幕 / 缩放 / 布局 / 打码按成片时间裁剪平移）。
                    let segmentProject = project.clippedToOutputRange(
                        inPoint: segment.start,
                        outPoint: segment.end
                    ) ?? project
                    let url = resume.directory
                        .appendingPathComponent(segment.fileName)
                    let configuration = ExportConfiguration(
                        outputSize: self.exportResolution
                            .outputSize(for: segmentProject),
                        frameRate: self.exportFrameRate,
                        codec: self.exportCodec
                    )
                    try await CompositionBuilder.makeExport(
                        for: segmentProject,
                        outputURL: url,
                        configuration: configuration
                    ) { [weak self] progress in
                        guard let self else { return }
                        let overall = (Double(position)
                            + min(0.98, max(0, progress))) / Double(total)
                        self.exportProgress = min(0.98, overall)
                        self.exportMessage =
                            "第 \(position + 1)/\(total) 段 · \(segment.markerName) · "
                            + (progress < 0.98
                                ? "正在渲染 \(Int(progress * 100))%"
                                : "正在写入文件…")
                    }
                    if let sidecarIssue = self.writeCaptionSidecar(
                        for: segmentProject,
                        nextTo: url
                    ) {
                        self.errorMessage = sidecarIssue
                    }
                    self.rememberExportDirectory(url)
                }
                self.exportProgress = 1
                self.exportMessage = "分段导出完成（共 \(total) 段）"
                self.markerSegmentResume = nil
                self.markerSegmentFailedIndex = nil
                NSWorkspace.shared.activateFileViewerSelecting(
                    [resume.directory]
                )
                try? await Task.sleep(for: .seconds(1.2))
                self.exportProgress = nil
                self.exportMessage = nil
            } catch {
                self.exportProgress = nil
                self.exportMessage = nil
                let wasCancelled = error is CancellationError
                    || (error as? ExportError) == .cancelled
                self.markerSegmentResume = resume
                self.markerSegmentFailedIndex = currentIndex
                let name = segments[currentIndex].markerName
                self.errorMessage = wasCancelled
                    ? "已取消：已完成 \(currentIndex)/\(total) 段并保留，可从第 \(currentIndex + 1) 段继续。"
                    : "第 \(currentIndex + 1)/\(total) 段（\(name)）导出失败：\(error.localizedDescription)。已完成段已保留，可在导出卡重试剩余段。"
            }
        }
    }


    func revealProjectFolder() {
        guard let project = draft else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
    }

    func clearError() {
        errorMessage = nil
    }

    private func replaceCaptions(
        _ cues: [CaptionCue],
        language: String?
    ) {
        guard var project = draft else { return }
        let previous = project
        let glossary = glossaryAutoApply ? glossaryEntries : []
        project.captionCues = cues
            .filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            .map { cue in
                var cue = cue
                cue.start = min(
                    max(0, cue.start),
                    max(0, project.trimDuration - 0.05)
                )
                cue.end = min(
                    project.trimDuration,
                    max(cue.start + 0.05, cue.end)
                )
                if cue.language == nil {
                    cue.language = language
                }
                // 1.2 术语表：新生成的字幕初稿和导入 SRT 在入工程时自动
                // 套用；套用结果就是 cue 文本，在字幕列表可见可改。
                cue.text = CaptionGlossary.apply(glossary, to: cue.text)
                return cue
            }
            .sorted { $0.start < $1.start }
        project.captions.enabled = true
        guard project != previous else { return }
        recordUndo(for: previous)
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    // MARK: 字幕增强（1.2 块3）

    // 术语表：存应用偏好，不进单个工程。

    func addGlossaryEntry(wrong: String, right: String) {
        let trimmedWrong = wrong.trimmingCharacters(in: .whitespaces)
        guard !trimmedWrong.isEmpty else { return }
        var entries = glossaryEntries
        if let index = entries.firstIndex(where: { $0.wrong == trimmedWrong }) {
            entries[index].right = right
        } else {
            entries.append(
                GlossaryEntry(wrong: trimmedWrong, right: right)
            )
        }
        glossaryEntries = entries
        GlossaryPreferences.saveEntries(entries)
    }

    func removeGlossaryEntry(_ entry: GlossaryEntry) {
        var entries = glossaryEntries
        entries.removeAll { $0 == entry }
        glossaryEntries = entries
        GlossaryPreferences.saveEntries(entries)
    }

    func setGlossaryAutoApply(_ enabled: Bool) {
        glossaryAutoApply = enabled
        GlossaryPreferences.saveAutoApply(enabled)
    }

    /// 对当前字幕手动重新套用术语表（自动套用关闭时的补偿入口）。
    func applyGlossaryToCaptions() {
        guard !glossaryEntries.isEmpty, draft != nil else { return }
        updateProject { project in
            for index in project.captionCues.indices {
                project.captionCues[index].text = CaptionGlossary.apply(
                    glossaryEntries,
                    to: project.captionCues[index].text
                )
            }
        }
        captionStatus = "已按术语表重新套用（可撤销）"
    }

    // 双语字幕：副字幕轨（第二份 SRT）。

    /// 导入第二语言 SRT 作为副字幕轨。不做机器翻译、不联网；
    /// 术语表不套用到副轨（副轨多为译文，替换规则会误改）。
    func importSecondaryCaptionsSRT() {
        guard let project = draft else { return }
        let panel = NSOpenPanel()
        panel.title = "导入第二语言字幕（SRT）"
        panel.prompt = "导入"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .plainText,
            .plainText
        ]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // T3：SRT 上限 8MB（正常字幕几 KB）——病态大文件不再在主线程
            // 整读整解析。
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let size = (attributes[.size] as? Int) ?? 0
            guard size <= 8 * 1024 * 1024 else {
                errorMessage =
                    "这个 SRT 文件超过 8MB，不像是正常字幕文件。请检查是否选错文件。"
                return
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let cues = SubtitleFile.parse(
                source,
                duration: project.trimDuration
            )
            guard !cues.isEmpty else {
                errorMessage = "没有在这个 SRT 文件里找到有效字幕。"
                return
            }
            updateProject { target in
                target.secondaryCaptionCues = cues
                target.captions.secondaryEnabled = true
            }
            captionStatus =
                "已导入 \(cues.count) 条副字幕（按时间对齐同屏显示）"
        } catch {
            errorMessage = "无法读取 SRT 字幕：\(error.localizedDescription)"
        }
    }

    func removeSecondaryCaptions() {
        guard draft?.secondaryCaptionCues.isEmpty == false else { return }
        updateProject { project in
            project.secondaryCaptionCues = []
            project.captions.secondaryEnabled = false
        }
        captionStatus = "已移除副字幕轨"
    }

    func setSecondaryCaptionsEnabled(_ enabled: Bool) {
        guard draft?.secondaryCaptionCues.isEmpty == false else { return }
        updateProject { $0.captions.secondaryEnabled = enabled }
    }

    func setCaptionSecondaryPosition(_ position: CaptionSecondaryPosition) {
        updateProject { $0.captions.secondaryPosition = position }
    }

    /// 导出烧录模式：主 / 副 / 双 / 不烧录。同步维护旧字段 `burnIn`，
    /// 让旧版本应用读工程时行为一致。
    func setCaptionBurnMode(_ mode: CaptionBurnMode) {
        updateProject { project in
            project.captions.burnMode = mode
            project.captions.burnIn = mode != .off
        }
    }

    // 字幕样式预设：只是现有参数的成套组合。

    func applyCaptionStylePreset(_ preset: CaptionStylePreset) {
        updateProject { project in
            preset.apply(to: &project.captions)
        }
    }

    /// 章节标题卡开关（预览与导出都渲染，进统一渲染链）。
    func setChapterCardsEnabled(_ enabled: Bool) {
        updateProject { $0.captions.chapterCardsEnabled = enabled }
    }

    private func writeCaptionSidecar(
        for project: StudioProject,
        nextTo outputURL: URL
    ) -> String? {
        guard
            project.captionCues.contains(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            })
        else {
            return nil
        }
        let subtitleURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("srt")
        do {
            try SubtitleFile.write(project.captionCues, to: subtitleURL)
            return nil
        } catch {
            return "MP4 已导出，但随视频一起导出的 .srt 字幕文件写入失败：\(error.localizedDescription)"
        }
    }

    private func validateSource() -> Bool {
        switch setup.sourceKind {
        case .display:
            return true
        case .window:
            if setup.window == nil {
                errorMessage = RecorderError.windowUnavailable.localizedDescription
                return false
            }
            return true
        case .region:
            guard let region = setup.region, region.isValid else {
                errorMessage = RecorderError.regionInvalid.localizedDescription
                return false
            }
            return true
        }
    }

    private func screenForCurrentSource() -> NSScreen? {
        let displayID = setup.sourceKind == .window
            ? (setup.window?.displayID ?? setup.displayID)
            : setup.displayID
        return screen(for: displayID) ?? NSScreen.main
    }

    private func updateProject(
        groupingKey: String? = nil,
        _ mutate: (inout StudioProject) -> Void
    ) {
        guard var project = draft else { return }
        let previous = project
        mutate(&project)
        guard project != previous else { return }
        recordUndo(for: previous, groupingKey: groupingKey)
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        if previous.audio.processing != project.audio.processing {
            scheduleAudioProcessingPreparation()
        }
        scheduleSave()
        schedulePreviewRefresh()
    }

    private func recordUndo(
        for project: StudioProject,
        groupingKey: String? = nil
    ) {
        guard interactiveUndoSnapshot == nil else { return }
        undoHistory.record(project, groupingKey: groupingKey)
        publishUndoState()
    }

    private func publishUndoState() {
        canUndo = undoHistory.canUndo
        canRedo = undoHistory.canRedo
    }

    private func commitTimelineProject(_ project: StudioProject) {
        guard let previous = draft, previous != project else { return }
        recordUndo(for: previous)
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        if previous.audio.processing != project.audio.processing
            || previous.timeline != project.timeline
        {
            // 时间线变化改变缓存签名；设置变化改变处理参数。
            scheduleAudioProcessingPreparation()
        }
        currentTime = min(
            max(0, currentTime),
            max(0, project.trimDuration)
        )
        scheduleSave()
        schedulePreviewRefresh(immediately: true)
    }

    private func updateTimelineClipRange(
        clipID: UUID,
        sourceStart: Double? = nil,
        sourceEnd: Double? = nil,
        groupingKey: String
    ) {
        guard
            var project = draft,
            let clip = project.timeline.clips.first(where: {
                $0.id == clipID
            })
        else {
            return
        }
        let previous = project
        let start = sourceStart.map {
            min(
                max(0, $0),
                clip.sourceEnd - TimelineClip.minimumSourceDuration
            )
        } ?? clip.sourceStart
        let end = sourceEnd.map {
            max(
                min(project.duration, $0),
                clip.sourceStart + TimelineClip.minimumSourceDuration
            )
        } ?? clip.sourceEnd
        guard
            project.timeline.trimClip(
                id: clipID,
                sourceStart: start,
                sourceEnd: end
            ),
            project != previous
        else {
            return
        }
        recordUndo(for: previous, groupingKey: groupingKey)
        draft = project
        invalidateDerivedAnalysis(from: previous, to: project)
        currentTime = min(currentTime, project.trimDuration)
        scheduleSave()
        schedulePreviewRefresh()
    }

    private func applyHistoryProject(_ project: StudioProject) {
        let previous = draft
        draft = project
        if let previous {
            invalidateDerivedAnalysis(from: previous, to: project)
            if previous.audio.processing != project.audio.processing {
                scheduleAudioProcessingPreparation()
            }
        }
        currentTime = min(
            max(0, currentTime),
            max(0, project.trimDuration)
        )
        publishUndoState()
        scheduleSave()
        schedulePreviewRefresh()
    }

    private func preparePreview(
        for project: StudioProject,
        preserveTime: Double
    ) async {
        previewLoading = true
        defer { previewLoading = false }
        do {
            let item = try await CompositionBuilder.makePlayerItem(
                for: project,
                bypassAudioProcessing: audioPreviewBypassed
            )
            guard draft?.id == project.id else { return }
            let wasPlaying = player.rate > 0
            player.replaceCurrentItem(with: item)
            player.seek(
                to: CMTime(seconds: preserveTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: { _ in }
            )
            currentTime = preserveTime
            if wasPlaying {
                player.play()
            }
        } catch {
            errorMessage = "更新章节设置失败：\(error.localizedDescription)"
        }
    }

    private func schedulePreviewRefresh(
        immediately: Bool = false,
        at previewTime: Double? = nil
    ) {
        guard let project = draft else { return }
        auditionTask?.cancel()
        auditionTask = nil
        auditionPreviewEndTime = nil
        previewTask?.cancel()
        previewTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(260))
            }
            guard !Task.isCancelled else { return }
            let playerTime = player.currentTime().seconds
            let time = previewTime
                ?? (playerTime.isFinite ? max(0, playerTime) : 0)
            let startedAt = CFAbsoluteTimeGetCurrent()
            await preparePreview(
                for: project,
                preserveTime: time
            )
            guard !Task.isCancelled else { return }
            let elapsedMilliseconds = (
                CFAbsoluteTimeGetCurrent() - startedAt
            ) * 1000
            previewLog.debug(
                "preview_refresh_ms=\(elapsedMilliseconds, privacy: .public)"
            )
        }
    }

    private func cancelChromaKeySampling() {
        chromaKeySampleID = nil
        chromaKeySampleTask?.cancel()
        chromaKeySampleTask = nil
        isSamplingChromaKey = false
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if !self.isScrubbing {
                    let observedTime = max(0, time.seconds)
                    self.currentTime = self.pausedCameraSegmentStart(
                        near: observedTime
                    )
                        ?? observedTime
                }
                if
                    self.isPlaying,
                    let project = self.draft,
                    time.seconds >= project.trimDuration
                {
                    self.player.pause()
                    self.isPlaying = false
                    self.seek(to: project.trimDuration)
                }
                if
                    let auditionEnd = self.auditionPreviewEndTime,
                    self.player.rate == 0,
                    time.seconds >= auditionEnd - 0.05
                {
                    self.auditionPreviewEndTime = nil
                    self.schedulePreviewRefresh(immediately: true)
                }
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    private func pausedCameraSegmentStart(near time: Double) -> Double? {
        guard player.rate == 0, let segments = draft?.cameraSegments else {
            return nil
        }
        var nearest: Double?
        for segment in segments {
            let distance: Double = abs(segment.start - time)
            guard distance <= 1.0 / 60.0 else { continue }
            if let current = nearest {
                let currentDistance: Double = abs(current - time)
                if distance < currentDistance {
                    nearest = segment.start
                }
            } else {
                nearest = segment.start
            }
        }
        return nearest
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            self.saveDraftNow()
        }
    }

    private func saveDraftNow() {
        guard let project = draft else { return }
        // P4 防卡死：编码+读校验+双写盘随工程体积（rawCursor 采样等）
        // 线性增长，且 selectProject 会在主线程同步调到这里——下沉后台
        // 串行链，主线程只更新列表缓存。链式排队保证旧快照不会晚于
        // 新快照落盘。
        let previous = saveChain
        saveChain = Task.detached { [weak self] in
            await previous?.value
            do {
                try ProjectStore.save(project)
                await MainActor.run {
                    if
                        let index = self?.projects.firstIndex(
                            where: { $0.id == project.id }
                        )
                    {
                        self?.projects[index] = project
                    }
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage =
                        "保存工程失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func generateThumbnailIfNeeded(for project: StudioProject) async {
        guard project.thumbnailURL == nil else { return }
        guard let thumbnail = try? await Thumbnailer.generate(for: project) else {
            return
        }
        var updated = project
        updated.thumbnailFile = thumbnail
        try? ProjectStore.save(updated)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = updated
        }
        if draft?.id == project.id {
            draft?.thumbnailFile = thumbnail
        }
    }

    private func stopCameraPreview() async {
        cameraOverlay.hide()
        CameraPreviewRegistry.detachAll()
        await cameraRecorder.stopPreview()
        cameraPreviewActive = false
    }

    /// 电平上抛消费（主线程）——归一化 + 静音告警状态机。
    /// 只告警不干预录制；告警过一次后不再重复。
    private func ingestMicrophoneLevel(_ rms: Double) {
        let level = InputLevelMeter.displayValue(rms: rms)
        microphoneLevel = level
        hud.setMicrophoneLevel(level)
        guard isRecording, let startedAt = recordingStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if silentAlarm.sample(
            isSilent: InputLevelMeter.isSilent(rms: rms),
            elapsed: elapsed
        ) {
            silentAlarmVisible = true
            hud.setSilentAlarmVisible(true)
        }
    }

    private func handleUnexpectedStop(_ error: Error) async {
        guard isRecording || isPreparing, !isStopping else { return }
        isStopping = true
        isRecording = false
        isRecordingPaused = false
        isRecordingTransitioning = false
        hud.hide()
        statusItem.hide()
        cameraOverlay.hide()
        isPreparing = true
        do {
            let result = try await recorder.stop()
            let cameraStop = await cameraRecorder.stopRecording()
            if let cameraResult = cameraStop.result {
                cameraSessions.append(cameraResult)
            } else if let failure = cameraStop.failure {
                errorMessage = "摄像头录制未完成：\(failure.localizedDescription)"
            }
            await adoptRecording(
                result: result,
                cameraSessions: cameraSessions
            )
            showMainWindows()
            errorMessage = "录制意外停止，已保存现有素材：\(error.localizedDescription)"
        } catch {
            cameraRecorder.cancelRecording()
            showMainWindows()
            errorMessage = "录制意外停止：\(error.localizedDescription)"
        }
        await stopCameraPreview()
        screenRecordingStart = nil
        cameraSessions.removeAll()
        cameraEnabledForRecording = false
        isStopping = false
        isPreparing = false
    }

    private func adoptRecording(
        result: RecordingResult,
        cameraSessions: [CameraRecordingResult]
    ) async {
        var project = result.project
        do {
            if let cameraOutput = try await CameraTrackBuilder.build(
                sessions: cameraSessions,
                clock: result.clock,
                folder: project.folderURL
            ) {
                project.cameraFile = cameraOutput.url.lastPathComponent
                project.cameraOffset = cameraOutput.offset
                var composition = recordingCameraComposition
                composition.enabled = true
                composition.layout = .pictureInPicture
                project.camera = composition
            } else {
                project.camera.enabled = false
            }
        } catch {
            project.camera.enabled = false
            if !cameraSessions.isEmpty {
                errorMessage = "摄像头素材整理失败，本次工程保留屏幕和声音：\(error.localizedDescription)"
            }
        }
        project.markers = rawRecordingMarkers.compactMap { raw in
            guard let time = result.clock.outputTime(
                forHostTime: raw.hostTime
            ) else {
                return nil
            }
            guard time <= project.duration else { return nil }
            return RecordingMarker(
                sourceTime: (time * 1_000).rounded() / 1_000,
                name: raw.name
            )
        }
        rawRecordingMarkers.removeAll()
        try? ProjectStore.save(project)
        if let thumbnail = try? await Thumbnailer.generate(for: project) {
            project.thumbnailFile = thumbnail
            try? ProjectStore.save(project)
        }
        projects.insert(project, at: 0)
        selectedProjectID = project.id
        interactiveUndoSnapshot = nil
        undoHistory.removeAll()
        publishUndoState()
        draft = project
        auditionPreviewEndTime = nil
        resetSmartCutResults()
        resetFillerSuggestions()
        updateExportDefaults(for: project)
        await preparePreview(for: project, preserveTime: 0)
        scheduleSave()
    }

    private func updateExportDefaults(for project: StudioProject) {
        exportFrameRate = project.fps >= 50 ? 60 : 30
        let size = project.canvasOutputSize
        exportResolution = min(size.width, size.height) >= 1440
            ? .ultraHD
            : .fullHD
    }

    /// 导出平台预设：一键填充（不自动触发导出），填充后各项仍可手调。
    /// 画布比例联动走 setCanvasAspect（与手动改比例同路径，走撤销栈）。
    /// 只记录上次选中项到应用偏好，不写工程数据。
    func applyExportPreset(_ id: String) {
        guard let preset = ExportPreset.preset(id: id) else { return }
        selectedExportPresetID = preset.id
        ExportPresetPreferences.saveSelectionID(preset.id)
        let applied = ExportPreset.applying(
            preset,
            resolution: exportResolution,
            frameRate: exportFrameRate,
            codec: exportCodec
        )
        exportResolution = applied.resolution
        exportFrameRate = applied.frameRate
        exportCodec = applied.codec
        if let aspect = preset.canvasAspect {
            setCanvasAspect(aspect)
        }
    }

    private func hideMainWindows() {
        NSApp.windows
            .filter { !($0 is NSPanel) && $0.canBecomeMain }
            .forEach { $0.orderOut(nil) }
    }

    private func showMainWindows() {
        // 停止录制只恢复主窗口——设置 / 快捷键帮助等辅助窗口
        // 保持隐藏，别一起弹回前台盖住刚生成的工程画面。
        let mainWindows = NSApp.windows
            .filter { !($0 is NSPanel) && $0.canBecomeMain }
            .filter { $0.title == "八角录屏" }
        let windows = mainWindows.isEmpty
            // 兜底：SwiftUI 窗口 title 不受我们控制，匹配不到时回退原行为
            ? NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }
            : mainWindows
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            return number?.uint32Value == displayID
        }
    }

    private func safeFilename(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(
            of: #"[/\\:*?"<>|]+"#,
            with: "-",
            options: .regularExpression
        )
        return cleaned.isEmpty ? "八角录屏" : cleaned
    }

    private func persistSetup() {
        guard let data = try? JSONEncoder().encode(setup) else { return }
        UserDefaults.standard.set(data, forKey: setupKey)
    }
}
