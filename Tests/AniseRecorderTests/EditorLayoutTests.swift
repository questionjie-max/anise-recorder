import AppKit
import SwiftUI
import XCTest
@testable import AniseRecorder

/// 编辑器三栏布局回归（2026-11-11 任务一）：右栏检查器内容再长也不改变中间
/// 主编辑区的尺寸，右栏栏内滚动兜底，中间预览有保底高度。用 NSHostingView
/// 承载真实 EditorView 后测量 AppKit 视图树（HostingScrollView 与
/// AVPlayerView 的实际 frame）。
@MainActor
final class EditorLayoutTests: XCTestCase {
    /// 摄像头页全部分组展开（最坏情况：右栏内容约 1300pt 高）。
    private static let allCameraSections: Set<InspectorSection> = [
        .cameraComposition,
        .cameraPosition,
        .cameraAppearance,
        .cameraChromaKey,
        .cameraFace
    ]

    private struct Measurement {
        var inspectorScrollFrame = CGRect.zero
        var inspectorDocumentHeight: CGFloat = 0
        var previewFrame = CGRect.zero
    }

    /// 构造带摄像头轨的模型；只落一个空 camera.mov 让 cameraURL 非空，
    /// 足以渲染完整摄像头卡（布局测量不需要可播放素材）。
    private func makeModel() throws -> (StudioModel, URL) {
        let folder = ProjectStore.rootURL.appendingPathComponent(
            "layout-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("layout".utf8).write(
            to: folder.appendingPathComponent("camera.mov")
        )
        var project = StudioProject(
            id: UUID(),
            name: "布局测试工程",
            createdAt: Date(),
            folderName: folder.lastPathComponent,
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
        project.cameraFile = "camera.mov"
        project.camera.enabled = true
        let model = StudioModel()
        model.draft = project
        return (model, folder)
    }

    /// 把 EditorView 装进给定尺寸的窗口并强制布局，返回右栏滚动区与中间预览的实测 frame。
    private func measure(
        model: StudioModel,
        windowSize: NSSize,
        tab: EditorTab,
        expandedSections: Set<InspectorSection>
    ) throws -> Measurement {
        let view = EditorView(
            model: model,
            tab: tab,
            expandedSections: expandedSections
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: windowSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

        var result = Measurement()
        func maxContentHeight(from view: NSView) -> CGFloat {
            var height = view is NSScroller ? 0 : view.frame.height
            for sub in view.subviews {
                height = max(height, maxContentHeight(from: sub))
            }
            return height
        }
        func walk(_ view: NSView) {
            let name = String(describing: type(of: view))
            if name == "AVPlayerView" {
                result.previewFrame = view.frame
            }
            if let scroll = view as? NSScrollView,
               abs(scroll.frame.width - 338) < 1
            {
                result.inspectorScrollFrame = scroll.frame
                // SwiftUI 的 HostingScrollView 自管剪裁视图：文档高度取滚动区
                // 子树内最高视图（即 SwiftUI 内容视图，排除滚动条）。
                result.inspectorDocumentHeight = maxContentHeight(from: scroll)
            }
            for sub in view.subviews {
                walk(sub)
            }
        }
        walk(host)
        return result
    }

    func testEditorInspectorScrollsWithinColumnWhenFullyExpanded() throws {
        let (model, folder) = try makeModel()
        defer { try? FileManager.default.removeItem(at: folder) }
        for size in [NSSize(width: 1220, height: 800), NSSize(width: 1060, height: 700)] {
            let measured = try measure(
                model: model,
                windowSize: size,
                tab: .camera,
                expandedSections: Self.allCameraSections
            )
            // 右栏滚动区被约束在栏内：不超出窗口底部。
            XCTAssertLessThanOrEqual(
                measured.inspectorScrollFrame.maxY,
                size.height + 1,
                "右栏滚动区溢出窗口（\(Int(size.width))×\(Int(size.height))）"
            )
            // 内容高于可视区 → 滚动只发生在栏内。
            XCTAssertGreaterThan(
                measured.inspectorDocumentHeight,
                measured.inspectorScrollFrame.height,
                "右栏内容未被栏内滚动兜底（\(Int(size.width))×\(Int(size.height))）"
            )
        }
    }

    func testEditorPreviewFrameUnchangedWhenInspectorContentGrows() throws {
        let (model, folder) = try makeModel()
        defer { try? FileManager.default.removeItem(at: folder) }
        let size = NSSize(width: 1220, height: 800)
        let collapsed = try measure(
            model: model,
            windowSize: size,
            tab: .camera,
            expandedSections: [.cameraComposition]
        )
        let expanded = try measure(
            model: model,
            windowSize: size,
            tab: .camera,
            expandedSections: Self.allCameraSections
        )
        XCTAssertEqual(collapsed.previewFrame, expanded.previewFrame)
    }

    func testEditorPreviewKeepsMinimumHeightWhenWindowIsShort() throws {
        let (model, folder) = try makeModel()
        defer { try? FileManager.default.removeItem(at: folder) }
        let measured = try measure(
            model: model,
            windowSize: NSSize(width: 1220, height: 450),
            tab: .camera,
            expandedSections: [.cameraComposition, .cameraChromaKey]
        )
        XCTAssertGreaterThanOrEqual(
            measured.previewFrame.height,
            160,
            "矮窗口下中间预览被挤没了"
        )
    }
}
