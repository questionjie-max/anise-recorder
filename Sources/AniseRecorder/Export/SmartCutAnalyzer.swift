import AVFoundation
import Foundation
import AniseRecorderCore

/// 一次精剪扫描的应用层结果。
struct SmartCutScanOutcome: Sendable {
    let analysis: SmartCutAnalysis
    /// 实际用于分析的音轨来源；不是麦克风时 UI 需要说明结果可能不可靠。
    let audioSource: SmartCutAudioSource
    /// “保护系统声音”是否实际生效（没有系统声音轨时不生效）。
    let systemSoundProtected: Bool
}

/// 应用层精剪审计器（路线图 8.2）：读取当前时间线的有效成片音频（尊重已有
/// 切分、ripple 和变速，复用 `CompositionBuilder` 的组合逻辑），调用
/// `AniseRecorderCore` 的纯逻辑检测。本类型不做 UI，不持久化任何结果；
/// 调用方在后台 Task 中运行 `scan`，进度通过回调回到主线程。
enum SmartCutAnalyzer {
    /// 分析采样率：语音活动检测不需要 44.1/48 kHz 的全带宽，降到 16 kHz
    /// 单声道可把 10 分钟素材的内存占用控制在约 40 MB。
    private static let analysisSampleRate = 16_000.0

    /// 点击前后的屏幕活动保护窗口（秒）：覆盖点击动作和落点附近的
    /// 光标移动；窗口大小是集中定义的起始值，调参时同步更新这里。
    private static let clickActivityLead = 0.3
    private static let clickActivityTail = 0.5
    /// 光标移动采样的前后保护窗口（秒）。采样器在移动时按 60 Hz 记录，
    /// 合并后即可覆盖一整段拖拽 / 鼠标路径。
    private static let cursorActivityLead = 0.08
    private static let cursorActivityTail = 0.12

    static func scan(
        project: StudioProject,
        mode: SmartCutMode,
        protectScreenActivity: Bool,
        protectSystemSound: Bool,
        progress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> SmartCutScanOutcome {
        // 1. 主音轨：麦克风优先，其次系统声音，最后录屏内嵌声音。
        let main = try await CompositionBuilder.makeTimelineAudioComposition(
            for: project
        )
        try Task.checkCancellation()

        // 2. 保护区间输入。
        let screenRanges = protectScreenActivity
            ? screenActivityRanges(of: project)
            : []
        var systemRanges: [ClosedRange<Double>] = []
        var systemProtected = false
        if protectSystemSound {
            if
                let systemComposition = try await CompositionBuilder
                    .makeSystemSoundComposition(for: project)
            {
                let systemReading = try await readSamples(
                    composition: systemComposition,
                    progress: { _ in },
                    isCancelled: isCancelled
                )
                let activity = SmartCutActivityDetector.detectSpeechActivity(
                    in: systemReading.samples,
                    sampleRate: systemReading.sampleRate
                )
                systemRanges = activity.map { $0.start...$0.end }
                systemProtected = !systemRanges.isEmpty
            }
        }

        // 3. 读取主音轨 PCM 并调用纯逻辑检测。
        let reading = try await readSamples(
            composition: main.composition,
            progress: progress,
            isCancelled: isCancelled
        )
        try Task.checkCancellation()
        let analysis = SmartCutEngine.analyze(
            samples: reading.samples,
            sampleRate: reading.sampleRate,
            mode: mode,
            screenActivity: screenRanges,
            systemSound: systemRanges
        )
        return SmartCutScanOutcome(
            analysis: analysis,
            audioSource: main.source,
            systemSoundProtected: systemProtected
        )
    }

    // MARK: - 私有辅助

    /// 点击和明显光标移动（源时间）映射到成片时间的保护区间；已被剪掉的
    /// 事件忽略，重叠或相接的区间合并。
    static func screenActivityRanges(
        of project: StudioProject
    ) -> [ClosedRange<Double>] {
        let duration = project.trimDuration
        let clicks: [ClosedRange<Double>] = project.clicks
            .filter(\.enabled)
            .compactMap { click -> ClosedRange<Double>? in
                guard let output = project.outputTime(forSourceTime: click.time)
                else {
                    return nil
                }
                let start = max(0, output - clickActivityLead)
                let end = min(duration, output + clickActivityTail)
                return end > start ? start...end : nil
            }
        let cursorMoves: [ClosedRange<Double>] = project.cursor.enabled
            ? project.rawCursor.compactMap {
                sample -> ClosedRange<Double>? in
                guard
                    sample.moved,
                    sample.visible,
                    let output = project.outputTime(
                        forSourceTime: sample.sourceTime
                    )
                else {
                    return nil
                }
                let start = max(0, output - cursorActivityLead)
                let end = min(duration, output + cursorActivityTail)
                return end > start ? start...end : nil
            }
            : []
        return mergedRanges(clicks + cursorMoves)
    }

    private static func mergedRanges(
        _ ranges: [ClosedRange<Double>]
    ) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if
                let last = merged.last,
                range.lowerBound <= last.upperBound
            {
                merged[merged.count - 1] =
                    last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// 用 AVAssetReader 从合成音频直接读出 16 kHz 单声道 Float32 样本，
    /// 不产生临时文件；按样本块回报进度并支持取消。
    private static func readSamples(
        composition: AVMutableComposition,
        progress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> (samples: [Float], sampleRate: Double) {
        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw ExportError.noAudioForTranscription
        }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: analysisSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ] as [String: Any]
        )
        guard reader.canAdd(output) else {
            throw ExportError.failed
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ExportError.failed
        }

        let totalSeconds = max(0.001, composition.duration.seconds)
        let estimatedSamples = Int(totalSeconds * analysisSampleRate)
        var samples: [Float] = []
        var lastReported = 0.0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            guard
                let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else {
                continue
            }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer else {
                continue
            }
            let floatCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: $0, count: floatCount)
                )
            }

            let value = min(1, Double(samples.count) / Double(max(1, estimatedSamples)))
            if value - lastReported >= 0.01 {
                lastReported = value
                progress(value)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? ExportError.failed
        }
        progress(1)
        return (samples, analysisSampleRate)
    }
}
