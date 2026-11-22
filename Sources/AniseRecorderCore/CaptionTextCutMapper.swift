import Foundation

/// 字幕文本选区 → 成片时间区间映射（纯函数）。
///
/// 双模式（与 `CaptionSegmentSurgery` 同一口径）：
/// - **精确模式**：传入 cue 时间范围内的识别分段（本机识别当次
///   会话），且按 `SubtitleFile.joinedSegmentTexts` 重建校验通过——
///   选中文本覆盖的 segment 时间并集即剪切区间。
/// - **近似模式**：无 segments 或校验不过（SRT 导入 / 术语表改写 /
///   手动字幕 / 保存重开）——按选中字符数占整条的比例切 `[start, end)`，
///   `isApproximate = true`，UI 必须原地标注「按字数比例估算」。
///
/// 偏移单位为 **UTF-16 offset**（与 SwiftUI `TextField` 的
/// `selectedRange` 一致），内部转 `Character` 计算比例（中英混排按
/// 字符，不按字节）。
package enum CaptionTextCutMapper {
    /// 映射失败的原因（调用方转用户可见提示）。
    package enum Rejection: Equatable, Error {
        /// 选区为空（或整条选中）——没有可删的「中间段」。
        case emptySelection
        /// 剪掉时长低于 `minimumCutDuration`，会留下过短片段。
        case tooShort
        /// 剪切后剩余时长低于 `minimumRemainderDuration`。
        case remainderTooShort
    }

    /// 一条「删除选区对应音视频区间」的建议。
    package struct Suggestion: Equatable {
        /// 成片时间系剪切区间 [cutStart, cutEnd)。
        public let cutStart: Double
        public let cutEnd: Double
        /// 是否按字数比例近似（无 segment / 校验不过）。
        public let isApproximate: Bool
        /// 选中覆盖的 segment 数（近似模式为 0）。
        public let coveredSegments: Int

        package init(
            cutStart: Double,
            cutEnd: Double,
            isApproximate: Bool,
            coveredSegments: Int
        ) {
            self.cutStart = cutStart
            self.cutEnd = cutEnd
            self.isApproximate = isApproximate
            self.coveredSegments = coveredSegments
        }

        /// 预计剪掉的秒数。
        public var removedDuration: Double {
            max(0, cutEnd - cutStart)
        }
    }

    /// 剪掉片段的最短时长（秒）。低于它判定 `tooShort`——与
    /// `CaptionSplitter.minimumDuration` 同口径。
    package static let minimumCutDuration: Double = 0.3

    /// 剪切后原条剩余部分的最短时长（秒）。
    package static let minimumRemainderDuration: Double = 0.3

    /// 映射选区到成片时间区间。
    /// - Parameters:
    ///   - cueStart / cueEnd: 字幕条的成片时间区间（秒）
    ///   - text: 字幕条当前文本（与选区偏移同源）
    ///   - selection: 选区（UTF-16 offset，闭开区间）
    ///   - segments: cue 时间范围内的识别分段（可空；精确模式用）
    /// - Returns: 成功返回 `Suggestion`；失败返回 `Rejection`
    package static func suggest(
        cueStart: Double,
        cueEnd: Double,
        text: String,
        selection: Range<Int>,
        segments: [(text: String, start: Double, duration: Double)]
    ) -> Result<Suggestion, Rejection> {
        let characters = Array(text)
        guard !characters.isEmpty else { return .failure(.emptySelection) }
        let utf16Count = text.utf16.count
        let lower = min(max(selection.lowerBound, 0), utf16Count)
        let upper = min(max(selection.upperBound, lower), utf16Count)
        guard upper > lower else { return .failure(.emptySelection) }
        // 整条选中 = 没有「中间段」可删（调用方应改走删条路径）
        guard !(lower == 0 && upper == utf16Count) else {
            return .failure(.emptySelection)
        }
        let duration = cueEnd - cueStart
        guard duration > 0 else { return .failure(.tooShort) }

        // 选区转 Character 区间（比例计算按字符）
        let selStartChar = utf16ToCharacter(text, utf16Offset: lower)
        let selEndChar = utf16ToCharacter(text, utf16Offset: upper)

        let scoped = scopedSegments(
            segments,
            cueStart: cueStart,
            cueEnd: cueEnd
        )
        let rebuilt = scoped.isEmpty
            ? nil
            : joinedSegmentTexts(scoped.map(\.text))
        if let rebuilt, rebuilt == text, !scoped.isEmpty {
            return precise(
                cueStart: cueStart,
                cueEnd: cueEnd,
                selStartChar: selStartChar,
                selEndChar: selEndChar,
                segments: scoped
            )
        }
        return approximate(
            cueStart: cueStart,
            cueEnd: cueEnd,
            duration: duration,
            totalCharacters: characters.count,
            selStartChar: selStartChar,
            selEndChar: selEndChar
        )
    }

    // MARK: - 精确模式

    private static func precise(
        cueStart: Double,
        cueEnd: Double,
        selStartChar: Int,
        selEndChar: Int,
        segments: [(text: String, start: Double, duration: Double)]
    ) -> Result<Suggestion, Rejection> {
        // 按 joined 规则逐段累加，记录每段在重建文本中的字符区间
        // （连接空白归后段——与 joinedSegmentTexts 的拼接顺序一致）。
        var contributions: [(segment: (text: String, start: Double, duration: Double), range: Range<Int>)] = []
        var cursor = 0
        for segment in segments {
            let raw = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !raw.isEmpty else { continue }
            let piece = Array(raw)
            let start = cursor
            let end = cursor + piece.count
            contributions.append((segment, start ..< end))
            cursor = end
        }
        // cursor 之后可能还有连接空白？joined 在段间不加独立空白段，
        // 空白随段文本 trim 已去除；拼接时的连接空白计入后段起点之前，
        // 不改变「覆盖段」判定（选区落在空白上归相邻段并集）。
        guard !contributions.isEmpty else {
            return .failure(.emptySelection)
        }
        var firstStart: Double?
        var lastEnd: Double = 0
        var covered = 0
        for entry in contributions {
            // 选区与段区间有交集 → 覆盖
            let overlaps = selStartChar < entry.range.upperBound
                && selEndChar > entry.range.lowerBound
            guard overlaps else { continue }
            covered += 1
            let segStart = entry.segment.start
            let segEnd = entry.segment.start + entry.segment.duration
            if firstStart == nil { firstStart = segStart }
            lastEnd = segEnd
        }
        guard let cutStart = firstStart, covered > 0 else {
            return .failure(.emptySelection)
        }
        // segment 时间以 cue 边界钳制（浮点误差/中点归属边界）
        let clampedStart = min(max(cutStart, cueStart), cueEnd)
        let clampedEnd = min(max(lastEnd, clampedStart), cueEnd)
        return validate(
            cutStart: clampedStart,
            cutEnd: clampedEnd,
            cueStart: cueStart,
            cueEnd: cueEnd,
            isApproximate: false,
            coveredSegments: covered
        )
    }

    // MARK: - 近似模式

    private static func approximate(
        cueStart: Double,
        cueEnd: Double,
        duration: Double,
        totalCharacters: Int,
        selStartChar: Int,
        selEndChar: Int
    ) -> Result<Suggestion, Rejection> {
        let lowerFraction = Double(selStartChar) / Double(totalCharacters)
        let upperFraction = Double(selEndChar) / Double(totalCharacters)
        let cutStart = cueStart + duration * lowerFraction
        let cutEnd = cueStart + duration * upperFraction
        return validate(
            cutStart: cutStart,
            cutEnd: cutEnd,
            cueStart: cueStart,
            cueEnd: cueEnd,
            isApproximate: true,
            coveredSegments: 0
        )
    }

    // MARK: - 共用

    private static func validate(
        cutStart: Double,
        cutEnd: Double,
        cueStart: Double,
        cueEnd: Double,
        isApproximate: Bool,
        coveredSegments: Int
    ) -> Result<Suggestion, Rejection> {
        let clampedStart = min(max(cutStart, cueStart), cueEnd)
        let clampedEnd = min(max(cutEnd, clampedStart), cueEnd)
        guard clampedEnd - clampedStart >= Self.minimumCutDuration else {
            return .failure(.tooShort)
        }
        // 剩余：条头 + 条尾两段都不得过短
        let head = clampedStart - cueStart
        let tail = cueEnd - clampedEnd
        guard head >= Self.minimumRemainderDuration
            || head <= 0.001
        else {
            return .failure(.remainderTooShort)
        }
        guard tail >= Self.minimumRemainderDuration || tail <= 0.001 else {
            return .failure(.remainderTooShort)
        }
        return .success(
            Suggestion(
                cutStart: clampedStart,
                cutEnd: clampedEnd,
                isApproximate: isApproximate,
                coveredSegments: coveredSegments
            )
        )
    }

    /// 拼接规则副本：与 App target `SubtitleFile.joinedSegmentTexts`
    /// 逐字一致（空文本跳过；段间仅在「两侧皆非空白、皆非表意文字」时加
    /// 一个空格）。Core 不依赖 App target 类型，故在此维护同规则副本——
    /// 改动必须同步两处。
    static func joinedSegmentTexts(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// cue 时间范围内的 segment（中点归属、空文本过滤）——与
    /// `CaptionSegmentSurgery` 的既有规则一致。
    static func scopedSegments(
        _ segments: [(text: String, start: Double, duration: Double)],
        cueStart: Double,
        cueEnd: Double
    ) -> [(text: String, start: Double, duration: Double)] {
        segments.filter { segment in
            let raw = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !raw.isEmpty else { return false }
            let mid = segment.start + segment.duration / 2
            return mid >= cueStart && mid < cueEnd
        }
    }

    /// UTF-16 offset → Character offset（越界钳到两端；代理对中间退化为
    /// 文本末端——调用方极少触及）。
    static func utf16ToCharacter(_ text: String, utf16Offset: Int) -> Int {
        let utf16 = text.utf16
        let clamped = min(max(utf16Offset, 0), utf16.count)
        let index = utf16.index(utf16.startIndex, offsetBy: clamped)
        guard let stringIndex = index.samePosition(in: text) else {
            return text.count
        }
        return text.distance(from: text.startIndex, to: stringIndex)
    }
}
