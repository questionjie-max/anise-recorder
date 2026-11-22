import AppKit
import AVFoundation
import CoreMedia
import Foundation
import AniseRecorderCore
import QuartzCore
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case alreadyRecording
    case screenPermission
    case microphonePermission
    case displayUnavailable
    case windowUnavailable
    case regionInvalid
    case noVideo
    case writer(String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "已经在录制中。"
        case .screenPermission:
            // 与工作台告示卡（RecorderSetupView）同一修复路径：先重新检查，
            // 再重启；两处不许各指一条路。
            return "没有屏幕录制权限。请在“\(PrivacySettingsPane.screenRecording.pathDescription)”里允许“八角录屏”，回来后点“重新检查”；若仍没有画面，请重新打开本应用。"
        case .microphonePermission:
            return "没有麦克风权限。请在“\(PrivacySettingsPane.microphone.pathDescription)”里允许“八角录屏”。"
        case .displayUnavailable:
            return "找不到所选显示器，请重新选择。"
        case .windowUnavailable:
            return "找不到所选窗口，它可能已经关闭。请重新选择。"
        case .regionInvalid:
            return "录制区域太小，请至少选择一个 64 × 64 点的区域。"
        case .noVideo:
            return "没有收到屏幕画面，请检查屏幕录制权限后重试。"
        case let .writer(message):
            return "写入录制文件失败：\(message)"
        case let .stream(message):
            return "录屏启动失败：\(message)"
        }
    }
}

struct RecordingStartInfo {
    let folderURL: URL
    let videoURL: URL
    let microphoneURL: URL?
    let systemAudioURL: URL?
    let width: Int
    let height: Int
    let fps: Int
    let startedAt: Date
    let screenStartHostTime: Double
    let sourceFrame: CGRect
}

struct MicrophoneDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String

    static func available() -> [MicrophoneDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map {
            MicrophoneDeviceOption(id: $0.uniqueID, name: $0.localizedName)
        }
    }
}

private struct CapturePlan {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let source: CaptureSource
    let width: Int
    let height: Int
    let clickFrame: CGRect
    let clickFrameSource: ClickFrameSource
}

final class ScreenRecorder: NSObject {
    var onUnexpectedStop: ((Error) -> Void)?
    /// 麦克风输入电平回调（单一上抛口，主线程）。
    /// 参数为 RMS 原始值（未归一化）；UI 侧用 InputLevelMeter 换算。
    var onMicrophoneLevel: ((Double) -> Void)?

    private let captureQueue = DispatchQueue(
        label: "com.localstudio.capture",
        qos: .userInitiated
    )
    private var stream: SCStream?
    private var clickTracker: ClickTracker?
    private var cursorTracker: CursorTracker?
    /// 按键采集（开关由录制偏好传入，关闭时不挂监听）。
    private var keyStrokeTracker: KeyStrokeTracker?

    private var screenWriter: AVAssetWriter?
    private var screenVideoInput: AVAssetWriterInput?
    private var systemAudioWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneWriter: AVAssetWriter?
    private var microphoneAudioInput: AVAssetWriterInput?

    private var firstVideoPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var lastVideoOutputPTS: Double?
    private var captureClock = CaptureClock()
    /// 录制期是否记录按键（start 时由录制偏好写入）。
    private var captureKeyStrokes = false
    /// 1118 Loop：点击放大前置配置（start 时由录制偏好写入，
    /// 停止建工程时写入 project.json；渲染链路按工程字段消费）。
    private var captureClickZoom = true
    private var clickZoomDuration: Double = 1.2
    private var clickZoomScale: Double = 1.65
    private var pendingSystemAudio: [CMSampleBuffer] = []
    private var pendingMicrophone: [CMSampleBuffer] = []
    private var hasSystemAudioSample = false
    private var hasMicrophoneSample = false

    private var folderInfo: (id: UUID, name: String, url: URL)?
    private var screenURL: URL?
    private var systemAudioURL: URL?
    private var microphoneURL: URL?
    private var currentSource: CaptureSource = .display(displayID: CGMainDisplayID())
    private var outputWidth = 0
    private var outputHeight = 0
    private var outputFPS = 30
    private var screenStartHostTime: Double = 0
    private var recordingProjectName: String?
    /// 开始录制时的提词设置快照；停止建工程时写入 project.json，
    /// 录制中的调整会实时更新。
    private var activeTeleprompter = TeleprompterSettings()
    private var isRecording = false
    private var isPaused = false
    /// 电平上抛节流状态（0.2s）+ 累计 RMS（写链直读，
    /// 零新增系统资源）。上抛发生在 captureQueue，回调消费方自行
    /// 切主线程。
    private var lastLevelReportAt: Double = 0
    private var levelAccumulator: Double = 0
    private var levelAccumulatorCount = 0

    static func checkAccess(includeMicrophone: Bool) async throws {
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                throw RecorderError.screenPermission
            }
        }

        guard includeMicrophone else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            if !granted {
                throw RecorderError.microphonePermission
            }
        case .denied, .restricted:
            throw RecorderError.microphonePermission
        @unknown default:
            throw RecorderError.microphonePermission
        }
    }

    func start(
        setup: RecordSetup,
        screen: NSScreen?,
        folder: (id: UUID, name: String, url: URL)
    ) async throws -> RecordingStartInfo {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        try await Self.checkAccess(includeMicrophone: setup.captureMicrophone)

        let content: SCShareableContent
        do {
            // 窗口来源必须用 onScreenWindowsOnly: false，否则其他桌面
            // （Space）上的目标窗口在录制开始时找不到；整屏 / 区域
            // 不需要窗口清单，维持只枚举当前桌面以少扫一遍。
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: setup.sourceKind != .window
            )
        } catch {
            throw RecorderError.stream(error.localizedDescription)
        }

        let plan: CapturePlan
        do {
            plan = try makeCapturePlan(
                setup: setup,
                screen: screen,
                content: content
            )
        } catch {
            throw error
        }

        outputWidth = plan.width
        outputHeight = plan.height
        outputFPS = setup.fps
        currentSource = plan.source
        activeTeleprompter = setup.teleprompter
        folderInfo = folder
        let screenURL = folder.url.appendingPathComponent("screen.mp4")
        self.screenURL = screenURL
        let startedAt = Date()
        let projectName = Self.projectName(at: startedAt)

        do {
            try prepareWriters(
                folder: folder.url,
                screenURL: screenURL,
                includeSystemAudio: setup.captureSystemAudio,
                includeMicrophone: setup.captureMicrophone
            )
        } catch {
            cleanupFailedStart()
            throw error
        }
        recordingProjectName = projectName
        try? ProjectStore.saveInterruptedSession(
            RecordingSessionManifest(
                id: folder.id,
                name: projectName,
                createdAt: startedAt,
                folderName: folder.name,
                videoFile: screenURL.lastPathComponent,
                microphoneFile: microphoneURL?.lastPathComponent,
                systemAudioFile: systemAudioURL?.lastPathComponent,
                width: outputWidth,
                height: outputHeight,
                fps: outputFPS,
                source: plan.source
            )
        )

        let stream = SCStream(
            filter: plan.filter,
            configuration: plan.configuration,
            delegate: self
        )
        self.stream = stream
        do {
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: captureQueue
            )
            if setup.captureSystemAudio {
                try stream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: captureQueue
                )
            }
            if setup.captureMicrophone {
                try stream.addStreamOutput(
                    self,
                    type: .microphone,
                    sampleHandlerQueue: captureQueue
                )
            }

            clickTracker = ClickTracker(
                frameSource: plan.clickFrameSource,
                initialFrame: plan.clickFrame
            )
            clickTracker?.start()
            cursorTracker = CursorTracker(
                frameSource: plan.clickFrameSource,
                initialFrame: plan.clickFrame
            )
            cursorTracker?.start()
            captureKeyStrokes = setup.captureKeyStrokes
            captureClickZoom = setup.captureClickZoom
            clickZoomDuration = setup.clickZoomDuration
            clickZoomScale = setup.clickZoomScale
            if captureKeyStrokes {
                keyStrokeTracker = KeyStrokeTracker(clock: captureClock)
                keyStrokeTracker?.start()
            }
            screenStartHostTime = CACurrentMediaTime()
            try await startCapture(stream)
        } catch {
            _ = clickTracker?.stop()
            clickTracker = nil
            _ = cursorTracker?.stop()
            cursorTracker = nil
            _ = keyStrokeTracker?.stop()
            keyStrokeTracker = nil
            cleanupFailedStart()
            throw RecorderError.stream(error.localizedDescription)
        }

        isRecording = true
        return RecordingStartInfo(
            folderURL: folder.url,
            videoURL: screenURL,
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL,
            width: outputWidth,
            height: outputHeight,
            fps: outputFPS,
            startedAt: startedAt,
            screenStartHostTime: screenStartHostTime,
            sourceFrame: plan.clickFrame
        )
    }

    /// 录制中提词设置（字号 / 速度 / 面板位置）变化时更新快照，
    /// 停止建工程时写入 project.json。
    func updateTeleprompter(_ settings: TeleprompterSettings) {
        activeTeleprompter = settings
    }

    func stop() async throws -> RecordingResult {
        guard isRecording, let stream, let folderInfo, let screenURL else {
            throw RecorderError.noVideo
        }
        isRecording = false

        let rawClicks = clickTracker?.stop() ?? []
        clickTracker = nil
        let rawCursor = cursorTracker?.stop()
        cursorTracker = nil
        let keyStrokes = keyStrokeTracker?.stop() ?? []
        keyStrokeTracker = nil

        do {
            try await stopCapture(stream)
        } catch {
            // The writers still contain useful data if the stream stops with an error.
        }

        // captureQueue.sync 的约束（防回归，勿动）：本方法是非隔离 async
        // ——在协作池线程执行、不在主线程；captureQueue 上只挂轻量样本
        // 回调（append/时间戳），回调不得反向 sync 主线程或调用 stop()，
        // 否则此 sync 会互等死锁。
        captureQueue.sync {
            screenVideoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneAudioInput?.markAsFinished()
        }

        guard
            let firstVideoPTS,
            let lastVideoPTS,
            let screenWriter,
            let screenVideoInput
        else {
            screenWriter?.cancelWriting()
            systemAudioWriter?.cancelWriting()
            microphoneWriter?.cancelWriting()
            throw RecorderError.noVideo
        }

        _ = lastVideoPTS
        let videoDuration = max(
            0,
            (lastVideoOutputPTS ?? 0) + 1.0 / Double(outputFPS)
        )

        do {
            try await finishWriting(screenWriter, requiredInput: screenVideoInput)
            if let systemAudioWriter, hasSystemAudioSample {
                try await finishWriting(
                    systemAudioWriter,
                    requiredInput: systemAudioInput
                )
            } else {
                systemAudioWriter?.cancelWriting()
                if let systemAudioURL {
                    try? FileManager.default.removeItem(at: systemAudioURL)
                }
            }
            if let microphoneWriter, hasMicrophoneSample {
                try await finishWriting(
                    microphoneWriter,
                    requiredInput: microphoneAudioInput
                )
            } else {
                microphoneWriter?.cancelWriting()
                if let microphoneURL {
                    try? FileManager.default.removeItem(at: microphoneURL)
                }
            }
        } catch {
            throw error
        }

        let origin = CMTimeGetSeconds(firstVideoPTS)
        screenStartHostTime = origin
        let clicks = rawClicks.compactMap { raw -> ClickEvent? in
            guard
                let time = captureClock.outputTime(
                    forHostTime: raw.hostTime
                )
            else {
                return nil
            }
            guard time >= 0, time <= videoDuration - 0.12 else { return nil }
            return ClickEvent(
                time: (time * 1000).rounded() / 1000,
                x: raw.x,
                y: raw.y,
                enabled: true
            )
        }
        let cursorSamples = rawCursor?.samples.compactMap {
            raw -> CursorSample? in
            guard
                let time = captureClock.outputTime(
                    forHostTime: raw.hostTime
                ),
                time <= videoDuration
            else {
                return nil
            }
            return CursorSample(
                sourceTime: (time * 1000).rounded() / 1000,
                x: raw.x,
                y: raw.y,
                visible: raw.visible,
                appearanceID: raw.appearanceID,
                moved: raw.moved
            )
        } ?? []
        // 按键源时间在采集时已按 captureClock 换算，这里只过滤
        // 越界（暂停期间 captureClock 不推进，事件天然落在边界内）。
        let keyStrokeEvents = keyStrokes.filter { $0.sourceTime <= videoDuration }

        let project = StudioProject(
            id: folderInfo.id,
            name: recordingProjectName ?? Self.projectName(at: Date()),
            createdAt: Date(),
            folderName: folderInfo.name,
            videoFile: screenURL.lastPathComponent,
            microphoneFile: hasMicrophoneSample
                ? microphoneURL?.lastPathComponent
                : nil,
            thumbnailFile: nil,
            duration: (videoDuration * 1000).rounded() / 1000,
            width: outputWidth,
            height: outputHeight,
            fps: outputFPS,
            clicks: clicks,
            trimStart: 0,
            trimEnd: (videoDuration * 1000).rounded() / 1000,
            zoomScale: clickZoomScale,
            zoomDuration: clickZoomDuration,
            autoZoom: captureClickZoom,
            source: currentSource,
            systemAudioFile: hasSystemAudioSample
                ? systemAudioURL?.lastPathComponent
                : nil,
            rawCursor: cursorSamples,
            cursorAppearances: rawCursor?.appearances ?? [],
            keyStrokes: keyStrokeEvents,
            keyStripEnabled: captureKeyStrokes,
            canvas: CanvasSettings.forNewProject(source: currentSource),
            teleprompter: activeTeleprompter
        )
        try ProjectStore.save(project)
        ProjectStore.removeInterruptedSession(in: folderInfo.url)
        let finalizedClock = captureClock
        resetState()
        return RecordingResult(
            project: project,
            screenStartHostTime: screenStartHostTime,
            clock: finalizedClock
        )
    }

    func pause() async {
        guard isRecording else { return }
        await withCheckedContinuation { continuation in
            captureQueue.async {
                self.captureClock.pause(at: CACurrentMediaTime())
                self.isPaused = true
                continuation.resume()
            }
        }
    }

    func resume() async {
        guard isRecording else { return }
        await withCheckedContinuation { continuation in
            captureQueue.async {
                self.captureClock.resume(at: CACurrentMediaTime())
                self.isPaused = false
                continuation.resume()
            }
        }
    }

    private func makeCapturePlan(
        setup: RecordSetup,
        screen: NSScreen?,
        content: SCShareableContent
    ) throws -> CapturePlan {
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let scale: CGFloat
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        let source: CaptureSource
        let sourceWidth: CGFloat
        let sourceHeight: CGFloat
        let clickFrame: CGRect
        let clickFrameSource: ClickFrameSource

        switch setup.sourceKind {
        case .display:
            guard
                let display = content.displays.first(where: {
                    $0.displayID == setup.displayID
                })
            else {
                throw RecorderError.displayUnavailable
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            scale = max(1, CGFloat(filter.pointPixelScale))
            source = .display(displayID: display.displayID)
            sourceWidth = CGFloat(display.width) * scale
            sourceHeight = CGFloat(display.height) * scale
            clickFrame = screen?.frame ?? CGRect(
                x: 0,
                y: 0,
                width: display.width,
                height: display.height
            )
            clickFrameSource = .fixed(clickFrame)
        case .window:
            guard
                let info = setup.window,
                let window = content.windows.first(where: {
                    $0.windowID == info.windowID
                })
            else {
                throw RecorderError.windowUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            scale = max(1, CGFloat(filter.pointPixelScale))
            source = .window(
                WindowCaptureInfo(
                    windowID: window.windowID,
                    displayID: info.displayID,
                    appName: window.owningApplication?.applicationName ?? info.appName,
                    title: window.title ?? info.title,
                    width: Int(window.frame.width.rounded()),
                    height: Int(window.frame.height.rounded()),
                    bundleIdentifier: window.owningApplication?.bundleIdentifier
                        ?? info.bundleIdentifier,
                    isOnScreen: window.isOnScreen
                )
            )
            let contentRect = filter.contentRect
            sourceWidth = max(2, contentRect.width * scale)
            sourceHeight = max(2, contentRect.height * scale)
            clickFrame = Self.appKitFrame(for: window.frame)
            clickFrameSource = .window(window.windowID)
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.scalesToFit = true
        case .region:
            guard
                let region = setup.region,
                region.isValid,
                let display = content.displays.first(where: {
                    $0.displayID == setup.displayID
                })
            else {
                throw RecorderError.regionInvalid
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            scale = max(1, CGFloat(filter.pointPixelScale))
            source = .region(displayID: display.displayID, region: region)
            let displayFrame = screen?.frame ?? CGRect(
                x: 0,
                y: 0,
                width: display.width,
                height: display.height
            )
            let regionFrame = region.screenRect(in: displayFrame)
            let localRect = region.displayLocalCaptureRect(in: displayFrame)
            guard localRect.width >= 64, localRect.height >= 64 else {
                throw RecorderError.regionInvalid
            }
            configuration.sourceRect = localRect
            sourceWidth = localRect.width * scale
            sourceHeight = localRect.height * scale
            clickFrame = regionFrame
            clickFrameSource = .fixed(clickFrame)
            configuration.scalesToFit = true
        }

        let dimensions = Self.outputDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            quality: setup.quality
        )
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, setup.fps))
        )
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.capturesAudio = setup.captureSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = setup.captureMicrophone
        configuration.microphoneCaptureDeviceID = setup.microphoneDeviceID
        configuration.preservesAspectRatio = true
        configuration.streamName = "八角录屏 Recording"

        return CapturePlan(
            filter: filter,
            configuration: configuration,
            source: source,
            width: dimensions.width,
            height: dimensions.height,
            clickFrame: clickFrame,
            clickFrameSource: clickFrameSource
        )
    }

    private func prepareWriters(
        folder: URL,
        screenURL: URL,
        includeSystemAudio: Bool,
        includeMicrophone: Bool
    ) throws {
        let screenWriter = try AVAssetWriter(outputURL: screenURL, fileType: .mp4)
        screenWriter.movieFragmentInterval = CMTime(
            seconds: 2,
            preferredTimescale: 600
        )
        let width = outputWidth
        let height = outputHeight
        let bitrate = min(
            45_000_000,
            max(6_000_000, Int(Double(width * height * outputFPS) * 0.14))
        )
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: outputFPS,
                AVVideoMaxKeyFrameIntervalKey: outputFPS * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoInput.expectsMediaDataInRealTime = true
        guard screenWriter.canAdd(videoInput) else {
            throw RecorderError.writer("无法创建视频轨道")
        }
        screenWriter.add(videoInput)
        guard screenWriter.startWriting() else {
            throw RecorderError.writer(
                screenWriter.error?.localizedDescription ?? "无法开始写入"
            )
        }
        self.screenWriter = screenWriter
        self.screenVideoInput = videoInput

        if includeSystemAudio {
            let url = folder.appendingPathComponent("system.m4a")
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            writer.movieFragmentInterval = CMTime(
                seconds: 2,
                preferredTimescale: 600
            )
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.writer("无法创建系统声音轨道")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw RecorderError.writer(
                    writer.error?.localizedDescription ?? "无法开始写入系统声音"
                )
            }
            systemAudioWriter = writer
            systemAudioInput = input
            systemAudioURL = url
        }

        guard includeMicrophone else { return }
        let micURL = folder.appendingPathComponent("microphone.m4a")
        let micWriter = try AVAssetWriter(outputURL: micURL, fileType: .m4a)
        micWriter.movieFragmentInterval = CMTime(
            seconds: 2,
            preferredTimescale: 600
        )
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let micInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: micSettings
        )
        micInput.expectsMediaDataInRealTime = true
        guard micWriter.canAdd(micInput) else {
            throw RecorderError.writer("无法创建麦克风轨道")
        }
        micWriter.add(micInput)
        guard micWriter.startWriting() else {
            throw RecorderError.writer(
                micWriter.error?.localizedDescription ?? "无法开始写入麦克风"
            )
        }
        microphoneWriter = micWriter
        microphoneAudioInput = micInput
        microphoneURL = micURL
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        if !Self.frameIsComplete(sampleBuffer) { return }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstVideoPTS == nil {
            guard !captureClock.isPaused(at: sourcePTS.seconds) else {
                return
            }
            firstVideoPTS = sourcePTS
            screenStartHostTime = CMTimeGetSeconds(sourcePTS)
            captureClock.setOrigin(screenStartHostTime)
            screenWriter?.startSession(atSourceTime: .zero)
            systemAudioWriter?.startSession(atSourceTime: .zero)
            microphoneWriter?.startSession(atSourceTime: .zero)
            flushPendingAudio()
        }

        guard firstVideoPTS != nil else { return }
        guard
            let retimed = retime(
                sampleBuffer,
                fallbackDuration: CMTime(
                    value: 1,
                    timescale: CMTimeScale(max(1, outputFPS))
                )
            )
        else {
            return
        }
        if screenVideoInput?.isReadyForMoreMediaData == true {
            screenVideoInput?.append(retimed)
        }
        lastVideoPTS = sourcePTS
        lastVideoOutputPTS = CMSampleBufferGetPresentationTimeStamp(retimed)
            .seconds
    }

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, systemAudioInput != nil else { return }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstVideoPTS == nil {
            guard !captureClock.isPaused(at: sourcePTS.seconds) else {
                return
            }
            hasSystemAudioSample = true
            enqueue(&pendingSystemAudio, sampleBuffer)
            return
        }
        guard
            captureClock.outputTime(forHostTime: sourcePTS.seconds) != nil
        else {
            return
        }
        hasSystemAudioSample = true
        appendAudio(sampleBuffer, input: systemAudioInput)
    }

    private func handleMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, microphoneAudioInput != nil else { return }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstVideoPTS == nil {
            guard !captureClock.isPaused(at: sourcePTS.seconds) else {
                return
            }
            hasMicrophoneSample = true
            enqueue(&pendingMicrophone, sampleBuffer)
            return
        }
        guard
            captureClock.outputTime(forHostTime: sourcePTS.seconds) != nil
        else {
            return
        }
        hasMicrophoneSample = true
        accumulateMicrophoneLevel(sampleBuffer)
        appendAudio(sampleBuffer, input: microphoneAudioInput)
    }

    private func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        input: AVAssetWriterInput?
    ) {
        guard let input, input.isReadyForMoreMediaData else { return }
        guard
            let retimed = retime(
                sampleBuffer,
                fallbackDuration: CMTime(value: 1, timescale: 48_000)
            )
        else {
            return
        }
        input.append(retimed)
    }

    /// 麦克风样本的 RMS 累计与 0.2s 节流上抛。
    /// 复用写链上已经拿到的 CMSampleBuffer——不新建音频会话、
    /// 不复制样本数据（只读 blockBuffer 指针内的 float 声道）。
    private func accumulateMicrophoneLevel(_ sampleBuffer: CMSampleBuffer) {
        guard onMicrophoneLevel != nil else { return }
        guard
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return
        }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        let isFloat = (asbd?.pointee.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
        guard isFloat, let asbd else { return }
        let channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let base = dataPointer else {
            return
        }
        let floats = UnsafeRawPointer(base)
            .bindMemory(to: Float.self, capacity: length / 4)
        let count = min(length / 4, frames * channels)
        if count > 0 {
            let rms = InputLevelMeter.rms(
                of: Array(UnsafeBufferPointer(start: floats, count: count))
            )
            levelAccumulator += rms * rms * Double(count)
            levelAccumulatorCount += count
        }
        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if now - lastLevelReportAt >= 0.2 || lastLevelReportAt == 0 {
            lastLevelReportAt = now
            let mean = levelAccumulatorCount > 0
                ? (levelAccumulator / Double(levelAccumulatorCount)).squareRoot()
                : 0
            levelAccumulator = 0
            levelAccumulatorCount = 0
            onMicrophoneLevel?(mean)
        }
    }

    private func flushPendingAudio() {
        guard firstVideoPTS != nil else { return }
        let systemSamples = pendingSystemAudio
        let microphoneSamples = pendingMicrophone
        pendingSystemAudio.removeAll()
        pendingMicrophone.removeAll()
        for sample in systemSamples {
            appendAudio(sample, input: systemAudioInput)
        }
        for sample in microphoneSamples {
            appendAudio(sample, input: microphoneAudioInput)
        }
    }

    private func enqueue(
        _ queue: inout [CMSampleBuffer],
        _ sampleBuffer: CMSampleBuffer
    ) {
        queue.append(sampleBuffer)
        if queue.count > 120 {
            queue.removeFirst(queue.count - 120)
        }
    }

    private func retime(
        _ sampleBuffer: CMSampleBuffer,
        fallbackDuration: CMTime
    ) -> CMSampleBuffer? {
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard
            let outputTime = captureClock.outputTime(
                forHostTime: sourcePTS.seconds
            )
        else {
            return nil
        }
        let relative = CMTime(
            seconds: outputTime,
            preferredTimescale: 600
        )
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid || duration.seconds <= 0 {
            duration = fallbackDuration
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: relative,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    private static func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let rawValue = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawValue)
        else {
            return true
        }
        return status == .complete
    }

    private static func outputDimensions(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        quality: CaptureQuality
    ) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else {
            return (1920, 1080)
        }
        var width = sourceWidth
        var height = sourceHeight
        if quality == .fullHD {
            let scale = min(1, 1920.0 / width, 1080.0 / height)
            width *= scale
            height *= scale
        }
        var outputWidth = max(2, Int(width.rounded()))
        var outputHeight = max(2, Int(height.rounded()))
        outputWidth += outputWidth % 2
        outputHeight += outputHeight % 2
        return (outputWidth, outputHeight)
    }

    private static func appKitFrame(for cgFrame: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens
            .first(where: { screen in
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
                return number?.uint32Value == CGMainDisplayID()
            })?
            .frame.maxY ?? 0
        return CGRect(
            x: cgFrame.minX,
            y: mainHeight - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    private static func projectName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "录制 \(formatter.string(from: date))"
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func stopCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func finishWriting(
        _ writer: AVAssetWriter,
        requiredInput: AVAssetWriterInput?
    ) async throws {
        if writer.status == .unknown {
            writer.cancelWriting()
            return
        }
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status == .failed {
            throw RecorderError.writer(
                writer.error?.localizedDescription ?? "写入未完成"
            )
        }
        _ = requiredInput
    }

    private func cleanupFailedStart() {
        stream = nil
        cursorTracker = nil
        screenWriter?.cancelWriting()
        systemAudioWriter?.cancelWriting()
        microphoneWriter?.cancelWriting()
        if let folderInfo {
            try? FileManager.default.removeItem(at: folderInfo.url)
        }
        resetState()
    }

    private func resetState() {
        keyStrokeTracker = nil
        captureKeyStrokes = false
        stream = nil
        screenWriter = nil
        screenVideoInput = nil
        systemAudioWriter = nil
        systemAudioInput = nil
        microphoneWriter = nil
        microphoneAudioInput = nil
        firstVideoPTS = nil
        lastVideoPTS = nil
        lastVideoOutputPTS = nil
        // 电平累计状态随会话复位，避免跨录制携带旧值
        lastLevelReportAt = 0
        levelAccumulator = 0
        levelAccumulatorCount = 0
        captureClock = CaptureClock()
        isPaused = false
        pendingSystemAudio.removeAll()
        pendingMicrophone.removeAll()
        hasSystemAudioSample = false
        hasMicrophoneSample = false
        folderInfo = nil
        screenURL = nil
        systemAudioURL = nil
        microphoneURL = nil
        currentSource = .display(displayID: CGMainDisplayID())
        outputWidth = 0
        outputHeight = 0
        outputFPS = 30
        screenStartHostTime = 0
        recordingProjectName = nil
        activeTeleprompter = TeleprompterSettings()
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleSystemAudio(sampleBuffer)
        case .microphone:
            handleMicrophone(sampleBuffer)
        @unknown default:
            break
        }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isRecording else { return }
        onUnexpectedStop?(RecorderError.stream(error.localizedDescription))
    }
}
