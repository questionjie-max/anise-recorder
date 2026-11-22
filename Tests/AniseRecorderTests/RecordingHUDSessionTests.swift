import XCTest
@testable import AniseRecorder

/// HUD 回归：HUD 键盘路由与摄像头失败广播。
@MainActor
final class RecordingHUDSessionTests: XCTestCase {
    /// 摄像头启动失败标志置位后不回退（录制期内一次性事实）。
    func testCameraFailedFlagIsOneWay() {
        let session = RecordingHUDSession(startedAt: Date())
        XCTAssertFalse(session.cameraFailed)
        session.setCameraFailed()
        XCTAssertTrue(session.cameraFailed)
    }

    /// borderless 面板默认 canBecomeKey == false，Esc 停止快捷键
    /// 不可达；HUDPanel 必须允许成为 key（配合 makeKeyAndOrderFront）。
    func testHUDPanelCanBecomeKey() {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        XCTAssertTrue(panel.canBecomeKey)
        panel.orderOut(nil)
    }
}
