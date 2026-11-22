import XCTest
@testable import AniseRecorderCore

final class CaptureClockTests: XCTestCase {
    func testPauseRemovesWallClockGapFromOutputTime() throws {
        var clock = CaptureClock()
        XCTAssertNil(clock.outputTime(forHostTime: 101))

        clock.setOrigin(100)
        XCTAssertEqual(
            try XCTUnwrap(clock.outputTime(forHostTime: 110)),
            10,
            accuracy: 0.000_001
        )

        clock.pause(at: 112)
        XCTAssertNil(clock.outputTime(forHostTime: 119))
        XCTAssertNil(clock.nextActiveHostTime(atOrAfter: 113))

        clock.resume(at: 120)
        XCTAssertEqual(
            try XCTUnwrap(clock.outputTime(forHostTime: 120)),
            12,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(clock.outputTime(forHostTime: 125)),
            17,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(clock.nextActiveHostTime(atOrAfter: 113)),
            120,
            accuracy: 0.000_001
        )
    }

    func testMultiplePausesAreCompressedInOrder() throws {
        var clock = CaptureClock(originHostTime: 10)
        clock.pause(at: 12)
        clock.resume(at: 20)
        clock.pause(at: 25)
        clock.resume(at: 31)

        XCTAssertEqual(clock.pauses.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(clock.outputTime(forHostTime: 32)),
            8,
            accuracy: 0.000_001
        )
        XCTAssertNil(clock.outputTime(forHostTime: 9.5))
    }

    func testTenPausesCompressOnlyRecordedIntervals() throws {
        var clock = CaptureClock(originHostTime: 100)
        for index in 0 ..< 10 {
            let pause = 101.0 + Double(index) * 3
            clock.pause(at: pause)
            clock.resume(at: pause + 2)
        }
        XCTAssertEqual(clock.pauses.count, 10)
        XCTAssertEqual(
            try XCTUnwrap(clock.outputTime(forHostTime: 130)),
            10,
            accuracy: 0.000_001
        )
        XCTAssertNil(clock.outputTime(forHostTime: 129))
        XCTAssertEqual(
            try XCTUnwrap(clock.nextActiveHostTime(atOrAfter: 129.5)),
            130,
            accuracy: 0.000_001
        )
    }
}
