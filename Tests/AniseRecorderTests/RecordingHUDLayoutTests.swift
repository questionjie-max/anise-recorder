import CoreGraphics
import XCTest
@testable import AniseRecorder

final class RecordingHUDLayoutTests: XCTestCase {
    /// 回归：面板 contentRect 必须与 SwiftUI 内容同宽——曾固定 680，
    /// 开摄像头内容 800 时端部的「停止」按钮被窗口边界裁掉。
    func testHUDContentSizeMatchesSwiftUIContent() {
        XCTAssertEqual(
            FloatingPanelLayout.hudContentSize(hasCamera: true),
            CGSize(width: 800, height: 60)
        )
        XCTAssertEqual(
            FloatingPanelLayout.hudContentSize(hasCamera: false),
            CGSize(width: 570, height: 60)
        )
    }

    func testTopCenteredOriginPinsBelowTopEdge() {
        let origin = FloatingPanelLayout.topCenteredOrigin(
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1040),
            panelSize: CGSize(width: 800, height: 60)
        )
        XCTAssertEqual(origin.x, 560)
        XCTAssertEqual(origin.y, 952)
    }

    func testTopCenteredOriginSupportsNegativeOriginScreen() {
        let origin = FloatingPanelLayout.topCenteredOrigin(
            visibleFrame: CGRect(x: -1512, y: -982, width: 1512, height: 982),
            panelSize: CGSize(width: 570, height: 60)
        )
        XCTAssertEqual(origin.x, -1512 + (1512 - 570) / 2)
        XCTAssertEqual(origin.y, -982 + 982 - 60 - 28)
    }

    func testCenteredOriginForCountdown() {
        let origin = FloatingPanelLayout.centeredOrigin(
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            panelSize: CGSize(width: 190, height: 190)
        )
        XCTAssertEqual(origin.x, 865)
        XCTAssertEqual(origin.y, 445)
    }

    func testClampedOriginKeepsPanelInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = CGSize(width: 800, height: 60)
        // 拖出右缘 → 贴右缘；拖出左缘 → 贴左缘。
        XCTAssertEqual(
            FloatingPanelLayout.clampedOrigin(
                origin: CGPoint(x: 1500, y: 500),
                panelSize: size,
                visibleFrame: visibleFrame
            ),
            CGPoint(x: 1120, y: 500)
        )
        XCTAssertEqual(
            FloatingPanelLayout.clampedOrigin(
                origin: CGPoint(x: -40, y: 500),
                panelSize: size,
                visibleFrame: visibleFrame
            ),
            CGPoint(x: 0, y: 500)
        )
    }

    func testClampedOriginPinsOversizedPanelToLeftEdge() {
        XCTAssertEqual(
            FloatingPanelLayout.clampedOrigin(
                origin: CGPoint(x: 100, y: 100),
                panelSize: CGSize(width: 2400, height: 60),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            CGPoint(x: 0, y: 100)
        )
    }
}
