import XCTest
@testable import AniseRecorderCore

/// 1.2 音频一键优化纯逻辑测试。合成素材覆盖路线图要求的五种区段：
/// 安静段、正常口播、大声段、人声与系统声重叠段、低频噪声段。
/// 期望数值基于 `AudioEnhancer` 集中定义的固定参数，调参需同步更新。
final class AudioProcessingTests: XCTestCase {
    // MARK: 合成素材

    private enum Fixture {
        static let sampleRate = 48_000.0
        /// 正常口播 ≈ -20 dBFS 正弦 + 幅度调制，模拟语音能量起伏。
        static let normalSpeechAmplitude: Float = 0.1
        /// 大声段 ≈ -4 dBFS。
        static let loudSpeechAmplitude: Float = 0.63
        /// 低水平底噪。
        static let noiseAmplitude: Float = 0.0015
        /// 低频哼声 60 Hz（降噪高通目标）。
        static let humAmplitude: Float = 0.05
    }

    /// 确定性合成：正弦相位连续，静音为零，噪声用固定伪随机。
    private func samples(
        segments: [(duration: Double, kind: SegmentKind)]
    ) -> [Float] {
        var output: [Float] = []
        var phase: Double = 0
        var seed = 0x9E3779B9
        func nextNoise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(truncatingIfNeeded: seed >> 16))
                / Float(Int32.max)
        }
        for segment in segments {
            let count = Int(segment.duration * Fixture.sampleRate)
            for _ in 0..<count {
                switch segment.kind {
                case .speech(let amplitude):
                    phase += 2 * .pi * 220 / Fixture.sampleRate
                    let envelope = 0.6 + 0.4 * sin(phase / 19)
                    output.append(
                        amplitude * Float(envelope * sin(phase))
                    )
                case .noise:
                    output.append(Fixture.noiseAmplitude * nextNoise())
                case .hum:
                    phase += 2 * .pi * 60 / Fixture.sampleRate
                    output.append(
                        Fixture.humAmplitude * Float(sin(phase))
                            + Fixture.noiseAmplitude * nextNoise()
                    )
                case .silence:
                    output.append(Fixture.noiseAmplitude * nextNoise())
                }
            }
        }
        return output
    }

    private enum SegmentKind {
        case speech(Float)
        case noise
        case hum
        case silence
    }

    /// 检核素材：安静 0–1s，正常口播 1–3s，大声 3–4s，低频哼声 4–5s。
    private func voiceFixture() -> [Float] {
        samples(segments: [
            (1.0, .silence),
            (2.0, .speech(Fixture.normalSpeechAmplitude)),
            (1.0, .speech(Fixture.loudSpeechAmplitude)),
            (1.0, .hum)
        ])
    }

    /// 系统声 fixture：只在 1.5–2.5 秒与口播重叠。
    private func systemFixture() -> [Float] {
        var segments: [(Double, SegmentKind)] = [(1.5, .silence)]
        segments.append((1.0, .speech(0.08)))
        segments.append((2.5, .silence))
        return samples(segments: segments)
    }

    private func rmsDB(_ samples: [Float], range: ClosedRange<Double>) -> Double {
        let start = Int(range.lowerBound * Fixture.sampleRate)
        let end = min(samples.count, Int(range.upperBound * Fixture.sampleRate))
        guard end > start else { return -200 }
        var sum = 0.0
        for sample in samples[start..<end] {
            sum += Double(sample) * Double(sample)
        }
        return 10 * log10(max(sum / Double(end - start), 1e-12))
    }

    // MARK: 自动电平

    func testAutoLevelGainClampsToTwelveDB() {
        // 极安静素材（-60 dBFS 级别）建议 +12 dB 封顶。
        let quiet = samples(segments: [(1.0, .noise)])
        let quietGain = AudioEnhancer.autoLevelGain(
            currentLoudness: -38,
            peakDB: AudioEnhancer.samplePeakDB(samples: quiet)
        )
        XCTAssertEqual(quietGain, 12, accuracy: 0.001)

        // 极响素材建议 -12 dB 封底。
        XCTAssertEqual(
            AudioEnhancer.autoLevelGain(currentLoudness: 5, peakDB: -0.5),
            -12,
            accuracy: 0.001
        )
    }

    func testAutoLevelGainReservesPeakHeadroom() {
        // 峰值已经贴 0 dBFS 时，即使响度远低于目标也不能超过 -1 dBFS 预留。
        let gain = AudioEnhancer.autoLevelGain(
            currentLoudness: -26,
            peakDB: -2.5
        )
        XCTAssertLessThanOrEqual(gain, 1.5)
        XCTAssertGreaterThanOrEqual(gain, 0.5)
    }

    func testAutoLevelConvergesTowardTargetLoudness() {
        let original = voiceFixture()
        let loudness = AudioEnhancer.integratedLoudness(
            samples: original,
            sampleRate: Fixture.sampleRate
        )
        guard let loudness else {
            return XCTFail("合成素材应可测得响度")
        }
        let peak = AudioEnhancer.samplePeakDB(samples: original)
        var settings = AudioEnhanceSettings()
        settings.autoLevelEnabled = true
        settings.autoLevelGainDB = AudioEnhancer.autoLevelGain(
            currentLoudness: loudness,
            peakDB: peak
        )
        let result = AudioEnhancer.process(
            channels: [original],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )
        guard let processedLoudness = result.loudness else {
            return XCTFail("处理后应可测得响度")
        }
        // 响度向 -14 收敛（K 加权近似容差 ±2 LU；门限非线性导致非精确）。
        XCTAssertEqual(
            processedLoudness,
            AudioEnhancer.targetLoudness,
            accuracy: 2.0
        )
        // 峰值必须 ≤ -1 dBFS。
        XCTAssertLessThanOrEqual(result.peakDB, AudioEnhancer.peakCeiling + 1e-6)
    }

    // MARK: 人声增强

    func testPresenceBoostRaisesMidbandEnergy() {
        // 3.5 kHz 单频（-30 dBFS，低于压缩膝起点，隔离 EQ 效应）：
        // 增强后能量应提升约 +2 dB（±1 dB）。
        var phase = 0.0
        let tone: [Float] = (0..<Int(Fixture.sampleRate)).map { _ in
            phase += 2 * .pi * 3500 / Fixture.sampleRate
            return Float(0.03 * sin(phase))
        }
        var settings = AudioEnhanceSettings()
        settings.voiceEnhanceEnabled = true
        let result = AudioEnhancer.process(
            channels: [tone],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )
        let before = rmsDB(tone, range: 0.1...0.9)
        let after = rmsDB(result.channels[0], range: 0.1...0.9)
        XCTAssertEqual(after - before, 2.0, accuracy: 1.0)
    }

    func testCompressorReducesDynamicRange() {
        // 大声段（≈ -0.5 dBFS 峰值）被压缩后与正常段的有效电平差应缩小；
        // 正常段取 -24 dBFS 阈值之下（膝外），几乎不被压缩。
        var settings = AudioEnhanceSettings()
        settings.voiceEnhanceEnabled = true
        let loud = samples(segments: [(1.0, .speech(0.95))])
        let normal = samples(segments: [(1.0, .speech(0.06))])
        let compressedLoud = AudioEnhancer.Compressor(sampleRate: Fixture.sampleRate)
            .apply(loud)
        let compressedNormal = AudioEnhancer.Compressor(sampleRate: Fixture.sampleRate)
            .apply(normal)
        let loudReduction = rmsDB(loud, range: 0.1...0.9)
            - rmsDB(compressedLoud, range: 0.1...0.9)
        let normalReduction = rmsDB(normal, range: 0.1...0.9)
            - rmsDB(compressedNormal, range: 0.1...0.9)
        // 大声段被压得更多，动态范围缩小。
        XCTAssertGreaterThan(loudReduction, normalReduction + 1.0)
        XCTAssertGreaterThan(loudReduction, 1.5)
        // 阈值之下的正常口播几乎不动（保守：不伤常态语音）。
        XCTAssertLessThan(abs(normalReduction), 1.0)
    }

    // MARK: Ducking

    func testDuckEnvelopeBoundaries() {
        let amount = 6.0
        let target = Float(pow(10, -amount / 20))

        // 全静音：无区间 → 恒 1。
        let silent = AudioEnhancer.duckEnvelope(
            duckRanges: [],
            sampleRate: Fixture.sampleRate,
            duration: 2,
            amountDB: amount
        )
        XCTAssertEqual(silent.count, Int(2 * Fixture.sampleRate))
        XCTAssertTrue(silent.allSatisfy { abs($0 - 1) < 1e-6 })

        // 全程人声：攻击段后恒定压低。
        let full = AudioEnhancer.duckEnvelope(
            duckRanges: [0...2],
            sampleRate: Fixture.sampleRate,
            duration: 2,
            amountDB: amount
        )
        let lateDuck = full[Int(1.5 * Fixture.sampleRate)]
        XCTAssertEqual(lateDuck, target, accuracy: 0.001)

        // 区间结束 + hold + release 之后恢复到 1。
        let burst = AudioEnhancer.duckEnvelope(
            duckRanges: [1...1.5],
            sampleRate: Fixture.sampleRate,
            duration: 3,
            amountDB: amount
        )
        let during = burst[Int(1.2 * Fixture.sampleRate)]
        XCTAssertEqual(during, target, accuracy: 0.01)
        let afterRelease = burst[Int(2.5 * Fixture.sampleRate)]
        XCTAssertEqual(afterRelease, 1, accuracy: 0.01)
        // hold 期间尚未恢复。
        let duringHold = burst[Int(1.55 * Fixture.sampleRate)]
        XCTAssertEqual(duringHold, target, accuracy: 0.02)
    }

    func testDuckingWidensLevelGapInOverlap() {
        // 完整链：人声 1–3s，系统声 1.5–2.5s 重叠。处理后重叠段
        // 系统声相对人声电平差应至少扩大 duckingAmountDB - 1.5 dB。
        let voice = voiceFixture()
        let system = systemFixture()
        var settings = AudioEnhanceSettings()
        settings.duckingEnabled = true
        settings.duckingAmountDB = 6
        let result = AudioEnhancer.process(
            channels: [system],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .system,
            duckRanges: [1.0...3.0]
        )
        let beforeGap = rmsDB(system, range: 1.5...2.5)
            - rmsDB(voice, range: 1.5...2.5)
        let afterGap = rmsDB(result.channels[0], range: 1.5...2.5)
            - rmsDB(voice, range: 1.5...2.5)
        XCTAssertLessThanOrEqual(
            afterGap,
            beforeGap - 6.0 + 1.5,
            "重叠段系统声相对电平应被压低约 6 dB"
        )
        // 非重叠段系统声不变（完全在 ducking 起点之前）。
        XCTAssertEqual(
            rmsDB(result.channels[0], range: 0.1...0.9),
            rmsDB(system, range: 0.1...0.9),
            accuracy: 0.1
        )
    }

    // MARK: 降噪

    func testNoiseGateAttenuatesNoiseAndKeepsOnset() {
        var settings = AudioEnhanceSettings()
        settings.noiseReductionEnabled = true
        let original = voiceFixture()
        let result = AudioEnhancer.process(
            channels: [original],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )

        // 安静段（0–1s，含 60 Hz 之外的底噪）被压低 ≥ 6 dB（门深 -12，
        // 底噪贴近门限，保守断言 6 dB）。
        let noiseBefore = rmsDB(original, range: 0.05...0.95)
        let noiseAfter = rmsDB(result.channels[0], range: 0.05...0.95)
        XCTAssertLessThanOrEqual(
            noiseAfter,
            noiseBefore - 6.0,
            "噪声段应被噪声门压低"
        )

        // 口播起音（1.0 s）不被切：起音后 50 ms 能量保留 ≥ 85%。
        let onset = 1.0
        let beforeEnergy = energy(original, from: onset, seconds: 0.05)
        let afterEnergy = energy(result.channels[0], from: onset, seconds: 0.05)
        XCTAssertGreaterThanOrEqual(
            afterEnergy / max(beforeEnergy, 1e-12),
            0.85,
            "人声起音 50 ms 能量必须保留"
        )

        // 60 Hz 哼声段（4–5s）：门不关（哼声高于门限），但 80 Hz 高通
        // 二阶巴特沃斯对 60 Hz 约有 -6 dB 衰减，断言 ≥ 4.5 dB。
        let humBefore = rmsDB(original, range: 4.05...4.95)
        let humAfter = rmsDB(result.channels[0], range: 4.05...4.95)
        XCTAssertLessThanOrEqual(humAfter, humBefore - 4.5)
    }

    func testGateThresholdFollowsNoiseFloor() {
        // 语音段之后底噪更低的尾部：关门阈值应跟随噪声底，
        // 语音结束并超过 hold 后尾部静音重新被压低。
        var segments: [(Double, SegmentKind)] = [(1.0, .noise)]
        segments.append((1.0, .speech(0.05)))
        segments.append((1.0, .noise))
        let material = samples(segments: segments)
        var settings = AudioEnhanceSettings()
        settings.noiseReductionEnabled = true
        let result = AudioEnhancer.process(
            channels: [material],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )
        let tailBefore = rmsDB(material, range: 2.05...2.95)
        let tailAfter = rmsDB(result.channels[0], range: 2.05...2.95)
        XCTAssertLessThanOrEqual(tailAfter, tailBefore - 6.0)
    }

    // MARK: 组合与确定性

    func testFullChainDeterministicAndPeakSafe() {
        let voice = voiceFixture()
        var settings = AudioEnhanceSettings()
        settings.autoLevelEnabled = true
        settings.autoLevelGainDB = 4
        settings.voiceEnhanceEnabled = true
        settings.noiseReductionEnabled = true
        let first = AudioEnhancer.process(
            channels: [voice],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )
        let second = AudioEnhancer.process(
            channels: [voice],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )
        XCTAssertEqual(first.channels[0], second.channels[0])
        XCTAssertLessThanOrEqual(first.peakDB, AudioEnhancer.peakCeiling + 1e-6)
    }

    func testEmptyAndDegenerateInputs() {
        var settings = AudioEnhanceSettings()
        settings.autoLevelEnabled = true
        settings.autoLevelGainDB = 6
        let empty = AudioEnhancer.process(
            channels: [],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )
        XCTAssertTrue(empty.channels.isEmpty)

        let silent = AudioEnhancer.process(
            channels: [[Float](repeating: 0, count: 48_000)],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .voice
        )
        XCTAssertEqual(silent.channels[0].count, 48_000)
        XCTAssertNil(silent.loudness)
    }

    func testDuckingWithoutRangesLeavesSystemUntouched() {
        var settings = AudioEnhanceSettings()
        settings.duckingEnabled = true
        settings.duckingAmountDB = 6
        let system = systemFixture()
        let result = AudioEnhancer.process(
            channels: [system],
            sampleRate: Fixture.sampleRate,
            settings: settings,
            role: .system,
            duckRanges: []
        )
        XCTAssertEqual(result.channels[0], system)
    }

    // MARK: 成片时间 → 源时间映射

    func testSourceRangesForOutputRangeAcrossSpeeds() {
        let timeline = ProjectTimeline(clips: [
            TimelineClip(sourceStart: 0, sourceEnd: 4, playbackRate: 1),
            TimelineClip(sourceStart: 10, sourceEnd: 14, playbackRate: 2)
        ])
        // 第一段输出 0–4 对应源 0–4。
        let head = timeline.sourceRanges(forOutputRange: 0...2)
        XCTAssertEqual(head.count, 1)
        XCTAssertEqual(head[0], 0.0...2.0)
        // 跨两段：输出 3–5 → 源 3–4（1x）+ 10–12（2x 下输出 1 秒 = 源 2 秒）。
        let ranges = timeline.sourceRanges(forOutputRange: 3...5)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 3, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].upperBound, 4, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].lowerBound, 10, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].upperBound, 12, accuracy: 1e-9)
        // 空区间与超界区间安全降级。
        XCTAssertTrue(timeline.sourceRanges(forOutputRange: 2...2).isEmpty)
        XCTAssertEqual(
            timeline.sourceRanges(forOutputRange: -1...2).count,
            1
        )
    }

    // MARK: 私有辅助

    private func energy(
        _ samples: [Float],
        from time: Double,
        seconds: Double
    ) -> Double {
        let start = Int(time * Fixture.sampleRate)
        let end = min(samples.count, start + Int(seconds * Fixture.sampleRate))
        guard end > start else { return 0 }
        var sum = 0.0
        for sample in samples[start..<end] {
            sum += Double(sample) * Double(sample)
        }
        return sum
    }
}
