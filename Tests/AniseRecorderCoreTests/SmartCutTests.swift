import XCTest
@testable import AniseRecorderCore

/// 精剪引擎测试：语音活动检测、两种阈值模式、候选合并与保护分类。
/// 合成音频 fixture 的期望值来自语音活动检测参数的推荐起始阈值，
/// 调整阈值时必须同步更新这里的期望区间。
final class SmartCutTests: XCTestCase {
    // MARK: 合成音频 fixture

    private enum Fixture {
        static let sampleRate = 48_000.0
        static let speechAmplitude: Float = 0.1
        static let noiseAmplitude: Float = 0.001

        enum Segment {
            case speech(Double)
            case noise(Double)
            case ramp(duration: Double, from: Float, to: Float)
            case silence(Double)
        }

        /// 生成确定性的正弦样本：speech ≈ -23 dBFS，noise ≈ -63 dBFS。
        static func samples(_ segments: [Segment]) -> [Float] {
            var samples: [Float] = []
            for segment in segments {
                let duration: Double
                let from: Float
                let to: Float
                switch segment {
                case .speech(let seconds):
                    duration = seconds
                    from = speechAmplitude
                    to = speechAmplitude
                case .noise(let seconds):
                    duration = seconds
                    from = noiseAmplitude
                    to = noiseAmplitude
                case .ramp(let seconds, let lower, let upper):
                    duration = seconds
                    from = lower
                    to = upper
                case .silence(let seconds):
                    duration = seconds
                    from = 0
                    to = 0
                }
                let count = Int((duration * sampleRate).rounded())
                for index in 0..<count {
                    let progress = count > 1 ? Double(index) / Double(count - 1) : 0
                    let amplitude = from + (to - from) * Float(progress)
                    let time = Double(samples.count + index) / sampleRate
                    samples.append(amplitude * Float(sin(2 * .pi * 220 * time)))
                }
            }
            return samples
        }
    }

    // MARK: 语音活动检测

    func testPureSilenceYieldsNoCandidateWithoutDetectedSpeech() {
        let analysis = SmartCutEngine.analyze(
            samples: Fixture.samples([.silence(2)]),
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )

        XCTAssertTrue(analysis.speechActivity.isEmpty)
        XCTAssertTrue(analysis.candidates.isEmpty)
    }

    func testSteadyAudibleSignalDoesNotBecomeWholeFilePause() {
        let analysis = SmartCutEngine.analyze(
            samples: Fixture.samples([.speech(5)]),
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )

        XCTAssertTrue(analysis.speechActivity.isEmpty)
        XCTAssertTrue(analysis.candidates.isEmpty)
    }

    func testHangoverBridgesOnlySubHangoverGaps() throws {
        // 0.1 秒的句间间隙应被 hangover 合并成一段连续语音。
        let bridged = SmartCutActivityDetector.detectSpeechActivity(
            in: Fixture.samples([.speech(0.3), .silence(0.1), .speech(0.3)]),
            sampleRate: Fixture.sampleRate
        )
        XCTAssertEqual(bridged.count, 1)

        // 0.3 秒的间隙超过 hangover，应拆成两段语音。
        let split = SmartCutActivityDetector.detectSpeechActivity(
            in: Fixture.samples([.speech(0.3), .silence(0.3), .speech(0.3)]),
            sampleRate: Fixture.sampleRate
        )
        XCTAssertEqual(split.count, 2)
        let first = try XCTUnwrap(split.first)
        let last = try XCTUnwrap(split.last)
        XCTAssertEqual(last.start - first.end, 0.13, accuracy: 0.02)
    }

    func testAdaptiveNoiseFloorHandlesLowAndRisingNoise() throws {
        // 低噪声底：静音段是约 -63 dBFS 的正弦，中间的语音仍应被完整检出。
        let lowNoise = SmartCutActivityDetector.detectSpeechActivity(
            in: Fixture.samples([.noise(1), .speech(1), .noise(1)]),
            sampleRate: Fixture.sampleRate
        )
        XCTAssertEqual(lowNoise.count, 1)
        let speech = try XCTUnwrap(lowNoise.first)
        XCTAssertEqual(speech.start, 0.99, accuracy: 0.02)
        XCTAssertEqual(speech.end, 2.16, accuracy: 0.02)

        // 只有缓慢抬升的噪声、没有语音时，不应产生虚假语音活动。
        let noiseOnly = SmartCutActivityDetector.detectSpeechActivity(
            in: Fixture.samples([
                .noise(2),
                .ramp(duration: 2, from: Fixture.noiseAmplitude, to: Fixture.noiseAmplitude * 2),
                .noise(2),
            ]),
            sampleRate: Fixture.sampleRate
        )
        XCTAssertTrue(noiseOnly.isEmpty)
    }

    func testDigitalSilenceLeadInDoesNotMaskRealNoiseFloor() throws {
        let activity = SmartCutActivityDetector.detectSpeechActivity(
            in: Fixture.samples([
                .silence(0.2),
                .noise(1),
                .speech(1),
                .noise(1),
            ]),
            sampleRate: Fixture.sampleRate
        )

        // 文件头的数字静音不能把噪声底拉到 -140 dB，否则后面的正常底噪
        // 会被整段误判为语音，真实停顿也就永远找不到。
        XCTAssertEqual(activity.count, 1)
        let speech = try XCTUnwrap(activity.first)
        XCTAssertGreaterThan(speech.start, 1.0)
        XCTAssertLessThan(speech.end, 2.5)
    }

    func testSuddenOnsetIsDetectedWithFrameAccuracy() throws {
        let activity = SmartCutActivityDetector.detectSpeechActivity(
            in: Fixture.samples([.silence(2), .speech(1)]),
            sampleRate: Fixture.sampleRate
        )
        XCTAssertEqual(activity.count, 1)
        let first = try XCTUnwrap(activity.first)
        XCTAssertEqual(first.start, 1.99, accuracy: 0.02)
    }

    // MARK: 候选生成与阈值模式

    func testFixedAudioAnalysisIsDeterministic() {
        let samples = Fixture.samples([.speech(2), .silence(2), .speech(2)])
        let first = SmartCutEngine.analyze(
            samples: samples,
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )
        let second = SmartCutEngine.analyze(
            samples: samples,
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )
        XCTAssertEqual(first, second)
    }

    func testPauseBetweenSpeechBecomesCandidateWithSafetyMargins() throws {
        let analysis = SmartCutEngine.analyze(
            samples: Fixture.samples([.speech(2), .silence(2), .speech(2)]),
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )

        XCTAssertEqual(analysis.speechActivity.count, 2)
        XCTAssertEqual(analysis.candidates.count, 1)
        let candidate = try XCTUnwrap(analysis.candidates.first)

        // 检测到的停顿 ≈ [2.16, 3.99]：前端受帧量化影响，尾端保留 hangover。
        XCTAssertEqual(candidate.start, 2.16, accuracy: 0.02)
        XCTAssertEqual(candidate.end, 3.99, accuracy: 0.02)
        XCTAssertEqual(candidate.kind, .pureSpeechPause)
        XCTAssertTrue(candidate.isDefaultSelected)

        // 删除窗口必须向两侧人声保留 0.25 秒安全余量。
        XCTAssertEqual(candidate.cutStart, candidate.start + 0.25, accuracy: 0.001)
        XCTAssertEqual(candidate.cutEnd, candidate.end - 0.25, accuracy: 0.001)
        XCTAssertEqual(candidate.savedDuration, candidate.pauseDuration - 0.5, accuracy: 0.001)
    }

    func testNaturalModeSkipsBreathThatCompactModeKeeps() throws {
        // 0.7 秒气口：自然模式（最小 0.8 秒）不产生候选，紧凑模式（0.4 秒）保留。
        let samples = Fixture.samples([.speech(1.5), .silence(0.7), .speech(1.5)])
        let natural = SmartCutEngine.analyze(
            samples: samples,
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )
        XCTAssertTrue(natural.candidates.isEmpty)

        let compact = SmartCutEngine.analyze(
            samples: samples,
            sampleRate: Fixture.sampleRate,
            mode: .compact
        )
        XCTAssertEqual(compact.candidates.count, 1)
        let candidate = try XCTUnwrap(compact.candidates.first)
        XCTAssertEqual(candidate.kind, .shortBreath)
        XCTAssertEqual(candidate.pauseDuration, 0.53, accuracy: 0.02)
        XCTAssertEqual(candidate.cutStart, candidate.start + 0.125, accuracy: 0.001)
        XCTAssertEqual(candidate.cutEnd, candidate.end - 0.125, accuracy: 0.001)
    }

    func testModeMarginsControlCutWindowOnSyntheticPause() throws {
        func candidates(for mode: SmartCutMode) -> [SmartCutCandidate] {
            SmartCutEngine.makeCandidates(
                speechActivity: [
                    SpeechActivity(start: 0, end: 1),
                    SpeechActivity(start: 2, end: 3),
                ],
                analyzedDuration: 3,
                mode: mode
            )
        }

        let natural = try XCTUnwrap(candidates(for: .natural).first)
        XCTAssertEqual(natural.kind, .pureSpeechPause)
        XCTAssertEqual(natural.cutStart, 1.25, accuracy: 0.001)
        XCTAssertEqual(natural.cutEnd, 1.75, accuracy: 0.001)
        XCTAssertEqual(natural.savedDuration, 0.5, accuracy: 0.001)

        // 1.0 秒的停顿不短于短气口上限，两种模式下都按普通停顿分类，
        // 只有删除窗口随模式变化。
        let compact = try XCTUnwrap(candidates(for: .compact).first)
        XCTAssertEqual(compact.kind, .pureSpeechPause)
        XCTAssertEqual(compact.cutStart, 1.125, accuracy: 0.001)
        XCTAssertEqual(compact.cutEnd, 1.875, accuracy: 0.001)
        XCTAssertEqual(compact.savedDuration, 0.75, accuracy: 0.001)
    }

    func testLongSilencesProduceSortedNonOverlappingCandidates() throws {
        let analysis = SmartCutEngine.analyze(
            samples: Fixture.samples([.speech(1), .silence(2), .speech(1), .silence(3), .speech(1)]),
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )

        XCTAssertEqual(analysis.candidates.count, 2)
        let first = try XCTUnwrap(analysis.candidates.first)
        let second = try XCTUnwrap(analysis.candidates.last)
        XCTAssertLessThan(first.end, second.start)
        XCTAssertEqual(first.kind, .pureSpeechPause)
        XCTAssertEqual(second.kind, .pureSpeechPause)
        XCTAssertEqual(first.pauseDuration, 1.83, accuracy: 0.02)
        XCTAssertEqual(second.pauseDuration, 2.83, accuracy: 0.02)
        XCTAssertEqual(analysis.recommendedCandidateCount, 2)
        XCTAssertEqual(analysis.estimatedSavedDuration, 3.66, accuracy: 0.05)
    }

    func testEmptyAudioYieldsEmptyAnalysis() {
        let analysis = SmartCutEngine.analyze(
            samples: [],
            sampleRate: Fixture.sampleRate,
            mode: .natural
        )
        XCTAssertEqual(analysis.analyzedDuration, 0)
        XCTAssertTrue(analysis.speechActivity.isEmpty)
        XCTAssertTrue(analysis.candidates.isEmpty)
    }

    // MARK: 保护分类（屏幕操作 / 系统声音）

    /// 合成停顿 [1, 4]：两段语音之间的 3 秒纯人声间隙。
    private func makeCandidates(
        mode: SmartCutMode = .natural,
        screen: [ClosedRange<Double>] = [],
        system: [ClosedRange<Double>] = []
    ) -> [SmartCutCandidate] {
        SmartCutEngine.makeCandidates(
            speechActivity: [
                SpeechActivity(start: 0, end: 1),
                SpeechActivity(start: 4, end: 5),
            ],
            analyzedDuration: 5,
            mode: mode,
            screenActivity: screen,
            systemSound: system
        )
    }

    func testSystemSoundSplitsPauseIntoProtectedAndIdleCandidates() throws {
        let candidates = makeCandidates(system: [1.5...2.5])
        XCTAssertEqual(candidates.count, 2)

        // 有系统声音的区间成为灰色候选，范围精确到保护区而不是整个停顿。
        let protected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(protected.start, 1.5, accuracy: 0.001)
        XCTAssertEqual(protected.end, 2.5, accuracy: 0.001)
        XCTAssertEqual(protected.kind, .hasSystemSound)
        XCTAssertFalse(protected.isDefaultSelected)

        // 右侧 1.5 秒空闲区间仍是推荐候选；左侧 0.5 秒短于最小长度不产生候选。
        let idle = try XCTUnwrap(candidates.last)
        XCTAssertEqual(idle.start, 2.5, accuracy: 0.001)
        XCTAssertEqual(idle.end, 4, accuracy: 0.001)
        XCTAssertEqual(idle.kind, .pureSpeechPause)
        XCTAssertTrue(idle.isDefaultSelected)
        XCTAssertEqual(candidates.filter(\.isDefaultSelected).count, 1)
        XCTAssertEqual(
            candidates.filter(\.isDefaultSelected).reduce(0) { $0 + $1.savedDuration },
            1.0,
            accuracy: 0.001
        )
    }

    func testScreenActivityCandidateKeepsPreciseExtent() throws {
        let candidates = makeCandidates(screen: [1.5...2.5])
        XCTAssertEqual(candidates.count, 2)
        let protected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(protected.kind, .hasScreenActivity)
        XCTAssertFalse(protected.isDefaultSelected)
        XCTAssertEqual(protected.start, 1.5, accuracy: 0.001)
        XCTAssertEqual(protected.end, 2.5, accuracy: 0.001)
    }

    func testSystemSoundTakesPrecedenceOverScreenActivity() throws {
        let candidates = makeCandidates(screen: [1.5...2.5], system: [1.8...2.2])
        XCTAssertEqual(candidates.count, 2)
        let protected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(protected.kind, .hasSystemSound)
    }

    // MARK: 候选合并

    func testMergedCandidatesSortMergeAndEnforceMinimums() {
        func candidate(
            _ start: Double,
            _ end: Double,
            kind: SmartCutCandidateKind = .pureSpeechPause
        ) -> SmartCutCandidate {
            SmartCutCandidate(
                start: start,
                end: end,
                kind: kind,
                keepEachSide: SmartCutMode.natural.keepEachSide
            )
        }

        // 乱序 + 链式重叠：合并为一个候选并重算删除窗口。
        let merged = SmartCutEngine.mergedCandidates(
            [candidate(2, 3), candidate(0.5, 2.5), candidate(0, 1)],
            mode: .natural
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(merged[0].end, 3, accuracy: 0.001)
        XCTAssertEqual(merged[0].kind, .pureSpeechPause)
        XCTAssertEqual(merged[0].cutStart, 0.25, accuracy: 0.001)
        XCTAssertEqual(merged[0].cutEnd, 2.75, accuracy: 0.001)

        // 保护类候选优先级更高，合并后默认不勾选。
        let precedence = SmartCutEngine.mergedCandidates(
            [candidate(0, 2), candidate(1, 3, kind: .hasScreenActivity)],
            mode: .natural
        )
        XCTAssertEqual(precedence.count, 1)
        XCTAssertEqual(precedence[0].kind, .hasScreenActivity)
        XCTAssertFalse(precedence[0].isDefaultSelected)

        // 短于最小长度的候选被丢弃；相邻不重叠的候选保持独立；空输入返回空。
        XCTAssertEqual(
            SmartCutEngine.mergedCandidates([candidate(0, 0.5)], mode: .natural).count,
            0
        )
        XCTAssertEqual(
            SmartCutEngine.mergedCandidates([candidate(0, 1), candidate(1, 2)], mode: .natural).count,
            2
        )
        XCTAssertTrue(SmartCutEngine.mergedCandidates([], mode: .natural).isEmpty)

        // 短候选与长候选重叠时先合并再判断最小长度，不被单独丢弃。
        let rescued = SmartCutEngine.mergedCandidates(
            [candidate(0, 0.5), candidate(0.3, 1.5)],
            mode: .natural
        )
        XCTAssertEqual(rescued.count, 1)
        XCTAssertEqual(rescued[0].pauseDuration, 1.5, accuracy: 0.001)
    }

    // MARK: 语音驱动摄像头计划（纯逻辑）

    func testVoiceCameraPlanHidesAfterLongSilenceAndRevealsBeforeSpeech() throws {
        // 口播 3 秒 → 静默 2 秒 → 口播 2 秒：
        // 静默 1.5 秒后隐藏（3 + 1.5 = 4.5），下一段说话前 0.2 秒恢复
        // （5 − 0.2 = 4.8）。
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: [
                SpeechActivity(start: 0, end: 3),
                SpeechActivity(start: 5, end: 7)
            ],
            analyzedDuration: 7
        )

        XCTAssertEqual(plan.intervals.count, 1)
        let interval = try XCTUnwrap(plan.intervals.first)
        XCTAssertEqual(interval.hideStart, 4.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(interval.revealStart), 4.8, accuracy: 1e-9)
    }

    func testVoiceCameraPlanSkipsShortSilence() {
        // 句间 1 秒短停顿不触发反复显隐。
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: [
                SpeechActivity(start: 0, end: 3),
                SpeechActivity(start: 4, end: 7)
            ],
            analyzedDuration: 7
        )
        XCTAssertTrue(plan.intervals.isEmpty)
    }

    func testVoiceCameraPlanSkipsShortSpeechAfterSilence() {
        // 静默后的下一“段”只有 0.25 秒（咳嗽、碰麦）时，
        // 既不隐藏也不恢复，避免闪烁。
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: [
                SpeechActivity(start: 0, end: 3),
                SpeechActivity(start: 5, end: 5.25),
                SpeechActivity(start: 6, end: 8)
            ],
            analyzedDuration: 8
        )
        XCTAssertTrue(plan.intervals.isEmpty)
    }

    func testVoiceCameraPlanSkipsZeroLengthHideWindow() {
        // 静默 1.6 秒：隐藏点 1.5 与提前恢复点 1.4 挤在一起，
        // 没有有效的隐藏窗口就不生成。
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: [
                SpeechActivity(start: 0, end: 1),
                SpeechActivity(start: 2.6, end: 5)
            ],
            analyzedDuration: 5
        )
        XCTAssertTrue(plan.intervals.isEmpty)
    }

    func testVoiceCameraPlanHidesThroughTrailingSilence() throws {
        // 结尾长静默：只隐藏，不生成恢复段。
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: [SpeechActivity(start: 0, end: 3)],
            analyzedDuration: 8
        )
        XCTAssertEqual(plan.intervals.count, 1)
        let interval = try XCTUnwrap(plan.intervals.first)
        XCTAssertEqual(interval.hideStart, 4.5, accuracy: 1e-9)
        XCTAssertNil(interval.revealStart)
    }

    func testVoiceCameraPlanIgnoresShortLeadingSilence() {
        // 开头 1 秒静默不生成任何段。
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: [SpeechActivity(start: 1, end: 5)],
            analyzedDuration: 5
        )
        XCTAssertTrue(plan.intervals.isEmpty)
    }

    // MARK: 口头禅与重说建议（纯逻辑）

    private func fragment(
        _ start: Double,
        _ end: Double,
        _ text: String
    ) -> SmartCutCaptionFragment {
        SmartCutCaptionFragment(
            id: UUID(),
            start: start,
            end: end,
            text: text
        )
    }

    func testFillerSuggestionsDetectChineseAndEnglishFillers() throws {
        let suggestions = SmartCutFillerDetector.suggestions(in: [
            fragment(1.0, 1.4, "嗯"),
            fragment(1.5, 2.2, "我们开始今天的主题"),
            fragment(3.0, 3.3, "Um,"),
            fragment(3.4, 4.2, "the deployment pipeline"),
            fragment(5.0, 5.6, "这个接口返回列表")
        ])

        XCTAssertEqual(suggestions.count, 2)
        let filler = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(filler.kind, .fillerWord)
        XCTAssertEqual(filler.confidence, 0.9, accuracy: 1e-9)
        // 切点向内收缩 0.02 秒，避免贴着相邻语音。
        XCTAssertEqual(filler.cutRange.lowerBound, 1.02, accuracy: 1e-9)
        XCTAssertEqual(filler.cutRange.upperBound, 1.38, accuracy: 1e-9)
        XCTAssertEqual(filler.context, "嗯")
        let english = try XCTUnwrap(suggestions.last)
        XCTAssertEqual(english.kind, .fillerWord)
        XCTAssertEqual(english.confidence, 0.9, accuracy: 1e-9)
    }

    func testRepeatedPhraseSuggestsKeepingLastInstance() throws {
        let first = fragment(1.0, 2.0, "我们来看这个例子")
        let second = fragment(2.6, 3.6, "我们来看这个例子。")
        let suggestions = SmartCutFillerDetector.suggestions(in: [
            first,
            second,
            fragment(4.0, 5.0, "然后保存文件")
        ])

        XCTAssertEqual(suggestions.count, 1)
        let suggestion = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(suggestion.kind, .repeatedPhrase)
        XCTAssertEqual(suggestion.repeatCount, 2)
        XCTAssertTrue(suggestion.keepLastInstance)
        XCTAssertTrue(suggestion.isRecommended)
        // 默认保留最后一遍：删除第一处。
        XCTAssertEqual(
            suggestion.activeRange().lowerBound,
            first.start + 0.02,
            accuracy: 1e-9
        )
        // 切换后删除最后一处。
        let switched = SmartCutFillerSuggestion(
            kind: suggestion.kind,
            context: suggestion.context,
            confidence: suggestion.confidence,
            repeatCount: suggestion.repeatCount,
            keepLastInstance: false,
            cutRange: suggestion.cutRange,
            alternateRange: suggestion.alternateRange
        )
        XCTAssertEqual(
            switched.activeRange().lowerBound,
            second.start + 0.02,
            accuracy: 1e-9
        )
    }

    func testThreeRepeatedTakesCreateTwoCutRangesThatKeepLast() {
        let first = fragment(1.0, 2.0, "我们来看这个例子")
        let second = fragment(2.6, 3.6, "我们来看这个例子。")
        let third = fragment(4.2, 5.2, "我们来看这个例子！")
        let suggestions = SmartCutFillerDetector.suggestions(in: [
            first,
            second,
            third
        ])

        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(
            suggestions.map { $0.activeRange().lowerBound },
            [first.start + 0.02, second.start + 0.02]
        )
    }

    func testRestartSuggestionIsLowConfidenceAndNotRecommended() throws {
        let abandoned = fragment(2.0, 2.7, "我们开始")
        let complete = fragment(3.0, 4.5, "我们开始讲今天的部署流程")
        let suggestions = SmartCutFillerDetector.suggestions(in: [
            fragment(1.0, 1.8, "上一节讲完了"),
            abandoned,
            complete
        ])

        XCTAssertEqual(suggestions.count, 1)
        let suggestion = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(suggestion.kind, .restart)
        XCTAssertEqual(suggestion.confidence, 0.6, accuracy: 1e-9)
        XCTAssertFalse(suggestion.isRecommended)
        XCTAssertEqual(suggestion.repeatCount, 2)
        XCTAssertEqual(
            suggestion.activeRange().lowerBound,
            abandoned.start + 0.02,
            accuracy: 1e-9
        )
    }

    func testShortCommonWordsAndFarRepeatsDoNotTriggerSuggestions() {
        let suggestions = SmartCutFillerDetector.suggestions(in: [
            fragment(1.0, 1.2, "对"),
            fragment(1.6, 1.8, "对"),
            fragment(2.4, 2.7, "好的"),
            fragment(3.2, 3.5, "好的"),
            fragment(4.0, 5.0, "我们来看这个例子"),
            // 相同文本但间隔超过 4 秒窗口，不算重说。
            fragment(10.0, 11.0, "我们来看这个例子")
        ])
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testFillerDetectorHandlesEmptyAndCleanInput() {
        XCTAssertTrue(SmartCutFillerDetector.suggestions(in: []).isEmpty)
        XCTAssertTrue(
            SmartCutFillerDetector.suggestions(in: [
                fragment(1.0, 2.0, "正常的口播内容"),
                fragment(2.2, 3.4, "第二句话保持节奏")
            ]).isEmpty
        )
    }

    // MARK: 剪切事务（纯逻辑）

    /// 构造删除窗口等于 start...end 的候选（keepEachSide 为 0）。
    private func cutCandidate(
        _ start: Double,
        _ end: Double
    ) -> SmartCutCandidate {
        SmartCutCandidate(
            start: start,
            end: end,
            kind: .pureSpeechPause,
            keepEachSide: 0
        )
    }

    func testCutTransactionSplitsClipAndRipplesOutputTime() throws {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let outcome = TimelineCutTransaction.apply(
            [cutCandidate(3, 5)],
            to: timeline
        )

        XCTAssertEqual(outcome.timeline.clips.count, 2)
        XCTAssertEqual(outcome.timeline.duration, 8, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(outcome.timeline.clips.first).sourceEnd,
            3,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(outcome.timeline.clips.last).sourceStart,
            5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(outcome.removedDuration, 2, accuracy: 0.000_001)
        XCTAssertTrue(outcome.skippedCandidates.isEmpty)

        // 输出时间映射：删除区间前不变，区间后前移，区间内无映射。
        XCTAssertEqual(try XCTUnwrap(outcome.mappedTime(2)), 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(outcome.mappedTime(6)), 4, accuracy: 1e-9)
        XCTAssertNil(outcome.mappedTime(4))
    }

    func testCutTransactionRemovesInteriorAndTrimsPartialClips() throws {
        let timeline = ProjectTimeline(clips: [
            TimelineClip(sourceStart: 0, sourceEnd: 2),
            TimelineClip(sourceStart: 2, sourceEnd: 4),
            TimelineClip(sourceStart: 4, sourceEnd: 6),
        ])
        let outcome = TimelineCutTransaction.apply(
            [cutCandidate(1, 5)],
            to: timeline
        )

        XCTAssertEqual(outcome.timeline.clips.count, 2)
        XCTAssertEqual(outcome.timeline.duration, 2, accuracy: 0.000_001)
        let first = try XCTUnwrap(outcome.timeline.clips.first)
        let last = try XCTUnwrap(outcome.timeline.clips.last)
        XCTAssertEqual(first.sourceStart, 0, accuracy: 0.000_001)
        XCTAssertEqual(first.sourceEnd, 1, accuracy: 0.000_001)
        XCTAssertEqual(last.sourceStart, 5, accuracy: 0.000_001)
        XCTAssertEqual(last.sourceEnd, 6, accuracy: 0.000_001)
    }

    func testCutTransactionSnapsToFrameGrid() throws {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let outcome = TimelineCutTransaction.apply(
            [cutCandidate(3.011, 4.987)],
            to: timeline,
            frameDuration: 1.0 / 30
        )

        // 删除边界吸附到最近的 1/30 秒帧网格：3.011 → 3.0，4.987 → 5.0。
        XCTAssertEqual(outcome.timeline.duration, 8, accuracy: 0.000_001)
        XCTAssertEqual(outcome.deletions.count, 1)
        let deletion = try XCTUnwrap(outcome.deletions.first)
        XCTAssertEqual(deletion.lowerBound, 3, accuracy: 1e-9)
        XCTAssertEqual(deletion.upperBound, 5, accuracy: 1e-9)
    }

    func testCutTransactionSkipsCandidateLeavingPieceBelowMinimum() {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 4)
        let outcome = TimelineCutTransaction.apply(
            [cutCandidate(0.005, 1)],
            to: timeline
        )

        // 删除窗口在片段头部只留下 5 ms，低于 minimumSourceDuration，
        // 整个候选被跳过且不产生任何修改。
        XCTAssertTrue(outcome.deletions.isEmpty)
        XCTAssertEqual(outcome.removedDuration, 0, accuracy: 1e-9)
        XCTAssertEqual(outcome.skippedCandidates.count, 1)
        XCTAssertEqual(
            outcome.timeline.clips.count,
            1
        )
        XCTAssertEqual(outcome.timeline.duration, 4, accuracy: 0.000_001)
    }

    func testCutTransactionSkipsCombinationLeavingPieceBelowMinimum() {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let outcome = TimelineCutTransaction.apply(
            [
                cutCandidate(2, 4),
                cutCandidate(4.01, 6),
            ],
            to: timeline
        )

        // 两条删除单独看都安全，连续应用却只留下 10 ms，低于最小时长。
        // 事务必须整体校验并把后一条候选跳过。
        XCTAssertEqual(outcome.deletions.count, 1)
        XCTAssertEqual(outcome.skippedCandidates.count, 1)
        XCTAssertEqual(outcome.timeline.duration, 8, accuracy: 0.000_001)
        XCTAssertTrue(
            outcome.timeline.clips.allSatisfy {
                $0.sourceDuration >= TimelineClip.minimumSourceDuration - 1e-9
            }
        )
    }

    func testCutTransactionKeptRangesSupportTrackRipple() throws {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let outcome = TimelineCutTransaction.apply(
            [cutCandidate(3, 5)],
            to: timeline
        )

        XCTAssertEqual(outcome.keptRanges(in: 0...2).count, 1)
        XCTAssertEqual(
            try XCTUnwrap(outcome.keptRanges(in: 2...4).first),
            2...3
        )
        XCTAssertEqual(
            try XCTUnwrap(outcome.keptRanges(in: 4.5...6).first),
            3...4
        )
        XCTAssertTrue(outcome.keptRanges(in: 3.2...4.8).isEmpty)
        // 完全位于删除之前的区间原样映射。
        XCTAssertEqual(
            try XCTUnwrap(outcome.keptRanges(in: 0...2).first),
            0...2
        )
    }

    func testCutTransactionMergesOverlappingCandidates() throws {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let outcome = TimelineCutTransaction.apply(
            [cutCandidate(3, 4), cutCandidate(3.5, 5.5)],
            to: timeline
        )

        XCTAssertEqual(outcome.timeline.duration, 7.5, accuracy: 0.000_001)
        XCTAssertEqual(outcome.deletions.count, 1)
        let deletion = try XCTUnwrap(outcome.deletions.first)
        XCTAssertEqual(deletion.lowerBound, 3, accuracy: 1e-9)
        XCTAssertEqual(deletion.upperBound, 5.5, accuracy: 1e-9)
    }

    func testCutTransactionMultipleDeletionsAreOrderIndependent() throws {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let reversed = TimelineCutTransaction.apply(
            [cutCandidate(1, 2), cutCandidate(5, 7)],
            to: timeline
        )
        let forward = TimelineCutTransaction.apply(
            [cutCandidate(5, 7), cutCandidate(1, 2)],
            to: timeline
        )

        XCTAssertEqual(reversed.timeline.duration, 7, accuracy: 0.000_001)
        // 结构一致：新切出的片段 id 每次生成不同，只比较源区间和速率。
        XCTAssertEqual(
            reversed.timeline.clips.map { [$0.sourceStart, $0.sourceEnd, $0.playbackRate] },
            forward.timeline.clips.map { [$0.sourceStart, $0.sourceEnd, $0.playbackRate] }
        )
        XCTAssertEqual(forward.timeline.duration, 7, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(forward.mappedTime(0.5)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(forward.mappedTime(2.5)), 1.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(forward.mappedTime(8)), 5, accuracy: 1e-9)
        XCTAssertNil(forward.mappedTime(5.5))
        XCTAssertNil(forward.mappedTime(1.999))
        XCTAssertEqual(try XCTUnwrap(forward.mappedTime(2)), 1, accuracy: 1e-9)
    }
}
