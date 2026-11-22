import Foundation

/// 1.2 音频优化工程设置（路线图 12 节第 1 项）。全部是工程字段，旧工程
/// 缺省关闭；增益值由分析建议、用户确认后写入。
///
/// 近似声明（不得在 UI 中宣称精确 LUFS）：响度测量使用 ITU-R BS.1770 的
/// K 加权两段固定 48 kHz 双二阶系数 + 400 ms 块 / 75% 重叠 / 绝对 -70 与
/// 相对 -10 门限，属于 K 加权近似；未做过采样真峰值，峰值用样本峰值估计。
/// 对典型口播素材与回放实现偏差预期在 ±1 LU 内。
package struct AudioEnhanceSettings: Hashable, Sendable, Codable {
    /// 自动电平：把主导人声轨整体增益到目标响度（约 -14 LUFS 近似值）。
    package var autoLevelEnabled = false
    /// 建议并经用户确认的增益（dB），钳制在 ±12；0 表示尚未分析或无增益。
    package var autoLevelGainDB = 0.0
    /// 人声增强：2–5 kHz 存在感频段小幅提升 + 轻量压缩（固定保守参数）。
    package var voiceEnhanceEnabled = false
    /// Ducking：麦克风有声时系统声自动压低（需要独立的系统声音轨）。
    package var duckingEnabled = false
    /// 压低量（dB），默认 6，可调 1...12。
    package var duckingAmountDB = 6.0
    /// 轻量降噪：约 80 Hz 高通 + 噪声门（阈值跟随自适应噪声底）。
    package var noiseReductionEnabled = false

    /// 任一处理开关是否开启（混音链据此选择已处理缓存）。
    package var isEffectivelyEmpty: Bool {
        !(autoLevelEnabled || voiceEnhanceEnabled || duckingEnabled
            || noiseReductionEnabled)
    }

    /// 参与处理缓存命中的字段（数值四舍五入到 0.1dB，诊断字段不参与）。
    package var cacheSignature: String {
        [
            autoLevelEnabled ? "1" : "0",
            String((autoLevelGainDB * 10).rounded() / 10),
            voiceEnhanceEnabled ? "1" : "0",
            duckingEnabled ? "1" : "0",
            String((duckingAmountDB * 10).rounded() / 10),
            noiseReductionEnabled ? "1" : "0"
        ].joined(separator: "|")
    }

    package init() {}

    private enum CodingKeys: String, CodingKey {
        case autoLevelEnabled
        case autoLevelGainDB
        case voiceEnhanceEnabled
        case duckingEnabled
        case duckingAmountDB
        case noiseReductionEnabled
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        autoLevelEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .autoLevelEnabled
        ) ?? false
        autoLevelGainDB = try values.decodeIfPresent(
            Double.self,
            forKey: .autoLevelGainDB
        ) ?? 0
        voiceEnhanceEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .voiceEnhanceEnabled
        ) ?? false
        duckingEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .duckingEnabled
        ) ?? false
        duckingAmountDB = try values.decodeIfPresent(
            Double.self,
            forKey: .duckingAmountDB
        ) ?? 6.0
        noiseReductionEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .noiseReductionEnabled
        ) ?? false
    }
}

/// 音频优化纯逻辑引擎：响度 / 峰值测量、增益建议、以及逐轨 DSP。
/// 只接收数值样本与设置，不依赖 AVFoundation / AppKit / SwiftUI。
package enum AudioEnhancer {
    // MARK: 集中定义的固定参数（路线图要求参数集中、写注释）

    /// 自动电平目标响度（K 加权近似 LUFS）。
    package static let targetLoudness = -14.0
    /// 自动电平增益钳制（±12 dB）。
    package static let autoLevelGainLimit = 12.0
    /// 峰值预留（dBFS）：处理后人声峰值不得超过该值，防削波。
    package static let peakCeiling = -1.0

    /// 人声增强存在感频段中心（Hz，覆盖约 2–5 kHz）。
    package static let presenceFrequency = 3500.0
    /// 存在感频段默认提升（dB）；UI 上限 +4。
    package static let presenceGainDB = 2.0
    package static let presenceQ = 1.0

    /// 轻量压缩固定参数（保守：慢 attack/release、2:1、无 makeup）。
    package static let compressorThresholdDB = -24.0
    package static let compressorRatio = 2.0
    package static let compressorKneeDB = 6.0
    package static let compressorAttackSeconds = 0.03
    package static let compressorReleaseSeconds = 0.25

    /// 降噪高通截止（Hz）。
    package static let highPassFrequency = 80.0
    /// 噪声门窗口 / 步进（与精剪检测同族的自适应噪声底）。
    package static let gateWindowSeconds = 0.02
    package static let gateHopSeconds = 0.01
    /// 开门 / 关门余量（高于噪声底的 dB 数）：宁可少降，不许伤人声起音。
    package static let gateOpenMarginDB = 8.0
    package static let gateCloseMarginDB = 4.0
    /// 最大压低深度（dB）：不静音，只压到 -12 dB。
    package static let gateDepthDB = 12.0
    /// 门开启 / 关闭平滑与保持。
    package static let gateAttackSeconds = 0.005
    package static let gateReleaseSeconds = 0.08
    package static let gateHoldSeconds = 0.2
    package static let gateFloorRiseDBPerSecond = 0.5
    package static let gateFloorFallDBPerSecond = 30.0

    /// Ducking 包络：进入语音时压低、离开后保持再缓慢恢复。
    package static let duckAttackSeconds = 0.15
    package static let duckReleaseSeconds = 0.4
    package static let duckHoldSeconds = 0.15

    // MARK: 测量

    /// K 加权近似积分响度（LUFS 近似值）。样本过短或全静音时返回 nil。
    package static func integratedLoudness(
        samples: [Float],
        sampleRate: Double
    ) -> Double? {
        guard sampleRate > 0, samples.count >= Int(sampleRate * 0.1) else {
            return nil
        }
        let weighted = kWeight(samples, sampleRate: sampleRate)
        let blockSize = max(1, Int(sampleRate * 0.4))
        let hop = blockSize / 4
        var blockPowers: [Double] = []
        var index = 0
        while index + blockSize <= weighted.count {
            var sum = 0.0
            for sample in weighted[index..<(index + blockSize)] {
                let value = Double(sample)
                sum += value * value
            }
            blockPowers.append(sum / Double(blockSize))
            index += hop
        }
        guard !blockPowers.isEmpty else { return nil }
        // BS.1770 门限：绝对 -70 LUFS，再按未门控均值 -10 LU 相对门限。
        let absoluteThreshold = pow(10, (-70.0 + -0.691) / 10)
        let loudBlocks = blockPowers.filter { $0 > absoluteThreshold }
        guard !loudBlocks.isEmpty else { return nil }
        let ungatedMean = loudBlocks.reduce(0, +) / Double(loudBlocks.count)
        let relativeThreshold = ungatedMean * pow(10, -10.0 / 10)
        let gated = loudBlocks.filter { $0 > relativeThreshold }
        let mean = (gated.isEmpty ? loudBlocks : gated)
            .reduce(0, +) / Double((gated.isEmpty ? loudBlocks : gated).count)
        return -0.691 + 10 * log10(mean)
    }

    /// 样本峰值（dBFS）。未做过采样真峰值，作为削波保护的保守下界使用。
    package static func samplePeakDB(samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -Double.infinity }
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        return 20 * log10(max(Double(peak), 1e-7))
    }

    /// 自动电平增益建议（dB）：对齐目标响度并做峰值预留与 ±12 钳制。
    package static func autoLevelGain(
        currentLoudness: Double?,
        peakDB: Double
    ) -> Double {
        guard let currentLoudness else { return 0 }
        var gain = targetLoudness - currentLoudness
        // 峰值预留：应用增益后峰值不得高于天花板。
        let peakHeadroom = peakCeiling - peakDB
        gain = min(gain, peakHeadroom)
        return min(autoLevelGainLimit, max(-autoLevelGainLimit, gain))
    }

    // MARK: 逐轨处理

    package enum TrackRole {
        /// 主导人声轨（麦克风优先）：自动电平、人声增强、降噪作用对象。
        case voice
        /// 系统声音轨：只做 ducking。
        case system
    }

    package struct ProcessedResult: Hashable, Sendable {
        package var channels: [[Float]]
        /// 处理后样本峰值（dBFS，按各通道最大值）。
        package var peakDB: Double
        /// 处理后 K 加权近似响度（单声道合并测量）。
        package var loudness: Double?
    }

    /// 处理一条音轨。`channels` 为各声道样本（长度一致）；
    /// `duckRanges` 只对 system 轨生效：人声活动区间（该轨的源时间）。
    package static func process(
        channels: [[Float]],
        sampleRate: Double,
        settings: AudioEnhanceSettings,
        role: TrackRole,
        duckRanges: [ClosedRange<Double>] = []
    ) -> ProcessedResult {
        guard sampleRate > 0, !channels.isEmpty else {
            return ProcessedResult(channels: channels, peakDB: samplePeakDB(samples: channels.first ?? []), loudness: nil)
        }
        var channels = channels
        switch role {
        case .voice:
            if settings.noiseReductionEnabled {
                let envelopes = gateEnvelopes(
                    channels: channels,
                    sampleRate: sampleRate
                )
                let highpass = Biquad.highPass(
                    sampleRate: sampleRate,
                    frequency: highPassFrequency
                )
                for index in channels.indices {
                    channels[index] = filtered(
                        channels[index],
                        filters: [highpass],
                        gate: envelopes[index],
                        sampleRate: sampleRate
                    )
                }
            }
            if settings.voiceEnhanceEnabled {
                let presence = Biquad.peaking(
                    sampleRate: sampleRate,
                    frequency: presenceFrequency,
                    q: presenceQ,
                    gainDB: presenceGainDB
                )
                let compressor = Compressor(sampleRate: sampleRate)
                for index in channels.indices {
                    var samples = filtered(
                        channels[index],
                        filters: [presence],
                        sampleRate: sampleRate
                    )
                    samples = compressor.apply(samples)
                    channels[index] = samples
                }
            }
            if settings.autoLevelEnabled, settings.autoLevelGainDB != 0 {
                let gain = Float(linearGain(settings.autoLevelGainDB))
                for index in channels.indices {
                    for sampleIndex in channels[index].indices {
                        channels[index][sampleIndex] *= gain
                    }
                }
            }
            // 削波保护：只降不升，保证峰值 ≤ -1 dBFS。
            let peak = channels.map { samplePeakDB(samples: $0) }.max() ?? -Double.infinity
            if peak > peakCeiling {
                let scale = Float(linearGain(peakCeiling - peak))
                for index in channels.indices {
                    for sampleIndex in channels[index].indices {
                        channels[index][sampleIndex] *= scale
                    }
                }
            }
        case .system:
            if settings.duckingEnabled, settings.duckingAmountDB > 0,
               !duckRanges.isEmpty
            {
                let envelope = duckEnvelope(
                    duckRanges: duckRanges,
                    sampleRate: sampleRate,
                    duration: Double(channels[0].count) / sampleRate,
                    amountDB: min(12, max(1, settings.duckingAmountDB))
                )
                for index in channels.indices {
                    for sampleIndex in channels[index].indices {
                        channels[index][sampleIndex] *= envelope[sampleIndex]
                    }
                }
            }
        }
        let mono = mixdown(channels)
        return ProcessedResult(
            channels: channels,
            peakDB: channels.map { samplePeakDB(samples: $0) }.max()
                ?? -Double.infinity,
            loudness: integratedLoudness(samples: mono, sampleRate: sampleRate)
        )
    }

    // MARK: - Ducking 包络

    /// 按人声活动区间生成系统轨增益包络（线性，含 hold / attack / release）。
    /// 边界约定：全静音（无区间）→ 常量 1；全程人声 → 攻击段后恒定压低。
    package static func duckEnvelope(
        duckRanges: [ClosedRange<Double>],
        sampleRate: Double,
        duration: Double,
        amountDB: Double
    ) -> [Float] {
        let total = max(0, Int((duration * sampleRate).rounded()))
        let target = Float(linearGain(-abs(amountDB)))
        var envelope = [Float](repeating: 1, count: total)
        guard total > 0, sampleRate > 0 else { return envelope }
        let attack = max(1, Int(duckAttackSeconds * sampleRate))
        let release = max(1, Int(duckReleaseSeconds * sampleRate))
        let hold = Int(duckHoldSeconds * sampleRate)
        let sorted = duckRanges
            .map { max(0, $0.lowerBound)...min(duration, $0.upperBound) }
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        for range in sorted {
            let start = Int((range.lowerBound * sampleRate).rounded())
            let end = min(total, Int((range.upperBound * sampleRate).rounded()))
            guard end > start else { continue }
            // 进入：线性压低。
            for index in start..<min(end, start + attack) {
                let progress = Float(index - start) / Float(attack)
                envelope[index] *= 1 - progress * (1 - target)
            }
            for index in min(end, start + attack)..<end {
                envelope[index] *= target
            }
            // 离开：hold 段保持压低，之后线性恢复；与下一段重叠时以较低值
            // 为准（乘法叠加自动满足），因此只需在不重叠时补恢复段。
            let holdEnd = min(total, end + max(0, hold))
            for index in end..<holdEnd {
                envelope[index] *= target
            }
            if holdEnd < total, !overlapsNext(range, sorted) {
                for index in holdEnd..<min(total, holdEnd + release) {
                    let progress = Float(index - holdEnd) / Float(release)
                    envelope[index] *= target + progress * (1 - target)
                }
            }
        }
        return envelope
    }

    private static func overlapsNext(
        _ range: ClosedRange<Double>,
        _ sorted: [ClosedRange<Double>]
    ) -> Bool {
        if let index = sorted.firstIndex(where: { $0 == range }),
           index + 1 < sorted.count
        {
            return sorted[index + 1].lowerBound
                <= range.upperBound + duckHoldSeconds
        }
        return false
    }

    // MARK: - 噪声门

    /// 每个声道一条 0...1 的门增益曲线；阈值跟随自适应噪声底
    /// （与精剪检测同族：受限上浮 / 下探）。开门快、关门慢 + hold，
    /// 保守压低不静音，保护人声起音。
    package static func gateEnvelopes(
        channels: [[Float]],
        sampleRate: Double
    ) -> [[Float]] {
        channels.map { samples in
            gateEnvelope(samples: samples, sampleRate: sampleRate)
        }
    }

    private static func gateEnvelope(
        samples: [Float],
        sampleRate: Double
    ) -> [Float] {
        let total = samples.count
        guard total > 0, sampleRate > 0 else { return [] }
        let window = max(1, Int(gateWindowSeconds * sampleRate))
        let hop = max(1, Int(gateHopSeconds * sampleRate))
        var frameCount = 0
        if total >= window {
            frameCount = (total - window) / hop + 1
        }
        guard frameCount > 0 else {
            return [Float](repeating: 1, count: total)
        }
        var energies = [Double](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let start = frame * hop
            var sum = 0.0
            for index in start..<(start + window) {
                let value = Double(samples[index])
                sum += value * value
            }
            energies[frame] = 10 * log10(max(sum / Double(window), 1e-12))
        }
        // 自适应噪声底：低分位初始化 + 受限上浮 / 下探（语音期间冻结）。
        let sorted = energies.sorted()
        var floorDB = sorted[max(0, Int((Double(frameCount - 1) * 0.1).rounded()))]
        let risePerFrame = gateFloorRiseDBPerSecond * Double(hop) / sampleRate
        let fallPerFrame = gateFloorFallDBPerSecond * Double(hop) / sampleRate
        var frameGains = [Float](repeating: 1, count: frameCount)
        var gateOpen = false
        var holdFrames = 0
        for frame in 0..<frameCount {
            let energy = energies[frame]
            if !gateOpen {
                if energy > floorDB + gateOpenMarginDB {
                    gateOpen = true
                    holdFrames = Int(gateHoldSeconds * sampleRate / Double(hop))
                }
            } else {
                if energy < floorDB + gateCloseMarginDB {
                    if holdFrames > 0 {
                        holdFrames -= 1
                    } else {
                        gateOpen = false
                    }
                } else {
                    holdFrames = Int(gateHoldSeconds * sampleRate / Double(hop))
                }
            }
            if !gateOpen {
                if energy < floorDB {
                    floorDB = max(energy, floorDB - fallPerFrame)
                } else {
                    floorDB = min(energy, floorDB + risePerFrame)
                }
            }
            frameGains[frame] = gateOpen ? 1 : Float(linearGain(-gateDepthDB))
        }
        // 帧增益 → 逐样本：开门快（attack），关门慢（release）。
        var envelope = [Float](repeating: 1, count: total)
        let attackSamples = max(1, Int(gateAttackSeconds * sampleRate))
        let releaseSamples = max(1, Int(gateReleaseSeconds * sampleRate))
        var current: Float = frameGains.first ?? 1
        var frame = 0
        var frameCursor = 0
        for index in 0..<total {
            if frame < frameCount && index >= frameCursor + hop {
                frameCursor += hop
                frame += 1
            }
            let targetGain = frame < frameCount ? frameGains[frame] : (frameGains.last ?? 1)
            if targetGain > current {
                let step = (1 - Float(linearGain(-gateDepthDB))) / Float(attackSamples)
                current = min(targetGain, current + step)
            } else if targetGain < current {
                let step = (1 - Float(linearGain(-gateDepthDB))) / Float(releaseSamples)
                current = max(targetGain, current - step)
            }
            envelope[index] = current
        }
        return envelope
    }

    // MARK: - 滤波与压缩

    private static func filtered(
        _ samples: [Float],
        filters: [Biquad],
        gate: [Float]? = nil,
        sampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var states = filters.map { _ in Biquad.State() }
        var output = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            var value = samples[index]
            for (filterIndex, filter) in filters.enumerated() {
                value = filter.apply(value, &states[filterIndex])
            }
            if let gate, index < gate.count {
                value *= gate[index]
            }
            output[index] = value
        }
        return output
    }

    /// 标准双二阶滤波器（RBJ cookbook 公式），每声道独立状态。
    package struct Biquad: Sendable {
        package struct State {
            var x1 = 0.0
            var x2 = 0.0
            var y1 = 0.0
            var y2 = 0.0
        }

        package let b0: Double
        package let b1: Double
        package let b2: Double
        package let a1: Double
        package let a2: Double

        package static func highPass(
            sampleRate: Double,
            frequency: Double
        ) -> Biquad {
            let omega = 2 * .pi * frequency / sampleRate
            let cosine = cos(omega)
            let alpha = sin(omega) / (2 * 0.707_113_562_438_127_8)
            let a0 = 1 + alpha
            return Biquad(
                b0: ((1 + cosine) / 2) / a0,
                b1: (-(1 + cosine)) / a0,
                b2: ((1 + cosine) / 2) / a0,
                a1: (-2 * cosine) / a0,
                a2: (1 - alpha) / a0
            )
        }

        package static func peaking(
            sampleRate: Double,
            frequency: Double,
            q: Double,
            gainDB: Double
        ) -> Biquad {
            let a = pow(10, gainDB / 40)
            let omega = 2 * .pi * frequency / sampleRate
            let cosine = cos(omega)
            let alpha = sin(omega) / (2 * max(0.1, q))
            let a0 = 1 + alpha / a
            return Biquad(
                b0: (1 + alpha * a) / a0,
                b1: (-2 * cosine) / a0,
                b2: (1 - alpha * a) / a0,
                a1: (-2 * cosine) / a0,
                a2: (1 - alpha / a) / a0
            )
        }

        package func apply(_ input: Float, _ state: inout State) -> Float {
            let x = Double(input)
            let y = b0 * x + b1 * state.x1 + b2 * state.x2
                - a1 * state.y1 - a2 * state.y2
            state.x2 = state.x1
            state.x1 = x
            state.y2 = state.y1
            state.y1 = y
            return Float(y)
        }
    }

    /// 轻量压缩器：软膝静态曲线 + 包络跟随（固定保守参数，无 makeup）。
    package struct Compressor: Sendable {
        private let attackCoefficient: Double
        private let releaseCoefficient: Double

        package init(sampleRate: Double) {
            guard sampleRate > 0 else {
                attackCoefficient = 0
                releaseCoefficient = 0
                return
            }
            attackCoefficient = exp(-1 / (compressorAttackSeconds * sampleRate))
            releaseCoefficient = exp(-1 / (compressorReleaseSeconds * sampleRate))
        }

        /// 静态增益曲线（dB → dB）：低于阈值不动；膝内平滑；膝上按比例压缩。
        package func outputGainDB(inputDB: Double) -> Double {
            let threshold = compressorThresholdDB
            let knee = compressorKneeDB
            let kneeStart = threshold - knee / 2
            guard inputDB > kneeStart else { return 0 }
            if inputDB < threshold + knee / 2 {
                // 软膝：二次插值到全压缩段。
                let x = inputDB - kneeStart
                let slope = 1 / compressorRatio - 1
                return slope * x * x / (2 * knee)
            }
            let over = inputDB - threshold
            return over * (1 / compressorRatio - 1)
        }

        package func apply(_ samples: [Float]) -> [Float] {
            guard !samples.isEmpty else { return samples }
            var output = [Float](repeating: 0, count: samples.count)
            var envelope = -60.0
            for index in samples.indices {
                let inputDB = 20 * log10(max(abs(Double(samples[index])), 1e-7))
                let coefficient = inputDB > envelope
                    ? attackCoefficient
                    : releaseCoefficient
                envelope = coefficient * envelope
                    + (1 - coefficient) * inputDB
                let gain = linearGain(outputGainDB(inputDB: envelope))
                output[index] = samples[index] * Float(gain)
            }
            return output
        }
    }

    // MARK: - K 加权

    /// BS.1770 K 加权：固定 48 kHz 系数的高架 + 高通两段。其他采样率
    /// 直接套用（近似声明见 `AudioEnhanceSettings` 文档）。
    private static func kWeight(
        _ samples: [Float],
        sampleRate: Double
    ) -> [Float] {
        _ = sampleRate // 系数为 48 kHz 标准值；保留参数以标明意图。
        let stage1 = Biquad(
            b0: 1.535_124_859_586_97,
            b1: -2.691_696_189_406_38,
            b2: 1.198_392_810_852_85,
            a1: -1.690_659_293_182_41,
            a2: 0.732_480_774_215_85
        )
        let stage2 = Biquad(
            b0: 1.0,
            b1: -2.0,
            b2: 1.0,
            a1: -1.990_047_454_833_98,
            a2: 0.990_072_250_366_21
        )
        var state1 = Biquad.State()
        var state2 = Biquad.State()
        var output = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            let first = stage1.apply(samples[index], &state1)
            output[index] = stage2.apply(first, &state2)
        }
        return output
    }

    // MARK: - 私有辅助

    private static func mixdown(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        var mono = [Float](repeating: 0, count: first.count)
        for channel in channels {
            for index in mono.indices where index < channel.count {
                mono[index] += channel[index]
            }
        }
        let scale = 1.0 / Float(channels.count)
        for index in mono.indices {
            mono[index] *= scale
        }
        return mono
    }

    static func linearGain(_ db: Double) -> Double {
        pow(10, db / 20)
    }
}
