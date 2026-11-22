import Foundation

/// 方向键步进播放头（纯函数部分）。
///
/// 左右方向键移动播放头：默认步进 1 帧（1/fps），按住 Shift 步进 1 秒；
/// 结果钳制在 [0, duration]。摄像头微调已改道 `Option+方向键`
/// （EditorView 键盘路由），与此互不占用。
package enum PlayheadStepper {
    /// 返回步进后的播放头位置；`isFrameStep` 为 false 时按 Shift 的
    /// 1 秒粗步。步进方向由 `isForward` 决定。
    package static func step(
        current: Double,
        duration: Double,
        fps: Double,
        isForward: Bool,
        isCoarse: Bool
    ) -> Double {
        let delta: Double
        if isCoarse {
            delta = 1.0
        } else {
            delta = 1.0 / max(1, fps)
        }
        let moved = current + (isForward ? delta : -delta)
        return min(max(0, moved), max(0, duration))
    }
}
