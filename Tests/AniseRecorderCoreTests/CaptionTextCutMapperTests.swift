import XCTest
@testable import AniseRecorderCore

/// 文本选区 → 成片时间映射回归（验收标准 1）。
final class CaptionTextCutMapperTests: XCTestCase {
    // 助手：构造 cue 时间范围内的 segment（中点归属）
    private func seg(_ text: String, _ start: Double, _ duration: Double)
        -> (text: String, start: Double, duration: Double)
    {
        (text: text, start: start, duration: duration)
    }

    func testPreciseModeHeadSelection() {
        // 文本「甲乙丙丁」4 字，segments 各 1 秒；选中前两字 → 剪 0-2s
        let segments = [
            seg("甲", 0, 1),
            seg("乙", 1, 1),
            seg("丙", 2, 1),
            seg("丁", 3, 1),
        ]
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 4,
            text: "甲乙丙丁",
            selection: 0 ..< 2,
            segments: segments
        )
        guard case .success(let s) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertFalse(s.isApproximate)
        XCTAssertEqual(s.coveredSegments, 2)
        XCTAssertEqual(s.cutStart, 0, accuracy: 1e-6)
        XCTAssertEqual(s.cutEnd, 2, accuracy: 1e-6)
        XCTAssertEqual(s.removedDuration, 2, accuracy: 1e-6)
    }

    func testPreciseModeMiddleSelection() {
        let segments = [
            seg("甲", 0, 1),
            seg("乙", 1, 1),
            seg("丙", 2, 1),
            seg("丁", 3, 1),
        ]
        // 选中「乙丙」（偏移 1..3）→ 剪 1-3s
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 4,
            text: "甲乙丙丁",
            selection: 1 ..< 3,
            segments: segments
        )
        guard case .success(let s) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(s.cutStart, 1, accuracy: 1e-6)
        XCTAssertEqual(s.cutEnd, 3, accuracy: 1e-6)
        XCTAssertEqual(s.coveredSegments, 2)
    }

    func testPreciseModeTailSelection() {
        let segments = [
            seg("甲", 0, 1),
            seg("乙", 1, 1),
            seg("丙", 2, 1),
            seg("丁", 3, 1),
        ]
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 4,
            text: "甲乙丙丁",
            selection: 2 ..< 4,
            segments: segments
        )
        guard case .success(let s) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(s.cutStart, 2, accuracy: 1e-6)
        XCTAssertEqual(s.cutEnd, 4, accuracy: 1e-6)
    }

    func testApproximateModeWithoutSegments() {
        // 无 segments（SRT 导入）：10 字 10 秒，选中 2-4 字 → 2-4s
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 10,
            text: "一二三四五六七八九十",
            selection: 2 ..< 4,
            segments: []
        )
        guard case .success(let s) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(s.isApproximate)
        XCTAssertEqual(s.coveredSegments, 0)
        XCTAssertEqual(s.cutStart, 2, accuracy: 1e-6)
        XCTAssertEqual(s.cutEnd, 4, accuracy: 1e-6)
    }

    func testApproximateModeWhenRebuildMismatch() {
        // segments 重建「完全不一样」与 cue.text「完全不一样啊」不一致
        // （术语表改写过）→ 回退近似
        let segments = [
            seg("完", 0, 2),
            seg("全", 2, 2),
            seg("不一", 4, 2),
            seg("样", 6, 2),
        ]
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 8,
            text: "完全不一样啊",
            selection: 2 ..< 4,
            segments: segments
        )
        guard case .success(let s) = result else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(s.isApproximate)
    }

    func testRejectsEmptySelection() {
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 4,
            text: "甲乙丙丁",
            selection: 1 ..< 1,
            segments: []
        )
        XCTAssertEqual(result, .failure(.emptySelection))
    }

    func testRejectsWholeTextSelection() {
        // 整条选中 → 让调用方改走删条
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 4,
            text: "甲乙丙丁",
            selection: 0 ..< 4,
            segments: []
        )
        XCTAssertEqual(result, .failure(.emptySelection))
    }

    func testRejectsTooShortCut() {
        // 10 字 10 秒选中 1 字 → 剪 1s？不够——构造 0.2s 的场景：
        // 10 字 2.2 秒，选 1 字 → 剪 0.22s < 0.3 → tooShort
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 2.2,
            text: "一二三四五六七八九十",
            selection: 0 ..< 1,
            segments: []
        )
        XCTAssertEqual(result, .failure(.tooShort))
    }

    func testRejectsShortRemainder() {
        // 条尾只剩 0.1s：10 字 1.2 秒，选中 9-10 字 → 剪 1.08-1.2，
        // 尾部剩 0 → OK；改选 0-9 字 → 剩 0.12s < 0.3 → remainderTooShort
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 1.2,
            text: "一二三四五六七八九十",
            selection: 0 ..< 9,
            segments: []
        )
        XCTAssertEqual(result, .failure(.remainderTooShort))
    }

    func testClampsOutOfRangeSelection() {
        // 选区越界（UTF-16 count 之外）→ 钳到文本内，不崩
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 4,
            text: "甲乙丙丁",
            selection: 2 ..< 99,
            segments: []
        )
        guard case .success(let s) = result else {
            return XCTFail("expected success with clamped selection")
        }
        XCTAssertEqual(s.cutStart, 2, accuracy: 1e-6)
        XCTAssertEqual(s.cutEnd, 4, accuracy: 1e-6)
    }

    func testEnglishMixedTextUsesCharacters() {
        // 中英混排：按字符不按字节——「你好world再见」共 9 字符
        let text = "你好world再见"
        XCTAssertEqual(text.count, 9)
        let result = CaptionTextCutMapper.suggest(
            cueStart: 0,
            cueEnd: 9,
            text: text,
            selection: 0 ..< 2,
            segments: []
        )
        guard case .success(let s) = result else {
            return XCTFail("expected success")
        }
        // 2/9 字符 → 剪 0-2s
        XCTAssertEqual(s.cutStart, 0, accuracy: 1e-6)
        XCTAssertEqual(s.cutEnd, 2, accuracy: 1e-6)
    }

    func testScopedSegmentsFiltersByMidpoint() {
        let segments = [
            seg("之前", -2, 1),   // 中点在 cue 外
            seg("甲", 0, 1),
            seg("乙", 1, 1),
            seg("之后", 4, 1),    // 中点在 cue 外
            seg("空", 2, 1),      // 空文本过滤
        ]
        let scoped = CaptionTextCutMapper.scopedSegments(
            segments, cueStart: 0, cueEnd: 2
        )
        XCTAssertEqual(scoped.count, 2)
        XCTAssertEqual(scoped.map(\.text), ["甲", "乙"])
    }
}
