import XCTest
@testable import AniseRecorder

/// GIF 导出尺寸档位：小 / 中 / 大 → 最长边 360 / 720 / 1080，
/// 非法档位回退默认中档 720；体积估算按所选最长边换算。
final class GifSizePresetTests: XCTestCase {
    private func makeProject() -> StudioProject {
        StudioProject(
            id: UUID(),
            name: "测试工程",
            createdAt: Date(),
            folderName: "test-project",
            videoFile: "screen.mp4",
            duration: 10,
            width: 1600,
            height: 900,
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 10,
            zoomScale: 1.65,
            zoomDuration: 1.2,
            autoZoom: true,
            source: .display(displayID: 1),
            canvas: CanvasSettings()
        )
    }

    func testPresetMapsToMaximumEdge() {
        XCTAssertEqual(GifSizePreset.small.maximumWidth, 360)
        XCTAssertEqual(GifSizePreset.medium.maximumWidth, 720)
        XCTAssertEqual(GifSizePreset.large.maximumWidth, 1080)
        XCTAssertEqual(GifSizePreset.allCases.count, 3, "只有小 / 中 / 大三档")
    }

    func testInvalidPresetFallsBackToMedium720() {
        XCTAssertEqual(GifSizePreset.resolved(nil), .medium)
        XCTAssertEqual(GifSizePreset.resolved(""), .medium)
        XCTAssertEqual(GifSizePreset.resolved("huge"), .medium)
        XCTAssertEqual(
            GifSizePreset.resolved("small"),
            .small,
            "合法档位应按原值解析"
        )
    }

    func testEstimateScalesWithSelectedMaximumEdge() {
        let project = makeProject()
        let small = GifExporter.estimate(
            for: project,
            outputSize: project.canvasOutputSize,
            maximumWidth: GifSizePreset.small.maximumWidth
        )
        let medium = GifExporter.estimate(
            for: project,
            outputSize: project.canvasOutputSize,
            maximumWidth: GifSizePreset.medium.maximumWidth
        )
        let large = GifExporter.estimate(
            for: project,
            outputSize: project.canvasOutputSize,
            maximumWidth: GifSizePreset.large.maximumWidth
        )
        XCTAssertEqual(
            max(medium.frameSize.width, medium.frameSize.height),
            720,
            accuracy: 2,
            "中档最长边应为 720"
        )
        XCTAssertEqual(
            max(small.frameSize.width, small.frameSize.height),
            360,
            accuracy: 2,
            "小档最长边应为 360"
        )
        XCTAssertEqual(
            max(large.frameSize.width, large.frameSize.height),
            1080,
            accuracy: 2,
            "大档最长边应为 1080"
        )
        XCTAssertEqual(
            Double(small.estimatedBytes),
            Double(medium.estimatedBytes) / 4,
            accuracy: Double(medium.estimatedBytes) / 4 * 0.02,
            "最长边减半，估算体积约为四分之一"
        )
    }

    func testEstimateDefaultsToMedium720() {
        let project = makeProject()
        let defaultEstimate = GifExporter.estimate(
            for: project,
            outputSize: project.canvasOutputSize
        )
        let mediumEstimate = GifExporter.estimate(
            for: project,
            outputSize: project.canvasOutputSize,
            maximumWidth: GifSizePreset.medium.maximumWidth
        )
        XCTAssertEqual(
            defaultEstimate.frameSize,
            mediumEstimate.frameSize,
            "不传档位时保持原默认最长边 720"
        )
        XCTAssertEqual(
            defaultEstimate.estimatedBytes,
            mediumEstimate.estimatedBytes
        )
        XCTAssertLessThanOrEqual(
            max(defaultEstimate.frameSize.width, defaultEstimate.frameSize.height),
            720
        )
    }

    func testEstimateDoesNotUpscaleSmallCanvas() {
        // 画布本身小于档位最长边时不应放大（scale 封顶 1）。
        let project = makeProject()
        let estimate = GifExporter.estimate(
            for: project,
            outputSize: CGSize(width: 320, height: 180),
            maximumWidth: GifSizePreset.large.maximumWidth
        )
        XCTAssertEqual(
            estimate.frameSize,
            CGSize(width: 320, height: 180),
            "画布小于档位边长时保持原尺寸"
        )
    }
}
