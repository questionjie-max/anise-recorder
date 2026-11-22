import AppKit
import XCTest
@testable import AniseRecorder

final class TeleprompterPanelTests: XCTestCase {
    // MARK: - 默认位置（靠近摄像头预览区）

    @MainActor
    func testDefaultFrameSitsAboveCameraOverlayWithoutOverlap() throws {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let camera = CGRect(
            x: 1_460,
            y: 0,
            width: 460,
            height: 260
        )
        let frame = TeleprompterPanelGeometry.defaultFrame(
            visibleFrame: visible,
            cameraFrame: camera
        )
        XCTAssertEqual(frame.width, 340, accuracy: 0.001)
        XCTAssertEqual(frame.height, 300, accuracy: 0.001)
        // 右对齐摄像头悬浮窗，且整体在可视区内
        XCTAssertEqual(
            frame.maxX,
            camera.maxX,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
        // 位于摄像头上方，留有间隔，不重叠
        XCTAssertGreaterThanOrEqual(
            frame.minY,
            camera.maxY + 8
        )
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
        XCTAssertFalse(frame.intersects(camera))
    }

    @MainActor
    func testDefaultFrameWithoutCameraUsesBottomRightReferenceZone() throws {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = TeleprompterPanelGeometry.defaultFrame(
            visibleFrame: visible,
            cameraFrame: nil
        )
        // 无摄像头时按参考区（右下 30% × 28%）上方放置
        XCTAssertGreaterThan(frame.minY, visible.height * 0.28)
        XCTAssertEqual(frame.maxX, visible.maxX - 24, accuracy: 0.001)
        XCTAssertFalse(visible.insetBy(dx: -1, dy: -1).intersection(frame).isEmpty)
    }

    @MainActor
    func testDefaultFrameFitsSmallVisibleArea() throws {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 500)
        let frame = TeleprompterPanelGeometry.defaultFrame(
            visibleFrame: visible,
            cameraFrame: nil
        )
        XCTAssertLessThanOrEqual(frame.width, visible.width)
        XCTAssertLessThanOrEqual(frame.height, visible.height)
        XCTAssertTrue(visible.contains(frame))
    }

    // MARK: - 位置记忆钳制

    @MainActor
    func testClampedFrameKeepsPreferredSizeAndPinsIntoVisibleArea() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = TeleprompterPanelGeometry.clampedFrame(
            CGRect(x: 1900, y: 1050, width: 340, height: 300),
            visibleFrame: visible
        )
        XCTAssertEqual(
            clamped,
            CGRect(x: 1580, y: 780, width: 340, height: 300)
        )
        XCTAssertTrue(visible.contains(clamped))
    }

    @MainActor
    func testClampedFrameShrinksOversizedPanelToFit() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
        let clamped = TeleprompterPanelGeometry.clampedFrame(
            CGRect(x: 0, y: 0, width: 640, height: 480),
            visibleFrame: visible
        )
        XCTAssertLessThanOrEqual(clamped.width, visible.width)
        XCTAssertLessThanOrEqual(clamped.height, visible.height)
        XCTAssertTrue(visible.contains(clamped))
    }

    // MARK: - 字号 / 速度钳制

    func testFontSizeAndSpeedClampToDefinedRanges() {
        XCTAssertEqual(
            TeleprompterPanelGeometry.clampedFontSize(2),
            TeleprompterPanelGeometry.fontSizeRange.lowerBound,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TeleprompterPanelGeometry.clampedFontSize(500),
            TeleprompterPanelGeometry.fontSizeRange.upperBound,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TeleprompterPanelGeometry.clampedFontSize(34),
            34,
            accuracy: 0.001
        )
    }

    // MARK: - 面板窗口属性（核心检核：不入录像的代码证据）

    @MainActor
    func testPanelWindowIsNonSharingFloatingAndMovable() throws {
        let controller = TeleprompterPanelController()
        controller.show(
            settings: TeleprompterSettings(script: "测试文稿"),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            cameraFrame: nil,
            onCommit: { _ in }
        )
        let panel = try XCTUnwrap(controller.panelForTesting)
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(
            panel.collectionBehavior.contains(.fullScreenAuxiliary)
        )
        XCTAssertFalse(panel.ignoresMouseEvents)

        // 窗口服务器层面的共享状态：kCGWindowSharingState == 0
        // （kCGSWindowSharingNone）意味着任何采集 API 都拿不到窗口内容。
        let windowNumber = panel.windowNumber
        XCTAssertGreaterThan(windowNumber, 0)
        let infoList = CGWindowListCopyWindowInfo(
            [],
            kCGNullWindowID
        ) as? [[String: Any]]
        let info = try XCTUnwrap(
            infoList?.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                    == UInt32(windowNumber)
            }),
            "面板窗口应出现在窗口服务器窗口列表中"
        )
        XCTAssertEqual(
            (info[kCGWindowSharingState as String] as? NSNumber)?.intValue,
            0,
            "提词面板在窗口服务器必须是不可共享状态"
        )
        XCTAssertEqual(
            (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            getpid(),
            "被查询的窗口必须是本进程的面板"
        )

        controller.hide()
        XCTAssertNil(controller.panelForTesting)
    }

    // MARK: - 窗口选择器路径（核心检核：面板不会被列为可选窗口）

    /// 本 App 的任何窗口（包括提词面板）都不进入窗口选择器；
    /// 他 App 的正常桌面窗口可列出；桌面层 / 过小 / 无应用名 / 空白名不可列出。
    func testWindowCatalogNeverListsOwnAppWindows() {
        let own = "com.localstudio.recorder"
        XCTAssertFalse(
            WindowCatalog.isListableWindow(
                windowLayer: 0,
                width: 340,
                height: 300,
                owningBundleIdentifier: own,
                appName: "八角录屏",
                ownBundleID: own
            )
        )
        XCTAssertTrue(
            WindowCatalog.isListableWindow(
                windowLayer: 0,
                width: 800,
                height: 600,
                owningBundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit",
                ownBundleID: own
            )
        )
        XCTAssertFalse(
            WindowCatalog.isListableWindow(
                windowLayer: 3,
                width: 800,
                height: 600,
                owningBundleIdentifier: "com.apple.dock",
                appName: "Dock",
                ownBundleID: own
            )
        )
        XCTAssertFalse(
            WindowCatalog.isListableWindow(
                windowLayer: 0,
                width: 100,
                height: 50,
                owningBundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit",
                ownBundleID: own
            )
        )
        XCTAssertFalse(
            WindowCatalog.isListableWindow(
                windowLayer: 0,
                width: 800,
                height: 600,
                owningBundleIdentifier: nil,
                appName: "TextEdit",
                ownBundleID: own
            )
        )
        XCTAssertFalse(
            WindowCatalog.isListableWindow(
                windowLayer: 0,
                width: 800,
                height: 600,
                owningBundleIdentifier: "com.apple.TextEdit",
                appName: "   ",
                ownBundleID: own
            )
        )
    }

    @MainActor
    func testPanelMarksRehearsalStateFromShow() {
        let controller = TeleprompterPanelController()
        controller.show(
            settings: TeleprompterSettings(script: "预演"),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            cameraFrame: nil,
            isRecording: false,
            onCommit: { _ in }
        )
        XCTAssertEqual(controller.sessionForTesting?.isRehearsal, true)
        controller.show(
            settings: TeleprompterSettings(script: "录制中"),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            cameraFrame: nil,
            isRecording: true,
            onCommit: { _ in }
        )
        XCTAssertEqual(controller.sessionForTesting?.isRehearsal, false)
        controller.hide()
    }

    @MainActor
    func testPanelPauseTogglesWithoutMovingScrollPosition() {
        let controller = TeleprompterPanelController()
        controller.show(
            settings: TeleprompterSettings(script: "测试文稿"),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            cameraFrame: nil,
            onCommit: { _ in }
        )
        defer { controller.hide() }
        guard let session = controller.sessionForTesting else {
            return XCTFail("session missing")
        }
        session.contentHeight = 2_000
        session.viewportHeight = 300
        session.tick(at: session.lastTick.addingTimeInterval(1))
        let held = session.scrollState
        session.togglePause()
        XCTAssertTrue(session.scrollState.isPaused)
        session.tick(at: session.lastTick.addingTimeInterval(5))
        XCTAssertEqual(
            session.scrollState.offset,
            held.offset,
            accuracy: 0.000_001
        )
        session.togglePause()
        XCTAssertFalse(session.scrollState.isPaused)
        // 拖回进度
        session.seek(to: 40)
        XCTAssertEqual(session.scrollState.offset, 40, accuracy: 0.000_001)
    }

    // MARK: - 分段标记与段尾减速（二级）

    @MainActor
    func testSessionComputesSegmentOffsetsFromMeasuredHeights() throws {
        let session = TeleprompterPanelSession(
            settings: TeleprompterSettings(
                script: "第一段\n\n第二段\n\n第三段",
                fontSize: 28
            )
        )
        session.updateSegmentHeights([0: 100, 1: 60, 2: 80])
        // 布局：上内边距 14 + 段高 + 段间距（字号 × 1.2 = 33.6）
        let spacing = session.segmentSpacing
        XCTAssertEqual(spacing, 33.6, accuracy: 0.000_001)
        XCTAssertEqual(session.segmentStartOffsets[0], 14, accuracy: 0.000_001)
        XCTAssertEqual(session.segmentEndOffsets[0], 114, accuracy: 0.000_001)
        XCTAssertEqual(
            session.segmentStartOffsets[1],
            114 + spacing,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            session.segmentEndOffsets[2],
            114 + spacing + 60 + spacing + 80,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testSessionReportsCurrentSegmentAndNextPreview() throws {
        let session = TeleprompterPanelSession(
            settings: TeleprompterSettings(
                script: "第一段内容\n\n第二段从这里开始继续",
                fontSize: 28
            )
        )
        session.contentHeight = 2_000
        session.viewportHeight = 300
        session.updateSegmentHeights([0: 300, 1: 240])

        // offset 0：阅读线在 120 → 当前第 0 段，下一段有预告
        session.seek(to: 0)
        XCTAssertEqual(session.currentSegmentIndex, 0)
        XCTAssertEqual(session.nextSegmentPreview, "第二段从这里开始继续")

        // offset 500：阅读线在 620，越过第 0 段结束（314）→ 当前第 1 段，无下一段
        session.seek(to: 500)
        XCTAssertEqual(session.currentSegmentIndex, 1)
        XCTAssertNil(session.nextSegmentPreview)
    }

    @MainActor
    func testSessionDeceleratesNearSegmentEndAndRecoversAfter() throws {
        let session = TeleprompterPanelSession(
            settings: TeleprompterSettings(
                script: "第一段\n\n第二段",
                fontSize: 28
            )
        )
        session.contentHeight = 2_000
        session.viewportHeight = 300
        session.updateSegmentHeights([0: 300, 1: 200])

        // 远离段尾：无减速
        session.seek(to: 0)
        XCTAssertNil(session.activeDeceleration)
        let fastBefore = session.scrollState
        session.tick(at: session.lastTick.addingTimeInterval(0.5))
        let fastAfter = session.scrollState
        XCTAssertEqual(
            fastAfter.offset - fastBefore.offset,
            120 * 0.5,
            accuracy: 0.000_001
        )

        // 阅读线（offset + 120）距段尾 314 不到减速区（84）→ 减速激活
        // offset 200：阅读线 320 已过段尾；用 offset 120：阅读线 240，
        // 边界折算 314 - 120 = 194，剩余 74 < 84 → 激活
        session.seek(to: 120)
        let deceleration = try XCTUnwrap(session.activeDeceleration)
        XCTAssertEqual(deceleration.boundaryOffset, 194, accuracy: 0.000_001)
        XCTAssertEqual(deceleration.zone, 84, accuracy: 0.000_001)
        XCTAssertEqual(deceleration.floor, 0.35, accuracy: 0.000_001)

        let slowBefore = session.scrollState
        session.tick(at: session.lastTick.addingTimeInterval(0.5))
        let slowAfter = session.scrollState
        let remaining = deceleration.boundaryOffset - slowBefore.offset
        let factor = max(0.35, remaining / deceleration.zone)
        XCTAssertEqual(
            slowAfter.offset - slowBefore.offset,
            120 * 0.5 * factor,
            accuracy: 0.000_001
        )
        XCTAssertLessThan(slowAfter.offset - slowBefore.offset, 60)
    }

    @MainActor
    func testSessionStepOffsetSeeksByEstimatedLine() {
        let session = TeleprompterPanelSession(
            settings: TeleprompterSettings(script: "回退一行", fontSize: 28)
        )
        session.contentHeight = 2_000
        session.viewportHeight = 300
        session.seek(to: 200)
        session.stepOffset(-1)
        XCTAssertEqual(
            session.scrollState.offset,
            200 - 28 * 1.45,
            accuracy: 0.000_001
        )
        session.stepOffset(-10)
        XCTAssertEqual(session.scrollState.offset, 0, accuracy: 0.000_001)
        session.stepOffset(2)
        XCTAssertEqual(
            session.scrollState.offset,
            2 * 28 * 1.45,
            accuracy: 0.000_001
        )
    }
}
