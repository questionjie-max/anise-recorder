import XCTest
@testable import AniseRecorder

/// Esc / 停止按钮防误触确认状态机（纯函数，HUD 只消费）。
/// 默认关 = 任何一次按键立即停止（现状）；开 = 窗口内第二次按键才停。
final class StopConfirmationTests: XCTestCase {
    private let window: TimeInterval = 0.5
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testDisabledStopsImmediatelyOnFirstPress() {
        // 默认关：现状不变，第一次按键直接停止，不进待确认。
        let (phase, action) = StopConfirmation.press(
            enabled: false,
            phase: .idle,
            now: t0,
            window: window
        )
        XCTAssertEqual(phase, .idle)
        XCTAssertEqual(action, .stop)
    }

    func testEnabledFirstPressPromptsWithoutStopping() {
        // 开：第一次按键只给提示，不停止；记录窗口截止时刻。
        let (phase, action) = StopConfirmation.press(
            enabled: true,
            phase: .idle,
            now: t0,
            window: window
        )
        XCTAssertEqual(phase, .awaiting(deadline: t0.addingTimeInterval(window)))
        XCTAssertEqual(action, .prompt)
    }

    func testEnabledSecondPressWithinWindowStops() {
        // 开：窗口内第二次按键确认停止，回到待机。
        let awaiting = StopConfirmation.Phase.awaiting(
            deadline: t0.addingTimeInterval(window)
        )
        let (phase, action) = StopConfirmation.press(
            enabled: true,
            phase: awaiting,
            now: t0.addingTimeInterval(0.4),
            window: window
        )
        XCTAssertEqual(phase, .idle)
        XCTAssertEqual(action, .stop)
    }

    func testEnabledSecondPressAtWindowBoundaryStops() {
        // 恰好落在截止时刻（含端点）也算窗口内确认。
        let awaiting = StopConfirmation.Phase.awaiting(
            deadline: t0.addingTimeInterval(window)
        )
        let (_, action) = StopConfirmation.press(
            enabled: true,
            phase: awaiting,
            now: t0.addingTimeInterval(window),
            window: window
        )
        XCTAssertEqual(action, .stop)
    }

    func testEnabledSecondPressAfterWindowStartsNewCycle() {
        // 超过窗口的第二按不停止——重新走一轮提示（防误触的本意）。
        let awaiting = StopConfirmation.Phase.awaiting(
            deadline: t0.addingTimeInterval(window)
        )
        let (phase, action) = StopConfirmation.press(
            enabled: true,
            phase: awaiting,
            now: t0.addingTimeInterval(0.6),
            window: window
        )
        XCTAssertEqual(
            phase,
            .awaiting(deadline: t0.addingTimeInterval(0.6 + window))
        )
        XCTAssertEqual(action, .prompt)
    }

    func testEnabledPressAfterWindowExpiredRevertsThenPrompts() {
        // UI 超时回退未及触发时，过期的待确认相位也等同待机：
        // 下一按重新提示，绝不误停。
        let awaiting = StopConfirmation.Phase.awaiting(
            deadline: t0.addingTimeInterval(window)
        )
        let (phase, action) = StopConfirmation.press(
            enabled: true,
            phase: awaiting,
            now: t0.addingTimeInterval(2),
            window: window
        )
        XCTAssertEqual(
            phase,
            .awaiting(deadline: t0.addingTimeInterval(2 + window))
        )
        XCTAssertEqual(action, .prompt)
    }

    func testDisablingMidConfirmationStopsImmediatelyOnNextPress() {
        // 录制中设置不可达（主窗口隐藏），但状态机对开关翻转仍自洽：
        // 关闭后的下一按立即停止。
        let awaiting = StopConfirmation.Phase.awaiting(
            deadline: t0.addingTimeInterval(window)
        )
        let (phase, action) = StopConfirmation.press(
            enabled: false,
            phase: awaiting,
            now: t0.addingTimeInterval(0.1),
            window: window
        )
        XCTAssertEqual(phase, .idle)
        XCTAssertEqual(action, .stop)
    }
}
