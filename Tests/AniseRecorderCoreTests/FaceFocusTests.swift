import CoreGraphics
import XCTest
@testable import AniseRecorderCore

/// 1.2 人脸居中规划器测试：焦点收敛、抖动上限、无脸 / 多脸 / 出画边界、
/// Vision 坐标 → cropFocus 的 y 翻转。
final class FaceFocusTests: XCTestCase {
    func testVisionRectMapsToCropFocusWithYFlip() {
        // Vision 左下原点：矩形 y 0.55 高 0.3 → 中心 y 0.7 →
        // cropFocus.y = 1 - 0.7 = 0.3。
        let rect = CGRect(x: 0.4, y: 0.55, width: 0.2, height: 0.3)
        let focus = FaceFocusPlanner.cropFocusFromVisionRect(rect)
        XCTAssertEqual(focus.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(focus.y, 0.3, accuracy: 0.001)
    }

    func testLargestFaceWinsAmongMultiple() {
        let small = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        let large = CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
        let focus = FaceFocusPlanner.largestFaceFocus(in: [small, large])
        // 大脸中心（Vision y 上）：x 0.75, y 1 - 0.75 = 0.25。
        XCTAssertEqual(focus?.x ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(focus?.y ?? -1, 0.25, accuracy: 0.001)
        XCTAssertNil(FaceFocusPlanner.largestFaceFocus(in: []))
    }

    func testFocusConvergesToFaceCenterWithDeadband() {
        // 0–3s 脸在左，3s 后脸移到右：应有且只有一段切换。
        let left = CGRect(x: 0.15, y: 0.4, width: 0.2, height: 0.2)
        let right = CGRect(x: 0.65, y: 0.4, width: 0.2, height: 0.2)
        var observations: [FaceFocusPlanner.Observation] = []
        var time = 0.0
        while time < 3 {
            observations.append(.init(time: time, faces: [left]))
            time += 0.5
        }
        while time < 6 {
            observations.append(.init(time: time, faces: [right]))
            time += 0.5
        }
        let segments = FaceFocusPlanner.plan(
            observations: observations,
            analyzedDuration: 6
        )
        XCTAssertEqual(segments.count, 2, "一次移动只应产生一个新段")
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
        // 左脸中心（Vision y 0.5 → cropFocus y 0.5）。
        XCTAssertEqual(segments[0].focus.x, 0.25, accuracy: 0.03)
        XCTAssertEqual(segments[1].start, 3.0, accuracy: 0.6)
        XCTAssertEqual(segments[1].focus.x, 0.75, accuracy: 0.03)
    }

    func testJitterWithinDeadbandProducesNoExtraSegments() {
        // 同一位置附近 ±0.01 抖动（峰峰值 0.02 < 死区 0.03）：不应产生
        // 新段；±0.02 的峰峰值已超过死区，属于真实移动。
        var observations: [FaceFocusPlanner.Observation] = []
        for index in 0..<12 {
            let offset = index.isMultiple(of: 2) ? 0.01 : -0.01
            observations.append(
                .init(
                    time: Double(index) * 0.5,
                    faces: [CGRect(x: 0.2 + offset, y: 0.4, width: 0.2, height: 0.2)]
                )
            )
        }
        let segments = FaceFocusPlanner.plan(
            observations: observations,
            analyzedDuration: 6
        )
        XCTAssertEqual(segments.count, 1, "死区内抖动不应切换焦点")
    }

    func testNoFaceKeepsPreviousFocus() {
        let face = CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.2)
        var observations: [FaceFocusPlanner.Observation] = [
            .init(time: 0, faces: [face]),
            .init(time: 1, faces: [face])
        ]
        // 2–5 秒无脸。
        var time = 2.0
        while time < 5 {
            observations.append(.init(time: time, faces: []))
            time += 0.5
        }
        observations.append(.init(time: 5, faces: [face]))
        let segments = FaceFocusPlanner.plan(
            observations: observations,
            analyzedDuration: 5.5
        )
        XCTAssertEqual(segments.count, 1, "无脸区间沿用上一个焦点")
        XCTAssertEqual(segments[0].focus.x, 0.3, accuracy: 0.03)
    }

    func testFaceOutOfRangeClampsFocus() {
        // 脸中心超出 0...1（检测框越界）：焦点钳制。
        let outside = CGRect(x: 0.95, y: -0.2, width: 0.3, height: 0.3)
        let focus = FaceFocusPlanner.cropFocusFromVisionRect(outside)
        XCTAssertLessThanOrEqual(focus.x, 1)
        XCTAssertGreaterThanOrEqual(focus.y, 0)
        XCTAssertEqual(focus.x, 1, accuracy: 0.001)
        XCTAssertEqual(focus.y, 1, accuracy: 0.001)
    }

    func testEmptyObservationsAndShortMaterial() {
        XCTAssertTrue(
            FaceFocusPlanner.plan(
                observations: [],
                analyzedDuration: 10
            ).isEmpty
        )
        // 采样间隔低于下限 → 拒绝（绝不逐帧）。
        XCTAssertTrue(
            FaceFocusPlanner.plan(
                observations: [
                    .init(time: 0, faces: [CGRect(x: 0, y: 0, width: 0.2, height: 0.2)])
                ],
                analyzedDuration: 10,
                samplingInterval: 0.1
            ).isEmpty
        )
    }
}
