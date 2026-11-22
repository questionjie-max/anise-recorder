import AVFoundation
import Foundation
import AniseRecorderCore

/// 1.2 音频一键优化的应用层：把源音轨按工程设置离线处理成 48 kHz float32
/// WAV 缓存，预览与导出共用同一批缓存文件（同一条混合链，路线图硬约束）。
///
/// 设计决策（同步写进 loop 日志）：
/// - 处理对象是「主导人声轨」（麦克风优先，其次独立系统声轨，最后录屏内嵌
///   声音）+ 独立系统声轨的 ducking。处理结果按源时间整轨生效，变速与切分
///   由现有合成逻辑照常处理。
/// - 缓存位于系统临时目录，键 = 工程设置签名 + 时间线签名 + 源文件身份。
///   预览只命中缓存（miss 时回落原始音轨，UI 显示准备中），导出确保命中
///   （缺失时同步处理，正确性优先）。
/// - 读取统一为 48 kHz 交错 float32（单声道源上混双声道，导出仍立体声）；
///   DSP 按通道独立、包络共享，输出 WAV 按通道数落盘。
enum AudioOptimizer {
    /// 处理采样率：读取时由 AVFoundation 统一重采样，DSP 固定按 48 kHz。
    static let processingSampleRate: Double = 48_000

    // MARK: 源解析

    struct ResolvedSources {
        /// 麦克风轨插入时使用的 URL（nil = 无麦克风轨或未处理）。
        var microphoneURL: URL?
        /// 独立系统轨插入时使用的 URL。无麦克风时系统轨同时是人声轨，
        /// 也用这个槽位（人声设置处理，无 ducking）。
        var systemURL: URL?
        /// 内嵌声分支使用的 URL（nil = 使用原始内嵌声）。
        var embeddedURL: URL?
    }

    enum Mode {
        /// 预览：只命中缓存，miss 回落原始音轨。
        case useCache
        /// 导出：缺失时同步处理（正确性优先）。
        case ensure
        /// A/B 试听旁路：全部使用原始音轨。
        case bypass
    }

    /// 按设置解析预览 / 导出应使用的音轨 URL。设置全关或 bypass 时
    /// 返回空解析（全部回落原始音轨）。
    static func resolve(
        project: StudioProject,
        mode: Mode
    ) async throws -> ResolvedSources {
        let settings = project.audio.processing
        guard !settings.isEffectivelyEmpty, mode != .bypass else {
            return ResolvedSources()
        }
        let directory = cacheDirectory(for: project)
        let mic = project.microphoneURL
        let system = project.systemAudioURL
        // ducking 需要独立的麦克风轨 + 系统声轨；没有麦克风时人声角色
        // 落到唯一可用音轨，不做 ducking。
        let hasSeparateSystem = system != nil && mic != nil
        let needsDucking = settings.duckingEnabled && hasSeparateSystem

        var resolved = ResolvedSources()
        if mic == nil, system == nil {
            // 唯一音轨是录屏内嵌声音：处理结果替换内嵌声分支。
            resolved.embeddedURL = try await ensureTrack(
                sourceURL: project.videoURL,
                kind: .voice,
                settings: settings,
                duckRanges: [],
                directory: directory,
                mode: mode
            )
            return resolved
        }

        if let mic {
            if let url = try await ensureTrack(
                sourceURL: mic,
                kind: .voice,
                settings: settings,
                duckRanges: [],
                directory: directory,
                mode: mode
            ) {
                resolved.microphoneURL = url
            }
            if let system, hasSeparateSystem {
                let duckRanges: [ClosedRange<Double>] = needsDucking
                    ? try await duckingSourceRanges(project: project)
                    : []
                if let url = try await ensureTrack(
                    sourceURL: system,
                    kind: .system,
                    settings: settings,
                    duckRanges: duckRanges,
                    directory: directory,
                    mode: mode
                ) {
                    resolved.systemURL = url
                }
            }
        } else if let system {
            // 无麦克风：系统轨同时是人声轨，按人声设置处理，无 ducking。
            if let url = try await ensureTrack(
                sourceURL: system,
                kind: .voice,
                settings: settings,
                duckRanges: [],
                directory: directory,
                mode: mode
            ) {
                resolved.systemURL = url
            }
        }
        return resolved
    }

    private enum TrackKind: String {
        case voice
        case system
        case embedded
    }

    /// 缓存命中（useCache）或离线处理（ensure）一条音轨。
    private static func ensureTrack(
        sourceURL: URL,
        kind: TrackKind,
        settings: AudioEnhanceSettings,
        duckRanges: [ClosedRange<Double>],
        directory: URL,
        mode: Mode
    ) async throws -> URL? {
        let destination = directory
            .appendingPathComponent("audio-\(kind.rawValue).wav")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        guard mode == .ensure else { return nil }
        let (channels, sampleRate) = try await readTrack(url: sourceURL)
        try Task.checkCancellation()
        let result = AudioEnhancer.process(
            channels: channels,
            sampleRate: sampleRate,
            settings: settings,
            role: kind == .system ? .system : .voice,
            duckRanges: duckRanges
        )
        try Task.checkCancellation()
        try writeWAV(
            channels: result.channels,
            sampleRate: sampleRate,
            to: destination
        )
        return destination
    }

    // MARK: Ducking 的源时间区间

    /// 语音活动检测采样率（与精剪扫描一致，16 kHz 单声道足够）。
    private static let analysisRate = 16_000.0

    /// 把成片时间的人声活动区间映射到系统声轨的源时间：先在麦克风成片
    /// 音频上检测语音活动，再经时间线映射（变速自动展开）。
    private static func duckingSourceRanges(
        project: StudioProject
    ) async throws -> [ClosedRange<Double>] {
        guard let mic = project.microphoneURL else { return [] }
        let asset = AVURLAsset(url: mic)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first
        else {
            return []
        }
        let composition = AVMutableComposition()
        guard
            try await CompositionBuilder.insertTimelineAudioTrack(
                track,
                clips: project.timeline.clips,
                composition: composition,
                sourceOrigin: try await track.load(.timeRange).start
            ) != nil
        else {
            return []
        }
        let samples = try await readComposition(
            composition: composition,
            sampleRate: analysisRate
        )
        try Task.checkCancellation()
        let activity = SmartCutActivityDetector.detectSpeechActivity(
            in: samples,
            sampleRate: analysisRate
        )
        var ranges: [ClosedRange<Double>] = []
        for interval in activity {
            ranges.append(
                contentsOf: project.timeline.sourceRanges(
                    forOutputRange: interval.start...interval.end
                )
            )
        }
        return mergeRanges(ranges)
    }

    private static func mergeRanges(
        _ ranges: [ClosedRange<Double>]
    ) -> [ClosedRange<Double>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in sorted {
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

    // MARK: 音轨读取（48 kHz 交错 float32）

    /// 成片合成音频读取（单声道，用于语音活动检测）。
    static func readComposition(
        composition: AVAsset,
        sampleRate: Double
    ) async throws -> [Float] {
        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw ExportError.noAudioForTranscription
        }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
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
        return try await pumpFloatSamples(
            output: output,
            reader: reader,
            channels: 1,
            reportProgress: nil
        )
    }

    /// 源音轨读取：48 kHz 交错 float32，通道数跟随源（1 或 2）。
    static func readTrack(
        url: URL,
        progress: ((Double) -> Void)? = nil
    ) async throws -> (channels: [[Float]], sampleRate: Double) {
        let asset = AVURLAsset(url: url)
        guard
            let track = try await asset.loadTracks(withMediaType: .audio).first
        else {
            throw ExportError.noAudioForTranscription
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: processingSampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ] as [String: Any]
        )
        guard reader.canAdd(output) else {
            throw ExportError.failed
        }
        reader.add(output)
        let interleaved = try await pumpFloatSamples(
            output: output,
            reader: reader,
            channels: 2,
            reportProgress: progress
        )
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(interleaved.count / 2)
        right.reserveCapacity(interleaved.count / 2)
        for index in stride(from: 0, to: interleaved.count, by: 2) {
            let value = interleaved[index]
            left.append(value)
            right.append(index + 1 < interleaved.count ? interleaved[index + 1] : value)
        }
        // 单声道源上混后两通道相同，处理保留立体声输出。
        let channels: [[Float]] = interleaved.count == 2
            ? [[interleaved[0], interleaved[1]]]
            : [left, right]
        return (channels, processingSampleRate)
    }

    private static func pumpFloatSamples(
        output: AVAssetReaderOutput,
        reader: AVAssetReader,
        channels: Int,
        reportProgress: ((Double) -> Void)?
    ) async throws -> [Float] {
        guard reader.startReading() else {
            throw reader.error ?? ExportError.failed
        }
        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
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
                    contentsOf: UnsafeBufferPointer(
                        start: $0,
                        count: floatCount
                    )
                )
            }
            if let reportProgress, channels > 0 {
                // 进度按块回调；这里没有总长估计，调用方自行换算。
                reportProgress(Double(samples.count))
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? ExportError.failed
        }
        return samples
    }

    // MARK: WAV 落盘与缓存目录

    /// 写 48 kHz float32 WAV（RIFF/WAVE，format tag 3），通道交错。
    static func writeWAV(
        channels: [[Float]],
        sampleRate: Double,
        to url: URL
    ) throws {
        guard
            let first = channels.first,
            !first.isEmpty,
            sampleRate > 0
        else {
            throw ExportError.failed
        }
        let channelCount = channels.count
        let frameCount = first.count
        let dataByteCount = frameCount * channelCount * 4
        var header = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + dataByteCount))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        append32(16)
        append16(3) // IEEE float
        append16(UInt16(channelCount))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * UInt32(channelCount) * 4)
        append16(UInt16(channelCount * 4))
        append16(32)
        header.append(contentsOf: "data".utf8)
        append32(UInt32(dataByteCount))

        var data = header
        data.reserveCapacity(header.count + dataByteCount)
        var samples = [Float]()
        samples.reserveCapacity(frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                samples.append(
                    frame < channels[channel].count
                        ? channels[channel][frame]
                        : 0
                )
            }
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    /// 缓存目录：签名 = 设置 + 时间线 + 源文件身份，任何一项变化都会
    /// 生成新目录，旧目录由系统临时目录清理兜底。
    static func cacheDirectory(for project: StudioProject) -> URL {
        let signature = cacheSignature(for: project)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AniseRecorderAudioCache", isDirectory: true)
            .appendingPathComponent(signature, isDirectory: true)
    }

    static func cacheSignature(for project: StudioProject) -> String {
        let settings = project.audio.processing
        let timeline = project.timeline.clips
            .map {
                "\($0.id.uuidString)-\($0.sourceStart)-\($0.sourceEnd)-\($0.playbackRate)"
            }
            .joined(separator: ";")
        let identity = trackIdentity(project.microphoneURL)
            + "/" + trackIdentity(project.systemAudioURL)
            + "/" + trackIdentity(project.videoURL)
        let raw = [
            project.id.uuidString,
            settings.cacheSignature,
            timeline,
            identity
        ].joined(separator: "|")
        return stableHash(raw)
    }

    private static func trackIdentity(_ url: URL?) -> String {
        guard let url else { return "none" }
        let manager = FileManager.default
        guard
            let attributes = try? manager.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int,
            let modified = attributes[.modificationDate] as? Date
        else {
            return url.lastPathComponent
        }
        return "\(url.lastPathComponent)-\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    /// 稳定哈希（跨进程一致，FNV-1a 64 位），仅作缓存目录名用途。
    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// 1.2 音频优化分析（建议而非独裁）：测量成片人声响度与峰值，给出
/// 自动电平增益建议。结果只进会话状态，用户确认后才写入工程设置。
enum AudioOptimizationAnalyzer {
    struct Proposal: Equatable {
        /// 主导人声轨的 K 加权近似响度（LUFS 近似值）；不可测时为 nil。
        var loudness: Double?
        /// 主导人声轨样本峰值（dBFS）。
        var peak: Double
        /// 建议增益（dB，已钳制 ±12 且保留峰值余量）。
        var suggestedGainDB: Double
        /// ducking 是否可用（需要独立的麦克风轨 + 系统声轨）。
        var duckingAvailable: Bool
    }

    static func analyze(
        project: StudioProject
    ) async throws -> Proposal {
        // 复用「有效成片音频」的合成逻辑（麦克风优先）。
        let (composition, _) = try await CompositionBuilder
            .makeTimelineAudioComposition(for: project)
        let samples = try await AudioOptimizer.readComposition(
            composition: composition,
            sampleRate: AudioOptimizer.processingSampleRate
        )
        try Task.checkCancellation()
        let loudness = AudioEnhancer.integratedLoudness(
            samples: samples,
            sampleRate: AudioOptimizer.processingSampleRate
        )
        let peak = AudioEnhancer.samplePeakDB(samples: samples)
        return Proposal(
            loudness: loudness,
            peak: peak,
            suggestedGainDB: AudioEnhancer.autoLevelGain(
                currentLoudness: loudness,
                peakDB: peak
            ),
            duckingAvailable: project.microphoneURL != nil
                && project.systemAudioURL != nil
        )
    }
}
