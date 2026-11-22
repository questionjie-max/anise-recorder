import Foundation
import Speech

private final class RecognitionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

enum OfflineCaptionError: LocalizedError, Equatable {
    case permissionDenied
    case permissionUnavailable
    case permissionTimedOut
    case offlineRecognitionUnavailable
    case noSpeechDetected
    case recognitionTimedOut
    case failed(String)

    static func mapped(_ error: Error) -> OfflineCaptionError {
        let message = error.localizedDescription
        let normalized = message.lowercased()
        if
            normalized.contains("no speech detected")
                || message.contains("没有检测到")
                || message.contains("未检测到")
        {
            return .noSpeechDetected
        }
        return .failed(message)
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "本机语音识别权限被拒绝。请在系统设置中允许“八角录屏”使用语音识别，或改用 SRT 导入。"
        case .permissionUnavailable:
            return "当前账号无法使用本机语音识别，请改用 SRT 导入。"
        case .permissionTimedOut:
            return "等待语音识别权限超时。请检查“系统设置 › 隐私与安全性 › 语音识别”后重试，或改用 SRT 导入。"
        case .offlineRecognitionUnavailable:
            return "当前系统或语言没有可用的本机离线识别模型。“八角录屏”不会切换到云端，请改用 SRT 导入。"
        case .noSpeechDetected:
            return "本机识别完成，但没有检测到可用语音。请检查麦克风音轨或改用 SRT 导入。"
        case .recognitionTimedOut:
            return "本机语音识别超时。请缩短工程后重试，或改用 SRT 导入。"
        case let .failed(message):
            return "本机字幕生成失败：\(message)"
        }
    }
}

enum OfflineCaptionTranscriber {
    static func transcribe(
        audioURL: URL,
        totalDuration: Double,
        preferredLanguage: String?
    ) async throws -> [CaptionCue] {
        try await transcribeWithSegments(
            audioURL: audioURL,
            totalDuration: totalDuration,
            preferredLanguage: preferredLanguage
        ).cues
    }

    /// 除合并后的 cue 外，同时返回原始识别分段
    /// （timestamp + duration + substring），供句内填充词检测与字幕文本
    /// 手术使用。分段只进会话态，不写入 project.json。
    ///
    /// P4 防卡死：`progress` 以识别到的音频位置/总时长回报 0…1（识别
    /// 分段随处理推进）；调用方取消 Task 时，识别链经
    /// `withTaskCancellationHandler` 终结 SF 任务并恢复 continuation。
    static func transcribeWithSegments(
        audioURL: URL,
        totalDuration: Double,
        preferredLanguage: String?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> OfflineTranscription {
        try await ensureAuthorization()
        guard
            let recognizer = recognizer(
                preferredLanguage: preferredLanguage
            )
        else {
            throw OfflineCaptionError.offlineRecognitionUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw OfflineCaptionError.offlineRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        // 进度回报依赖分段结果流；不请求时与旧行为一致。
        request.shouldReportPartialResults = progress != nil
        request.addsPunctuation = true
        request.taskHint = .dictation

        let result = try await recognize(
            request: request,
            recognizer: recognizer,
            totalDuration: totalDuration,
            progress: progress
        )
        let transcription = outcome(
            from: result.bestTranscription.segments.map {
                SpeechSegment(
                    text: $0.substring,
                    start: $0.timestamp,
                    duration: $0.duration
                )
            },
            totalDuration: totalDuration
        )
        guard !transcription.cues.isEmpty else {
            throw OfflineCaptionError.noSpeechDetected
        }
        return transcription
    }

    /// 纯逻辑构建（可测试）：cues 的生成入口仍是
    /// `SubtitleFile.cues(from:)`，与旧路径逐字一致（回归断言守护）；
    /// 原始分段原样保留。
    static func outcome(
        from segments: [SpeechSegment],
        totalDuration: Double
    ) -> OfflineTranscription {
        OfflineTranscription(
            cues: SubtitleFile.cues(
                from: segments,
                totalDuration: totalDuration
            ),
            segments: segments
        )
    }

    private static func ensureAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw OfflineCaptionError.permissionDenied
        case .notDetermined:
            let status = try await awaitAuthorization {
                SFSpeechRecognizer.requestAuthorization($0)
            }
            guard status == .authorized else {
                throw OfflineCaptionError.permissionDenied
            }
        @unknown default:
            throw OfflineCaptionError.permissionUnavailable
        }
    }

    static func awaitAuthorization(
        timeout: TimeInterval = 30,
        request: (
            @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
        ) -> Void
    ) async throws -> SFSpeechRecognizerAuthorizationStatus {
        let gate = RecognitionContinuationGate()
        return try await withCheckedThrowingContinuation { continuation in
            request { status in
                guard gate.claim() else { return }
                continuation.resume(returning: status)
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout
            ) {
                guard gate.claim() else { return }
                continuation.resume(
                    throwing: OfflineCaptionError.permissionTimedOut
                )
            }
        }
    }

    private static func recognizer(
        preferredLanguage: String?
    ) -> SFSpeechRecognizer? {
        var identifiers: [String] = []
        if let preferredLanguage, !preferredLanguage.isEmpty {
            identifiers.append(preferredLanguage)
        }
        identifiers.append(
            contentsOf: Locale.preferredLanguages.prefix(2)
        )
        identifiers.append(contentsOf: ["zh-CN", "en-US"])

        var seen: Set<String> = []
        for identifier in identifiers where seen.insert(identifier).inserted {
            let locale = Locale(identifier: identifier)
            guard
                let recognizer = SFSpeechRecognizer(locale: locale),
                recognizer.isAvailable,
                recognizer.supportsOnDeviceRecognition
            else {
                continue
            }
            return recognizer
        }
        return nil
    }

    private static func recognize(
        request: SFSpeechRecognitionRequest,
        recognizer: SFSpeechRecognizer,
        totalDuration: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> SFSpeechRecognitionResult {
        let gate = RecognitionContinuationGate()
        let taskBox = RecognitionTaskBox()
        // P4 防卡死：取消支持——continuation 收进 box，onCancel 终结
        // SF 任务后恢复 CancellationError；gate 保证与 SF 回调 / 300s
        // 超时三条路径只有一条真正恢复。
        let resumeBox = RecognitionResumeBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resumeBox.store(continuation)
                let task = recognizer.recognitionTask(
                    with: request
                ) { result, error in
                    if let result, result.isFinal {
                        guard gate.claim() else { return }
                        resumeBox.resume(returning: result)
                    } else if let error {
                        guard gate.claim() else { return }
                        resumeBox.resume(
                            throwing: OfflineCaptionError.mapped(error)
                        )
                    } else if let result, let progress {
                        // 非最终分段：按识别到的音频位置估算进度。
                        let last = result.bestTranscription.segments.last
                        let processed = (last?.timestamp ?? 0)
                            + (last?.duration ?? 0)
                        if processed > 0, totalDuration > 0 {
                            progress(min(processed / totalDuration, 0.99))
                        }
                    }
                }
                taskBox.set(task)
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + 300
                ) {
                    guard gate.claim() else { return }
                    taskBox.cancel()
                    resumeBox.resume(
                        throwing: OfflineCaptionError.recognitionTimedOut
                    )
                }
            }
        } onCancel: {
            taskBox.cancel()
            guard gate.claim() else { return }
            resumeBox.resume(throwing: CancellationError())
        }
    }
}

/// P4 防卡死：continuation 的安全存取——取消可能在 `store` 之前到达，
/// pending 结果在 store 时补恢复；配合 gate 单恢复语义。
private final class RecognitionResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        SFSpeechRecognitionResult, Error
    >?
    private var pending: Result<SFSpeechRecognitionResult, Error>?

    func store(
        _ continuation: CheckedContinuation<
            SFSpeechRecognitionResult, Error
        >
    ) {
        lock.lock()
        if let pending {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: SFSpeechRecognitionResult) {
        resume(with: .success(value))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(
        with result: Result<SFSpeechRecognitionResult, Error>
    ) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        pending = result
        lock.unlock()
    }
}

private final class RecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?

    func set(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
