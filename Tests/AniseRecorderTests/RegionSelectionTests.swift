import CoreGraphics
import XCTest
@testable import AniseRecorder

final class RegionSelectionTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testHitZoneCoversCornersEdgesInsideAndOutside() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertEqual(hitZone(101, 101, rect), .bottomLeft)
        XCTAssertEqual(hitZone(499, 101, rect), .bottomRight)
        XCTAssertEqual(hitZone(101, 399, rect), .topLeft)
        XCTAssertEqual(hitZone(499, 399, rect), .topRight)
        XCTAssertEqual(hitZone(100, 250, rect), .left)
        XCTAssertEqual(hitZone(500, 250, rect), .right)
        XCTAssertEqual(hitZone(300, 100, rect), .bottom)
        XCTAssertEqual(hitZone(300, 400, rect), .top)
        XCTAssertEqual(hitZone(300, 250, rect), .inside)
        XCTAssertEqual(hitZone(94, 250, rect), .left)
        XCTAssertEqual(hitZone(20, 250, rect), .outside)
    }

    func testCreationHandlesReverseDragAndClampsToBounds() {
        let reversed = RegionSelectionGeometry.rect(
            from: CGPoint(x: 500, y: 600),
            to: CGPoint(x: 200, y: 300),
            clampedTo: bounds
        )
        XCTAssertEqual(
            reversed,
            CGRect(x: 200, y: 300, width: 300, height: 300)
        )

        let clamped = RegionSelectionGeometry.rect(
            from: CGPoint(x: -40, y: -60),
            to: CGPoint(x: 1200, y: 900),
            clampedTo: bounds
        )
        XCTAssertEqual(clamped, bounds)
    }

    func testMoveKeepsSelectionInsideBounds() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)

        XCTAssertEqual(
            RegionSelectionGeometry.moved(
                rect,
                by: CGSize(width: 5000, height: 5000),
                clampedTo: bounds
            ),
            CGRect(x: 800, y: 650, width: 200, height: 150)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.moved(
                rect,
                by: CGSize(width: -5000, height: -5000),
                clampedTo: bounds
            ),
            CGRect(x: 0, y: 0, width: 200, height: 150)
        )
    }

    func testResizeEdgesEnforcesMinimumSize() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .left,
                by: CGSize(width: 1000, height: 0),
                clampedTo: bounds
            ),
            CGRect(x: 436, y: 100, width: 64, height: 300)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .right,
                by: CGSize(width: -1000, height: 0),
                clampedTo: bounds
            ),
            CGRect(x: 100, y: 100, width: 64, height: 300)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .top,
                by: CGSize(width: 0, height: -1000),
                clampedTo: bounds
            ),
            CGRect(x: 100, y: 100, width: 400, height: 64)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .bottom,
                by: CGSize(width: 0, height: 1000),
                clampedTo: bounds
            ),
            CGRect(x: 100, y: 336, width: 400, height: 64)
        )
    }

    func testResizeClampsToScreenBounds() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .left,
                by: CGSize(width: -1000, height: 0),
                clampedTo: bounds
            ),
            CGRect(x: 0, y: 100, width: 500, height: 300)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .top,
                by: CGSize(width: 0, height: 1000),
                clampedTo: bounds
            ),
            CGRect(x: 100, y: 100, width: 400, height: 700)
        )
    }

    func testResizeCornersMovesBothAxes() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .topLeft,
                by: CGSize(width: 1000, height: -1000),
                clampedTo: bounds
            ),
            CGRect(x: 436, y: 100, width: 64, height: 64)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.resized(
                rect,
                zone: .bottomRight,
                by: CGSize(width: -1000, height: 1000),
                clampedTo: bounds
            ),
            CGRect(x: 100, y: 336, width: 64, height: 64)
        )
    }

    func testNormalizedRegionFlipsVerticalAxis() {
        XCTAssertEqual(
            RegionSelectionGeometry.normalizedRegion(for: bounds, in: bounds),
            CaptureRegion(x: 0, y: 0, width: 1, height: 1)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.normalizedRegion(
                for: CGRect(x: 0, y: 600, width: 1000, height: 200),
                in: bounds
            ),
            CaptureRegion(x: 0, y: 0, width: 1, height: 0.25)
        )
        XCTAssertEqual(
            RegionSelectionGeometry.normalizedRegion(
                for: CGRect(x: 0, y: 0, width: 1000, height: 200),
                in: bounds
            ),
            CaptureRegion(x: 0, y: 0.75, width: 1, height: 0.25)
        )
    }

    func testNormalizedRegionHandlesOffsetBounds() {
        let offset = CGRect(x: 120, y: 40, width: 1000, height: 800)
        XCTAssertEqual(
            RegionSelectionGeometry.normalizedRegion(for: offset, in: offset),
            CaptureRegion(x: 0, y: 0, width: 1, height: 1)
        )
    }

    func testNormalizedRegionRejectsEmptySelection() {
        XCTAssertNil(
            RegionSelectionGeometry.normalizedRegion(for: .zero, in: bounds)
        )
    }

    func testConfirmableRequiresMinimumSize() {
        XCTAssertTrue(
            RegionSelectionGeometry.isConfirmable(
                CGRect(x: 0, y: 0, width: 64, height: 64)
            )
        )
        XCTAssertFalse(
            RegionSelectionGeometry.isConfirmable(
                CGRect(x: 0, y: 0, width: 63.9, height: 64)
            )
        )
    }

    private func hitZone(
        _ x: CGFloat,
        _ y: CGFloat,
        _ rect: CGRect
    ) -> RegionSelectionHitZone {
        RegionSelectionGeometry.hitZone(
            for: CGPoint(x: x, y: y),
            in: rect
        )
    }
}
