import Foundation

/// 一段连续的语音活动区间，时间为当前工程成片时间，单位秒。
///
/// 纯逻辑类型之一：只携带数值，不依赖
/// AVFoundation、AppKit 或 SwiftUI。文件读取与任务调度属于应用层的
/// `SmartCutAnalyzer`，不在这里。
package struct SpeechActivity: Hashable, Sendable {
    package var start: Double
    package var end: Double

    package init(start: Double, end: Double) {
        let lower = start.isFinite ? max(0, start) : 0
        self.start = lower
        self.end = end.isFinite ? max(lower, end) : lower
    }

    package var duration: Double {
        end - start
    }
}

/// 精剪候选的两种预设节奏。阈值使用下方常量的默认起始值
/// （取区间中点），集中在这里定义，UI 与分析器都从这里读取，不得各写一份。
package enum SmartCutMode: String, CaseIterable, Sendable, Codable {
    /// 自然：默认，保留口播节奏。
    case natural
    /// 紧凑：短视频或节奏较快的教程。
    case compact

    /// 成为候选的最小停顿长度（秒）。
    package var minimumPauseDuration: Double {
        switch self {
        case .natural: 0.8
        case .compact: 0.4
        }
    }

    /// 候选两侧向人声保留的安全余量（秒）。
    package var keepEachSide: Double {
        switch self {
        case .natural: 0.25
        case .compact: 0.125
        }
    }

    /// 纯人声间隙短于该时长时按“短气口”分类；1.1 不做语义级呼吸分类。
    package static let shortBreathCeiling = 1.0
}

package enum SmartCutCandidateKind: Hashable, Sendable {
    /// 纯说话停顿：只有人声缺失，画面操作和系统声音都不明显，默认勾选。
    case pureSpeechPause
    /// 短气口：两段连续语音之间的低能量短间隙，只缩短不为零，默认勾选。
    case shortBreath
    /// 有屏幕操作：停顿期间有点击、明显光标移动或窗口切换，默认不勾选。
    case hasScreenActivity
    /// 有系统声音：停顿期间系统音轨仍活跃，默认不勾选。
    case hasSystemSound
    /// 口头禅 / 填充词：整条字幕就是填充词，默认勾选。
    case fillerWord
    /// 重复句 / 重说：短窗口内重复或放弃重开，默认保留最后一遍。
    case repeatedTake

    package var isProtected: Bool {
        self == .hasScreenActivity || self == .hasSystemSound
    }

    package var isDefaultSelected: Bool {
        !isProtected
    }
}

/// 一个停顿 / 气口候选。`start...end` 是检测到的停顿区间，`cutStart...cutEnd`
/// 是建议删除的中间部分（两侧保留安全余量）。时间均为成片时间，单位秒。
/// 候选是临时数据，不写入 `project.json`（路线图 8.3）。
package struct SmartCutCandidate: Hashable, Sendable {
    package var start: Double
    package var end: Double
    package var cutStart: Double
    package var cutEnd: Double
    package var kind: SmartCutCandidateKind

    package init(
        start: Double,
        end: Double,
        kind: SmartCutCandidateKind,
        keepEachSide: Double
    ) {
        let lower = start.isFinite ? max(0, start) : 0
        let upper = end.isFinite ? max(lower, end) : lower
        self.start = lower
        self.end = upper
        let keep = keepEachSide.isFinite ? max(0, keepEachSide) : 0
        self.cutStart = min(upper, lower + keep)
        self.cutEnd = max(lower, upper - keep)
        self.kind = kind
    }

    package var pauseDuration: Double {
        end - start
    }

    package var savedDuration: Double {
        max(0, cutEnd - cutStart)
    }

    package var isDefaultSelected: Bool {
        kind.isDefaultSelected
    }
}

/// 一次精剪扫描的纯逻辑结果。
package struct SmartCutAnalysis: Hashable, Sendable {
    package var mode: SmartCutMode
    package var analyzedDuration: Double
    package var speechActivity: [SpeechActivity]
    package var candidates: [SmartCutCandidate]

    /// 默认勾选（建议删除）的候选数量。
    package var recommendedCandidateCount: Int {
        candidates.filter(\.isDefaultSelected).count
    }

    /// 默认勾选候选合计的预计节省时长（秒）。
    package var estimatedSavedDuration: Double {
        candidates.filter(\.isDefaultSelected).reduce(0) { $0 + $1.savedDuration }
    }
}

/// PCM 语音活动检测参数的推荐起始值。
package struct SmartCutDetectionSettings: Hashable, Sendable {
    /// 分析窗长度（秒）。
    package var windowDuration = 0.02
    /// 分析窗步进（秒）。
    package var hopDuration = 0.01
    /// 语音结束后保持活动的时间（秒），防止词尾被误判为静音。
    package var hangoverDuration = 0.15
    /// 帧能量高于噪声底多少 dB 判定为语音。
    package var speechMarginDb = 10.0
    /// 噪声底在无活动帧上每秒上浮的 dB 数；下探受下方速率限制。
    package var noiseFloorRiseDbPerSecond = 0.5
    /// 噪声底每秒允许下探的最大 dB 数。限制短促数字静音 / 掉包立即把
    /// 噪声底拉到极低值，导致随后的正常底噪被误判成连续语音。
    package var noiseFloorFallDbPerSecond = 30.0

    package static let standard = Self()
}

/// 基于帧能量与自适应噪声底的语音活动检测：PCM 样本进，成片时间语音区间出。
package enum SmartCutActivityDetector {
    package static func detectSpeechActivity(
        in samples: [Float],
        sampleRate: Double,
        settings: SmartCutDetectionSettings = .standard
    ) -> [SpeechActivity] {
        guard sampleRate > 0, sampleRate.isFinite, !samples.isEmpty else { return [] }
        let windowSamples = max(1, Int((settings.windowDuration * sampleRate).rounded()))
        let hopSamples = max(1, Int((settings.hopDuration * sampleRate).rounded()))
        let frameCount = (samples.count - windowSamples) / hopSamples + 1
        guard frameCount > 0 else { return [] }

        var energies = [Double](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let start = frame * hopSamples
            var sum = 0.0
            for index in start..<(start + windowSamples) {
                let value = Double(samples[index])
                sum += value * value
            }
            let rms = (sum / Double(windowSamples)).squareRoot()
            energies[frame] = 20 * log10(max(rms, 1e-7))
        }

        // 噪声底：用低分位能量初始化，避开文件头数字静音把噪声底拉到
        // -140 dB（否则之后正常底噪会被整段误判为语音）。运行时遇更低
        // 能量受限下探，无活动帧上缓慢上浮；语音期间冻结，避免连续说话
        // 把噪声底抬到语音能量附近。
        let sortedEnergies = energies.sorted()
        let floorSeedIndex = Int(
            (Double(sortedEnergies.count - 1) * 0.1).rounded()
        )
        var floorDb = sortedEnergies[max(0, floorSeedIndex)]
        let risePerFrame = settings.noiseFloorRiseDbPerSecond * Double(hopSamples) / sampleRate
        let fallPerFrame = settings.noiseFloorFallDbPerSecond
            * Double(hopSamples) / sampleRate
        var active = [Bool](repeating: false, count: frameCount)
        for frame in 0..<frameCount {
            let energy = energies[frame]
            let isActive = energy > floorDb + settings.speechMarginDb
            active[frame] = isActive
            if !isActive {
                if energy < floorDb {
                    floorDb = max(energy, floorDb - fallPerFrame)
                } else {
                    floorDb = min(energy, floorDb + risePerFrame)
                }
            }
        }

        // 连续活动帧合并成区间；语音结尾追加 hangover，重叠或相接的区间再合并。
        var activities: [SpeechActivity] = []
        var frame = 0
        while frame < frameCount {
            guard active[frame] else {
                frame += 1
                continue
            }
            var lastLoud = frame
            while lastLoud + 1 < frameCount, active[lastLoud + 1] {
                lastLoud += 1
            }
            let start = Double(frame * hopSamples) / sampleRate
            let stop = Double(lastLoud * hopSamples + windowSamples) / sampleRate
                + settings.hangoverDuration
            if let last = activities.last, start <= last.end {
                activities[activities.count - 1].end = max(last.end, stop)
            } else {
                activities.append(SpeechActivity(start: start, end: stop))
            }
            frame = lastLoud + 1
        }
        return activities
    }
}

/// 精剪候选引擎的纯逻辑入口：语音活动 + 保护区间 → 候选，以及候选的统一
/// 排序、合并和最小长度裁剪。剪切事务本身在应用层实现。
package enum SmartCutEngine {
    /// 对固定音频执行完整分析：活动检测 + 候选生成 + 合并。相同输入必须
    /// 产出完全相同的结果。
    package static func analyze(
        samples: [Float],
        sampleRate: Double,
        mode: SmartCutMode,
        screenActivity: [ClosedRange<Double>] = [],
        systemSound: [ClosedRange<Double>] = [],
        settings: SmartCutDetectionSettings = .standard
    ) -> SmartCutAnalysis {
        let activity = SmartCutActivityDetector.detectSpeechActivity(
            in: samples,
            sampleRate: sampleRate,
            settings: settings
        )
        let duration = sampleRate > 0 && sampleRate.isFinite
            ? Double(samples.count) / sampleRate
            : 0
        return SmartCutAnalysis(
            mode: mode,
            analyzedDuration: duration,
            speechActivity: activity,
            candidates: mergedCandidates(
                makeCandidates(
                    speechActivity: activity,
                    analyzedDuration: duration,
                    mode: mode,
                    screenActivity: screenActivity,
                    systemSound: systemSound
                ),
                mode: mode
            )
        )
    }

    /// 从语音活动区间生成候选。与屏幕操作 / 系统声音重叠的部分按保护类
    /// 候选拆出并精确标注范围，只推荐真正空闲的部分；一个长间隙因此可能
    /// 拆成多个候选。
    package static func makeCandidates(
        speechActivity: [SpeechActivity],
        analyzedDuration: Double,
        mode: SmartCutMode,
        screenActivity: [ClosedRange<Double>] = [],
        systemSound: [ClosedRange<Double>] = []
    ) -> [SmartCutCandidate] {
        let duration = analyzedDuration.isFinite ? max(0, analyzedDuration) : 0
        guard duration > 0 else { return [] }
        // 没有可识别语音时，不把整条音轨当作一个停顿。否则持续音、房间
        // 噪声或 VAD 失手都会生成“删除全片”的危险候选。
        let speech = mergedSpeech(speechActivity, within: duration)
        guard !speech.isEmpty else { return [] }
        let pauses = pauses(
            outside: speech,
            duration: duration
        )
        guard !pauses.isEmpty else { return [] }
        let protected = mergedRanges(screenActivity + systemSound, within: duration)

        var candidates: [SmartCutCandidate] = []
        for pause in pauses {
            var cursor = pause.lowerBound
            for range in protected {
                let overlapStart = max(cursor, range.lowerBound)
                let overlapEnd = min(pause.upperBound, range.upperBound)
                guard overlapEnd > overlapStart else { continue }
                if overlapStart > cursor {
                    appendIdleCandidate(
                        cursor...overlapStart,
                        to: &candidates,
                        mode: mode
                    )
                }
                appendProtectedCandidate(
                    overlapStart...overlapEnd,
                    to: &candidates,
                    mode: mode,
                    screenActivity: screenActivity,
                    systemSound: systemSound
                )
                cursor = max(cursor, overlapEnd)
                if cursor >= pause.upperBound { break }
            }
            if cursor < pause.upperBound {
                appendIdleCandidate(cursor...pause.upperBound, to: &candidates, mode: mode)
            }
        }
        return candidates
    }

    /// 统一排序、合并重叠候选并按模式重算删除窗口与最小长度。仅严格重叠的
    /// 候选会合并；相邻不重叠的候选保持独立，因为它们往往分别对应“空闲”
    /// 和“有操作”两类区间。
    package static func mergedCandidates(
        _ candidates: [SmartCutCandidate],
        mode: SmartCutMode
    ) -> [SmartCutCandidate] {
        let sorted = candidates
            .filter { $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        var merged: [SmartCutCandidate] = []
        for candidate in sorted {
            if let last = merged.last, candidate.start < last.end {
                let end = max(last.end, candidate.end)
                merged[merged.count - 1] = SmartCutCandidate(
                    start: last.start,
                    end: end,
                    kind: strictestKind(last.kind, candidate.kind, pauseDuration: end - last.start),
                    keepEachSide: mode.keepEachSide
                )
            } else {
                merged.append(candidate)
            }
        }
        return merged.filter {
            isAtLeastMinimum($0.pauseDuration, mode: mode)
                && $0.cutEnd > $0.cutStart
        }
    }

    // MARK: - 私有辅助

    /// 语音区间之外的间隙，即停顿候选的来源区间。
    private static func pauses(
        outside speech: [SpeechActivity],
        duration: Double
    ) -> [ClosedRange<Double>] {
        var pauses: [ClosedRange<Double>] = []
        var cursor = 0.0
        for activity in speech {
            if activity.start > cursor {
                pauses.append(cursor...activity.start)
            }
            cursor = max(cursor, activity.end)
            if cursor >= duration { break }
        }
        if cursor < duration {
            pauses.append(cursor...duration)
        }
        return pauses.filter { $0.upperBound > $0.lowerBound }
    }

    /// 最小长度比较容忍 1e-9 的浮点噪声，避免恰好在阈值上的停顿被丢掉。
    private static func isAtLeastMinimum(
        _ duration: Double,
        mode: SmartCutMode
    ) -> Bool {
        duration >= mode.minimumPauseDuration - 1e-9
    }

    private static func appendIdleCandidate(
        _ range: ClosedRange<Double>,
        to candidates: inout [SmartCutCandidate],
        mode: SmartCutMode
    ) {
        guard isAtLeastMinimum(
            range.upperBound - range.lowerBound,
            mode: mode
        ) else { return }
        let kind: SmartCutCandidateKind = range.upperBound - range.lowerBound
            < SmartCutMode.shortBreathCeiling ? .shortBreath : .pureSpeechPause
        candidates.append(
            SmartCutCandidate(
                start: range.lowerBound,
                end: range.upperBound,
                kind: kind,
                keepEachSide: mode.keepEachSide
            )
        )
    }

    private static func appendProtectedCandidate(
        _ range: ClosedRange<Double>,
        to candidates: inout [SmartCutCandidate],
        mode: SmartCutMode,
        screenActivity: [ClosedRange<Double>],
        systemSound: [ClosedRange<Double>]
    ) {
        guard isAtLeastMinimum(
            range.upperBound - range.lowerBound,
            mode: mode
        ) else { return }
        // 同时存在系统声音与屏幕操作时优先标注系统声音：删除该段会切掉正在
        // 播放的声音，是更强的保护原因。
        let kind: SmartCutCandidateKind = overlaps(range, systemSound)
            ? .hasSystemSound
            : .hasScreenActivity
        candidates.append(
            SmartCutCandidate(
                start: range.lowerBound,
                end: range.upperBound,
                kind: kind,
                keepEachSide: mode.keepEachSide
            )
        )
    }

    private static func overlaps(
        _ range: ClosedRange<Double>,
        _ others: [ClosedRange<Double>]
    ) -> Bool {
        others.contains {
            $0.upperBound > range.lowerBound && $0.lowerBound < range.upperBound
        }
    }

    private static func strictestKind(
        _ first: SmartCutCandidateKind,
        _ second: SmartCutCandidateKind,
        pauseDuration: Double
    ) -> SmartCutCandidateKind {
        if first == .hasSystemSound || second == .hasSystemSound { return .hasSystemSound }
        if first == .hasScreenActivity || second == .hasScreenActivity { return .hasScreenActivity }
        return pauseDuration < SmartCutMode.shortBreathCeiling ? .shortBreath : .pureSpeechPause
    }

    /// 裁剪到分析时长内、按时间排序并合并重叠或相接的语音区间。
    private static func mergedSpeech(
        _ activities: [SpeechActivity],
        within duration: Double
    ) -> [SpeechActivity] {
        var clamped: [SpeechActivity] = []
        for activity in activities {
            let start = max(0, activity.start)
            let end = min(duration, activity.end)
            if end > start {
                clamped.append(SpeechActivity(start: start, end: end))
            }
        }
        clamped.sort {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var merged: [SpeechActivity] = []
        for activity in clamped {
            if let last = merged.last, activity.start <= last.end {
                merged[merged.count - 1].end = max(last.end, activity.end)
            } else {
                merged.append(activity)
            }
        }
        return merged
    }

    /// 屏幕操作与系统声音区间合并成一张保护区间表，相接的区间视为同一保护区。
    private static func mergedRanges(
        _ ranges: [ClosedRange<Double>],
        within duration: Double
    ) -> [ClosedRange<Double>] {
        var clamped: [ClosedRange<Double>] = []
        for range in ranges {
            let lower = max(0, range.lowerBound)
            let upper = min(duration, range.upperBound)
            if upper > lower {
                clamped.append(lower...upper)
            }
        }
        clamped.sort {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        var merged: [ClosedRange<Double>] = []
        for range in clamped {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                let upper = max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = last.lowerBound...upper
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// 语音驱动摄像头的显隐计划：复用停顿分析的语音活动
/// 结果，输出摄像头应隐藏的成片时间区间。生成实际 `CameraLayoutSegment`
/// 的组装在应用层完成。
package enum SmartCutVoiceCamera {
    /// 一段摄像头隐藏窗口。`hideStart` / `revealStart` 都是布局段起点
    /// （成片时间）：摄像头在 `hideStart` 过渡到隐藏，在 `revealStart`
    /// 过渡回原设置；结尾长静默没有恢复点，`revealStart` 为 nil。
    package struct Interval: Hashable, Sendable {
        package let hideStart: Double
        package let revealStart: Double?
    }

    package struct Plan: Hashable, Sendable {
        package let intervals: [Interval]
    }

    package static func plan(
        speechActivity: [SpeechActivity],
        analyzedDuration: Double,
        hideAfterSilence: Double = 1.5,
        revealLead: Double = 0.2,
        minimumSpeechToReveal: Double = 0.35
    ) -> Plan {
        let duration = analyzedDuration.isFinite ? max(0, analyzedDuration) : 0
        guard duration > 0, hideAfterSilence > 0, !speechActivity.isEmpty
        else {
            return Plan(intervals: [])
        }
        // 迟滞：连续静默不足阈值不触发；下一“段”说话太短（咳嗽、碰麦）
        // 时保持现状，避免闪烁。
        var intervals: [Interval] = []
        let speech = speechActivity.sorted { $0.start < $1.start }
        for (index, activity) in speech.enumerated() {
            let silenceStart = min(duration, activity.end)
            let hideStart = silenceStart + hideAfterSilence
            let next = index + 1 < speech.count ? speech[index + 1] : nil
            if let next {
                guard next.start - silenceStart >= hideAfterSilence else {
                    continue
                }
                guard next.duration >= minimumSpeechToReveal else {
                    continue
                }
                let revealStart = max(hideStart, next.start - revealLead)
                guard hideStart < revealStart, hideStart < duration else {
                    continue
                }
                intervals.append(
                    Interval(
                        hideStart: hideStart,
                        revealStart: min(revealStart, duration)
                    )
                )
            } else {
                guard hideStart < duration else { continue }
                intervals.append(Interval(hideStart: hideStart, revealStart: nil))
            }
        }
        return Plan(intervals: intervals)
    }
}

/// 口头禅 / 重说分析的字幕片段输入。应用层把 `CaptionCue` 映射成
/// 这个中性类型，纯逻辑不依赖应用层字幕模型。
package struct SmartCutCaptionFragment: Hashable, Sendable {
    package let id: UUID
    package let start: Double
    package let end: Double
    package let text: String

    package init(id: UUID, start: Double, end: Double, text: String) {
        self.id = id
        self.start = start.isFinite ? max(0, start) : 0
        self.end = end.isFinite ? max(start, end) : self.start
        self.text = text
    }
}

/// 一条口头禅 / 重说建议（路线图第 6 节）。默认只建议、不自动删除；
/// `confidence` 低于 `SmartCutFillerDetector.safeConfidence` 的建议不进入
/// “选择安全候选”。重复 / 重说默认保留最后一遍，删除区间可用
/// `alternateRange` 切换。
package struct SmartCutFillerSuggestion: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        /// 整条字幕就是一个填充词。
        case fillerWord
        /// 同一句在短窗口内重复出现。
        case repeatedPhrase
        /// 起句后放弃并重新开始，后一次更完整。
        case restart
        /// 长句内部独立成词的填充词 segment（句内填充词）：删除后所属字幕
        /// 文本按 segment 边界做手术。
        case inSentenceFiller
    }

    package let kind: Kind
    /// 所在字幕全文，供审阅时看前后文。
    package let context: String
    package let confidence: Double
    package let repeatCount: Int
    /// 审阅时可切换：保留最后一遍（默认）还是删除最后一遍。
    package var keepLastInstance: Bool
    /// 默认（保留最后一遍时）建议删除的成片时间区间。
    package let cutRange: ClosedRange<Double>
    /// 关闭“保留最后一遍”时改为删除的区间；填充词没有备选区间。
    package let alternateRange: ClosedRange<Double>?
    /// 句内建议（句内填充词）指向的原始识别分段时间区间（旧成片时间）；
    /// 其余建议为 nil。字幕文本手术按它与 segments 精确对位。
    package let sourceSegmentRange: ClosedRange<Double>?

    package init(
        kind: Kind,
        context: String,
        confidence: Double,
        repeatCount: Int,
        keepLastInstance: Bool,
        cutRange: ClosedRange<Double>,
        alternateRange: ClosedRange<Double>? = nil,
        sourceSegmentRange: ClosedRange<Double>? = nil
    ) {
        self.kind = kind
        self.context = context
        self.confidence = confidence
        self.repeatCount = repeatCount
        self.keepLastInstance = keepLastInstance
        self.cutRange = cutRange
        self.alternateRange = alternateRange
        self.sourceSegmentRange = sourceSegmentRange
    }

    package var isRecommended: Bool {
        confidence >= SmartCutFillerDetector.safeConfidence
    }

    /// 当前状态下应删除的成片时间区间。
    package func activeRange() -> ClosedRange<Double> {
        if keepLastInstance {
            return cutRange
        }
        return alternateRange ?? cutRange
    }
}

/// 基于现有本机字幕的口头禅 / 重复句 / 重说检测。只做文本匹配，
/// 不联网、不下载模型；无字幕时调用方给出明确降级提示，停顿清理不受影响。
package enum SmartCutFillerDetector {
    /// 重复句判定的时间窗口（秒）：后一次必须在窗口内开始。
    package static let repeatWindow = 4.0
    /// 参与重复判定的最小归一化长度（字符），过滤“对”“好的”这类高频短语。
    package static let minimumRepeatLength = 4
    /// 达到该置信度的建议才进入“选择安全候选”（路线图：低置信度不进入
    /// 全部应用）。
    package static let safeConfidence = 0.7
    /// 重说（前缀重开）的建议置信度：仅供参考，需人工勾选。
    package static let restartConfidence = 0.6
    /// 填充词切点向内收缩量（秒），避免贴着相邻语音切。
    package static let cutInset = 0.02
    /// 重说判断里“放弃的开头”最长时长（秒）。
    package static let maxRestartPrefixDuration = 1.5
    /// 重说两段之间的最大间隔（秒）。
    package static let restartGap = 1.5
    /// 句内填充词 segment 的最长时长（秒）：整段恰为一个填充词
    /// 才建议；更长的段多半是识别把相邻实词并了进来，不做内部猜测。
    package static let maximumInSentenceFillerDuration = 1.5
    /// 中文停顿词首版列表（中英文词表分开维护）。
    /// 刻意不收：「然后」单独出现多为真实连词；叠用（“呃呃”）与一段
    /// 多词（“嗯，那个”）按反例集约定不命中——宁可漏删不误删。
    package static let chineseFillers = [
        "嗯", "呃", "额", "啊", "那个", "就是说", "然后就是"
    ]
    /// 英文停顿词列表；只匹配整条字幕 / 独立成词的 segment，降低
    /// “like”等常用词误报。句内模式补充 “er”（独立成词时）。
    package static let englishFillers = ["um", "uh", "erm", "er", "like"]

    package static func suggestions(
        in fragments: [SmartCutCaptionFragment]
    ) -> [SmartCutFillerSuggestion] {
        let sorted = fragments
            .filter { $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var suggestions: [SmartCutFillerSuggestion] = []
        // 归一化文本 → 最近一次出现的片段，用于逐对检测重复句。
        var seen: [String: SmartCutCaptionFragment] = [:]
        var previous: SmartCutCaptionFragment?

        for fragment in sorted {
            let normalized = Self.normalized(fragment.text)
            guard !normalized.isEmpty else {
                previous = fragment
                continue
            }

            // 1. 整条字幕就是填充词。
            if isFiller(normalized) {
                suggestions.append(
                    SmartCutFillerSuggestion(
                        kind: .fillerWord,
                        context: fragment.text,
                        confidence: 0.9,
                        repeatCount: 1,
                        keepLastInstance: true,
                        cutRange: insetRange(fragment)
                    )
                )
                previous = fragment
                continue
            }

            // 2. 同一句在短窗口内重复。
            if
                normalized.count >= minimumRepeatLength,
                let first = seen[normalized],
                fragment.start - first.end <= repeatWindow
            {
                // 每对相邻重复各生成一条建议。三次重复会产生两条建议，
                // 同时勾选时正好删除前两遍、保留最后一遍；不能只保留
                // 第一遍的删除区间，否则中间那次会残留。
                suggestions.append(
                    SmartCutFillerSuggestion(
                        kind: .repeatedPhrase,
                        context: fragment.text,
                        confidence: 0.85,
                        repeatCount: 2,
                        keepLastInstance: true,
                        cutRange: insetRange(first),
                        alternateRange: insetRange(fragment)
                    )
                )
                seen[normalized] = fragment
                previous = fragment
                continue
            }

            // 3. 起句后放弃并重新开始：前一条短、当前以它开头且更完整。
            if
                let prev = previous,
                prev.end > prev.start,
                fragment.start - prev.end <= restartGap,
                prev.end - prev.start <= maxRestartPrefixDuration,
                let prevNormalized = nonEmptyNormalized(prev.text),
                normalized.hasPrefix(prevNormalized),
                normalized.count > prevNormalized.count,
                prevNormalized.count >= 2
            {
                suggestions.append(
                    SmartCutFillerSuggestion(
                        kind: .restart,
                        context: prev.text,
                        confidence: restartConfidence,
                        repeatCount: 2,
                        keepLastInstance: true,
                        cutRange: insetRange(prev)
                    )
                )
                seen[normalized] = fragment
                previous = fragment
                continue
            }

            if normalized.count >= minimumRepeatLength {
                seen[normalized] = fragment
            }
            previous = fragment
        }
        return suggestions
    }

    /// 句内模式（句内填充词）：按原始识别分段检测「独立成词」的填充词。
    ///
    /// 规则写死（不许运行时猜测）：
    /// 1. segment 归一化（复用 `normalized`：去首尾空白与标点、小写）后
    ///    必须恰等于词表中的一个填充词，才视为独立成词；
    /// 2. 不做 segment 内部子串匹配——“那个方案很好”“I like this”这类
    ///    含实词的段一律不命中，只删整段独立成词的填充词；
    /// 3. segment 时长超过 `maximumInSentenceFillerDuration` 不命中
    ///    （识别并段时把实词并进来的长段不可信）。
    package static func inSentenceSuggestions(
        in fragments: [SmartCutCaptionFragment]
    ) -> [SmartCutFillerSuggestion] {
        fragments
            .filter { $0.end > $0.start }
            .sorted {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }
            .compactMap { fragment in
                let normalized = Self.normalized(fragment.text)
                guard
                    !normalized.isEmpty,
                    isFiller(normalized),
                    fragment.end - fragment.start
                        <= maximumInSentenceFillerDuration
                else {
                    return nil
                }
                return SmartCutFillerSuggestion(
                    kind: .inSentenceFiller,
                    context: fragment.text,
                    confidence: 0.9,
                    repeatCount: 1,
                    keepLastInstance: true,
                    cutRange: insetRange(fragment),
                    alternateRange: nil,
                    sourceSegmentRange: fragment.start...fragment.end
                )
            }
    }

    /// 整条建议 + 句内建议合并（句内填充词）：调用方拿到 cue 级片段（现有
    /// 检测）与 segment 级片段（有原始分段时）后统一出建议。整条填充词
    /// 建议若与句内建议覆盖同一区间则让位——句内建议携带手术所需分段
    /// 信息，也避免同一处出现两条候选；重复句 / 重说建议不受影响。
    /// 没有分段时行为与 `suggestions(in:)` 完全一致（回归）。
    package static func suggestions(
        in cueFragments: [SmartCutCaptionFragment],
        segmentFragments: [SmartCutCaptionFragment]?
    ) -> [SmartCutFillerSuggestion] {
        let cueLevel = suggestions(in: cueFragments)
        guard let segmentFragments else {
            return cueLevel
        }
        let inSentence = inSentenceSuggestions(in: segmentFragments)
        guard !inSentence.isEmpty else {
            return cueLevel
        }
        let yielding = cueLevel.filter { cue in
            guard cue.kind == .fillerWord else { return true }
            return !inSentence.contains {
                $0.cutRange.lowerBound < cue.cutRange.upperBound
                    && cue.cutRange.lowerBound < $0.cutRange.upperBound
            }
        }
        return (yielding + inSentence).sorted {
            $0.cutRange.lowerBound < $1.cutRange.lowerBound
        }
    }

    // MARK: - 私有辅助

    private static func normalized(_ text: String) -> String {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(
                charactersIn: "。，,．.!？?…、；;：:\"'“”‘’()"
            ))
        return stripped.lowercased()
    }

    private static func nonEmptyNormalized(_ text: String) -> String? {
        let value = normalized(text)
        return value.isEmpty ? nil : value
    }

    private static func isFiller(_ normalized: String) -> Bool {
        chineseFillers.contains(normalized)
            || englishFillers.contains(normalized)
    }

    /// 切点向内收缩，避免贴着相邻语音的起止点。
    private static func insetRange(
        _ fragment: SmartCutCaptionFragment
    ) -> ClosedRange<Double> {
        let lower = fragment.start + cutInset
        let upper = fragment.end - cutInset
        return upper > lower ? lower...upper : fragment.start...fragment.end
    }
}

/// 勾选建议的预计剪掉总时长。按各建议当前删除区间求和，是
/// 未吸附帧网格的近似值（UI 显示「将剪掉约 X 秒」）。
package extension Collection where Element == SmartCutFillerSuggestion {
    package func estimatedSavedDuration(selectedIndices: Set<Int>) -> Double {
        enumerated().reduce(0) { total, entry in
            guard selectedIndices.contains(entry.offset) else {
                return total
            }
            let range = entry.element.activeRange()
            let saved = range.upperBound - range.lowerBound
            return total + (saved > 0 ? saved : 0)
        }
    }
}
