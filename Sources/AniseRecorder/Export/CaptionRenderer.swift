import CoreGraphics
import CoreImage
import CoreText
import Foundation

enum CaptionRenderer {
    private static let cache = NSCache<NSString, CIImage>()

    /// 字幕叠加层。`burnMode` 语义：nil = 预览（显示全部已启用轨，
    /// 与 1.1 前「预览始终显示已启用字幕」一致）；非 nil = 导出，按
    /// 烧录模式渲染主 / 副 / 双。预览与导出共用同一套绘制代码。
    static func overlay(
        on image: CIImage,
        time: TimeInterval,
        project: StudioProject,
        outputSize: CGSize,
        burnMode: CaptionBurnMode? = nil
    ) -> CIImage {
        guard project.captions.enabled else { return image }
        let showPrimary = burnMode.map {
            $0 == .primary || $0 == .both
        } ?? true
        let showSecondary = burnMode.map {
            $0 == .secondary || $0 == .both
        } ?? project.captions.secondaryEnabled
        guard showPrimary || showSecondary else { return image }

        let primaryCue = showPrimary
            ? activeCue(in: project.captionCues, at: time)
            : nil
        let secondaryCue = showSecondary
            && project.captions.secondaryEnabled
            ? activeCue(in: project.secondaryCaptionCues, at: time)
            : nil
        guard primaryCue != nil || secondaryCue != nil else { return image }

        let bottom = max(12, outputSize.height * 0.055)
        let gap = max(6, outputSize.height * 0.012)
        let primaryImage = primaryCue.flatMap {
            makeImage(
                for: $0.text,
                project: project,
                outputSize: outputSize,
                fontScaleOverride: nil
            )
        }
        let secondaryImage = secondaryCue.flatMap {
            makeImage(
                for: $0.text,
                project: project,
                outputSize: outputSize,
                fontScaleOverride: project.captions.fontScale * 0.82
            )
        }

        // 布局：主上副下 = 副字幕贴底、主字幕在其上方；主下副上相反。
        // 只有一条轨时该轨独占贴底槽位。
        var result = image
        let primaryHeight = primaryImage?.extent.height ?? 0
        let secondaryHeight = secondaryImage?.extent.height ?? 0
        let bothShown = primaryImage != nil && secondaryImage != nil
        let primaryY: CGFloat?
        let secondaryY: CGFloat?
        if bothShown {
            switch project.captions.secondaryPosition {
            case .below:
                secondaryY = bottom
                primaryY = bottom + secondaryHeight + gap
            case .above:
                primaryY = bottom
                secondaryY = bottom + primaryHeight + gap
            }
        } else {
            primaryY = primaryImage != nil ? bottom : nil
            secondaryY = secondaryImage != nil ? bottom : nil
        }
        if let primaryImage, let primaryY {
            result = positionedImage(
                primaryImage,
                y: primaryY,
                outputSize: outputSize
            ).composited(over: result)
        }
        if let secondaryImage, let secondaryY {
            result = positionedImage(
                secondaryImage,
                y: secondaryY,
                outputSize: outputSize
            ).composited(over: result)
        }
        return result
    }

    private static func positionedImage(
        _ caption: CIImage,
        y: CGFloat,
        outputSize: CGSize
    ) -> CIImage {
        caption.transformed(
            by: CGAffineTransform(
                translationX: (outputSize.width - caption.extent.width) / 2,
                y: y
            )
        )
    }

    /// 1.2 章节标题卡：章节起始处约 2 秒的大号标题，样式跟随字幕预设
    /// （字号 = 字幕字号 ×1.15，背景浓度 0.45）。章节数据来自现有
    /// 字幕合并（ChapterBuilder），不新造章节来源。
    static func chapterCardOverlay(
        on image: CIImage,
        time: TimeInterval,
        project: StudioProject,
        outputSize: CGSize
    ) -> CIImage {
        guard project.captions.enabled, project.captions.chapterCardsEnabled
        else {
            return image
        }
        let chapters = ChapterBuilder.build(
            from: project.captionCues,
            totalDuration: project.trimDuration
        )
        guard
            let chapter = chapters.first(where: {
                time >= $0.start && time < $0.start + chapterCardDuration
            }),
            !chapter.title.isEmpty,
            let card = makeImage(
                for: chapter.title,
                project: project,
                outputSize: outputSize,
                fontScaleOverride: project.captions.fontScale * 1.15,
                backgroundOpacityOverride: 0.45
            )
        else {
            return image
        }
        return card.transformed(
            by: CGAffineTransform(
                translationX: (outputSize.width - card.extent.width) / 2,
                y: outputSize.height * 0.42
            )
        ).composited(over: image)
    }

    /// 章节标题卡时长（秒）。
    static let chapterCardDuration: Double = 2

    private static func activeCue(
        in cues: [CaptionCue],
        at time: TimeInterval
    ) -> CaptionCue? {
        cues
            .filter({
                !$0.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && $0.start <= time + 0.000_001
                    && time < $0.end
            })
            .max(by: { $0.start < $1.start })
    }

    private static func makeImage(
        for text: String,
        project: StudioProject,
        outputSize: CGSize,
        fontScaleOverride: Double?,
        backgroundOpacityOverride: Double? = nil
    ) -> CIImage? {
        let scale = min(
            2.5,
            max(0.75, fontScaleOverride ?? project.captions.fontScale)
        )
        let fontSize = max(22, outputSize.width * 0.024 * scale)
        let width = max(320, outputSize.width * 0.84)
        let opacity = min(
            0.9,
            max(
                0,
                backgroundOpacityOverride
                    ?? project.captions.backgroundOpacity
            )
        )
        let key = [
            text,
            String(Int(fontSize)),
            String(Int(width)),
            String(Int(opacity * 100))
        ].joined(separator: "|") as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let font = CTFontCreateWithName(
            "PingFang SC" as CFString,
            fontSize,
            nil
        )
        let paragraph: CTParagraphStyle = withUnsafePointer(
            to: CTTextAlignment.center
        ) { alignment in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: alignment
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String):
                    paragraph
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributed
        )
        let horizontalPadding = fontSize * 0.7
        let verticalPadding = fontSize * 0.45
        let textWidth = width - horizontalPadding * 2
        var fitRange = CFRange()
        let suggestion = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(
                width: textWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            &fitRange
        )
        let canvasWidth = ceil(min(width, suggestion.width + horizontalPadding * 2))
        let canvasHeight = ceil(suggestion.height + verticalPadding * 2)
        guard
            canvasWidth > 2,
            canvasHeight > 2,
            let context = CGContext(
                data: nil,
                width: Int(canvasWidth),
                height: Int(canvasHeight),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.clear(
            CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        )
        let bubble = CGRect(
            x: 0,
            y: 0,
            width: canvasWidth,
            height: canvasHeight
        )
        context.setFillColor(
            CGColor(red: 0.03, green: 0.04, blue: 0.04, alpha: opacity)
        )
        context.addPath(
            CGPath(
                roundedRect: bubble,
                cornerWidth: min(18, canvasHeight / 2),
                cornerHeight: min(18, canvasHeight / 2),
                transform: nil
            )
        )
        context.fillPath()

        let path = CGPath(
            rect: CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: canvasWidth - horizontalPadding * 2,
                height: canvasHeight - verticalPadding * 2
            ),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }
}
