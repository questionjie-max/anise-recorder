import XCTest
@testable import AniseRecorder

/// 按标记分段导出的分段规划纯函数。覆盖 sourceTime→成片映射、
/// 已剪除区间跳过、空标记、单标记、相邻标记边界与文件命名回退。
final class MarkerSegmentPlannerTests: XCTestCase {
    private func makeMarker(
        _ sourceTime: Double,
        _ name: String = "标记"
    ) -> RecordingMarker {
        RecordingMarker(sourceTime: sourceTime, name: name)
    }

    /// 无剪辑：sourceTime 原样映射为成片时间，段终点为下一标记或片尾。
    func testUncutProjectMapsSourceTimeDirectly() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(5, "第二节"), makeMarker(12, "第三节")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.skipped.count, 0)
        XCTAssertEqual(plan.segments[0].markerName, "第二节")
        XCTAssertEqual(plan.segments[0].start, 5, accuracy: 0.001)
        XCTAssertEqual(plan.segments[0].end, 12, accuracy: 0.001)
        XCTAssertEqual(plan.segments[1].start, 12, accuracy: 0.001)
        XCTAssertEqual(plan.segments[1].end, 20, accuracy: 0.001)
    }

    /// 剪掉源时间 [5, 15) 后：20 映射为 10，12 落入剪除区间 → 跳过。
    func testMarkerInCutRegionIsSkipped() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(12, "被剪"), makeMarker(20, "保留")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { time in
                if time >= 5 && time < 15 { return nil }
                return time < 5 ? time : time - 10
            }
        )
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertEqual(plan.skipped[0].markerName, "被剪")
        XCTAssertEqual(plan.segments[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(plan.segments[0].end, 20, accuracy: 0.001)
    }

    func testNoMarkersProducesEmptyPlan() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertTrue(plan.segments.isEmpty)
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testSingleMarkerProducesSegmentToEnd() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(8, "第一节")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan.segments[0].start, 8, accuracy: 0.001)
        XCTAssertEqual(plan.segments[0].end, 20, accuracy: 0.001)
    }

    /// 标记在 0：首段从 0 开始，不产生空段、不丢开头。
    func testMarkerAtZeroStartsFirstSegmentAtZero() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(0, "开场"), makeMarker(6, "正文")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(plan.segments[0].end, 6, accuracy: 0.001)
        XCTAssertEqual(plan.segments[1].start, 6, accuracy: 0.001)
        XCTAssertEqual(plan.segments[1].end, 20, accuracy: 0.001)
    }

    /// 标记恰在片尾：映射到片尾不成段，列入跳过清单。
    func testMarkerAtTailProducesNoEmptySegment() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(6, "正文"), makeMarker(20, "片尾")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan.segments[0].start, 6, accuracy: 0.001)
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertEqual(plan.skipped[0].markerName, "片尾")
    }

    /// 标记贴近片尾（不足最短段长）：不产生过短段，列入跳过清单。
    func testMarkerJustBeforeTailProducesNoShortSegment() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(19.95, "片尾")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertTrue(plan.segments.isEmpty)
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertEqual(plan.skipped[0].markerName, "片尾")
    }

    /// 同一时间多标记：合并为一段，不产生空段。胜出者由标记 id 决定
    /// （与 project.markers 既有排序一致），测试只断言不变量：甲 / 乙
    /// 之一成段、另一个并入前段。
    func testSameTimeMarkersMergeIntoOneSegment() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [
                makeMarker(6, "甲"),
                makeMarker(6, "乙"),
                makeMarker(12, "丙")
            ],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertTrue(
            plan.segments[0].markerName == "甲"
                || plan.segments[0].markerName == "乙"
        )
        XCTAssertEqual(plan.segments[0].end, 12, accuracy: 0.001)
        XCTAssertEqual(plan.segments[1].markerName, "丙")
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertNotEqual(
            plan.skipped[0].markerName,
            plan.segments[0].markerName
        )
        XCTAssertTrue(
            plan.skipped[0].markerName == "甲"
                || plan.skipped[0].markerName == "乙"
        )
    }

    /// 相邻标记：间隔小于最短段长并入前段；达到阈值正常分段。
    func testAdjacentMarkersBelowThresholdMerge() {
        let close = MarkerSegmentPlanner.plan(
            markers: [makeMarker(6, "甲"), makeMarker(6.05, "乙")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(close.segments.count, 1)
        XCTAssertEqual(close.segments[0].markerName, "甲")
        XCTAssertEqual(close.skipped.count, 1)

        let separate = MarkerSegmentPlanner.plan(
            markers: [makeMarker(6, "甲"), makeMarker(6.5, "乙")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(separate.segments.count, 2)
        XCTAssertTrue(separate.skipped.isEmpty)
    }

    /// 未勾选的标记不进段、也不进跳过清单。
    func testExcludedMarkerIsOmitted() {
        let kept = makeMarker(6, "保留")
        let dropped = makeMarker(12, "不导出")
        let plan = MarkerSegmentPlanner.plan(
            markers: [kept, dropped],
            excludedIDs: [dropped.id],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan.segments[0].markerID, kept.id)
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    /// 全部标记被剪除：无段可导出。
    func testAllMarkersSkippedYieldsEmptySegments() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(6, "被剪"), makeMarker(8, "也被剪")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { _ in nil }
        )
        XCTAssertTrue(plan.segments.isEmpty)
        XCTAssertEqual(plan.skipped.count, 2)
    }

    func testFileNameUsesBaseAndMarkerName() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(6, "第二节")],
            excludedIDs: [],
            baseName: "Swift 入门",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments[0].fileName, "Swift 入门-第二节.mp4")
    }

    /// 空名标记回退「段 N」命名（N 为段序号），不产生无法保存的文件名。
    func testEmptyMarkerNameFallsBackToSegmentNumber() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [makeMarker(6, ""), makeMarker(12, "第二节")],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 20,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments[0].fileName, "课程-段 1.mp4")
        XCTAssertEqual(plan.segments[1].fileName, "课程-第二节.mp4")
    }

    /// 重名标记自动加序号；非法字符回退连字符，仍可保存。
    func testDuplicateMarkerNamesGetSequenceSuffixAndSanitize() {
        let plan = MarkerSegmentPlanner.plan(
            markers: [
                makeMarker(6, "回顾"),
                makeMarker(12, "回顾"),
                makeMarker(18, "第3章:答疑")
            ],
            excludedIDs: [],
            baseName: "课程",
            trimDuration: 30,
            outputTime: { $0 }
        )
        XCTAssertEqual(plan.segments[0].fileName, "课程-回顾.mp4")
        XCTAssertEqual(plan.segments[1].fileName, "课程-回顾-2.mp4")
        XCTAssertEqual(plan.segments[2].fileName, "课程-第3章-答疑.mp4")
    }
}
