import Foundation

/// 静音告警状态机（第 1 层纯函数）。
///
/// 纪律（写进验收标准）：**窗口内持续静音只告警一次；恢复人声不告警；
/// 只告警不干预录制**。状态机把这三条钉死，UI 层只读
/// `shouldWarn` 的置位结果。
package struct SilentAlarm {
    /// 观测窗口：开录后 8-15 秒内持续静音才告警。
    static let windowStart: Double = 8
    static let windowEnd: Double = 15

    private(set) var hasWarned = false

    package init() {}

    package init(hasWarned: Bool) {
        self.hasWarned = hasWarned
    }

    /// 喂入一次「当前是否静音」的采样，返回是否应当**触发一次**告警。
    /// - Parameters:
    ///   - isSilent: 本次采样的静音判定（InputLevelMeter.isSilent）
    ///   - elapsed: 距录制开始的秒数
    /// - Returns: 仅第一次满足条件时返回 true；此后始终 false
    @discardableResult
    package mutating func sample(isSilent: Bool, elapsed: Double) -> Bool {
        guard !hasWarned else { return false }
        guard isSilent else { return false }
        guard elapsed >= Self.windowStart, elapsed <= Self.windowEnd else {
            return false
        }
        hasWarned = true
        return true
    }
}
