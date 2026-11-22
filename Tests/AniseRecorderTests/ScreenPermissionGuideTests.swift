import XCTest
@testable import AniseRecorder

/// 屏幕录制权限预检 → 来源预览卡顶部引导卡可见性（纯逻辑映射）。
final class ScreenPermissionGuideTests: XCTestCase {
    func testDeniedIdleSetupShowsGuideCard() {
        // 未授权且工作台空闲：首屏直接给路径，不等点「开始录制」报错。
        XCTAssertTrue(
            ScreenPermissionGuide.shouldShowCard(
                permissionGranted: false,
                isPreparing: false,
                isRecording: false
            )
        )
    }

    func testGrantedNeverShowsGuideCard() {
        // 已授权：任何状态都不出卡，避免打扰已就绪用户。
        XCTAssertFalse(
            ScreenPermissionGuide.shouldShowCard(
                permissionGranted: true,
                isPreparing: false,
                isRecording: false
            )
        )
        XCTAssertFalse(
            ScreenPermissionGuide.shouldShowCard(
                permissionGranted: true,
                isPreparing: true,
                isRecording: true
            )
        )
    }

    func testPreparingAndRecordingHideGuideCard() {
        // 「开始录制」的 checkAccess 是最终闸门：准备中 / 录制中由
        // 闸门与错误提示负责，引导卡不叠加抢提示。
        XCTAssertFalse(
            ScreenPermissionGuide.shouldShowCard(
                permissionGranted: false,
                isPreparing: true,
                isRecording: false
            )
        )
        XCTAssertFalse(
            ScreenPermissionGuide.shouldShowCard(
                permissionGranted: false,
                isPreparing: false,
                isRecording: true
            )
        )
    }
}
