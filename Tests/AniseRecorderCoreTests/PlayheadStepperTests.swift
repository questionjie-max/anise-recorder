import XCTest
@testable import AniseRecorderCore

/// 方向键步进播放头的纯函数回归（验收标准 1）。
final class PlayheadStepperTests: XCTestCase {
    func testFrameStepAt30fps() {
        XCTAssertEqual(
            PlayheadStepper.step(
                current: 1.0,
                duration: 10,
                fps: 30,
                isForward: true,
                isCoarse: false
            ),
            1.0 + 1.0 / 30,
            accuracy: 1e-9
        )
    }

    func testCoarseStepIsOneSecond() {
        XCTAssertEqual(
            PlayheadStepper.step(
                current: 1.0,
                duration: 10,
                fps: 30,
                isForward: true,
                isCoarse: true
            ),
            2.0,
            accuracy: 1e-9
        )
    }

    func testClampsToLowerBound() {
        XCTAssertEqual(
            PlayheadStepper.step(
                current: 0.005,
                duration: 10,
                fps: 30,
                isForward: false,
                isCoarse: false
            ),
            0,
            accuracy: 1e-9
        )
    }

    func testClampsToUpperBound() {
        XCTAssertEqual(
            PlayheadStepper.step(
                current: 9.99,
                duration: 10,
                fps: 30,
                isForward: true,
                isCoarse: true
            ),
            10,
            accuracy: 1e-9
        )
    }

    func testZeroDurationStaysAtZero() {
        XCTAssertEqual(
            PlayheadStepper.step(
                current: 0,
                duration: 0,
                fps: 30,
                isForward: true,
                isCoarse: false
            ),
            0,
            accuracy: 1e-9
        )
    }
}
