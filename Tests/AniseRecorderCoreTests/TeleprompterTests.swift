import XCTest
@testable import AniseRecorderCore

final class TeleprompterScrollEngineTests: XCTestCase {
    // MARK: - 速度映射

    func testSpeedMappingIsLinearAcrossTenLevels() {
        XCTAssertEqual(
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 1),
            24,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 10),
            240,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 5),
            120,
            accuracy: 0.000_001
        )
        // 单调递增且每档差值一致（线性）
        var previous = 0.0
        for level in 1 ... 10 {
            let pps = TeleprompterScrollEngine.pointsPerSecond(forSpeed: Double(level))
            XCTAssertGreaterThan(pps, previous)
            previous = pps
        }
        XCTAssertEqual(
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 6)
                - TeleprompterScrollEngine.pointsPerSecond(forSpeed: 5),
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 2)
                - TeleprompterScrollEngine.pointsPerSecond(forSpeed: 1),
            accuracy: 0.000_001
        )
    }

    func testSpeedMappingClampsOutOfRangeValues() {
        XCTAssertEqual(
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 0),
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 1)
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: -3),
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 1)
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 99),
            TeleprompterScrollEngine.pointsPerSecond(forSpeed: 10)
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.clampedSpeed(0.5),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.clampedSpeed(42),
            10,
            accuracy: 0.000_001
        )
    }

    // MARK: - 位置计算

    func testAdvanceMovesOffsetBySpeedTimesElapsed() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 5_000,
            viewportHeight: 300,
            speed: 5
        )
        var state = TeleprompterScrollState.initial
        state = engine.advanced(from: state, by: 1)
        XCTAssertEqual(state.offset, 120, accuracy: 0.000_001)
        state = engine.advanced(from: state, by: 0.5)
        XCTAssertEqual(state.offset, 180, accuracy: 0.000_001)
        XCTAssertEqual(state.elapsedActiveTime, 1.5, accuracy: 0.000_001)
        XCTAssertFalse(state.isPaused)
    }

    func testMaxOffsetSubtractsViewportFromContent() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 500,
            viewportHeight: 300,
            speed: 5
        )
        XCTAssertEqual(engine.maxOffset, 200, accuracy: 0.000_001)
        let smallEngine = TeleprompterScrollEngine(
            contentHeight: 100,
            viewportHeight: 300,
            speed: 5
        )
        XCTAssertEqual(smallEngine.maxOffset, 0, accuracy: 0.000_001)
        XCTAssertTrue(smallEngine.isAtEnd(in: TeleprompterScrollState.initial))
    }

    func testAdvanceClampsAtEndAndStaysThere() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 500,
            viewportHeight: 300,
            speed: 10
        )
        var state = TeleprompterScrollState.initial
        state = engine.advanced(from: state, by: 100)
        XCTAssertEqual(state.offset, 200, accuracy: 0.000_001)
        XCTAssertTrue(engine.isAtEnd(in: state))
        // 已到尾部继续推进：不回弹、不为负、不再前进
        state = engine.advanced(from: state, by: 10)
        XCTAssertEqual(state.offset, 200, accuracy: 0.000_001)
    }

    // MARK: - 暂停不跳位

    func testPauseHoldsPositionWithoutAccumulatingTime() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 5_000,
            viewportHeight: 300,
            speed: 5
        )
        var state = TeleprompterScrollState.initial
        state = engine.advanced(from: state, by: 2)
        let heldOffset = state.offset
        state = engine.paused(state)
        XCTAssertTrue(state.isPaused)

        // 暂停期间任意时长推进：位置与活跃时长都不变
        state = engine.advanced(from: state, by: 0.016)
        state = engine.advanced(from: state, by: 30)
        XCTAssertEqual(state.offset, heldOffset, accuracy: 0.000_001)
        XCTAssertEqual(state.elapsedActiveTime, 2, accuracy: 0.000_001)

        // 继续后从原位接着走，不跳位
        state = engine.resumed(state)
        XCTAssertFalse(state.isPaused)
        state = engine.advanced(from: state, by: 1)
        XCTAssertEqual(state.offset, heldOffset + 120, accuracy: 0.000_001)
    }

    func testPauseIsIdempotentAndResumePreservesOffset() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 5_000,
            viewportHeight: 300,
            speed: 3
        )
        var state = TeleprompterScrollState.initial
        state = engine.advanced(from: state, by: 1)
        state = engine.paused(state)
        state = engine.paused(state)
        XCTAssertTrue(state.isPaused)
        let offset = state.offset
        state = engine.resumed(state)
        state = engine.resumed(state)
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.offset, offset, accuracy: 0.000_001)
    }

    // MARK: - 进度拖回

    func testSeekClampsToValidRange() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 500,
            viewportHeight: 300,
            speed: 5
        )
        var state = TeleprompterScrollState.initial
        state = engine.advanced(from: state, by: 3)

        state = engine.seek(to: 120, in: state)
        XCTAssertEqual(state.offset, 120, accuracy: 0.000_001)

        state = engine.seek(to: -50, in: state)
        XCTAssertEqual(state.offset, 0, accuracy: 0.000_001)

        state = engine.seek(to: 999, in: state)
        XCTAssertEqual(state.offset, 200, accuracy: 0.000_001)
    }

    func testSeekPreservesPauseStateAndContinuesCorrectly() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 5_000,
            viewportHeight: 300,
            speed: 5
        )
        var state = TeleprompterScrollState.initial
        state = engine.paused(state)
        state = engine.seek(to: 80, in: state)
        XCTAssertTrue(state.isPaused)
        XCTAssertEqual(state.offset, 80, accuracy: 0.000_001)
        state = engine.resumed(state)
        state = engine.advanced(from: state, by: 1)
        XCTAssertEqual(state.offset, 200, accuracy: 0.000_001)
    }

    // MARK: - 边界

    func testEmptyDocumentNeverMoves() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 0,
            viewportHeight: 300,
            speed: 5
        )
        var state = TeleprompterScrollState.initial
        XCTAssertTrue(engine.isAtEnd(in: state))
        state = engine.advanced(from: state, by: 60)
        XCTAssertEqual(state.offset, 0, accuracy: 0.000_001)
        XCTAssertTrue(engine.isAtEnd(in: state))
        state = engine.seek(to: 42, in: state)
        XCTAssertEqual(state.offset, 0, accuracy: 0.000_001)
    }

    func testVeryLongDocumentAdvancesMonotonicallyToEnd() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 120_000,
            viewportHeight: 300,
            speed: 10
        )
        var state = TeleprompterScrollState.initial
        var previousOffset = 0.0
        for _ in 0 ..< 10_000 {
            state = engine.advanced(from: state, by: 0.5)
            XCTAssertGreaterThanOrEqual(state.offset, previousOffset)
            previousOffset = state.offset
        }
        XCTAssertEqual(
            state.offset,
            engine.maxOffset,
            accuracy: 0.000_001
        )
        XCTAssertEqual(state.elapsedActiveTime, 5_000, accuracy: 0.000_001)
    }

    func testResetReturnsToTopAndKeepsSpeed() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 5_000,
            viewportHeight: 300,
            speed: 7
        )
        var state = TeleprompterScrollState.initial
        state = engine.advanced(from: state, by: 5)
        state = engine.paused(state)
        state = engine.seek(to: 900, in: state)
        state = engine.reset()
        XCTAssertEqual(state.offset, 0, accuracy: 0.000_001)
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.elapsedActiveTime, 0, accuracy: 0.000_001)
    }

    func testNegativeOrZeroIntervalIsNoOp() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 5_000,
            viewportHeight: 300,
            speed: 5
        )
        var state = TeleprompterScrollState.initial
        state = engine.advanced(from: state, by: 2)
        let offset = state.offset
        state = engine.advanced(from: state, by: 0)
        state = engine.advanced(from: state, by: -1)
        XCTAssertEqual(state.offset, offset, accuracy: 0.000_001)
    }

    // MARK: - 段尾减速（二级）

    func testDecelerationTapersLinearlyInsideZoneAndFloors() {
        // 边界 500、减速区 100、下限 0.35：剩 120 时全速，剩 50 减半，剩 5 到底
        XCTAssertEqual(
            TeleprompterScrollEngine.decelerationMultiplier(
                remainingToBoundary: 120,
                zone: 100,
                floor: 0.35
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.decelerationMultiplier(
                remainingToBoundary: 50,
                zone: 100,
                floor: 0.35
            ),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.decelerationMultiplier(
                remainingToBoundary: 5,
                zone: 100,
                floor: 0.35
            ),
            0.35,
            accuracy: 0.000_001
        )
    }

    func testDecelerationDoesNotApplyPastBoundaryOrInvalidZone() {
        XCTAssertEqual(
            TeleprompterScrollEngine.decelerationMultiplier(
                remainingToBoundary: -10,
                zone: 100,
                floor: 0.35
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.decelerationMultiplier(
                remainingToBoundary: 40,
                zone: 0,
                floor: 0.35
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterScrollEngine.decelerationMultiplier(
                remainingToBoundary: 40,
                zone: -5,
                floor: 0.35
            ),
            1,
            accuracy: 0.000_001
        )
    }

    func testAdvancedWithDecelerationSlowsNearSegmentEnd() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 5_000,
            viewportHeight: 300,
            speed: 5
        )
        let deceleration = TeleprompterScrollEngine.Deceleration(
            boundaryOffset: 500,
            zone: 100,
            floor: 0.35
        )
        // 剩余 120（500-380）→ 全速
        var state = TeleprompterScrollState(offset: 380)
        state = engine.advanced(from: state, by: 1, deceleration: deceleration)
        XCTAssertEqual(state.offset, 500, accuracy: 0.000_001)

        // 剩余 50 → 半速
        state = TeleprompterScrollState(offset: 450)
        state = engine.advanced(from: state, by: 0.5, deceleration: deceleration)
        XCTAssertEqual(state.offset, 480, accuracy: 0.000_001)

        // 越过边界后恢复全速
        state = TeleprompterScrollState(offset: 520)
        state = engine.advanced(from: state, by: 1, deceleration: deceleration)
        XCTAssertEqual(state.offset, 640, accuracy: 0.000_001)

        // 暂停时减速也不推进
        state = TeleprompterScrollState(offset: 450, isPaused: true)
        state = engine.advanced(from: state, by: 1, deceleration: deceleration)
        XCTAssertEqual(state.offset, 450, accuracy: 0.000_001)
    }

    func testEngineAcceptsViewportLargerThanContentAndNegativeInput() {
        let engine = TeleprompterScrollEngine(
            contentHeight: 200,
            viewportHeight: -50,
            speed: 2
        )
        // 视口非法输入按 0 处理：内容 200 全部可滚
        XCTAssertEqual(engine.maxOffset, 200, accuracy: 0.000_001)
    }

    // MARK: - 分段（二级：分段标记）

    func testSegmentsSplitOnBlankLines() {
        let text = "第一段第一行\n第一段第二行\n\n第二段只有一行\n\n\n第三段"
        let document = TeleprompterDocument(text: text)
        XCTAssertEqual(document.segments.count, 3)
        XCTAssertEqual(document.segments[0].text, "第一段第一行\n第一段第二行")
        XCTAssertEqual(document.segments[1].text, "第二段只有一行")
        XCTAssertEqual(document.segments[2].text, "第三段")
    }

    func testSegmentsPreserveSourceOffsets() {
        let text = "ABC\n\nDEF"
        let document = TeleprompterDocument(text: text)
        XCTAssertEqual(document.segments.count, 2)
        XCTAssertEqual(document.segments[0].startOffset, 0)
        XCTAssertEqual(document.segments[0].text, "ABC")
        XCTAssertEqual(document.segments[1].startOffset, 5)
        XCTAssertEqual(document.segments[1].text, "DEF")
    }

    func testEmptyAndWhitespaceDocumentsProduceNoSegments() {
        XCTAssertEqual(TeleprompterDocument(text: "").segments, [])
        XCTAssertEqual(
            TeleprompterDocument(text: "   \n \n\t\n").segments,
            []
        )
        let single = TeleprompterDocument(text: "只有一段")
        XCTAssertEqual(single.segments.count, 1)
    }

    func testCarriageReturnsAreNormalized() {
        let document = TeleprompterDocument(text: "第一段\r\n\r\n第二段")
        XCTAssertEqual(document.segments.count, 2)
        XCTAssertEqual(document.normalizedText, "第一段\n\n第二段")
    }
}
