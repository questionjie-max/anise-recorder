import CoreGraphics
import CoreImage
import Foundation

struct CursorFrameState {
    let point: CGPoint
    let appearanceID: UUID?
}

enum CursorResolver {
    static func state(
        atOutput time: TimeInterval,
        project: StudioProject
    ) -> CursorFrameState? {
        guard
            project.cursor.enabled,
            !project.rawCursor.isEmpty,
            let sourceTime = project.timeline.sourceTime(atOutput: time),
            let index = sampleIndex(at: sourceTime, samples: project.rawCursor)
        else {
            return nil
        }
        let samples = project.rawCursor
        let sample = samples[index]
        guard sample.visible else { return nil }

        if project.cursor.hideWhenIdle {
            var movedAt = sample.sourceTime
            var cursorIndex = index
            while cursorIndex >= 0 {
                if samples[cursorIndex].moved {
                    movedAt = samples[cursorIndex].sourceTime
                    break
                }
                guard
                    sample.sourceTime - samples[cursorIndex].sourceTime
                        <= project.cursor.idleDelay + 0.5
                else {
                    break
                }
                if cursorIndex == 0 { break }
                cursorIndex -= 1
            }
            guard sourceTime - movedAt <= project.cursor.idleDelay else {
                return nil
            }
        }

        var point = CGPoint(x: sample.x, y: sample.y)
        if
            index + 1 < samples.count,
            samples[index + 1].visible,
            samples[index + 1].sourceTime > sample.sourceTime
        {
            let next = samples[index + 1]
            let progress = min(
                1,
                max(
                    0,
                    (sourceTime - sample.sourceTime)
                        / (next.sourceTime - sample.sourceTime)
                )
            )
            point.x += (next.x - point.x) * progress
            point.y += (next.y - point.y) * progress
        }

        let smoothing = min(0.95, max(0, project.cursor.smoothing))
        if smoothing > 0.001 {
            let window = 0.015 + smoothing * 0.105
            var totalWeight = 0.0
            var weightedX = 0.0
            var weightedY = 0.0
            var cursorIndex = index
            var inspected = 0
            while cursorIndex >= 0, inspected < 12 {
                let candidate = samples[cursorIndex]
                let age = sourceTime - candidate.sourceTime
                guard age <= window else { break }
                if candidate.visible {
                    let weight = 1 - age / max(window, 0.001)
                    totalWeight += weight
                    weightedX += candidate.x * weight
                    weightedY += candidate.y * weight
                }
                if cursorIndex == 0 { break }
                cursorIndex -= 1
                inspected += 1
            }
            if totalWeight > 0 {
                point.x = weightedX / totalWeight
                point.y = weightedY / totalWeight
            }
        }
        return CursorFrameState(
            point: point,
            appearanceID: sample.appearanceID
        )
    }

    private static func sampleIndex(
        at time: Double,
        samples: [CursorSample]
    ) -> Int? {
        guard
            let first = samples.first,
            let last = samples.last,
            time >= first.sourceTime,
            time <= last.sourceTime + 0.5
        else {
            return nil
        }
        var low = 0
        var high = samples.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if samples[mid].sourceTime <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

enum CursorRenderer {
    private static let cursorCache = NSCache<NSString, CIImage>()

    static func overlay(
        on image: CIImage,
        time: TimeInterval,
        project: StudioProject,
        screenExtent: CGRect,
        zoomSettings: ZoomSettings,
        outputSize: CGSize
    ) -> CIImage {
        guard
            project.cursor.enabled,
            !project.rawCursor.isEmpty,
            let projection = ZoomRenderer.projection(
                sourceExtent: screenExtent,
                time: time,
                settings: zoomSettings,
                outputSize: outputSize
            )
        else {
            return image
        }
        var result = image
        let canvas = CGRect(origin: .zero, size: outputSize)
        let scale = max(0.75, outputSize.width / 1920)

        if project.cursor.clickHighlight {
            for click in project.clicks where click.enabled {
                guard
                    let outputTime = project.timeline.outputTime(
                        forSource: click.time
                    )
                else {
                    continue
                }
                let elapsed = time - outputTime
                guard elapsed >= 0, elapsed < 0.46 else { continue }
                let point = projection.map(
                    CGPoint(x: click.x, y: click.y),
                    from: screenExtent
                )
                if
                    let ripple = clickRipple(
                        progress: elapsed / 0.46,
                        scale: scale
                    )
                {
                    let positioned = ripple.transformed(
                        by: CGAffineTransform(
                            translationX: point.x - ripple.extent.midX,
                            y: point.y - ripple.extent.midY
                        )
                    )
                    result = positioned.composited(over: result)
                }
            }
        }

        guard
            let state = CursorResolver.state(atOutput: time, project: project)
        else {
            return result.cropped(to: canvas)
        }
        let point = projection.map(state.point, from: screenExtent)
        guard let cursor = cursorImage(for: state, project: project) else {
            return result.cropped(to: canvas)
        }
        let size = max(8, 23 * project.cursor.size * scale)
        let aspect = cursor.extent.width / max(1, cursor.extent.height)
        let cursorHeight = size
        let cursorWidth = size * aspect
        let scaled = cursor.transformed(
            by: CGAffineTransform(
                scaleX: cursorWidth / max(1, cursor.extent.width),
                y: cursorHeight / max(1, cursor.extent.height)
            )
        )
        let appearance = project.cursorAppearances.first {
            $0.id == state.appearanceID
        }
        let hotspotX = (appearance?.hotspotX ?? 4) * scale
        let hotspotY = (appearance?.hotspotY ?? 4) * scale
        let positioned = scaled.transformed(
            by: CGAffineTransform(
                translationX: point.x - hotspotX,
                y: point.y - cursorHeight + hotspotY
            )
        )
        return positioned.composited(over: result).cropped(to: canvas)
    }

    private static func cursorImage(
        for state: CursorFrameState,
        project: StudioProject
    ) -> CIImage? {
        guard
            let appearance = project.cursorAppearances.first(where: {
                $0.id == state.appearanceID
            })
        else {
            return fallbackArrow
        }
        let key = appearance.id.uuidString as NSString
        if let cached = cursorCache.object(forKey: key) {
            return cached
        }
        guard let image = CIImage(data: appearance.pngData) else {
            return fallbackArrow
        }
        cursorCache.setObject(image, forKey: key)
        return image
    }

    private static let fallbackArrow: CIImage? = {
        let size = CGSize(width: 64, height: 64)
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.clear(CGRect(origin: .zero, size: size))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 8, y: 58))
        path.addLine(to: CGPoint(x: 8, y: 14))
        path.addLine(to: CGPoint(x: 22, y: 26))
        path.addLine(to: CGPoint(x: 31, y: 6))
        path.addLine(to: CGPoint(x: 40, y: 10))
        path.addLine(to: CGPoint(x: 31, y: 30))
        path.addLine(to: CGPoint(x: 50, y: 32))
        path.closeSubpath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }()

    private static func clickRipple(
        progress: Double,
        scale: CGFloat
    ) -> CIImage? {
        let size = CGSize(width: 96, height: 96)
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.clear(CGRect(origin: .zero, size: size))
        let radius = (8 + 24 * progress) * scale
        let alpha = max(0, 0.72 * (1 - progress))
        context.setStrokeColor(
            CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
        )
        context.setLineWidth(max(1.5, 2.5 * scale))
        context.strokeEllipse(
            in: CGRect(
                x: size.width / 2 - radius,
                y: size.height / 2 - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }
}
