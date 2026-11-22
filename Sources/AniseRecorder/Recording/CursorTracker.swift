import AppKit
import Foundation
import QuartzCore

struct RawCursorRecording {
    struct Sample {
        let hostTime: Double
        let x: Double
        let y: Double
        let visible: Bool
        let appearanceID: UUID?
        let moved: Bool
    }

    let samples: [Sample]
    let appearances: [CursorAppearance]
}

final class CursorTracker {
    private let frameSource: ClickFrameSource
    private var lastFrame: CGRect
    private var timer: Timer?
    private var samples: [RawCursorRecording.Sample] = []
    private var appearances: [CursorAppearance] = []
    private var appearanceIDs: [Data: UUID] = [:]
    private var currentAppearanceID: UUID?
    private var lastCursorData: Data?
    private var lastAppearanceSampleTime: Double = 0
    private var lastRecordedAt: Double = 0
    private var lastPoint: CGPoint?
    private var wasVisible = false

    init(frameSource: ClickFrameSource, initialFrame: CGRect) {
        self.frameSource = frameSource
        lastFrame = initialFrame
    }

    func start() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() -> RawCursorRecording {
        stopTimer()
        return RawCursorRecording(
            samples: samples,
            appearances: appearances
        )
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let hostTime = CACurrentMediaTime()
        let frame = CaptureFrameResolver.frame(
            for: frameSource,
            fallback: lastFrame
        )
        lastFrame = frame
        let location = NSEvent.mouseLocation
        let point = ClickCoordinateMapper.normalizedPoint(
            screenPoint: location,
            in: frame
        )
        let visible = point != nil

        if visible, hostTime - lastAppearanceSampleTime >= 0.1 {
            refreshAppearance()
            lastAppearanceSampleTime = hostTime
        }

        let moved: Bool
        if
            let point,
            let lastPoint,
            wasVisible
        {
            moved = hypot(
                (point.x - lastPoint.x) * frame.width,
                (point.y - lastPoint.y) * frame.height
            ) >= 0.75
        } else {
            moved = visible != wasVisible || (visible && lastPoint == nil)
        }

        let styleChanged = visible
            && currentAppearanceID != samples.last?.appearanceID
        if
            moved
                || styleChanged
                || visible != wasVisible
                || hostTime - lastRecordedAt >= 0.4
        {
            samples.append(
                RawCursorRecording.Sample(
                    hostTime: hostTime,
                    x: visible ? Double(point!.x) : 0,
                    y: visible ? Double(point!.y) : 0,
                    visible: visible,
                    appearanceID: visible ? currentAppearanceID : nil,
                    moved: moved
                )
            )
            lastRecordedAt = hostTime
        }
        lastPoint = point
        wasVisible = visible
    }

    private func refreshAppearance() {
        guard
            let cursor = NSCursor.currentSystem,
            let data = cursor.image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }
        if data == lastCursorData {
            return
        }
        lastCursorData = data
        if let existing = appearanceIDs[data] {
            currentAppearanceID = existing
            return
        }

        let size = cursor.image.size
        let hotspot = cursor.hotSpot
        let appearance = CursorAppearance(
            pngData: png,
            pointWidth: size.width > 0
                ? Double(size.width)
                : Double(bitmap.pixelsWide),
            pointHeight: size.height > 0
                ? Double(size.height)
                : Double(bitmap.pixelsHigh),
            hotspotX: Double(hotspot.x),
            hotspotY: Double(hotspot.y)
        )
        appearanceIDs[data] = appearance.id
        appearances.append(appearance)
        currentAppearanceID = appearance.id
    }
}
