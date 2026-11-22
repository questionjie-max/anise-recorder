import CoreGraphics

/// 区域框选浮层的命中区。坐标使用视图坐标（左下原点、y 向上）。
enum RegionSelectionHitZone: Equatable {
    case outside
    case inside
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

/// 框选浮层的纯几何逻辑：命中、创建、平移、缩放和归一化。
/// 不依赖 AppKit 窗口，方便用单元测试固定最小尺寸和 y 翻转约定。
enum RegionSelectionGeometry {
    static let minimumSize: CGFloat = 64
    static let hitTolerance: CGFloat = 8

    static func hitZone(
        for point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat = hitTolerance
    ) -> RegionSelectionHitZone {
        let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard expanded.contains(point) else { return .outside }

        let nearLeft = abs(point.x - rect.minX) <= tolerance
        let nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearBottom = abs(point.y - rect.minY) <= tolerance
        let nearTop = abs(point.y - rect.maxY) <= tolerance

        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _):
            return .bottomLeft
        case (true, _, _, true):
            return .topLeft
        case (_, true, true, _):
            return .bottomRight
        case (_, true, _, true):
            return .topRight
        case (true, _, _, _):
            return .left
        case (_, true, _, _):
            return .right
        case (_, _, true, _):
            return .bottom
        case (_, _, _, true):
            return .top
        default:
            return .inside
        }
    }

    static func rect(
        from start: CGPoint,
        to end: CGPoint,
        clampedTo bounds: CGRect
    ) -> CGRect {
        let minX = max(bounds.minX, min(start.x, end.x))
        let maxX = min(bounds.maxX, max(start.x, end.x))
        let minY = max(bounds.minY, min(start.y, end.y))
        let maxY = min(bounds.maxY, max(start.y, end.y))
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    static func moved(
        _ rect: CGRect,
        by delta: CGSize,
        clampedTo bounds: CGRect
    ) -> CGRect {
        let dx = min(
            max(delta.width, bounds.minX - rect.minX),
            bounds.maxX - rect.maxX
        )
        let dy = min(
            max(delta.height, bounds.minY - rect.minY),
            bounds.maxY - rect.maxY
        )
        return rect.offsetBy(dx: dx, dy: dy)
    }

    static func resized(
        _ rect: CGRect,
        zone: RegionSelectionHitZone,
        by delta: CGSize,
        minimumSize: CGFloat = minimumSize,
        clampedTo bounds: CGRect
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if zone.movesLeftEdge {
            minX = max(
                bounds.minX,
                min(rect.minX + delta.width, rect.maxX - minimumSize)
            )
        }
        if zone.movesRightEdge {
            maxX = min(
                bounds.maxX,
                max(rect.maxX + delta.width, rect.minX + minimumSize)
            )
        }
        if zone.movesBottomEdge {
            minY = max(
                bounds.minY,
                min(rect.minY + delta.height, rect.maxY - minimumSize)
            )
        }
        if zone.movesTopEdge {
            maxY = min(
                bounds.maxY,
                max(rect.maxY + delta.height, rect.minY + minimumSize)
            )
        }

        guard maxX > minX, maxY > minY else { return rect }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    static func isConfirmable(_ rect: CGRect) -> Bool {
        rect.width >= minimumSize && rect.height >= minimumSize
    }

    static func normalizedRegion(
        for rect: CGRect,
        in bounds: CGRect
    ) -> CaptureRegion? {
        guard
            bounds.width > 0,
            bounds.height > 0,
            rect.width >= 1,
            rect.height >= 1
        else {
            return nil
        }
        return CaptureRegion(
            x: (rect.minX - bounds.minX) / bounds.width,
            y: (bounds.maxY - rect.maxY) / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        )
    }
}

private extension RegionSelectionHitZone {
    var movesLeftEdge: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }

    var movesRightEdge: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }

    var movesBottomEdge: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }

    var movesTopEdge: Bool {
        self == .top || self == .topLeft || self == .topRight
    }
}
