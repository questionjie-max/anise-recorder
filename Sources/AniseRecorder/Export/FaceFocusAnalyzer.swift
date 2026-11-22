import AVFoundation
import CoreImage
import Foundation
import AniseRecorderCore
import Vision

/// 1.2 人脸居中的应用层分析器：对摄像头轨按 ≥0.5 秒间隔采样
/// （绝不逐帧），Vision 检测人脸，交给 Core 的 `FaceFocusPlanner`
/// 产出 cropFocus 建议段。后台运行、可取消，不冻结 UI。
/// 真实人脸效果需真机摄像头人工验收；自动测试注入假检测器验证管线。
enum FaceFocusAnalyzer {
    /// 实际采样间隔（秒）：高于 Core 的 0.5 秒下限，控制 Vision 开销。
    static let samplingInterval: Double = 0.6

    /// 检测器抽象：输入帧 CGImage，输出 Vision 归一化人脸矩形。
    /// 生产用 VNDetectFaceRectanglesRequest；测试注入固定结果。
    typealias FaceDetector = (CGImage) throws -> [CGRect]

    static func analyze(
        cameraURL: URL,
        cameraOffset: Double,
        project: StudioProject,
        detector: FaceDetector = visionDetector(),
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> [FaceFocusPlanner.Segment] {
        let sampled = try await sampleObservations(
            cameraURL: cameraURL,
            detector: detector,
            isCancelled: isCancelled
        )
        let segments = FaceFocusPlanner.plan(
            observations: sampled.observations,
            analyzedDuration: sampled.duration,
            samplingInterval: samplingInterval
        )
        // 摄像头文件时间 → 工程源时间（+cameraOffset）→ 成片时间。
        return segments.compactMap { segment in
            guard
                let outputTime = project.outputTime(
                    forSourceTime: segment.start + cameraOffset
                )
            else {
                return nil
            }
            return FaceFocusPlanner.Segment(
                start: outputTime,
                focus: segment.focus
            )
        }
    }

    /// C1 竖屏跟随分析：复用同一套采样与检测，交给 `PortraitFollowPlanner`
    /// 产出仅水平偏移的建议段（时间映射与人脸居中一致）。灵敏度三档
    /// （加深队列）映射到平移速率。
    static func analyzePortraitFollow(
        cameraURL: URL,
        cameraOffset: Double,
        project: StudioProject,
        sensitivity: PortraitFollowSensitivity = .standard,
        detector: FaceDetector = visionDetector(),
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> [PortraitFollowPlanner.Segment] {
        let sampled = try await sampleObservations(
            cameraURL: cameraURL,
            detector: detector,
            isCancelled: isCancelled
        )
        let segments = PortraitFollowPlanner.plan(
            observations: sampled.observations,
            analyzedDuration: sampled.duration,
            samplingInterval: samplingInterval,
            maximumHorizontalShiftPerSecond: sensitivity
                .maximumHorizontalShiftPerSecond
        )
        return segments.compactMap { segment in
            guard
                let outputTime = project.outputTime(
                    forSourceTime: segment.start + cameraOffset
                )
            else {
                return nil
            }
            return PortraitFollowPlanner.Segment(
                start: outputTime,
                offsetX: segment.offsetX
            )
        }
    }

    /// 按 `samplingInterval` 采样摄像头轨并检测人脸（检测器可注入）。
    static func sampleObservations(
        cameraURL: URL,
        detector: FaceDetector,
        isCancelled: @escaping () -> Bool
    ) async throws -> (
        observations: [FaceFocusPlanner.Observation],
        duration: Double
    ) {
        let asset = AVURLAsset(url: cameraURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > samplingInterval else {
            return ([], duration.isFinite ? duration : 0)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(
            seconds: samplingInterval / 2,
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceAfter = CMTime(
            seconds: samplingInterval / 2,
            preferredTimescale: 600
        )
        var observations: [FaceFocusPlanner.Observation] = []
        var time = 0.0
        while time < duration {
            if isCancelled() {
                throw CancellationError()
            }
            let sampleTime = CMTime(
                seconds: time,
                preferredTimescale: 600
            )
            if let frame = try? await generator.image(at: sampleTime).image {
                let faces = try detector(frame)
                observations.append(
                    FaceFocusPlanner.Observation(time: time, faces: faces)
                )
            }
            time += samplingInterval
        }
        if isCancelled() {
            throw CancellationError()
        }
        return (observations, duration)
    }

    /// 生产检测器：VNDetectFaceRectanglesRequest（全离线、不联网）。
    static func visionDetector() -> FaceDetector {
        { image in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(
                cgImage: image,
                options: [:]
            )
            try handler.perform([request])
            return request.results?.map(\.boundingBox) ?? []
        }
    }
}
