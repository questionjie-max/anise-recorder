import AppKit
import Foundation
import QuartzCore

enum ClickFrameSource {
    case fixed(CGRect)
    case window(CGWindowID)
}

struct ClickCoordinateMapper {
    static func normalizedPoint(
        screenPoint: CGPoint,
        in frame: CGRect
    ) -> CGPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let x = (screenPoint.x - frame.minX) / frame.width
        let y = (frame.maxY - screenPoint.y) / frame.height
        guard (0 ... 1).contains(x), (0 ... 1).contains(y) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    static func appKitFrame(
        for cgFrame: CGRect,
        mainScreenMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: cgFrame.minX,
            y: mainScreenMaxY - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }
}

enum CaptureFrameResolver {
    static func frame(
        for source: ClickFrameSource,
        fallback: CGRect
    ) -> CGRect {
        guard case let .window(windowID) = source else {
            if case let .fixed(frame) = source {
                return frame
            }
            return fallback
        }
        guard let cgFrame = windowFrame(for: windowID) else {
            return fallback
        }
        let mainScreenMaxY = NSScreen.screens
            .first(where: { screen in
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
                return number?.uint32Value == CGMainDisplayID()
            })?
            .frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return ClickCoordinateMapper.appKitFrame(
            for: cgFrame,
            mainScreenMaxY: mainScreenMaxY
        )
    }

    private static func windowFrame(for windowID: CGWindowID) -> CGRect? {
        guard
            let infoList = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                windowID
            ) as? [[String: Any]],
            let info = infoList.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                    == windowID
            }),
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds)
        else {
            return nil
        }
        return frame
    }
}

final class ClickTracker {
    private let frameSource: ClickFrameSource
    private var lastFrame: CGRect
    private var timer: Timer?
    private var wasPressed = false
    private var rawClicks: [RawClick] = []

    init(frameSource: ClickFrameSource, initialFrame: CGRect) {
        self.frameSource = frameSource
        lastFrame = initialFrame
    }

    func start() {
        stopTimer()
        wasPressed = NSEvent.pressedMouseButtons & 1 == 1
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() -> [RawClick] {
        stopTimer()
        return rawClicks
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let pressed = NSEvent.pressedMouseButtons & 1 == 1
        defer { wasPressed = pressed }
        guard pressed, !wasPressed else { return }

        let location = NSEvent.mouseLocation
        let frame = currentFrame()
        guard
            let point = ClickCoordinateMapper.normalizedPoint(
                screenPoint: location,
                in: frame
            )
        else {
            return
        }

        let click = RawClick(
            hostTime: CACurrentMediaTime(),
            x: Double(point.x),
            y: Double(point.y)
        )
        if
            let last = rawClicks.last,
            click.hostTime - last.hostTime < 0.65,
            hypot(
                (click.x - last.x) * frame.width,
                (click.y - last.y) * frame.height
            ) < 28
        {
            rawClicks[rawClicks.count - 1] = click
        } else {
            rawClicks.append(click)
        }
    }

    private func currentFrame() -> CGRect {
        let frame = CaptureFrameResolver.frame(
            for: frameSource,
            fallback: lastFrame
        )
        lastFrame = frame
        return frame
    }
}
