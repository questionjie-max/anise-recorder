import XCTest
@testable import AniseRecorderCore

/// 拆条纯函数回归（验收标准 1）。
final class CaptionSplitterTests: XCTestCase {
    func testEvenSplit() {
        let split = CaptionSplitter.split(
            start: 0,
            end: 10,
            splitOffset: 5,
            textCount: 10
        )
        XCTAssertEqual(split?.firstStart, 0)
        XCTAssertEqual(split?.firstEnd, 5)
        XCTAssertEqual(split?.secondStart, 5)
        XCTAssertEqual(split?.secondEnd, 10)
    }

    func testSkewedSplitByCharacterRatio() {
        // 1/4 处拆 → 第一条 2.5s
        let split = CaptionSplitter.split(
            start: 0,
            end: 10,
            splitOffset: 5,
            textCount: 20
        )
        XCTAssertEqual(split?.firstEnd ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertEqual(split?.secondStart ?? -1, 2.5, accuracy: 1e-9)
    }

    func testShortFirstClampsToMidpoint() {
        // 0.05s < minimumDuration 0.3 → 分界点推到中点
        let split = CaptionSplitter.split(
            start: 0,
            end: 10,
            splitOffset: 1,
            textCount: 200
        )
        XCTAssertEqual(split?.firstEnd ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(split?.secondStart ?? -1, 5, accuracy: 1e-9)
    }

    func testShortSecondClampsToMidpoint() {
        let split = CaptionSplitter.split(
            start: 0,
            end: 10,
            splitOffset: 199,
            textCount: 200
        )
        XCTAssertEqual(split?.firstEnd ?? -1, 5, accuracy: 1e-9)
    }

    func testOffsetAtEdgesIsClampedInside() {
        // 偏移 0 或 count 都不允许（会拆出空条）——钳到 1 / count-1
        let head = CaptionSplitter.split(
            start: 0, end: 10, splitOffset: 0, textCount: 10
        )
        XCTAssertEqual(head?.firstEnd ?? -1, 1, accuracy: 1e-9)
        let tail = CaptionSplitter.split(
            start: 0, end: 10, splitOffset: 10, textCount: 10
        )
        XCTAssertEqual(tail?.firstEnd ?? -1, 9, accuracy: 1e-9)
    }

    func testInvalidInputReturnsNil() {
        XCTAssertNil(
            CaptionSplitter.split(start: 5, end: 5, splitOffset: 2, textCount: 4)
        )
        XCTAssertNil(
            CaptionSplitter.split(start: 5, end: 3, splitOffset: 2, textCount: 4)
        )
        XCTAssertNil(
            CaptionSplitter.split(start: 0, end: 5, splitOffset: 1, textCount: 1)
        )
    }

    func testNoOverlapAndOrder() {
        let split = CaptionSplitter.split(
            start: 2, end: 9, splitOffset: 3, textCount: 6
        )
        guard let split else {
            return XCTFail("expected split")
        }
        XCTAssertLessThanOrEqual(split.firstStart, split.firstEnd)
        XCTAssertLessThanOrEqual(split.firstEnd, split.secondStart)
        XCTAssertLessThanOrEqual(split.secondStart, split.secondEnd)
    }

    func testSplitTextTrimsAndRejectsEmptySide() {
        let ok = CaptionSplitter.splitText("前半句 后半句", at: 3)
        XCTAssertEqual(ok?.first, "前半句")
        XCTAssertEqual(ok?.second, "后半句")
        // 偏移恰在空白上 → 一侧 trim 后为空 → nil（调用方改走删条）
        XCTAssertNil(CaptionSplitter.splitText("前半句   ", at: 4))
        // 单字符文本无从拆
        XCTAssertNil(CaptionSplitter.splitText("单", at: 0))
    }
}
