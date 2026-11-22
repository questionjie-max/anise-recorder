import CoreGraphics
import Foundation

/// 测试专用假人脸检测器：固定返回画面左侧的一张脸（Vision 归一化
/// 坐标，左下原点）。线程安全计数器仅保留扩展空间；当前所有调用返回
/// 同一结果，用于验证分析管线与坐标映射。
enum FaceFocusDetectorStub {
    private static let lock = NSLock()
    private static var calls = 0

    static func nextFaces() -> [CGRect] {
        lock.lock()
        defer {
            calls += 1
            lock.unlock()
        }
        // 每隔两次调用把脸从左半边移到右半边：模拟真实的位置变化，
        // 让规划器产出「左→右」两段建议（t=0 与中段各一段）。
        let onLeft = (calls / 2).isMultiple(of: 2)
        return [
            CGRect(
                x: onLeft ? 0.2 : 0.7,
                y: 0.35,
                width: 0.2,
                height: 0.3
            )
        ]
    }

    static func reset() {
        lock.lock()
        calls = 0
        lock.unlock()
    }
}
