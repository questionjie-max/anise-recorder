import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import AniseRecorderCore

/// F2 素材叠加轨：视频叠加素材在合成里的轨道引用（每个视频叠加
/// 片段一条 composition track）。
struct OverlayTrackRef {
    let clipID: UUID
    let trackID: CMPersistentTrackID
}

final class StudioCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    /// 视频叠加轨（clipID ↔ composition trackID 对照）。
    let overlayTracks: [OverlayTrackRef]
    let project: StudioProject
    let outputSize: CGSize
    let burnsCaptions: Bool
    /// 导出时的烧录模式；预览传 nil（显示全部已启用轨）。
    let captionBurnMode: CaptionBurnMode?

    init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        overlayTracks: [OverlayTrackRef] = [],
        project: StudioProject,
        outputSize: CGSize,
        burnsCaptions: Bool,
        captionBurnMode: CaptionBurnMode? = nil
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.overlayTracks = overlayTracks
        self.project = project
        self.outputSize = outputSize
        self.burnsCaptions = burnsCaptions
        self.captionBurnMode = captionBurnMode
        var ids = [NSNumber(value: screenTrackID)]
        if let cameraTrackID {
            ids.append(NSNumber(value: cameraTrackID))
        }
        ids.append(
            contentsOf: overlayTracks.map { NSNumber(value: $0.trackID) }
        )
        requiredSourceTrackIDs = ids
    }
}

final class StudioVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_32BGRA
            ]
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_32BGRA
            ]
        ]
    }

    private let context = CIContext(
        options: [.workingColorSpace: NSNull()]
    )
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard
                let instruction = request.videoCompositionInstruction
                    as? StudioCompositionInstruction,
                let buffer = request.renderContext.newPixelBuffer()
            else {
                request.finish(
                    with: StudioCompositorError.cannotCreateOutput
                )
                return
            }

            let screen = request.sourceFrame(byTrackID: instruction.screenTrackID)
                .map { CIImage(cvPixelBuffer: $0) }
            let camera = instruction.cameraTrackID
                .flatMap { request.sourceFrame(byTrackID: $0) }
                .map { CIImage(cvPixelBuffer: $0) }
            // F2：视频叠加素材帧按 clipID 收集（track 上无帧的时段不画）。
            var overlayFrames: [UUID: CIImage] = [:]
            for track in instruction.overlayTracks {
                if
                    let frame = request.sourceFrame(byTrackID: track.trackID)
                {
                    overlayFrames[track.clipID] = CIImage(cvPixelBuffer: frame)
                }
            }
            let output = CanvasRenderer.render(
                screen: screen,
                camera: camera,
                overlayFrames: overlayFrames,
                time: request.compositionTime.seconds,
                project: instruction.project,
                outputSize: instruction.outputSize,
                burnsCaptions: instruction.burnsCaptions,
                captionBurnMode: instruction.captionBurnMode
            )
            let bounds = CGRect(origin: .zero, size: instruction.outputSize)
            context.render(
                output,
                to: buffer,
                bounds: bounds,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

private enum StudioCompositorError: LocalizedError {
    case cannotCreateOutput

    var errorDescription: String? {
        "无法创建合成画面。"
    }
}

enum RenderBackground {
    case none
    case solid(CIColor)
    case gradient(CIColor, CIColor)
    case image(URL?)
}

/// 已映射到输出像素的打码计划项。
struct PlannedRedaction: Hashable {
    let region: RedactionRegion
    let rect: CGRect
}

/// F2：单条叠加层的输出像素矩形与当前帧内容（nil = 该时刻无画面）。
struct PlannedOverlay {
    let rect: CGRect
    let content: CIImage?
}

struct RenderPlan {
    let project: StudioProject
    let burnsCaptions: Bool
    let outputSize: CGSize
    let outputRect: CGRect
    let time: TimeInterval
    let sourceSize: CGSize
    let screenRect: CGRect
    let screenCornerRadius: CGFloat
    let screenShadowEnabled: Bool
    let screenShadowIntensity: Double
    let showsScreen: Bool
    let zoomSettings: ZoomSettings
    let cameraRect: CGRect
    let cameraSettings: CameraSettings
    let showsCamera: Bool
    let background: RenderBackground
    /// 当前时刻生效的打码区域，已经映射到最终输出像素（1.2 块2）。
    let redactions: [PlannedRedaction]
    /// nil = 预览（显示全部已启用字幕轨）；非 nil = 按烧录模式渲染。
    let captionBurnMode: CaptionBurnMode?
    /// F2 素材叠加层（数组序 = 叠放序，摄像头之上、打码之下）。
    let overlayLayers: [PlannedOverlay]

    init(
        project: StudioProject,
        time: TimeInterval,
        outputSize: CGSize,
        burnsCaptions: Bool = true,
        captionBurnMode: CaptionBurnMode? = nil,
        overlayFrames: [UUID: CIImage] = [:]
    ) {
        self.init(
            project: project,
            time: time,
            outputSize: outputSize,
            settings: project.cameraSettings(atOutput: time),
            burnsCaptions: burnsCaptions,
            captionBurnMode: captionBurnMode,
            overlayFrames: overlayFrames
        )
    }

    init(
        project: StudioProject,
        time: TimeInterval,
        outputSize: CGSize,
        settings: CameraSettings,
        burnsCaptions: Bool = true,
        captionBurnMode: CaptionBurnMode? = nil,
        overlayFrames: [UUID: CIImage] = [:]
    ) {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let sourceSize = CGSize(
            width: max(2, project.width),
            height: max(2, project.height)
        )
        let availableRect = CanvasLayout.availableRect(
            outputSize: outputSize,
            padding: project.canvas.padding
        )
        let contentRect = CanvasLayout.aspectFitRect(
            sourceSize: sourceSize,
            in: availableRect
        )
        let layoutRect = settings.layout == .sideBySide
            || settings.layout == .cameraOnly
            ? availableRect
            : contentRect
        let screenSlot = CanvasLayout.screenSlot(
            outputSize: outputSize,
            contentRect: layoutRect,
            settings: settings
        )
        let fittedScreenRect = CanvasLayout.aspectFitRect(
            sourceSize: sourceSize,
            in: screenSlot
        )
        let clicks = project.clicks.compactMap { click -> ClickEvent? in
            guard
                let outputTime = project.timeline.outputTime(
                    forSource: click.time
                )
            else {
                return nil
            }
            var mapped = click
            mapped.time = outputTime
            return mapped
        }

        self.project = project
        self.burnsCaptions = burnsCaptions
        self.outputSize = outputSize
        self.outputRect = outputRect
        self.time = time
        self.sourceSize = sourceSize
        screenRect = fittedScreenRect
        screenCornerRadius = {
            let fraction = min(0.12, max(0, project.canvas.cornerRadius))
            return min(
                fittedScreenRect.width,
                fittedScreenRect.height
            ) * fraction
        }()
        screenShadowEnabled = project.canvas.shadowEnabled
        screenShadowIntensity = project.canvas.shadowIntensity
        showsScreen = settings.layout != .cameraOnly
        let zoomSettings = ZoomSettings(
            enabled: project.autoZoom,
            scale: project.zoomScale,
            duration: project.zoomDuration,
            clicks: clicks,
            regions: project.zoomRegions
        )
        self.zoomSettings = zoomSettings
        let baseCameraRect = CanvasLayout.cameraSlot(
            outputSize: outputSize,
            contentRect: layoutRect,
            settings: settings
        )
        cameraRect = Self.cameraRect(
            base: baseCameraRect,
            time: time,
            outputSize: outputSize,
            sourceSize: sourceSize,
            screenRect: fittedScreenRect,
            zoomSettings: zoomSettings,
            settings: settings
        )
        cameraSettings = settings
        showsCamera = settings.enabled && settings.layout != .screenOnly
        self.captionBurnMode = captionBurnMode
        redactions = project
            .activeRedactionRegions(atOutput: time)
            .compactMap { region in
                guard
                    let rect = region.outputRect(
                        screenRect: fittedScreenRect,
                        sourceSize: sourceSize,
                        zoomSettings: zoomSettings,
                        time: time
                    )
                else {
                    return nil
                }
                return PlannedRedaction(region: region, rect: rect)
            }
        background = {
            let background = project.canvas.background
            switch background.kind {
            case .none:
                return .none
            case .solid:
                return .solid(CIColor(hex: background.colorHex))
            case .gradient:
                return .gradient(
                    CIColor(hex: background.gradientStartHex),
                    CIColor(hex: background.gradientEndHex)
                )
            case .image:
                return .image(project.backgroundImageURL)
            }
        }()
        overlayLayers = Self.plannedOverlayLayers(
            project: project,
            time: time,
            outputSize: outputSize,
            videoFrames: overlayFrames
        )
    }

    /// F2 叠加层计划：几何按素材宽高比折算；图片层走 NSCache 解码，
    /// 视频层取合成器送来的当前帧（素材播完的时段无帧不画）。
    private static func plannedOverlayLayers(
        project: StudioProject,
        time: TimeInterval,
        outputSize: CGSize,
        videoFrames: [UUID: CIImage]
    ) -> [PlannedOverlay] {
        project.activeOverlayClips(atOutput: time).map { clip in
            let rect = CanvasLayout.overlayRect(
                outputSize: outputSize,
                aspect: CGFloat(max(clip.aspect, 0.01)),
                center: clip.effectiveCenter,
                size: clip.size
            )
            let content: CIImage?
            switch clip.kind {
            case .image:
                // 先按文件名查缓存（命中即跳过解析 URL 的 fileExists
                // 热路径）；读写键统一为 fileName，未命中才解析 URL。
                if let cached = overlayImageCache.object(
                    forKey: clip.fileName as NSString
                ) {
                    content = cached
                } else if
                    let url = project.overlayMediaURL(for: clip),
                    let image = overlayImage(at: url)
                {
                    overlayImageCache.setObject(
                        image, forKey: clip.fileName as NSString
                    )
                    content = image
                } else {
                    content = nil
                }
            case .video:
                content = videoFrames[clip.id]
            }
            return PlannedOverlay(rect: rect, content: content)
        }
    }

    private static let overlayImageCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 16
        return cache
    }()

    private static func overlayImage(at url: URL) -> CIImage? {
        guard let image = CIImage(contentsOf: url) else { return nil }
        return image
    }

    private static func cameraRect(
        base baseRect: CGRect,
        time: TimeInterval,
        outputSize: CGSize,
        sourceSize: CGSize,
        screenRect: CGRect,
        zoomSettings: ZoomSettings,
        settings: CameraSettings
    ) -> CGRect {
        guard
            settings.enabled,
            settings.layout == .pictureInPicture,
            settings.avoidsZoomFocus,
            let focus = ZoomRenderer.activeFocus(
                at: time,
                settings: zoomSettings
            )
        else {
            return baseRect
        }
        let sourceExtent = CGRect(origin: .zero, size: sourceSize)
        guard
            let projection = ZoomRenderer.projection(
                sourceExtent: sourceExtent,
                time: time,
                settings: zoomSettings,
                outputSize: screenRect.size
            )
        else {
            return baseRect
        }
        let projected = projection.map(
            focus.point,
            from: sourceExtent
        )
        return CanvasLayout.cameraRectAvoidingZoomFocus(
            baseRect: baseRect,
            focusPoint: CGPoint(
                x: screenRect.minX + projected.x,
                y: screenRect.minY + projected.y
            ),
            weight: focus.weight,
            outputSize: outputSize,
            settings: settings
        )
    }
}

enum CanvasRenderer {
    private static let imageCache = NSCache<NSString, CIImage>()

    static func render(
        screen: CIImage?,
        camera: CIImage?,
        overlayFrames: [UUID: CIImage] = [:],
        time: TimeInterval,
        project: StudioProject,
        outputSize: CGSize,
        burnsCaptions: Bool = true,
        captionBurnMode: CaptionBurnMode? = nil
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: outputSize)
        if
            let transition = project.cameraTransition(atOutput: time),
            transition.progress < 0.999
        {
            let fromPlan = RenderPlan(
                project: project,
                time: time,
                outputSize: outputSize,
                settings: transition.from,
                burnsCaptions: burnsCaptions,
                captionBurnMode: captionBurnMode,
                overlayFrames: overlayFrames
            )
            let toPlan = RenderPlan(
                project: project,
                time: time,
                outputSize: outputSize,
                settings: transition.to,
                burnsCaptions: burnsCaptions,
                captionBurnMode: captionBurnMode,
                overlayFrames: overlayFrames
            )
            return dissolve(
                renderFrame(screen: screen, camera: camera, plan: fromPlan),
                to: renderFrame(
                    screen: screen,
                    camera: camera,
                    plan: toPlan
                ),
                progress: transition.progress
            )
                .cropped(to: canvasRect)
        }
        let plan = RenderPlan(
            project: project,
            time: time,
            outputSize: outputSize,
            burnsCaptions: burnsCaptions,
            captionBurnMode: captionBurnMode,
            overlayFrames: overlayFrames
        )
        return renderFrame(screen: screen, camera: camera, plan: plan)
    }

    private static func renderFrame(
        screen: CIImage?,
        camera: CIImage?,
        plan: RenderPlan
    ) -> CIImage {
        var image = background(
            for: plan.background,
            outputSize: plan.outputSize
        )

        if plan.showsScreen, let screen {
            let zoomed = ZoomRenderer.image(
                source: screen,
                time: plan.time,
                settings: plan.zoomSettings,
                outputSize: plan.screenRect.size
            )
            let withCursor = CursorRenderer.overlay(
                on: zoomed,
                time: plan.time,
                project: plan.project,
                screenExtent: screen.extent,
                zoomSettings: plan.zoomSettings,
                outputSize: plan.screenRect.size
            )
            let positioned = withCursor.transformed(
                by: CGAffineTransform(
                    translationX: plan.screenRect.minX,
                    y: plan.screenRect.minY
                )
            )
            if plan.screenShadowEnabled {
                let shadow = makeShadow(
                    rect: plan.screenRect,
                    cornerRadius: plan.screenCornerRadius,
                    intensity: plan.screenShadowIntensity
                )
                image = shadow.composited(over: image)
            }
            let masked = applyRoundedMask(
                to: positioned,
                rect: plan.screenRect,
                cornerRadius: plan.screenCornerRadius
            )
            image = masked.composited(over: image)
        }

        if
            plan.showsCamera,
            let camera
        {
            let keyedEnabled = plan.project.cameraChromaKey.enabled
            // 抠像同时交出 matte（不透明灰色图），供 light
            // wrap 定位边缘环带；matte 与提词画面共用同一 fill / fit
            // 变换，保证对齐。
            let keyed = keyedEnabled
                ? ChromaKeyRenderer.applyWithMatte(
                    camera,
                    settings: plan.project.cameraChromaKey
                )
                : (image: camera, matte: CIImage.empty())
            let cameraImage: CIImage
            let matteImage: CIImage
            switch plan.cameraSettings.contentMode {
            case .fill:
                cameraImage = fill(
                    keyed.image,
                    in: plan.cameraRect,
                    focus: plan.cameraSettings.cropFocus
                )
                matteImage = keyedEnabled
                    ? fill(
                        keyed.matte,
                        in: plan.cameraRect,
                        focus: plan.cameraSettings.cropFocus
                    )
                    : CIImage.empty()
            case .fit:
                cameraImage = fit(keyed.image, in: plan.cameraRect)
                matteImage = keyedEnabled
                    ? fit(keyed.matte, in: plan.cameraRect)
                    : CIImage.empty()
            }
            let mirrored = plan.cameraSettings.mirrored
                ? mirror(cameraImage, around: plan.cameraRect)
                : cameraImage
            // light wrap：rect 空间，backdrop = 画布摄像头区域裁剪
            /// （不随相机镜像翻转——最终画面上该位置背后的就是画布
            /// 本身；环带跟随镜像后的 matte 边缘）；关闭抠像时不走。
            let wrapped = keyedEnabled
                ? ChromaKeyRenderer.applyLightWrap(
                    mirrored,
                    matte: plan.cameraSettings.mirrored
                        ? mirror(matteImage, around: plan.cameraRect)
                        : matteImage,
                    settings: plan.project.cameraChromaKey,
                    backdrop: image.cropped(to: plan.cameraRect)
                )
                : mirrored
            let cornerRadius = cameraCornerRadius(
                rect: plan.cameraRect,
                settings: plan.cameraSettings
            )
            if
                plan.cameraSettings.shadowEnabled,
                !plan.project.cameraChromaKey.enabled
            {
                let shadow = makeShadow(
                    rect: plan.cameraRect,
                    cornerRadius: cornerRadius,
                    intensity: plan.cameraSettings.shadowIntensity
                )
                image = shadow.composited(over: image)
            }
            let masked = plan.project.cameraChromaKey.enabled
                ? wrapped
                : applyRoundedMask(
                    to: mirrored,
                    rect: plan.cameraRect,
                    cornerRadius: cornerRadius
                )
            image = masked.composited(over: image)
            if
                !plan.project.cameraChromaKey.enabled,
                let border = cameraBorder(
                    rect: plan.cameraRect,
                    cornerRadius: cornerRadius,
                    settings: plan.cameraSettings,
                    outputSize: plan.outputSize
                )
            {
                image = border.composited(over: image)
            }
        }

        // F2 素材叠加层：摄像头之上、打码/字幕之下（画中画语义）；
        // 数组序即叠放序，素材播完的时段（无帧）不画。
        for layer in plan.overlayLayers {
            guard let content = layer.content else { continue }
            let fitted = fit(content, in: layer.rect)
            image = fitted.composited(over: image)
        }

        // 按键小条：输出画布左下角（与底部居中的字幕错开），同样
        // 在打码/字幕之前（功能性遮挡优先）。
        image = KeyStripRenderer.overlay(
            on: image,
            time: plan.time,
            project: plan.project,
            outputSize: plan.outputSize
        )

        // 1.2 打码：作用于屏幕 + 摄像头合成后的最终输出像素（缩放后仍
        // 不可辨认），在字幕之前应用——用户字幕不被打码破坏。
        if !plan.redactions.isEmpty {
            image = RedactionRenderer.apply(image, redactions: plan.redactions)
        }
        if plan.burnsCaptions {
            image = CaptionRenderer.overlay(
                on: image,
                time: plan.time,
                project: plan.project,
                outputSize: plan.outputSize,
                burnMode: plan.captionBurnMode
            )
        }
        // 1.2 章节标题卡：在字幕之后叠加（进统一渲染链，预览/导出一致）。
        image = CaptionRenderer.chapterCardOverlay(
            on: image,
            time: plan.time,
            project: plan.project,
            outputSize: plan.outputSize
        )
        return image.cropped(to: plan.outputRect)
    }

    private static func dissolve(
        _ start: CIImage,
        to target: CIImage,
        progress: Double
    ) -> CIImage {
        start.applyingFilter(
            "CIDissolveTransition",
            parameters: [
                "inputTargetImage": target,
                "inputTime": min(1, max(0, progress))
            ]
        )
    }

    private static func background(
        for background: RenderBackground,
        outputSize: CGSize
    ) -> CIImage {
        let rect = CGRect(origin: .zero, size: outputSize)
        switch background {
        case .none:
            return CIImage(
                color: CIColor(red: 0.02, green: 0.025, blue: 0.026, alpha: 1)
            ).cropped(to: rect)
        case .solid(let color):
            return CIImage(color: color).cropped(to: rect)
        case .gradient(let start, let end):
            let gradient = CIFilter(name: "CILinearGradient")
            gradient?.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            gradient?.setValue(
                CIVector(x: outputSize.width, y: outputSize.height),
                forKey: "inputPoint1"
            )
            gradient?.setValue(start, forKey: "inputColor0")
            gradient?.setValue(end, forKey: "inputColor1")
            return (gradient?.outputImage ?? CIImage(color: start))
                .cropped(to: rect)
        case .image(let url):
            guard
                let url,
                let source = cachedImage(url)
            else {
                return CIImage(
                    color: CIColor(red: 0.02, green: 0.025, blue: 0.026, alpha: 1)
                ).cropped(to: rect)
            }
            return fill(source, in: rect)
        }
    }

    private static func cachedImage(_ url: URL) -> CIImage? {
        let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let identity = values?.fileResourceIdentifier
            .map { String(describing: $0) }
            ?? "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key = "\(url.path)|\(identity)" as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let image = CIImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func fill(
        _ image: CIImage,
        in rect: CGRect,
        focus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5)
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let focusX = min(1, max(0, CGFloat(focus.x)))
        let focusY = min(1, max(0, CGFloat(focus.y)))
        let offsetX = rect.minX
            + focusX * (rect.width - scaled.extent.width)
        let offsetY = rect.minY
            + (1 - focusY) * (rect.height - scaled.extent.height)
        return scaled
            .transformed(
                by: CGAffineTransform(
                    translationX: offsetX,
                    y: offsetY
                )
            )
            .cropped(to: rect)
    }

    private static func fit(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        let scale = min(rect.width / extent.width, rect.height / extent.height)
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        return scaled
            .transformed(
                by: CGAffineTransform(
                    translationX: rect.midX - scaled.extent.midX,
                    y: rect.midY - scaled.extent.midY
                )
            )
            .cropped(to: rect)
    }

    private static func mirror(_ image: CIImage, around rect: CGRect) -> CIImage {
        image.transformed(
            by: CGAffineTransform(translationX: rect.minX * 2 + rect.width, y: 0)
                .scaledBy(x: -1, y: 1)
        )
    }

    private static func cameraCornerRadius(
        rect: CGRect,
        settings: CameraSettings
    ) -> CGFloat {
        switch settings.shape {
        case .square:
            return 0
        case .circle:
            return min(rect.width, rect.height) / 2
        case .roundedRectangle:
            return min(rect.width, rect.height)
                * max(0.04, min(0.5, settings.cornerRadius))
        }
    }

    private static func cameraBorder(
        rect: CGRect,
        cornerRadius: CGFloat,
        settings: CameraSettings,
        outputSize: CGSize
    ) -> CIImage? {
        let width = min(80, max(0, settings.borderWidth))
            * min(outputSize.width, outputSize.height) / 1080
        guard width > 0.25, rect.width > 2, rect.height > 2 else {
            return nil
        }
        let pixelWidth = max(1, Int(ceil(rect.width)))
        let pixelHeight = max(1, Int(ceil(rect.height)))
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        let half = width / 2
        let pathRect = CGRect(
            x: half,
            y: half,
            width: max(0, rect.width - width),
            height: max(0, rect.height - width)
        )
        let pathRadius = max(0, cornerRadius - half)
        context.addPath(
            CGPath(
                roundedRect: pathRect,
                cornerWidth: pathRadius,
                cornerHeight: pathRadius,
                transform: nil
            )
        )
        let color = CIColor(hex: settings.borderColorHex)
        context.setStrokeColor(
            CGColor(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                components: [
                    color.red,
                    color.green,
                    color.blue,
                    color.alpha
                ]
            ) ?? CGColor(gray: 1, alpha: 1)
        )
        context.setLineWidth(width)
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(
                by: CGAffineTransform(
                    translationX: rect.minX,
                    y: rect.minY
                )
            )
            .cropped(to: rect)
    }

    private static func makeShadow(
        rect: CGRect,
        cornerRadius: CGFloat,
        intensity: Double
    ) -> CIImage {
        let alpha = min(0.8, max(0.05, intensity))
        let color = CIColor(red: 0, green: 0, blue: 0, alpha: alpha)
        let shadowRect = rect.offsetBy(dx: 0, dy: -min(18, rect.height * 0.025))
        let solid = CIImage(color: color).cropped(to: shadowRect)
        let mask = roundedMask(
            rect: shadowRect,
            cornerRadius: cornerRadius
        )
        let masked = solid.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ]
        )
        return masked
            .applyingFilter(
                "CIGaussianBlur",
                parameters: ["inputRadius": min(30, rect.height * 0.045)]
            )
            .cropped(to: rect.insetBy(dx: -40, dy: -40))
    }

    private static func applyRoundedMask(
        to image: CIImage,
        rect: CGRect,
        cornerRadius: CGFloat
    ) -> CIImage {
        guard cornerRadius > 0.5 else {
            return image.cropped(to: rect)
        }
        let mask = roundedMask(rect: rect, cornerRadius: cornerRadius)
        return image.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ]
        ).cropped(to: rect)
    }

    private static func roundedMask(
        rect: CGRect,
        cornerRadius: CGFloat
    ) -> CIImage {
        let filter = CIFilter(name: "CIRoundedRectangleGenerator")
        filter?.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter?.setValue(cornerRadius, forKey: "inputRadius")
        filter?.setValue(CIColor.white, forKey: "inputColor")
        return (filter?.outputImage ?? CIImage(color: .white))
            .cropped(to: rect)
    }
}

private extension CIColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if value.count == 8 {
            red = CGFloat((number >> 24) & 0xFF) / 255
            green = CGFloat((number >> 16) & 0xFF) / 255
            blue = CGFloat((number >> 8) & 0xFF) / 255
        } else {
            red = CGFloat((number >> 16) & 0xFF) / 255
            green = CGFloat((number >> 8) & 0xFF) / 255
            blue = CGFloat(number & 0xFF) / 255
        }
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}


/// 按键小条渲染：最近 2.5 秒内的按键按时间序横排在输出画布左下角，
/// 最新一条在最右。胶囊样式与 HUD 同语言（scrimOverMedia 底 + 纸白字）。
enum KeyStripRenderer {
    private static let visibleWindow: Double = 2.5
    private static let maxPills = 4

    private static let pillCache = NSCache<NSString, CIImage>()

    static func overlay(
        on image: CIImage,
        time: Double,
        project: StudioProject,
        outputSize: CGSize
    ) -> CIImage {
        guard project.keyStripEnabled, !project.keyStrokes.isEmpty else {
            return image
        }
        let recent = project.keyStrokes
            .compactMap { event -> (Double, String)? in
                guard
                    let outputTime = project.timeline.outputTime(
                        forSource: event.sourceTime
                    ),
                    outputTime <= time,
                    time - outputTime <= visibleWindow
                else {
                    return nil
                }
                return (outputTime, event.text)
            }
            .sorted { $0.0 < $1.0 }
            .suffix(maxPills)
        guard !recent.isEmpty else { return image }

        let scale = outputSize.height / 900
        let margin = 24 * scale
        let gap = 8 * scale
        var x = margin
        let y = margin
        var result = image
        for (_, text) in recent {
            guard let pill = pill(text: text, scale: scale) else { continue }
            let extent = pill.extent
            let position = pill.transformed(
                by: CGAffineTransform(
                    translationX: x,
                    y: y
                )
            )
            result = position.composited(over: result)
            x += extent.width + gap
        }
        return result
    }

    /// 单枚胶囊：scrim 圆角底 + 纸白文字，按文本+字号缓存。
    private static func pill(text: String, scale: CGFloat) -> CIImage? {
        let fontSize = CGFloat(22 * scale)
        let key = ("\(text)|\(Int(fontSize))") as NSString
        if let cached = pillCache.object(forKey: key) {
            return cached
        }
        let font = CTFontCreateWithName(
            "PingFang SC" as CFString, fontSize, nil
        )
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: 1),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = max(1, CTLineGetTypographicBounds(line, nil, nil, nil))
        let horizontalPadding = fontSize * 0.7
        let pillWidth = ceil(width + horizontalPadding * 2)
        let pillHeight = ceil(fontSize * 1.9)
        guard
            pillWidth > 2,
            pillHeight > 2,
            let context = CGContext(
                data: nil,
                width: Int(pillWidth),
                height: Int(pillHeight),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        // 胶囊底：scrim 82%
        let rect = CGRect(
            x: 0, y: 0, width: pillWidth, height: pillHeight
        )
        let radius = pillHeight / 2
        context.setFillColor(
            CGColor(red: 0.125, green: 0.188, blue: 0.235, alpha: 0.82)
        )
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.fillPath()
        // 文字垂直居中
        let textY = (pillHeight - fontSize) / 2 + fontSize * 0.12
        context.textPosition = CGPoint(
            x: horizontalPadding,
            y: textY
        )
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else { return nil }
        // CIImage(cgImage:) 无需翻转（CaptionRenderer 同口径）。
        let image = CIImage(cgImage: cgImage)
        pillCache.setObject(image, forKey: key)
        return image
    }
}
