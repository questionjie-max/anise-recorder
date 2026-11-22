import CoreGraphics
import Foundation

/// 归一化坐标点（左上角原点、y 向下，取值 0...1）——AGENTS.md 的全局
/// 坐标约定。原定义在应用层 Models.swift，1.2 人脸居中的纯逻辑也需要它，
/// 下沉到 Core（应用层通过 import AniseRecorderCore 继续使用同名类型）。
package struct NormalizedPoint: Codable, Hashable, Sendable {
    package var x: Double
    package var y: Double

    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    package var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// 1.2 人脸居中的纯逻辑规划器。输入按时间采样的检测结果（检测器无关，
/// 应用层用 Vision 填充；测试注入假检测），输出 cropFocus 建议段。
///
/// 边界定义（路线图要求写清）：
/// - 无脸：沿用上一个焦点（开头无脸用画面中心 0.5, 0.5）。
/// - 多脸：取最大脸（面积最大者）。
/// - 脸出画：焦点钳制在 0...1。
/// - 抖动：输出前做时间平滑 + 死区，相邻采样位移超过死区才产生新段。
package enum FaceFocusPlanner {
    package struct Observation: Hashable, Sendable {
        /// 采样时刻（摄像头轨源时间，秒）。
        package var time: Double
        /// 检出的人脸矩形（检测器输出的归一化坐标）。
        package var faces: [CGRect]

        package init(time: Double, faces: [CGRect]) {
            self.time = time
            self.faces = faces
        }
    }

    package struct Segment: Hashable, Sendable {
        /// 建议段起点（摄像头源时间，秒）。
        package var start: Double
        /// cropFocus（左上原点、y 向下，与 `CameraSettings.cropFocus`
        /// 同一约定）。
        package var focus: NormalizedPoint

        package init(start: Double, focus: NormalizedPoint) {
            self.start = start
            self.focus = focus
        }
    }

    /// 采样间隔下限（秒）：绝不逐帧跳，Vision 检测按 ≥0.5 秒采样。
    package static let minimumSamplingInterval = 0.5
    /// 焦点死区（归一化）：变化小于该值不产生新段，防止抖动。
    package static let focusDeadband = 0.03
    /// 时间平滑窗口（样本数）：相邻 3 个采样取中值滤波，抗单帧误检。
    package static let smoothingWindow = 3

    /// Vision 归一化坐标（左下原点、y 向上）→ cropFocus（左上、y 向下）。
    package static func cropFocusFromVisionRect(
        _ rect: CGRect
    ) -> NormalizedPoint {
        NormalizedPoint(
            x: min(1, max(0, Double(rect.midX))),
            y: min(1, max(0, Double(1 - rect.midY)))
        )
    }

    /// 最大脸的焦点；无脸返回 nil。
    package static func largestFaceFocus(
        in faces: [CGRect]
    ) -> NormalizedPoint? {
        guard
            let largest = faces.max(by: {
                $0.width * $0.height < $1.width * $1.height
            })
        else {
            return nil
        }
        return cropFocusFromVisionRect(largest)
    }

    package static func plan(
        observations: [Observation],
        analyzedDuration: Double,
        samplingInterval: Double = minimumSamplingInterval
    ) -> [Segment] {
        let duration = analyzedDuration.isFinite
            ? max(0, analyzedDuration)
            : 0
        guard duration > 0, samplingInterval >= minimumSamplingInterval
        else {
            return []
        }
        let sorted = observations
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }
            .sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        // 逐采样取最大脸焦点；中值平滑（窗口内焦点坐标的中位数）。
        var rawFocuses: [NormalizedPoint?] = sorted.map { observation in
            largestFaceFocus(in: observation.faces)
        }
        rawFocuses = medianSmooth(rawFocuses, window: smoothingWindow)

        // 展开为逐采样的有效焦点：无脸沿用上一个；死区内沿用，超过死区
        // 才切新段。段的起点用采样时刻（帧对齐由应用层处理）。
        var segments: [Segment] = []
        var currentFocus = NormalizedPoint(x: 0.5, y: 0.5)
        var hasEmitted = false
        for (index, observation) in sorted.enumerated() {
            let candidate = rawFocuses[index] ?? currentFocus
            let moved = abs(candidate.x - currentFocus.x)
                > focusDeadband
                || abs(candidate.y - currentFocus.y) > focusDeadband
            if !hasEmitted || moved {
                // 首段若贴近默认中心则不生成，避免无意义的第一段。
                if hasEmitted || distance(candidate, currentFocus) > focusDeadband {
                    segments.append(
                        Segment(start: observation.time, focus: candidate)
                    )
                    hasEmitted = true
                }
                currentFocus = candidate
            }
        }
        return segments
    }

    /// 中值平滑：窗口内已知（非 nil）焦点坐标逐维取中位数；窗口全空
    /// 保持 nil（沿用上一个焦点）。
    static func medianSmooth(
        _ values: [NormalizedPoint?],
        window: Int
    ) -> [NormalizedPoint?] {
        guard window > 1 else { return values }
        let half = window / 2
        return values.enumerated().map { index, value in
            if value != nil { return value }
            let start = max(0, index - half)
            let end = min(values.count - 1, index + half)
            let xs = (start...end).compactMap { values[$0]?.x }.sorted()
            let ys = (start...end).compactMap { values[$0]?.y }.sorted()
            guard !xs.isEmpty else { return nil }
            func median(_ list: [Double]) -> Double {
                list[list.count / 2]
            }
            return NormalizedPoint(x: median(xs), y: median(ys))
        }
    }

    private static func distance(
        _ a: NormalizedPoint,
        _ b: NormalizedPoint
    ) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
            .squareRoot()
    }
}

/// C1/加深队列：竖屏跟随灵敏度三档，映射到取景平移的最大速率。
package enum PortraitFollowSensitivity: String, CaseIterable {
    case slow
    case standard
    case fast

    /// 归一化宽度 / 秒：慢 = 更稳（远距离脸移动分更多小步），快 =
    /// 更跟手。死区与平滑窗口沿用同一组常量，只有速率档位不同。
    package var maximumHorizontalShiftPerSecond: Double {
        switch self {
        case .slow:
            return 0.35
        case .standard:
            return 0.6
        case .fast:
            return 1.0
        }
    }
}

/// C1 竖屏智能跟随（9:16 画布专用）的纯逻辑规划器。
///
/// 与 1.2 人脸居中的作用域关系（约定写死在此，UI 同步说明）：
/// - 竖屏跟随管「取景」：只在竖屏画布提供，把摄像头 fill 裁剪的水平
///   位置（cropFocus.x）按人脸中心平滑平移；只平移不缩放（不碰
///   size / 缩放区 / cropFocus.y）。
/// - 人脸居中管「焦点」：通用画布下的 cropFocus（x+y）取景焦点建议。
/// - 两者共用自动布局段池；竖屏画布下冲突时以竖屏跟随为准——跟随的
///   应用会整体替换自动段（含人脸居中段），竖屏画布下 UI 将人脸居中
///   入口让位给竖屏跟随。
///
/// 复用 `FaceFocusPlanner` 的采样间隔下限、死区与中值平滑规则，不新写
/// 检测。差异点：无脸时目标回中（0.5）而不是沿用上一个焦点；相邻段
/// 偏移变化率有硬上限，远距离人脸移动分步平移，绝不跳变。
package enum PortraitFollowPlanner {
    package struct Segment: Hashable, Sendable {
        /// 建议段起点（摄像头源时间，秒）。
        package var start: Double
        /// 取景水平偏移 = cropFocus.x（左上原点，0...1）。
        package var offsetX: Double

        package init(start: Double, offsetX: Double) {
            self.start = start
            self.offsetX = offsetX
        }
    }

    /// 取景水平偏移的默认最大变化速率（归一化宽度 / 秒）：脸瞬移时
    /// 分步平移，保证相邻段变化率不超过该值 × 采样间隔。灵敏度三档
    /// （加深队列）映射到不同速率：慢 = 更稳、快 = 更跟手。
    package static let maximumHorizontalShiftPerSecond = 0.6

    package static func plan(
        observations: [FaceFocusPlanner.Observation],
        analyzedDuration: Double,
        samplingInterval: Double = FaceFocusPlanner.minimumSamplingInterval,
        maximumHorizontalShiftPerSecond: Double = Self
            .maximumHorizontalShiftPerSecond
    ) -> [Segment] {
        let duration = analyzedDuration.isFinite
            ? max(0, analyzedDuration)
            : 0
        guard duration > 0, samplingInterval >= minimumSamplingInterval
        else {
            return []
        }
        let sorted = observations
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }
            .sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        // 逐采样取最大脸中心 x（复用最大脸规则；y 不参与跟随）。
        // 无脸的目标直接回中 0.5（与 FaceFocusPlanner 的“沿用”不同）。
        let targets: [Double] = sorted.map { observation in
            largestFaceCenterX(in: observation.faces) ?? 0.5
        }
        // 中值平滑（复用同一窗口常量）抗单帧误检。
        let smoothed = medianSmoothX(targets, window: smoothingWindow)

        // 展开为段：偏移向目标以最大速率步进，死区内不切段。
        var segments: [Segment] = []
        var current = 0.5
        let maxStep = maximumHorizontalShiftPerSecond * samplingInterval
        for (index, observation) in sorted.enumerated() {
            let target = min(1, max(0, smoothed[index]))
            let step = min(maxStep, max(-maxStep, target - current))
            let candidate = min(1, max(0, current + step))
            if segments.isEmpty
                || abs(candidate - current) > FaceFocusPlanner.focusDeadband
            {
                segments.append(
                    Segment(start: observation.time, offsetX: candidate)
                )
                current = candidate
            }
        }
        return segments
    }

    /// 最大脸的中心 x（Vision 归一化 x 与 cropFocus.x 同向，无需翻转）。
    private static func largestFaceCenterX(
        in faces: [CGRect]
    ) -> Double? {
        guard
            let largest = faces.max(by: {
                $0.width * $0.height < $1.width * $1.height
            })
        else {
            return nil
        }
        return min(1, max(0, Double(largest.midX)))
    }

    /// x 通道中值平滑（与 FaceFocusPlanner.medianSmooth 同一窗口语义）。
    private static func medianSmoothX(
        _ values: [Double],
        window: Int
    ) -> [Double] {
        guard window > 1 else { return values }
        let half = window / 2
        return values.enumerated().map { index, value in
            let start = max(0, index - half)
            let end = min(values.count - 1, index + half)
            let xs = (start...end).map { values[$0] }.sorted()
            return xs[xs.count / 2]
        }
    }

    private static var minimumSamplingInterval: Double {
        FaceFocusPlanner.minimumSamplingInterval
    }

    private static var smoothingWindow: Int {
        FaceFocusPlanner.smoothingWindow
    }
}
