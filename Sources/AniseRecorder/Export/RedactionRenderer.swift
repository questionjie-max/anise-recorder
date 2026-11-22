import CoreImage
import Foundation

/// 1.2 定时打码渲染：把已映射到输出像素的区域用高斯模糊 / 马赛克
/// 不可逆破坏。像素级要求：区域外像素与未打码渲染逐位一致（用
/// CIBlendWithMask 只在矩形内替换），多块区域按开始时间顺序叠加。
enum RedactionRenderer {
    static func apply(
        _ image: CIImage,
        redactions: [PlannedRedaction]
    ) -> CIImage {
        var result = image
        for item in redactions {
            guard item.rect.width > 1, item.rect.height > 1 else { continue }
            result = applyOne(result, item: item)
        }
        return result
    }

    private static func applyOne(
        _ image: CIImage,
        item: PlannedRedaction
    ) -> CIImage {
        let rect = item.rect
        let intensity = min(1, max(0.2, item.region.intensity))
        let processed: CIImage
        switch item.region.style {
        case .blur:
            // 模糊半径随区域高度与强度缩放；0.28 保证短边方向也充分混合。
            let radius = min(
                64,
                max(6, rect.height * 0.28 * (0.5 + intensity))
            )
            processed = image.applyingFilter(
                "CIGaussianBlur",
                parameters: ["inputRadius": radius]
            )
        case .mosaic:
            // 马赛克粒度：区域高度的约 1/6 * 强度系数，最低 6 像素。
            // CIPixellate 是逐格中心点采样，直接对高频图案（文字）会放大
            // 原图案；先做半格半径的模糊再点采样，每格才是真正的平均色。
            let scale = min(
                90,
                max(6, rect.height * 0.16 * (0.5 + intensity))
            )
            let averaged = image.applyingFilter(
                "CIGaussianBlur",
                parameters: ["inputRadius": scale / 2]
            )
            processed = averaged.applyingFilter(
                "CIPixellate",
                parameters: [
                    "inputScale": scale,
                    "inputCenter": CIVector(
                        x: rect.midX,
                        y: rect.midY
                    )
                ]
            )
        }
        let mask = rectangleMask(rect: rect)
        // 背景用原始图像：掩码外像素与未打码渲染完全一致。
        return processed.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: mask
            ]
        )
    }

    private static func rectangleMask(rect: CGRect) -> CIImage {
        // CIRectangleGenerator 没有 inputExtent 参数；圆角矩形生成器有，
        // 半径取 0 即纯矩形（CanvasRenderer.roundedMask 同款用法）。
        let filter = CIFilter(name: "CIRoundedRectangleGenerator")
        filter?.setValue(
            CIVector(cgRect: rect),
            forKey: "inputExtent"
        )
        filter?.setValue(0, forKey: "inputRadius")
        filter?.setValue(CIColor.white, forKey: "inputColor")
        return (filter?.outputImage ?? CIImage(color: .white))
            .cropped(to: rect)
    }
}
