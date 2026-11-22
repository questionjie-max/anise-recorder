import XCTest
@testable import AniseRecorderCore

/// 电平换算与静音告警的纯函数回归（验收标准 1/2）。
final class InputLevelMeterTests: XCTestCase {
    func testSilenceMapsToZero() {
        XCTAssertEqual(InputLevelMeter.displayValue(rms: 0), 0)
        XCTAssertEqual(InputLevelMeter.normalize(db: -80), 0)
    }

    func testFullScaleMapsToOne() {
        XCTAssertEqual(InputLevelMeter.normalize(db: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(InputLevelMeter.displayValue(rms: 1.0), 1, accuracy: 1e-9)
    }

    func testMinus20dBAndMinus60dBSamples() {
        // -20dBFS：rms = 10^(-20/20) = 0.1
        XCTAssertEqual(
            InputLevelMeter.displayValue(rms: 0.1),
            2.0 / 3.0,
            accuracy: 1e-9
        )
        XCTAssertFalse(InputLevelMeter.isSilent(rms: 0.1))
        // -60dBFS：rms = 10^(-60/20) = 0.001 → 归一化 0；低于 -55dB 阈值判静音
        XCTAssertEqual(InputLevelMeter.normalize(db: -60), 0, accuracy: 1e-9)
        XCTAssertTrue(InputLevelMeter.isSilent(rms: 0.001))
    }

    func testSilentThreshold() {
        // -55dB 以下判静音
        XCTAssertTrue(InputLevelMeter.isSilent(rms: 0.0))
        let minus60 = pow(10.0, -60.0 / 20.0)
        XCTAssertTrue(InputLevelMeter.isSilent(rms: minus60))
        let minus50 = pow(10.0, -50.0 / 20.0)
        XCTAssertFalse(InputLevelMeter.isSilent(rms: minus50))
    }

    func testRMSOfBuffer() {
        XCTAssertEqual(InputLevelMeter.rms(of: []), 0)
        XCTAssertEqual(InputLevelMeter.rms(of: [0, 0, 0]), 0)
        XCTAssertEqual(InputLevelMeter.rms(of: [1, -1, 1, -1]), 1, accuracy: 1e-9)
        XCTAssertEqual(
            InputLevelMeter.rms(of: [0.5, -0.5]),
            0.5,
            accuracy: 1e-9
        )
    }
}

/// 静音告警状态机回归（验收标准 2）。
final class SilentAlarmTests: XCTestCase {
    func testWarnsOnceInsideWindow() {
        var alarm = SilentAlarm()
        // 窗口内持续静音：只触发一次
        XCTAssertTrue(alarm.sample(isSilent: true, elapsed: 8.0))
        XCTAssertFalse(alarm.sample(isSilent: true, elapsed: 9.0))
        XCTAssertFalse(alarm.sample(isSilent: true, elapsed: 15.0))
    }

    func testDoesNotWarnBeforeOrAfterWindow() {
        var alarm = SilentAlarm()
        XCTAssertFalse(alarm.sample(isSilent: true, elapsed: 5.0))
        XCTAssertFalse(alarm.sample(isSilent: true, elapsed: 20.0))
        XCTAssertFalse(alarm.hasWarned)
    }

    func testDoesNotWarnOnLoudInput() {
        var alarm = SilentAlarm()
        for elapsed in stride(from: 0.0, through: 20.0, by: 1.0) {
            XCTAssertFalse(alarm.sample(isSilent: false, elapsed: elapsed))
        }
        XCTAssertFalse(alarm.hasWarned)
    }

    func testRecoveryInsideWindowStillWarnsOnce() {
        var alarm = SilentAlarm()
        // 窗口起点附近短暂非静音不消警（恢复后再次静音仍可告警一次）
        XCTAssertFalse(alarm.sample(isSilent: false, elapsed: 8.5))
        XCTAssertTrue(alarm.sample(isSilent: true, elapsed: 10.0))
        XCTAssertFalse(alarm.sample(isSilent: false, elapsed: 11.0))
        XCTAssertFalse(alarm.sample(isSilent: true, elapsed: 12.0))
    }
}
