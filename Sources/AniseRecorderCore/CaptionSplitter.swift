import Foundation

/// 字幕拆条纯函数（全文校对第 2 层第 1 步）。
///
/// 按字符比例把一条字幕在文本偏移处拆成两条；时间分配为**近似**
/// （按各自字符数占原条字符总数的比例切 `[start, end)`），边界钳制，
/// 极短条保护（任一侧低于 `minimumDuration` 时把分界点推向中点）。
/// UI 侧必须向用户标注「按字数比例估算，可再手动微调」。
package enum CaptionSplitter {
    /// 任一侧的最短时长（秒）。低于它时分界点被推向中点，避免
    /// 拆出肉眼不可读的碎片条。
    package static let minimumDuration: Double = 0.3

    /// 拆条结果：两条新字幕的 `(start, end)` 区间。
    package struct Split: Equatable {
        public let firstStart: Double
        public let firstEnd: Double
        public let secondStart: Double
        public let secondEnd: Double

        package init(
            firstStart: Double,
            firstEnd: Double,
            secondStart: Double,
            secondEnd: Double
        ) {
            self.firstStart = firstStart
            self.firstEnd = firstEnd
            self.secondStart = secondStart
            self.secondEnd = secondEnd
        }
    }

    /// 计算拆条后的两条时间区间。
    /// - Parameters:
    ///   - start: 原条起始（秒）
    ///   - end: 原条结束（秒）
    ///   - splitOffset: 拆分点在**原条文本**中的字符偏移（0..<count）
    ///   - textCount: 原条文本总字符数
    /// - Returns: 两条区间；`start >= end` 或 `textCount <= 1` 时返回 nil
    ///   （调用方应放弃拆条）
    package static func split(
        start: Double,
        end: Double,
        splitOffset: Int,
        textCount: Int
    ) -> Split? {
        guard end > start, textCount > 1 else { return nil }
        let clamped = min(max(splitOffset, 1), textCount - 1)
        let fraction = Double(clamped) / Double(textCount)
        let duration = end - start
        var boundary = start + duration * fraction

        // 极短条保护：任一侧低于最短时长时分界点推向中点
        if boundary - start < Self.minimumDuration {
            boundary = start + duration / 2
        }
        if end - boundary < Self.minimumDuration {
            boundary = start + duration / 2
        }
        return Split(
            firstStart: start,
            firstEnd: boundary,
            secondStart: boundary,
            secondEnd: end
        )
    }

    /// 把一条文本在偏移处切成两段（去首尾空白后仍为空的一侧返回 nil——
    /// 由调用方改走删条路径）。
    package static func splitText(
        _ text: String,
        at splitOffset: Int
    ) -> (first: String, second: String)? {
        let characters = Array(text)
        guard characters.count > 1 else { return nil }
        let clamped = min(max(splitOffset, 1), characters.count - 1)
        let first = String(characters[..<clamped])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(characters[clamped...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return (first, second)
    }
}
