import Foundation
import AniseRecorderCore

struct SpeechSegment: Equatable {
    let text: String
    let start: Double
    let duration: Double
}

/// 一次本机识别的完整结果：合并后的字幕 cue + 原始识别分段。
/// 原始分段只进会话态（句内填充词检测与文本手术用），不写入 project.json。
struct OfflineTranscription: Equatable {
    let cues: [CaptionCue]
    let segments: [SpeechSegment]
}

enum SubtitleFile {
    static func parse(
        _ source: String,
        duration: Double
    ) -> [CaptionCue] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var cues: [CaptionCue] = []
        var block: [String] = []
        for line in normalized.components(separatedBy: "\n") + [""] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let cue = parseBlock(block, duration: duration) {
                    cues.append(cue)
                }
                block.removeAll(keepingCapacity: true)
            } else {
                block.append(line)
            }
        }
        return cues.sorted {
            if abs($0.start - $1.start) > 0.000_001 {
                return $0.start < $1.start
            }
            return $0.end < $1.end
        }
    }

    static func string(from cues: [CaptionCue]) -> String {
        let cues = cues
            .filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            .sorted { $0.start < $1.start }
        return cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(timestamp(cue.start)) --> \(timestamp(max(cue.start + 0.05, cue.end)))
            \(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }.joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    static func write(
        _ cues: [CaptionCue],
        to url: URL
    ) throws {
        try Data(string(from: cues).utf8).write(
            to: url,
            options: [.atomic]
        )
    }

    static func cues(
        from segments: [SpeechSegment],
        totalDuration: Double,
        maximumCharacters: Int = 42,
        maximumDuration: Double = 7
    ) -> [CaptionCue] {
        let maxCharacters = max(8, maximumCharacters)
        let maxDuration = max(0.4, maximumDuration)
        var cues: [CaptionCue] = []
        var text = ""
        var start = 0.0
        var end = 0.0

        func flush() {
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty, end > start else {
                text = ""
                return
            }
            cues.append(
                CaptionCue(
                    start: start,
                    end: max(start + 0.05, end),
                    text: trimmed
                )
            )
            text = ""
        }

        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let raw = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                !raw.isEmpty,
                segment.start.isFinite,
                segment.duration.isFinite,
                segment.start < totalDuration
            else {
                continue
            }
            let segmentStart = min(
                max(0, segment.start),
                totalDuration
            )
            let segmentEnd = min(
                totalDuration,
                max(
                    segmentStart + 0.05,
                    segmentStart + max(0, segment.duration)
                )
            )
            guard segmentStart < totalDuration else { continue }

            if !text.isEmpty {
                let nextText = joined(text, raw)
                let gap = segmentStart - end
                let tooLong = nextText.count > maxCharacters
                let tooLate = segmentEnd - start > maxDuration
                if gap > 1.2 || tooLong || tooLate {
                    flush()
                }
            }

            if text.isEmpty {
                start = segmentStart
                end = segmentEnd
                text = raw
            } else {
                text = joined(text, raw)
                end = max(end, segmentEnd)
            }

            if
                text.count >= 14,
                let last = text.last,
                "。！？!?；;".contains(last)
            {
                flush()
            }
        }
        flush()
        return cues
    }

    /// 按 cues(from:) 的同一拼接规则把一组 segment 文本拼成一句话
    /// （文本手术的重建校验与重写共用；空文本跳过）。
    static func joinedSegmentTexts(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            let raw = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !raw.isEmpty else { continue }
            result = result.isEmpty ? raw : joined(result, raw)
        }
        return result
    }

    private static func joined(_ left: String, _ right: String) -> String {
        guard
            let last = left.last,
            let first = right.first
        else {
            return left + right
        }
        if last.isWhitespace || first.isWhitespace {
            return left + right
        }
        if isIdeographic(last) || isIdeographic(first) {
            return left + right
        }
        return left + " " + right
    }

    private static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x3040 ... 0x30ff,
             0x3400 ... 0x4dbf,
             0x4e00 ... 0x9fff,
             0xf900 ... 0xfaff:
            return true
        default:
            return false
        }
    }

    private static func parseBlock(
        _ lines: [String],
        duration: Double
    ) -> CaptionCue? {
        guard
            let timingIndex = lines.firstIndex(where: {
                $0.contains("-->")
            })
        else {
            return nil
        }
        let timing = lines[timingIndex].components(
            separatedBy: "-->"
        )
        guard
            timing.count == 2,
            let start = parseTimestamp(timing[0]),
            let rawEnd = parseTimestamp(timing[1]),
            start.isFinite,
            rawEnd.isFinite
        else {
            return nil
        }
        let safeStart = min(max(0, start), max(0, duration))
        let safeEnd = min(
            max(safeStart + 0.05, rawEnd),
            max(safeStart + 0.05, duration)
        )
        guard safeStart < duration else { return nil }
        let rawText = lines.dropFirst(timingIndex + 1)
            .joined(separator: "\n")
            .replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return nil }
        return CaptionCue(
            start: safeStart,
            end: safeEnd,
            text: rawText
        )
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let components = value.split(separator: ":")
        guard components.count == 3 else { return nil }
        guard
            let hours = Double(components[0]),
            let minutes = Double(components[1]),
            let seconds = Double(components[2])
        else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1000) % 60
        let remainder = milliseconds % 1000
        return String(
            format: "%02d:%02d:%02d,%03d",
            hours,
            minutes,
            wholeSeconds,
            remainder
        )
    }
}

/// 句内填充词重写：句内填充词删除后的字幕文本手术（纯函数，可测试）。
///
/// 手术规则（写死，不许运行时按字符位置猜）：
/// 1. 只有「重建校验」通过的 cue 才动刀：cue 时间范围内的 segments
///    （按中点归属、过滤空文本）用 `SubtitleFile.joinedSegmentTexts`
///    重建出的文本与 cue.text 逐字一致。校验不过（SRT 导入、术语表
///    改写、手动字幕）→ 文本原样保留，只按事务裁剪时间。
/// 2. 只删被选 segment 的原文子串及紧随的一个空白：实现为重拼时跳过
///    被选 segment，其余 segment 用 cues(from:) 同一拼接规则重拼——
///    等价于删除该子串与其后一个分隔空白（中文无空格时即删除子串）。
/// 3. cue 被切分成两段时按 segment 时间决定文本归属：保留 segment 经
///    事务映射后的时间落在哪个保留片段，其文本就归哪个片段。
/// 4. 片段重写后没有任何文本（例如整条 cue 只剩被删填充词）→ 该片段
///    随事务删除，不产出空字幕。
/// 5. 时间裁剪规则与 Models.rippledCaptionCues 一致（>50ms 保留、首段
///    沿用原 ID）；副字幕轨不走手术（无法校验），沿用既有 ripple。
enum CaptionSegmentSurgery {
    struct Report: Equatable {
        /// 重写文本并保留的 cue（片段）数。
        var rewrittenCues = 0
        /// 重写后没有任何文本而随事务删除的 cue 数。
        var deletedCues = 0
        /// 重建校验不过、文本原样保留的 cue 数。
        var skippedUnverifiedCues = 0
    }

    static func rewritten(
        cues: [CaptionCue],
        segments: [SpeechSegment],
        removedSegmentRanges: [ClosedRange<Double>],
        outcome: TimelineCutTransaction.Outcome
    ) -> (cues: [CaptionCue], report: Report) {
        var report = Report()
        var result: [CaptionCue] = []
        let tolerance = 1e-6
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let overlapped = outcome.deletions.contains {
                $0.lowerBound < cue.end - tolerance
                    && cue.start + tolerance < $0.upperBound
            }
            guard overlapped else {
                result.append(cue)
                continue
            }
            let cueSegments = segments
                .filter { segment in
                    let midpoint = segment.start + segment.duration / 2
                    return midpoint >= cue.start - tolerance
                        && midpoint <= cue.end + tolerance
                }
                .sorted { $0.start < $1.start }
            let verified = SubtitleFile.joinedSegmentTexts(
                cueSegments.map(\.text)
            ) == cue.text

            let pieces = outcome.keptRanges(in: cue.start...cue.end)
            guard verified else {
                if pieces.isEmpty {
                    report.deletedCues += 1
                } else {
                    report.skippedUnverifiedCues += 1
                    appendUnverified(cue, pieces: pieces, to: &result)
                }
                continue
            }

            var emitted = false
            for piece in pieces {
                let texts = cueSegments.compactMap { segment -> String? in
                    let range = segment.start...segment.start
                        + segment.duration
                    let removed = removedSegmentRanges.contains {
                        abs($0.lowerBound - range.lowerBound) <= tolerance
                            && abs($0.upperBound - range.upperBound)
                                <= tolerance
                    }
                    guard !removed else { return nil }
                    let mapped = outcome.mappedTime(segment.start)
                        ?? outcome.mappedTimeSnappingAfterCut(segment.start)
                    guard let mapped else { return nil }
                    return mapped >= piece.lowerBound - tolerance
                        && mapped <= piece.upperBound + tolerance
                        ? segment.text : nil
                }
                let text = SubtitleFile.joinedSegmentTexts(texts)
                guard
                    !text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    piece.upperBound - piece.lowerBound > 0.05
                else {
                    continue
                }
                result.append(
                    CaptionCue(
                        id: emitted ? UUID() : cue.id,
                        start: piece.lowerBound,
                        end: piece.upperBound,
                        text: text,
                        language: cue.language
                    )
                )
                emitted = true
                report.rewrittenCues += 1
            }
            if !emitted {
                report.deletedCues += 1
            }
        }
        return (result, report)
    }

    /// 校验不过的 cue：文本原样保留，切分规则与 ripple 相同。
    private static func appendUnverified(
        _ cue: CaptionCue,
        pieces: [ClosedRange<Double>],
        to result: inout [CaptionCue]
    ) {
        var emitted = false
        for piece in pieces {
            guard piece.upperBound - piece.lowerBound > 0.05 else {
                continue
            }
            result.append(
                CaptionCue(
                    id: emitted ? UUID() : cue.id,
                    start: piece.lowerBound,
                    end: piece.upperBound,
                    text: cue.text,
                    language: cue.language
                )
            )
            emitted = true
        }
    }
}

enum ChapterBuilder {
    struct Chapter: Hashable {
        var start: Double
        var end: Double
        var title: String
    }

    static func build(
        from cues: [CaptionCue],
        minimumDuration: Double = 4,
        totalDuration: Double
    ) -> [Chapter] {
        let cues = cues
            .filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            .sorted { $0.start < $1.start }
        guard !cues.isEmpty else { return [] }

        var chapters: [Chapter] = []
        var start = 0.0
        var end = 0.0
        var title = ""
        for cue in cues {
            let cueStart = min(max(0, cue.start), totalDuration)
            let cueEnd = min(totalDuration, max(cueStart + 0.05, cue.end))
            guard cueStart < totalDuration else { continue }
            if title.isEmpty {
                start = cueStart
                end = cueEnd
                title = shortTitle(cue.text)
                continue
            }
            let gap = cueStart - end
            let wouldRemainShort = end - start < minimumDuration
            if gap <= 1.5, wouldRemainShort {
                end = max(end, cueEnd)
            } else {
                chapters.append(
                    Chapter(start: start, end: end, title: title)
                )
                start = cueStart
                end = cueEnd
                title = shortTitle(cue.text)
            }
        }
        if !title.isEmpty {
            chapters.append(
                Chapter(start: start, end: end, title: title)
            )
        }
        return chapters
    }

    static func text(from chapters: [Chapter]) -> String {
        chapters.map { chapter in
            "\(timestamp(chapter.start)) \(chapter.title)"
        }
        .joined(separator: "\n") + (chapters.isEmpty ? "" : "\n")
    }

    private static func shortTitle(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).first ?? text
        return String(line.trimmingCharacters(in: .whitespaces).prefix(40))
    }

    private static func timestamp(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(
            format: "%02d:%02d:%02d",
            whole / 3600,
            (whole / 60) % 60,
            whole % 60
        )
    }
}
