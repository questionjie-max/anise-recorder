import CoreGraphics
import XCTest
@testable import AniseRecorderCore

/// C1 竖屏智能跟随规划器测试：偏移收敛、相邻变化率上限（防抖）、
/// 无脸回中、多脸取最大脸、死区内抖动不切段、采样间隔下限。
final class PortraitFollowTests: XCTestCase {
    func testOffsetConvergesToFaceCenter() {
        // 脸稳定在 x = 0.7：偏移应收敛到脸中心并停住。
        let face = CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.2)
        var observations: [FaceFocusPlanner.Observation] = []
        var time = 0.0
        while time < 4 {
            observations.append(.init(time: time, faces: [face]))
            time += 0.6
        }
        let segments = PortraitFollowPlanner.plan(
            observations: observations,
            analyzedDuration: 4
        )
        XCTAssertFalse(segments.isEmpty)
        // 最后一段落在脸中心（midX = 0.7）的死区之内。
        XCTAssertEqual(segments.last?.offsetX ?? -1, 0.7, accuracy: 0.031)
        // 收敛后不再产生新段。
        XCTAssertEqual(segments.count, 1)
    }

    func testAdjacentSegmentShiftRateIsCapped() {
        // 3 秒处脸从左侧瞬移到右侧：相邻段偏移变化不得超过
        // maximumHorizontalShiftPerSecond × 采样间隔（防抖上限），
        // 且最终仍收敛到目标。
        let left = CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2)
        let right = CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.2)
        var observations: [FaceFocusPlanner.Observation] = []
        var time = 0.0
        while time < 3 {
            observations.append(.init(time: time, faces: [left]))
            time += 0.6
        }
        while time < 8 {
            observations.append(.init(time: time, faces: [right]))
            time += 0.6
        }
        let segments = PortraitFollowPlanner.plan(
            observations: observations,
            analyzedDuration: 8
        )
        XCTAssertGreaterThanOrEqual(segments.count, 2, "远距离瞬移应分步平移")
        let cap = PortraitFollowPlanner.maximumHorizontalShiftPerSecond * 0.6
            + 0.001
        for index in 1 ..< segments.count {
            let delta = abs(
                segments[index].offsetX - segments[index - 1].offsetX
            )
            XCTAssertLessThanOrEqual(
                delta,
                cap,
                "相邻段偏移变化 \(delta) 超过变化率上限 \(cap)"
            )
        }
        XCTAssertEqual(segments.last?.offsetX ?? -1, 0.9, accuracy: 0.031)
    }

    func testNoFaceReturnsTowardCenter() {
        // 有人脸时偏移跟到 0.8，随后长时间无脸：偏移应回中（0.5）。
        let face = CGRect(x: 0.75, y: 0.4, width: 0.1, height: 0.2)
        var observations: [FaceFocusPlanner.Observation] = []
        var time = 0.0
        while time < 2 {
            observations.append(.init(time: time, faces: [face]))
            time += 0.6
        }
        while time < 6 {
            observations.append(.init(time: time, faces: []))
            time += 0.6
        }
        let segments = PortraitFollowPlanner.plan(
            observations: observations,
            analyzedDuration: 6
        )
        XCTAssertEqual(segments.last?.offsetX ?? -1, 0.5, accuracy: 0.031)
    }

    func testLargestFaceWinsAmongMultiple() {
        let small = CGRect(x: 0.9, y: 0.4, width: 0.05, height: 0.1)
        let large = CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.2)
        var observations: [FaceFocusPlanner.Observation] = []
        var time = 0.0
        while time < 3 {
            observations.append(
                .init(time: time, faces: [small, large])
            )
            time += 0.6
        }
        let segments = PortraitFollowPlanner.plan(
            observations: observations,
            analyzedDuration: 3
        )
        // 大脸中心 midX = 0.3。
        XCTAssertEqual(segments.last?.offsetX ?? -1, 0.3, accuracy: 0.031)
    }

    func testJitterWithinDeadbandProducesNoExtraSegments() {
        // 同一位置附近 ±0.01 抖动（峰峰值小于死区 0.03）：不应产生新段。
        var observations: [FaceFocusPlanner.Observation] = []
        for index in 0 ..< 10 {
            let offset = index.isMultiple(of: 2) ? 0.01 : -0.01
            observations.append(
                .init(
                    time: Double(index) * 0.6,
                    faces: [
                        CGRect(
                            x: 0.4 + offset,
                            y: 0.4,
                            width: 0.2,
                            height: 0.2
                        )
                    ]
                )
            )
        }
        let segments = PortraitFollowPlanner.plan(
            observations: observations,
            analyzedDuration: 6
        )
        XCTAssertEqual(segments.count, 1, "死区内抖动不应切换取景")
    }

    func testEmptyObservationsAndShortMaterialProduceNoSegments() {
        XCTAssertTrue(
            PortraitFollowPlanner.plan(
                observations: [],
                analyzedDuration: 10
            ).isEmpty
        )
        // 采样间隔低于下限 → 拒绝（绝不逐帧）。
        XCTAssertTrue(
            PortraitFollowPlanner.plan(
                observations: [
                    .init(
                        time: 0,
                        faces: [CGRect(x: 0, y: 0, width: 0.2, height: 0.2)]
                    )
                ],
                analyzedDuration: 10,
                samplingInterval: 0.1
            ).isEmpty
        )
    }
}

/// 加深队列：竖屏跟随灵敏度三档映射到平移速率，慢档更稳（步数更多、
/// 单步更小），三档都遵守相邻变化率上限与死区规则。
final class PortraitFollowSensitivityTests: XCTestCase {
    private func teleportObservations() -> [FaceFocusPlanner.Observation] {
        let left = CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2)
        let right = CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.2)
        var observations: [FaceFocusPlanner.Observation] = []
        var time = 0.0
        while time < 3 {
            observations.append(.init(time: time, faces: [left]))
            time += 0.6
        }
        while time < 10 {
            observations.append(.init(time: time, faces: [right]))
            time += 0.6
        }
        return observations
    }

    func testSensitivitiesMapToShiftRates() {
        XCTAssertEqual(
            PortraitFollowSensitivity.slow.maximumHorizontalShiftPerSecond,
            0.35,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PortraitFollowSensitivity.standard.maximumHorizontalShiftPerSecond,
            0.6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PortraitFollowSensitivity.fast.maximumHorizontalShiftPerSecond,
            1.0,
            accuracy: 0.001
        )
    }

    func testSlowPanningProducesMoreSmallerStepsThanFast() {
        let observations = teleportObservations()
        let slow = PortraitFollowPlanner.plan(
            observations: observations,
            analyzedDuration: 10,
            maximumHorizontalShiftPerSecond: PortraitFollowSensitivity.slow
                .maximumHorizontalShiftPerSecond
        )
        let fast = PortraitFollowPlanner.plan(
            observations: observations,
            analyzedDuration: 10,
            maximumHorizontalShiftPerSecond: PortraitFollowSensitivity.fast
                .maximumHorizontalShiftPerSecond
        )
        // 慢档单步更小、跨越瞬移需要更多段；两档都收敛到目标。
        XCTAssertGreaterThan(slow.count, fast.count)
        let slowMaxStep = zip(slow.dropFirst(), slow).map {
            abs($0.offsetX - $1.offsetX)
        }.max() ?? 0
        let fastMaxStep = zip(fast.dropFirst(), fast).map {
            abs($0.offsetX - $1.offsetX)
        }.max() ?? 0
        XCTAssertLessThanOrEqual(
            slowMaxStep,
            0.35 * 0.6 + 0.001,
            "慢档相邻变化率不超过其速率上限"
        )
        XCTAssertGreaterThanOrEqual(
            fastMaxStep,
            slowMaxStep,
            "快档单步不小于慢档"
        )
        XCTAssertEqual(slow.last?.offsetX ?? -1, 0.9, accuracy: 0.031)
        XCTAssertEqual(fast.last?.offsetX ?? -1, 0.9, accuracy: 0.031)
    }

    func testDefaultParameterKeepsStandardBehavior() {
        // 不传灵敏度（默认 0.6/秒）时与既有行为一致（回归保护）。
        let segments = PortraitFollowPlanner.plan(
            observations: teleportObservations(),
            analyzedDuration: 10
        )
        XCTAssertEqual(segments.last?.offsetX ?? -1, 0.9, accuracy: 0.031)
    }
}
