import AVFoundation
import CoreImage
import ImageIO
import Foundation
import UniformTypeIdentifiers

/// GIF 导出尺寸档位：小 / 中 / 大 → 最长边 360 / 720 / 1080，
/// 默认中档 720（与既有默认行为一致）。纯映射便于单测。
enum GifSizePreset: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:
            return "小"
        case .medium:
            return "中"
        case .large:
            return "大"
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .small:
            return 360
        case .medium:
            return 720
        case .large:
            return 1080
        }
    }

    /// 非法 / 缺失档位回退默认中档 720。
    static func resolved(_ rawValue: String?) -> GifSizePreset {
        GifSizePreset(rawValue: rawValue ?? "") ?? .medium
    }
}

/// 1.2 导出增强：GIF 导出。从现有帧管线分出 GIF 路径——复用
/// `CompositionBuilder` 的合成与 `RenderPlan` 统一渲染（AVAssetReader
/// VideoCompositionOutput 逐帧），再用 ImageIO 编码 GIF。
/// 默认参数：最长边 ≤720、15fps；面板按帧数估算体积档位，长片给警告。
enum GifExporter {
    static let defaultFrameRate = 15
    static let defaultMaximumWidth: CGFloat = 720
    /// 超过该时长（秒）在导出面板给出体积警告。
    static let longDurationThreshold: Double = 60

    struct Estimate {
        let frameCount: Int
        let frameSize: CGSize
        let estimatedBytes: Int64
        /// 小 / 中 / 大 / 超大 档位文案。
        let tier: String
        let isLong: Bool
    }

    /// 按帧数与尺寸估算体积（GIF 每帧 LZW 压缩后粗略按 0.25–0.35
    /// 字节/像素，取 0.3 并加 5% 容差；仅用于面板档位提示，不是精确值）。
    /// 按所选尺寸档位的最长边换算估算输入，随档位实时刷新。
    static func estimate(
        for project: StudioProject,
        outputSize: CGSize,
        frameRate: Int = defaultFrameRate,
        maximumWidth: CGFloat = defaultMaximumWidth
    ) -> Estimate {
        let duration = max(0.1, project.trimDuration)
        let frameCount = max(1, Int(duration * Double(frameRate)))
        let scale = min(
            1,
            maximumWidth / max(outputSize.width, outputSize.height)
        )
        let size = CGSize(
            width: max(
                2,
                (outputSize.width * scale / 2).rounded() * 2
            ),
            height: max(2, (outputSize.height * scale / 2).rounded() * 2)
        )
        let bytes = Int64(
            Double(frameCount) * Double(size.width * size.height) * 0.3
                * 1.05
        )
        let megabytes = Double(bytes) / 1_048_576
        let tier: String
        switch megabytes {
        case ..<2:
            tier = "较小"
        case ..<10:
            tier = "中等"
        case ..<50:
            tier = "较大"
        default:
            tier = "超大"
        }
        return Estimate(
            frameCount: frameCount,
            frameSize: size,
            estimatedBytes: bytes,
            tier: tier,
            isLong: duration > longDurationThreshold
        )
    }

    /// 渲染并写出 GIF。进度按已写出帧数回报。
    static func makeGif(
        for project: StudioProject,
        outputURL: URL,
        frameRate: Int = defaultFrameRate,
        maximumWidth: CGFloat = defaultMaximumWidth,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !outputURL.conflictsWithSourceFiles(of: project) else {
            throw ExportError.destinationIsSource
        }
        let composed = try await CompositionBuilder.makeComposition(
            for: project
        )
        try Task.checkCancellation()
        let videoComposition = CompositionBuilder.makeVideoComposition(
            for: composed.composition,
            project: project,
            cameraTrackID: composed.cameraTrackID,
            overlayTracks: composed.overlayTracks,
            outputSize: project.canvasOutputSize,
            frameRate: frameRate,
            burnsCaptions: project.captions.effectiveBurnMode != .off,
            captionBurnMode: project.captions.effectiveBurnMode
        )
        let renderSize = videoComposition.renderSize
        let scale = min(
            1,
            maximumWidth / max(renderSize.width, renderSize.height)
        )
        let gifSize = CGSize(
            width: max(2, (renderSize.width * scale / 2).rounded() * 2),
            height: max(2, (renderSize.height * scale / 2).rounded() * 2)
        )

        let reader = try AVAssetReader(asset: composed.composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composed.composition.tracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput.videoComposition = videoComposition
        guard reader.canAdd(videoOutput) else {
            throw ExportError.cannotAddOutput
        }
        reader.add(videoOutput)
        guard reader.startReading() else {
            throw reader.error ?? ExportError.failed
        }

        let temporaryURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".anise-recorder-(UUID().uuidString).gif"
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        guard
            let destination = CGImageDestinationCreateWithURL(
                temporaryURL as CFURL,
                UTType.gif.identifier as CFString,
                0,
                nil
            )
        else {
            throw ExportError.failed
        }
        // GIF 帧延迟以厘秒（1/100s）整数存储，1/15s = 6.67cs 会被统一
        // 舍入成 7cs，导致整片偏长约 5%、超出 ≤0.2s 的时长检核。按基准
        // 厘秒 + 均匀插入短帧（-1cs）补齐目标总时长，误差收敛到 1cs。
        let durationSeconds = composed.composition.duration.seconds
        let frameRateValue = Double(max(1, frameRate))
        let baseDelayCs = max(1, Int((100.0 / frameRateValue).rounded()))
        let totalFrames = max(
            1,
            Int((durationSeconds * frameRateValue).rounded())
        )
        let targetCs = max(totalFrames, Int((durationSeconds * 100).rounded()))
        let deficit = max(0, totalFrames * baseDelayCs - targetCs)
        func delayCs(forFrame index: Int) -> Int {
            // 前 deficit 帧按均匀分布降 1cs：x(i) = i*deficit/total 与
            // x(i+1) 不同则该帧属于补差帧。
            let before = index * deficit / max(1, totalFrames)
            let after = (index + 1) * deficit / max(1, totalFrames)
            return before == after ? baseDelayCs : max(1, baseDelayCs - 1)
        }
        var writtenFrames = 0
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // 合成时长会被取整到帧网格，末尾可能多出几帧；达到目标帧数
            // 即停止，保证 GIF 时长与成片一致（误差 ≤1 帧）。
            guard writtenFrames < totalFrames else { break }
            guard
                let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
            else {
                continue
            }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(
                image,
                from: CGRect(origin: .zero, size: image.extent.size)
            ) else {
                continue
            }
            // 按最大宽等比缩放（GIF 无半像素，取偶数尺寸）。
            let scaled = scaledImage(
                cgImage,
                to: gifSize
            )
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: Double(
                        delayCs(forFrame: writtenFrames)
                    ) / 100.0
                ]
            ]
            CGImageDestinationAddImage(
                destination,
                scaled,
                frameProperties as CFDictionary
            )
            writtenFrames += 1
            let value = min(
                0.98,
                Double(writtenFrames) / Double(max(1, totalFrames))
            )
            if writtenFrames % max(1, frameRate / 2) == 0 {
                await progress(value)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? ExportError.failed
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.failed
        }
        await progress(0.99)
        // 与 MP4 导出共用同一安装逻辑：已有 GIF 用 replaceItemAt 原子
        // 替换，替换失败保留旧文件，不再先删后移。
        try CompositionBuilder.installExport(
            temporaryURL: temporaryURL,
            outputURL: outputURL
        )
        await progress(1)
    }

    private static func scaledImage(
        _ image: CGImage,
        to size: CGSize
    ) -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard
            width > 1,
            height > 1,
            width != image.width || height != image.height,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }
        context.interpolationQuality = .medium
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage() ?? image
    }
}

private extension URL {
    /// GIF 目标不能是工程源素材。
    func conflictsWithSourceFiles(of project: StudioProject) -> Bool {
        let destination = standardizedFileURL.resolvingSymlinksInPath()
        let sources = [
            project.videoURL,
            project.microphoneURL,
            project.systemAudioURL,
            project.cameraURL,
            project.backgroundImageURL
        ].compactMap { $0 }
        return sources.contains { source in
            source.standardizedFileURL.resolvingSymlinksInPath()
                == destination
        }
    }
}
