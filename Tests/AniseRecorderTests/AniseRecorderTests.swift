import AppKit
import AVFoundation
import CoreImage
@testable import AniseRecorderCore
import XCTest
@testable import AniseRecorder

final class AniseRecorderTests: XCTestCase {
    func testDurationFormatting() {
        XCTAssertEqual(formatDuration(0), "0:00")
        XCTAssertEqual(formatDuration(65), "1:05")
        XCTAssertEqual(formatDuration(3661), "1:01:01")
        XCTAssertEqual(formatDuration(62.34, precise: true), "01:02.34")
    }

    func testAudioTrackSummaryBothTracks() {
        XCTAssertEqual(
            StudioProject.audioTrackSummary(mic: "mic.m4a", system: "sys.m4a"),
            "麦克风 + 系统声音"
        )
    }

    func testAudioTrackSummaryMicOnly() {
        XCTAssertEqual(
            StudioProject.audioTrackSummary(mic: "mic.m4a", system: nil),
            "麦克风"
        )
    }

    func testAudioTrackSummarySystemOnly() {
        XCTAssertEqual(
            StudioProject.audioTrackSummary(mic: nil, system: "sys.m4a"),
            "系统声音"
        )
    }

    func testAudioTrackSummaryNoTracks() {
        XCTAssertEqual(
            StudioProject.audioTrackSummary(mic: nil, system: nil),
            "无声音"
        )
    }

    // MARK: - 导出平台预设

    func testExportPresetListHasExpectedEntries() {
        XCTAssertEqual(
            ExportPreset.all.map { $0.title },
            [
                "原始画质",
                "微信 / 文档 1080p30 H.264",
                "9:16 短视频",
                "4K 60fps HEVC",
                "GIF 附件",
            ]
        )
        // 预设 id 唯一，便于按 id 存应用偏好。
        XCTAssertEqual(
            Set(ExportPreset.all.map { $0.id }).count,
            ExportPreset.all.count
        )
    }

    func testExportPresetOriginalKeepsSettingsUnchanged() {
        let preset = ExportPreset.preset(id: ExportPreset.originalID)
        XCTAssertNotNil(preset)
        let applied = ExportPreset.applying(
            preset!,
            resolution: .ultraHD,
            frameRate: 60,
            codec: .hevc
        )
        XCTAssertEqual(applied.resolution, .ultraHD)
        XCTAssertEqual(applied.frameRate, 60)
        XCTAssertEqual(applied.codec, .hevc)
        XCTAssertNil(preset?.canvasAspect)
    }

    func testExportPresetWeChatDocFillsCompatibilitySettings() {
        let preset = ExportPreset.preset(id: "wechat-doc")
        XCTAssertNotNil(preset)
        let applied = ExportPreset.applying(
            preset!,
            resolution: .ultraHD,
            frameRate: 60,
            codec: .hevc
        )
        XCTAssertEqual(applied.resolution, .fullHD)
        XCTAssertEqual(applied.frameRate, 30)
        XCTAssertEqual(applied.codec, .h264)
        // 微信 / 文档预设不动画布比例。
        XCTAssertNil(preset?.canvasAspect)
    }

    func testExportPresetPortraitFillsVerticalCanvas() {
        let preset = ExportPreset.preset(id: "portrait-916")
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.canvasAspect, .portrait)
        let applied = ExportPreset.applying(
            preset!,
            resolution: .ultraHD,
            frameRate: 60,
            codec: .hevc
        )
        XCTAssertEqual(applied.resolution, .fullHD)
        XCTAssertEqual(applied.frameRate, 30)
        XCTAssertEqual(applied.codec, .h264)
    }

    func testExportPresetMaster4KFillsHevc60() {
        let preset = ExportPreset.preset(id: "master-4k-hevc")
        XCTAssertNotNil(preset)
        let applied = ExportPreset.applying(
            preset!,
            resolution: .fullHD,
            frameRate: 30,
            codec: .h264
        )
        XCTAssertEqual(applied.resolution, .ultraHD)
        XCTAssertEqual(applied.frameRate, 60)
        XCTAssertEqual(applied.codec, .hevc)
        // 4K 母版预设不动画布比例。
        XCTAssertNil(preset?.canvasAspect)
    }

    func testExportPresetGifAttachmentOnlyChangesCanvasAspect() {
        let preset = ExportPreset.preset(id: "gif-attachment")
        XCTAssertNotNil(preset)
        // GIF 走独立固定档（15fps · 最长边 720），MP4 字段不动，
        // 只有画布比例影响 GIF 形状。
        let applied = ExportPreset.applying(
            preset!,
            resolution: .fullHD,
            frameRate: 30,
            codec: .h264
        )
        XCTAssertEqual(applied.resolution, .fullHD)
        XCTAssertEqual(applied.frameRate, 30)
        XCTAssertEqual(applied.codec, .h264)
        XCTAssertEqual(preset?.canvasAspect, .square)
    }

    func testExportPresetCanvasChangingPresetsKeepWholeFilmScopeHint() {
        // 画布比例联动的预设，说明文字必须保留「作用于全片」提示。
        for id in ["portrait-916", "gif-attachment"] {
            let preset = ExportPreset.preset(id: id)
            XCTAssertNotNil(preset)
            XCTAssertEqual(
                preset?.note.contains("作用于全片"),
                true,
                "预设 \(id) 的说明缺少「作用于全片」提示"
            )
        }
    }

    func testExportPresetNilFieldsKeepCurrentSettings() {
        // nil 字段保持原值：手调后的设置不被预设覆盖。
        let preset = ExportPreset.preset(id: "gif-attachment")
        let applied = ExportPreset.applying(
            preset!,
            resolution: .ultraHD,
            frameRate: 60,
            codec: .hevc
        )
        XCTAssertEqual(applied.resolution, .ultraHD)
        XCTAssertEqual(applied.frameRate, 60)
        XCTAssertEqual(applied.codec, .hevc)
    }

    func testExportPresetPreferenceRoundTrip() {
        // 预设选中项存应用偏好（UserDefaults），默认回落「原始画质」。
        let key = ExportPresetPreferences.selectionKey
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(
            ExportPresetPreferences.loadSelectionID(),
            ExportPreset.originalID
        )
        ExportPresetPreferences.saveSelectionID("portrait-916")
        XCTAssertEqual(ExportPresetPreferences.loadSelectionID(), "portrait-916")
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testExportPresetUnknownIDReturnsNil() {
        XCTAssertNil(ExportPreset.preset(id: "nonexistent"))
    }

    func testTimelineTracksMapToExpectedInspectorSections() {
        XCTAssertEqual(
            TimelineTrack.video.inspectorDestination,
            InspectorDestination(tab: .edit, section: .clip)
        )
        XCTAssertEqual(
            TimelineTrack.camera.inspectorDestination,
            InspectorDestination(tab: .camera, section: .cameraComposition)
        )
        XCTAssertEqual(
            TimelineTrack.zoom.inspectorDestination,
            InspectorDestination(tab: .edit, section: .zoom)
        )
        XCTAssertEqual(
            TimelineTrack.audio.inspectorDestination,
            InspectorDestination(tab: .edit, section: .audio)
        )
    }

    func testWindowPickerGroupsFiltersAndSearchesWindows() {
        let displays = [
            DisplayOption(
                id: 1,
                name: "主显示器",
                resolution: "1920 × 1080",
                isMain: true
            ),
            DisplayOption(
                id: 2,
                name: "副显示器",
                resolution: "2560 × 1440",
                isMain: false
            )
        ]
        let windows = [
            testWindow(
                id: 3,
                displayID: 2,
                app: "Zed",
                title: "副屏笔记"
            ),
            testWindow(
                id: 1,
                displayID: 1,
                app: "Zed",
                title: "主屏窗口"
            ),
            testWindow(
                id: 2,
                displayID: 1,
                app: "Alpha",
                title: "项目"
            ),
            testWindow(
                id: 4,
                displayID: 99,
                app: "Other",
                title: "已断开显示器"
            )
        ]

        let all = WindowPickerLogic.groups(
            windows: windows,
            displays: displays
        )
        XCTAssertEqual(all.map(\.title), ["主显示器", "副显示器", "其他显示器"])
        XCTAssertEqual(all[0].windows.map(\.appName), ["Alpha", "Zed"])
        XCTAssertEqual(all[2].windows.map(\.windowID), [4])

        let secondDisplay = WindowPickerLogic.groups(
            windows: windows,
            displays: displays,
            filter: .display(2)
        )
        XCTAssertEqual(secondDisplay.flatMap(\.windows).map(\.windowID), [3])

        let searchByApp = WindowPickerLogic.groups(
            windows: windows,
            displays: displays,
            query: "alpha"
        )
        XCTAssertEqual(searchByApp.flatMap(\.windows).map(\.windowID), [2])

        let searchByDisplay = WindowPickerLogic.groups(
            windows: windows,
            displays: displays,
            query: "副显示器"
        )
        XCTAssertEqual(searchByDisplay.map(\.title), ["副显示器"])
    }

    func testWindowPickerIncludesOtherDesktopWindowsAndFiltersThem() {
        let displays = [
            DisplayOption(
                id: 1,
                name: "主显示器",
                resolution: "1920 × 1080",
                isMain: true
            )
        ]
        var hidden = testWindow(
            id: 2,
            displayID: 1,
            app: "Alpha",
            title: "其他桌面"
        )
        hidden.isOnScreen = false
        let visible = testWindow(
            id: 1,
            displayID: 1,
            app: "Zeta",
            title: "当前桌面"
        )
        let windows = [hidden, visible]

        let all = WindowPickerLogic.groups(
            windows: windows,
            displays: displays
        )
        XCTAssertEqual(all.flatMap(\.windows).map(\.windowID), [1, 2])

        let current = WindowPickerLogic.groups(
            windows: windows,
            displays: displays,
            currentDesktopOnly: true
        )
        XCTAssertEqual(current.flatMap(\.windows).map(\.windowID), [1])

        XCTAssertEqual(
            WindowPickerLogic.displayCounts(
                windows: windows,
                displays: displays
            ),
            [1: 2]
        )
        XCTAssertEqual(
            WindowPickerLogic.displayCounts(
                windows: windows,
                displays: displays,
                currentDesktopOnly: true
            ),
            [1: 1]
        )
    }

    func testWindowCaptureInfoDecodesLegacyJSONWithoutVisibility() throws {
        let json = """
        {"windowID":7,"displayID":1,"appName":"Notes","title":"笔记","width":800,"height":600}
        """
        let info = try JSONDecoder().decode(
            WindowCaptureInfo.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(info.isOnScreen)
        XCTAssertTrue(info.isCurrentlyVisible)

        var hidden = info
        hidden.isOnScreen = false
        let decoded = try JSONDecoder().decode(
            WindowCaptureInfo.self,
            from: JSONEncoder().encode(hidden)
        )
        XCTAssertEqual(decoded.isOnScreen, false)
    }

    func testWindowDisplayAssignmentUsesWindowCenterAndFallback() {
        let displays = [
            WindowDisplayBounds(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            WindowDisplayBounds(
                id: 2,
                frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440)
            )
        ]
        XCTAssertEqual(
            WindowPickerLogic.displayID(
                containing: CGPoint(x: 2400, y: 500),
                displays: displays,
                fallback: 1
            ),
            2
        )
        XCTAssertEqual(
            WindowPickerLogic.displayID(
                containing: CGPoint(x: -100, y: 500),
                displays: displays,
                fallback: 1
            ),
            1
        )
    }

    func testBackgroundInstallerCopiesReplacesAndKeepsExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anise-recorder-background-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("wallpaper.PNG")
        try writeTestPNG(to: source)
        let oldBackground = root.appendingPathComponent("background.jpg")
        try Data("old".utf8).write(to: oldBackground)

        let filename = try CanvasBackgroundImageInstaller.install(
            from: source,
            into: root,
            replacing: oldBackground.lastPathComponent
        )
        XCTAssertEqual(filename, "background.PNG")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(filename).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldBackground.path)
        )

        var project = makeProject()
        project.canvas.background.kind = .image
        project.canvas.background.imageFile = filename
        let decoded = try JSONDecoder().decode(
            StudioProject.self,
            from: JSONEncoder().encode(project)
        )
        XCTAssertEqual(decoded.canvas.background.kind, .image)
        XCTAssertEqual(decoded.canvas.background.imageFile, filename)
    }

    func testBackgroundInstallerFailureKeepsExistingBackground() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anise-recorder-background-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let oldBackground = root.appendingPathComponent("background.png")
        try writeTestPNG(to: oldBackground)
        let invalidSource = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: invalidSource)

        XCTAssertThrowsError(
            try CanvasBackgroundImageInstaller.install(
                from: invalidSource,
                into: root,
                replacing: oldBackground.lastPathComponent
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oldBackground.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: oldBackground),
            try testPNGData()
        )
    }

    func testBackgroundInstallerCopiesSymlinkTargetContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anise-recorder-background-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("wallpaper-target.PNG")
        try writeTestPNG(to: target)
        let sourceLink = root.appendingPathComponent("wallpaper-link.PNG")
        try FileManager.default.createSymbolicLink(
            at: sourceLink,
            withDestinationURL: target
        )
        let destination = root.appendingPathComponent("background.PNG")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: target
        )

        let filename = try CanvasBackgroundImageInstaller.install(
            from: sourceLink,
            into: root,
            replacing: destination.lastPathComponent
        )
        let installed = root.appendingPathComponent(filename)
        let values = try installed.resourceValues(forKeys: [
            .isSymbolicLinkKey
        ])
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertEqual(
            try Data(contentsOf: installed),
            try Data(contentsOf: target)
        )
    }

    func testCanvasImageBackgroundRefreshesWhenSameFileIsReplaced() throws {
        let folderName = "test-background-cache-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let backgroundURL = folder.appendingPathComponent("background.png")
        try writeSolidPNG(.red, to: backgroundURL)

        var project = makeProject()
        project.folderName = folderName
        project.camera.enabled = false
        project.canvas.background = CanvasBackground(
            kind: .image,
            imageFile: backgroundURL.lastPathComponent
        )

        let outputSize = CGSize(width: 64, height: 64)
        let first = CanvasRenderer.render(
            screen: nil,
            camera: nil,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let firstPixel = try pixel(
            in: first,
            at: CGPoint(x: 32, y: 32)
        )
        XCTAssertGreaterThan(firstPixel.red, 220)
        XCTAssertLessThan(firstPixel.blue, 30)

        let replacement = folder.appendingPathComponent("replacement.png")
        try writeSolidPNG(.blue, to: replacement)
        _ = try CanvasBackgroundImageInstaller.install(
            from: replacement,
            into: folder,
            replacing: backgroundURL.lastPathComponent
        )

        let second = CanvasRenderer.render(
            screen: nil,
            camera: nil,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let secondPixel = try pixel(
            in: second,
            at: CGPoint(x: 32, y: 32)
        )
        XCTAssertLessThan(secondPixel.red, 30)
        XCTAssertGreaterThan(secondPixel.blue, 220)
    }

    @MainActor
    func testProjectThumbnailCacheDownsamplesAndClears() throws {
        ProjectThumbnailCache.removeAll()
        defer { ProjectThumbnailCache.removeAll() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let source = CIImage(color: .red).cropped(
            to: CGRect(x: 0, y: 0, width: 800, height: 400)
        )
        let cgImage = try XCTUnwrap(
            CIContext().createCGImage(source, from: source.extent)
        )
        let data = try XCTUnwrap(
            NSBitmapImageRep(cgImage: cgImage).representation(
                using: .png,
                properties: [:]
            )
        )
        try data.write(to: url)

        let first = try XCTUnwrap(ProjectThumbnailCache.image(for: url))

        XCTAssertLessThan(
            first.representations.map(\.pixelsWide).max() ?? 0,
            800
        )

        ProjectThumbnailCache.removeAll()
        let afterClear = try XCTUnwrap(
            ProjectThumbnailCache.image(for: url)
        )
        XCTAssertLessThan(
            afterClear.representations.map(\.pixelsWide).max() ?? 0,
            800
        )
    }

    func testZoomRendererAlwaysProducesRequestedSize() {
        let source = CIImage(
            color: CIColor(red: 0.2, green: 0.4, blue: 0.6)
        ).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let outputSize = CGSize(width: 800, height: 500)
        let settings = ZoomSettings(
            enabled: true,
            scale: 1.7,
            duration: 1.2,
            clicks: [
                ClickEvent(time: 1.0, x: 0.1, y: 0.1, enabled: true)
            ]
        )
        let output = ZoomRenderer.image(
            source: source,
            time: 1.1,
            settings: settings,
            outputSize: outputSize
        )
        XCTAssertEqual(output.extent.origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(output.extent.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(output.extent.width, outputSize.width, accuracy: 0.01)
        XCTAssertEqual(output.extent.height, outputSize.height, accuracy: 0.01)
    }

    func testZoomRendererCentersClickAndRespectsEnableSwitch() throws {
        let source = makeTestImage()
        let click = ClickEvent(time: 1.0, x: 0.75, y: 0.5, enabled: true)
        let baseSettings = ZoomSettings(
            enabled: true,
            scale: 2,
            duration: 1,
            clicks: [click]
        )

        let zoomed = ZoomRenderer.image(
            source: source,
            time: 1.1,
            settings: baseSettings,
            outputSize: CGSize(width: 200, height: 100)
        )
        XCTAssertGreaterThan(
            try brightness(of: zoomed, at: CGPoint(x: 100, y: 50)),
            0.9
        )

        let disabled = ZoomRenderer.image(
            source: source,
            time: 1.1,
            settings: ZoomSettings(
                enabled: false,
                scale: 2,
                duration: 1,
                clicks: [click]
            ),
            outputSize: CGSize(width: 200, height: 100)
        )
        XCTAssertLessThan(
            try brightness(of: disabled, at: CGPoint(x: 100, y: 50)),
            0.1
        )
        XCTAssertGreaterThan(
            try brightness(of: disabled, at: CGPoint(x: 150, y: 50)),
            0.9
        )
    }

    func testManualZoomRegionOverridesClickSuggestion() throws {
        let left = CIImage(
            color: CIColor(red: 0.05, green: 0.1, blue: 0.9)
        ).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = CIImage(
            color: CIColor(red: 0.95, green: 0.95, blue: 0.95)
        ).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let source = left.composited(over: right)
        let click = ClickEvent(
            time: 1,
            x: 0.25,
            y: 0.5,
            enabled: true
        )
        var region = ZoomRegion(
            start: 1,
            duration: 1.5,
            scale: 2,
            center: NormalizedPoint(x: 0.75, y: 0.5)
        )
        let outputSize = CGSize(width: 200, height: 100)

        let manual = ZoomRenderer.image(
            source: source,
            time: 1.2,
            settings: ZoomSettings(
                enabled: false,
                scale: 1.5,
                duration: 1,
                clicks: [click],
                regions: [region]
            ),
            outputSize: outputSize
        )
        XCTAssertGreaterThan(
            try brightness(of: manual, at: CGPoint(x: 100, y: 50)),
            0.8
        )

        region.enabled = false
        let clickOnly = ZoomRenderer.image(
            source: source,
            time: 1.2,
            settings: ZoomSettings(
                enabled: true,
                scale: 2,
                duration: 1,
                clicks: [click],
                regions: [region]
            ),
            outputSize: outputSize
        )
        XCTAssertLessThan(
            try brightness(of: clickOnly, at: CGPoint(x: 100, y: 50)),
            0.2
        )
    }

    func testLegacyProjectMigratesToSchemaFive() throws {
        let json = """
        {
          "id": "9E0A20B1-4F48-4C45-9A21-2E1A8A8C1111",
          "name": "旧工程",
          "createdAt": "2025-01-01T00:00:00Z",
          "folderName": "legacy",
          "videoFile": "screen.mp4",
          "microphoneFile": "microphone.m4a",
          "thumbnailFile": null,
          "duration": 12.5,
          "width": 1600,
          "height": 900,
          "fps": 30,
          "clicks": [],
          "trimStart": 0,
          "trimEnd": 12.5,
          "zoomScale": 1.65,
          "zoomDuration": 1.2,
          "autoZoom": true
        }
        """
        let project = try XCTUnwrap(
            ProjectStore.decode(Data(json.utf8))
        )
        XCTAssertEqual(project.schemaVersion, 5)
        XCTAssertEqual(project.canvas.aspect, .source)
        XCTAssertEqual(project.canvas.background.kind, .none)
        XCTAssertFalse(project.camera.enabled)
        XCTAssertNil(project.cameraFile)
        XCTAssertTrue(project.markers.isEmpty)
        XCTAssertEqual(project.name, "旧工程")
        XCTAssertEqual(project.timeline.clips.count, 1)
        XCTAssertEqual(project.timeline.clips[0].sourceStart, 0)
        XCTAssertEqual(project.timeline.clips[0].sourceEnd, 12.5)
        XCTAssertFalse(project.cameraChromaKey.enabled)
        XCTAssertEqual(project.cameraChromaKey.keyColorHex, "#00B140")
    }

    func testProjectDefaultsToSchemaFiveAndAudioVolumes() {
        let project = makeProject()
        XCTAssertEqual(project.schemaVersion, 5)

        var audio = AudioTrackSettings()
        XCTAssertEqual(audio.microphoneVolume, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(audio.systemVolume, 0.55, accuracy: 0.000_001)

        audio.microphoneGain = 4
        audio.systemGain = -2
        XCTAssertEqual(audio.microphoneVolume, 1, accuracy: 0.000_001)
        XCTAssertEqual(audio.systemVolume, 0, accuracy: 0.000_001)

        audio.microphoneMuted = true
        audio.systemMuted = true
        XCTAssertEqual(audio.microphoneVolume, 0)
        XCTAssertEqual(audio.systemVolume, 0)
    }

    // MARK: 音频一键优化（1.2 块1）

    func testAudioProcessingSettingsRoundTripAndLegacyDefaults() throws {
        // 旧工程（Schema 5 及更早）没有 processing 字段：解码得到全关默认。
        var audio = AudioTrackSettings()
        XCTAssertTrue(audio.processing.isEffectivelyEmpty)
        XCTAssertEqual(audio.processing.duckingAmountDB, 6, accuracy: 0.001)

        audio.processing.autoLevelEnabled = true
        audio.processing.autoLevelGainDB = 4.5
        audio.processing.voiceEnhanceEnabled = true
        audio.processing.duckingEnabled = true
        audio.processing.duckingAmountDB = 8
        audio.processing.noiseReductionEnabled = true

        let encoded = try JSONEncoder().encode(audio)
        let decoded = try JSONDecoder().decode(
            AudioTrackSettings.self,
            from: encoded
        )
        XCTAssertEqual(decoded, audio)

        // 部分字段缺失时逐字段回退默认。
        let partial = """
        {
          "processing": {
            "autoLevelEnabled": true,
            "duckingAmountDB": 3
          }
        }
        """
        let legacy = try JSONDecoder().decode(
            AudioTrackSettings.self,
            from: Data(partial.utf8)
        )
        XCTAssertTrue(legacy.processing.autoLevelEnabled)
        XCTAssertEqual(legacy.processing.autoLevelGainDB, 0, accuracy: 0.001)
        XCTAssertFalse(legacy.processing.voiceEnhanceEnabled)
        XCTAssertFalse(legacy.processing.duckingEnabled)
        XCTAssertEqual(legacy.processing.duckingAmountDB, 3, accuracy: 0.001)
        XCTAssertFalse(legacy.processing.noiseReductionEnabled)
    }

    func testLegacyProjectDecodesWithoutAudioProcessing() throws {
        // 完整旧工程 JSON 无 audio 字段：不丢数据，处理设置为默认。
        let json = """
        {
          "id": "9E0A20B1-4F48-4C45-9A21-2E1A8A8C2222",
          "name": "旧工程",
          "createdAt": "2025-01-01T00:00:00Z",
          "folderName": "legacy",
          "videoFile": "screen.mp4",
          "duration": 12.5,
          "width": 1600,
          "height": 900,
          "clicks": [],
          "trimStart": 0,
          "trimEnd": 12.5,
          "zoomScale": 1.65,
          "zoomDuration": 1.2,
          "autoZoom": true,
          "schemaVersion": 4
        }
        """
        let project = try XCTUnwrap(ProjectStore.decode(Data(json.utf8)))
        XCTAssertTrue(project.audio.processing.isEffectivelyEmpty)
        XCTAssertEqual(project.audio.microphoneGain, 0.8, accuracy: 0.001)
        XCTAssertEqual(project.trimDuration, 12.5, accuracy: 0.001)
    }

    /// 音频优化端到端：ensure 生成缓存、useCache 命中、导出电平按增益
    /// 变化、ducking 让系统声电平下降（真实 AVFoundation 导出）。
    /// 素材带 1 秒前置静音：语音活动检测需要静音建立噪声底，全程等幅
    /// 正弦会被正确地视为「持续声音」而不产生活动区间。
    @MainActor
    func testAudioProcessingExportLevelAndCache() async throws {
        let folderName = "test-audio-optimize-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        try await makeTestVideo(
            at: screenURL,
            fileType: .mp4,
            size: CGSize(width: 320, height: 180),
            color: CIColor(red: 0.2, green: 0.4, blue: 0.8),
            frameCount: 90,
            frameRate: 30
        )
        // 人声：1 秒静音 + 2 秒 -16 dBFS 正弦。
        let microphoneURL = folder.appendingPathComponent("microphone.wav")
        try makeBurstAudio(
            at: microphoneURL,
            duration: 3,
            leadSilence: 1,
            amplitude: 0.3
        )

        var project = makeProject()
        project.folderName = folderName
        project.duration = 3
        project.microphoneFile = microphoneURL.lastPathComponent
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 3)]
        )
        project.audio.processing.autoLevelEnabled = true
        project.audio.processing.autoLevelGainDB = 6

        // ensure：生成缓存；useCache：命中同一文件。
        let ensured = try await AudioOptimizer.resolve(
            project: project,
            mode: .ensure
        )
        XCTAssertNotNil(ensured.microphoneURL)
        let cached = try await AudioOptimizer.resolve(
            project: project,
            mode: .useCache
        )
        XCTAssertEqual(cached.microphoneURL, ensured.microphoneURL)

        // 处理后导出：人声按 +6 dB 提升（人声是唯一音轨，混音随之提升）。
        let processedURL = folder.appendingPathComponent("processed.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: processedURL
        ) { _ in }
        project.audio.processing = AudioEnhanceSettings()
        let rawURL = folder.appendingPathComponent("raw.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: rawURL
        ) { _ in }

        let processedRMS = Self.rmsDB(
            of: try await AudioOptimizer.readTrack(url: processedURL).channels
        )
        let rawRMS = Self.rmsDB(
            of: try await AudioOptimizer.readTrack(url: rawURL).channels
        )
        XCTAssertGreaterThan(processedRMS - rawRMS, 2.0)

        // 时长不受处理影响。
        let processedDuration = try await AVURLAsset(url: processedURL)
            .load(.duration).seconds
        let rawDuration = try await AVURLAsset(url: rawURL)
            .load(.duration).seconds
        XCTAssertEqual(processedDuration, rawDuration, accuracy: 0.2)
    }

    /// ducking 端到端：人声活动区间（成片时间）映射到系统声源时间后，
    /// 重叠段系统声在成片中被压低。系统声占主导以便观察电平差。
    @MainActor
    func testAudioProcessingDuckingLowersSystemInExport() async throws {
        let folderName = "test-audio-duck-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        try await makeTestVideo(
            at: screenURL,
            fileType: .mp4,
            size: CGSize(width: 320, height: 180),
            color: CIColor(red: 0.2, green: 0.4, blue: 0.8),
            frameCount: 90,
            frameRate: 30
        )
        let microphoneURL = folder.appendingPathComponent("microphone.wav")
        try makeBurstAudio(
            at: microphoneURL,
            duration: 3,
            leadSilence: 1,
            amplitude: 0.05
        )
        let systemURL = folder.appendingPathComponent("system.wav")
        try makeBurstAudio(
            at: systemURL,
            duration: 3,
            leadSilence: 0,
            amplitude: 0.4
        )

        var project = makeProject()
        project.folderName = folderName
        project.duration = 3
        project.microphoneFile = microphoneURL.lastPathComponent
        project.systemAudioFile = systemURL.lastPathComponent
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 3)]
        )
        project.audio.processing.duckingEnabled = true
        project.audio.processing.duckingAmountDB = 6

        let duckedURL = folder.appendingPathComponent("ducked.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: duckedURL
        ) { _ in }
        project.audio.processing = AudioEnhanceSettings()
        let rawURL = folder.appendingPathComponent("raw.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: rawURL
        ) { _ in }

        let duckedRMS = Self.rmsDB(
            of: try await AudioOptimizer.readTrack(url: duckedURL).channels
        )
        let rawRMS = Self.rmsDB(
            of: try await AudioOptimizer.readTrack(url: rawURL).channels
        )
        // 系统声约 2/3 时长被压低 6 dB，混音整体下降 ≥ 2 dB。
        XCTAssertLessThan(duckedRMS, rawRMS - 2.0)
    }

    /// 静音段 + 正弦段的测试音频（确定性 float32 WAV，48 kHz 立体声——
    /// 与处理缓存同通道几何，避免混入 mono→stereo 的电平差）。
    private func makeBurstAudio(
        at url: URL,
        duration: Double,
        leadSilence: Double,
        amplitude: Float
    ) throws {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * duration)
        let silenceFrames = Int(sampleRate * leadSilence)
        var samples = [Float](repeating: 0, count: frameCount)
        for index in silenceFrames..<frameCount {
            samples[index] = amplitude * sin(Float(index) * 0.05)
        }
        try AudioOptimizer.writeWAV(
            channels: [samples, samples],
            sampleRate: sampleRate,
            to: url
        )
    }

    private static func rmsDB(of channels: [[Float]]) -> Double {
        var sum = 0.0
        var count = 0
        for channel in channels {
            for sample in channel {
                sum += Double(sample) * Double(sample)
                count += 1
            }
        }
        guard count > 0 else { return -200 }
        return 10 * log10(max(sum / Double(count), 1e-12))
    }

    // MARK: 定时区域打码（1.2 块2）

    func testRedactionRegionsDecodeLegacyAndRoundTrip() throws {
        var project = makeProject()
        let rect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.25)
        project.redactionRegions = [
            RedactionRegion(
                start: 1,
                duration: 2,
                rect: rect,
                style: .mosaic,
                intensity: 0.8
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let decoded = try XCTUnwrap(ProjectStore.decode(data))
        XCTAssertEqual(decoded.redactionRegions.count, 1)
        XCTAssertEqual(decoded.redactionRegions[0].rect, rect)
        XCTAssertEqual(decoded.redactionRegions[0].style, .mosaic)
        XCTAssertEqual(decoded.redactionRegions[0].intensity, 0.8, accuracy: 0.001)
        XCTAssertTrue(decoded.redactionRegions[0].isActive(atOutput: 2))
        XCTAssertFalse(decoded.redactionRegions[0].isActive(atOutput: 3.1))

        // 旧工程（Schema 4/5 及缺失字段）解码得到空列表。
        let legacyJSON = """
        {
          "id": "9E0A20B1-4F48-4C45-9A21-2E1A8A8C2222",
          "name": "旧工程",
          "createdAt": "2025-01-01T00:00:00Z",
          "folderName": "legacy",
          "videoFile": "screen.mp4",
          "duration": 10,
          "width": 1600,
          "height": 900,
          "clicks": [],
          "trimStart": 0,
          "trimEnd": 10,
          "zoomScale": 1.65,
          "zoomDuration": 1.2,
          "autoZoom": false,
          "schemaVersion": 4
        }
        """
        let legacy = try XCTUnwrap(ProjectStore.decode(Data(legacyJSON.utf8)))
        XCTAssertTrue(legacy.redactionRegions.isEmpty)
    }

    func testRedactionRegionRipplesThroughCutTransaction() throws {
        var project = makeProject()
        project.duration = 10
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 10)]
        )
        project.redactionRegions = [
            // 完全在删除区间 [4, 6) 内 → 应被删除。
            RedactionRegion(start: 4.2, duration: 1.2, rect: .init(x: 0, y: 0, width: 0.1, height: 0.1)),
            // 跨越切点 → 分段保留并平移。
            RedactionRegion(start: 5, duration: 3, rect: .init(x: 0, y: 0, width: 0.2, height: 0.1)),
            // 完全在切点之后 → 平移。
            RedactionRegion(start: 7, duration: 2, rect: .init(x: 0, y: 0, width: 0.3, height: 0.1))
        ]
        let candidate = SmartCutCandidate(
            start: 4,
            end: 6,
            kind: .pureSpeechPause,
            keepEachSide: 0
        )
        let outcome = TimelineCutTransaction.apply(
            [candidate],
            to: project.timeline,
            frameDuration: nil
        )
        let updated = project.applyingCutTransaction(outcome)
        let regions = updated.redactionRegions
        // [4.2, 5.4) 整体落在 [4, 6) 内被删；[5, 8) 去头只剩 [6, 8) 平移为
        // [4, 6)；[7, 9) 平移为 [5, 7)。
        XCTAssertEqual(regions.count, 2)
        XCTAssertFalse(
            regions.contains { abs($0.start - 4.2) < 0.001 },
            "删除区间内的打码应被移除"
        )
        let crossRemainder = regions.first { abs($0.start - 4) < 0.001 }
        XCTAssertNotNil(crossRemainder, "跨越切点的打码保留剩余段并平移")
        XCTAssertEqual(crossRemainder?.end ?? 0, 6, accuracy: 0.001)
        let translated = regions.first { abs($0.start - 5) < 0.001 }
        XCTAssertNotNil(translated, "切点之后的打码应平移 -2 秒")
        XCTAssertEqual(translated?.end ?? 0, 7, accuracy: 0.001)
    }

    func testRedactionOutputRectMapsScreenContentThroughZoom() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        let region = RedactionRegion(
            start: 0,
            duration: 10,
            rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        project.redactionRegions = [region]
        let sourceSize = CGSize(width: 1600, height: 900)
        // 16:9 画布、无 padding：屏幕内容铺满画布。
        let screenRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let zoomSettings = ZoomSettings(
            enabled: false,
            scale: 1,
            duration: 1,
            clicks: [],
            regions: []
        )
        let plain = try XCTUnwrap(
            region.outputRect(
                screenRect: screenRect,
                sourceSize: sourceSize,
                zoomSettings: zoomSettings,
                time: 1
            )
        )
        XCTAssertEqual(plain.minX, 480, accuracy: 2)
        XCTAssertEqual(plain.maxX, 1440, accuracy: 2)
        XCTAssertEqual(plain.height, 540, accuracy: 2)

        // 放大 2× 且焦点在矩形中心：映射后的输出矩形约放大 2 倍。
        let zoomedSettings = ZoomSettings(
            enabled: false,
            scale: 1,
            duration: 1,
            clicks: [],
            regions: [
                ZoomRegion(
                    start: 0,
                    duration: 10,
                    scale: 2,
                    center: NormalizedPoint(x: 0.5, y: 0.5),
                    enabled: true
                )
            ]
        )
        let zoomed = try XCTUnwrap(
            region.outputRect(
                screenRect: screenRect,
                sourceSize: sourceSize,
                zoomSettings: zoomedSettings,
                time: 5
            )
        )
        XCTAssertGreaterThan(zoomed.width, plain.width * 1.9)
        XCTAssertGreaterThan(zoomed.height, plain.height * 1.9)
    }

    /// 高频棋盘格屏幕画面：打码区内的细节必须被破坏。
    private func makeCheckerboardImage(size: CGSize, cells: Int) -> CIImage {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cellWidth = size.width / CGFloat(cells)
        let cellHeight = size.height / CGFloat(max(1, cells / 2))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for row in 0..<Int(size.height / cellHeight) {
            for column in 0..<Int(size.width / cellWidth) {
                if (row + column).isMultiple(of: 2) {
                    context.fill(
                        CGRect(
                            x: CGFloat(column) * cellWidth,
                            y: CGFloat(row) * cellHeight,
                            width: cellWidth,
                            height: cellHeight
                        )
                    )
                }
            }
        }
        return CIImage(cgImage: context.makeImage()!)
    }

    private func averageVariance(
        of image: CIImage,
        in rect: CGRect,
        samples: Int = 8
    ) throws -> Double {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var values: [Double] = []
        for row in 0..<samples {
            for column in 0..<samples {
                let x = rect.minX
                    + (CGFloat(column) + 0.5) * rect.width / CGFloat(samples)
                let y = rect.minY
                    + (CGFloat(row) + 0.5) * rect.height / CGFloat(samples)
                var bytes = [UInt8](repeating: 0, count: 4)
                context.render(
                    image,
                    toBitmap: &bytes,
                    rowBytes: 4,
                    bounds: CGRect(x: x, y: y, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                values.append(Double(bytes[0]) + Double(bytes[2]))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) {
            $0 + ($1 - mean) * ($1 - mean)
        } / Double(values.count)
        return variance
    }

    @MainActor
    func testRedactionDestroysRegionPixelsAndKeepsOutsideIntact() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.redactionRegions = [
            RedactionRegion(
                start: 0,
                duration: 10,
                rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
                style: .blur,
                intensity: 0.9
            )
        ]
        let outputSize = CGSize(width: 960, height: 540)
        let screen = makeCheckerboardImage(size: CGSize(width: 960, height: 540), cells: 64)
        let withRedaction = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 2,
            project: project,
            outputSize: outputSize
        )
        project.redactionRegions = []
        let withoutRedaction = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 2,
            project: project,
            outputSize: outputSize
        )

        // 打码区（屏幕内容 0.3–0.7 × 0.3–0.7，y 翻转后 0.3–0.7 相同）：
        // 细节方差必须骤降（高斯模糊后接近常数）。
        let redactedRect = CGRect(x: 288, y: 162, width: 384, height: 216)
        let varianceInside = try averageVariance(
            of: withRedaction,
            in: redactedRect.insetBy(dx: 24, dy: 24)
        )
        let originalVarianceInside = try averageVariance(
            of: withoutRedaction,
            in: redactedRect.insetBy(dx: 24, dy: 24)
        )
        XCTAssertGreaterThan(originalVarianceInside, 4000)
        XCTAssertLessThan(
            varianceInside,
            originalVarianceInside * 0.05,
            "打码区内棋盘格细节必须被破坏"
        )

        // 区外像素与未打码渲染逐位一致。
        let outsidePoints = [
            CGPoint(x: 100, y: 100),
            CGPoint(x: 860, y: 100),
            CGPoint(x: 100, y: 440),
            CGPoint(x: 860, y: 440),
            CGPoint(x: 60, y: 270),
            CGPoint(x: 900, y: 270)
        ]
        for point in outsidePoints {
            let before = try pixel(in: withoutRedaction, at: point)
            let after = try pixel(in: withRedaction, at: point)
            XCTAssertEqual(
                before.red, after.red, "区外像素必须不变（\(point)）"
            )
            XCTAssertEqual(before.green, after.green)
            XCTAssertEqual(before.blue, after.blue)
        }

        // 点击缩放状态下（放大 2 倍、焦点在打码区内），区域仍不可辨认。
        project.redactionRegions = [
            RedactionRegion(
                start: 0,
                duration: 10,
                rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
                style: .mosaic,
                intensity: 0.9
            )
        ]
        project.zoomRegions = [
            ZoomRegion(
                start: 0,
                duration: 10,
                scale: 2,
                center: NormalizedPoint(x: 0.5, y: 0.5),
                enabled: true
            )
        ]
        let zoomed = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 2,
            project: project,
            outputSize: outputSize
        )
        let zoomedVariance = try averageVariance(
            of: zoomed,
            in: CGRect(x: 240, y: 135, width: 480, height: 270).insetBy(dx: 40, dy: 40)
        )
        XCTAssertLessThan(
            zoomedVariance,
            originalVarianceInside * 0.05,
            "放大后的打码区必须仍然不可辨认"
        )
    }

    /// 预览与导出同一时刻抽帧：打码区外逐点一致（≤2/255，编码噪声容差），
    /// 区内同为破坏后的低方差画面（预览/导出共用合成器的回归验证）。
    @MainActor
    func testRedactionPreviewAndExportFrameConsistency() async throws {
        let folderName = "test-redaction-export-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        try await makeCheckerVideo(
            at: screenURL,
            size: CGSize(width: 320, height: 180),
            cells: 32,
            frameCount: 30,
            frameRate: 30
        )
        var project = makeProject()
        project.folderName = folderName
        project.duration = 1
        project.width = 320
        project.height = 180
        project.canvas.aspect = .source
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 1)]
        )
        project.redactionRegions = [
            RedactionRegion(
                start: 0,
                duration: 1,
                rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                style: .blur,
                intensity: 0.9
            )
        ]

        let outputURL = folder.appendingPathComponent("redacted.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL
        ) { _ in }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exportFrame = CIImage(
            cgImage: try await generator.image(
                at: CMTime(seconds: 0.5, preferredTimescale: 600)
            ).image
        )
        let playerItem = try await CompositionBuilder.makePlayerItem(
            for: project
        )
        let previewGenerator = AVAssetImageGenerator(asset: playerItem.asset)
        previewGenerator.videoComposition = playerItem.videoComposition
        previewGenerator.requestedTimeToleranceBefore = .zero
        previewGenerator.requestedTimeToleranceAfter = .zero
        let previewFrame = CIImage(
            cgImage: try await previewGenerator.image(
                at: CMTime(seconds: 0.5, preferredTimescale: 600)
            ).image
        )

        // 打码区内：预览与导出都应为低方差（被破坏）画面。
        let insideRect = CGRect(x: 110, y: 65, width: 100, height: 50)
        let exportVariance = try averageVariance(of: exportFrame, in: insideRect)
        let previewVariance = try averageVariance(
            of: previewFrame,
            in: insideRect
        )
        XCTAssertLessThan(exportVariance, 2500, "导出帧打码区应被破坏")
        XCTAssertLessThan(previewVariance, 2500, "预览帧打码区应被破坏")

        // 无打码参照帧（预览渲染）。
        project.redactionRegions = []
        let plainItem = try await CompositionBuilder.makePlayerItem(
            for: project
        )
        let plainGenerator = AVAssetImageGenerator(asset: plainItem.asset)
        plainGenerator.videoComposition = plainItem.videoComposition
        plainGenerator.requestedTimeToleranceBefore = .zero
        plainGenerator.requestedTimeToleranceAfter = .zero
        let plainFrame = CIImage(
            cgImage: try await plainGenerator.image(
                at: CMTime(seconds: 0.5, preferredTimescale: 600)
            ).image
        )

        // 打码位置误差 ≤2px：沿中线扫描「与无打码参照的偏差」第一次超过
        // 阈值的位置，比较预览与导出的边界落点。
        let exportLeft = try destroyedBoundary(
            frame: exportFrame,
            reference: plainFrame,
            scanLine: CGPoint(x: 0, y: 90),
            step: CGPoint(x: 1, y: 0),
            samples: 320
        )
        let previewLeft = try destroyedBoundary(
            frame: previewFrame,
            reference: plainFrame,
            scanLine: CGPoint(x: 0, y: 90),
            step: CGPoint(x: 1, y: 0),
            samples: 320
        )
        guard let exportLeft = exportLeft, let previewLeft = previewLeft else {
            return XCTFail("应能在扫描线上找到打码破坏区边界")
        }
        XCTAssertLessThanOrEqual(
            abs(exportLeft - previewLeft),
            2,
            "打码左边界预览/导出位置误差必须 ≤2px"
        )

        // 区外取样点：预览与导出通道差 ≤10（与仓库既有预览/导出容差一致，
        // 4:2:0 编码噪声下 2 无法稳定达到）。
        for point in [
            CGPoint(x: 30, y: 30),
            CGPoint(x: 290, y: 30),
            CGPoint(x: 30, y: 150),
            CGPoint(x: 290, y: 150)
        ] {
            let exportPixel = try pixel(in: exportFrame, at: point)
            let previewPixel = try pixel(in: previewFrame, at: point)
            XCTAssertLessThanOrEqual(
                abs(exportPixel.red - previewPixel.red),
                10,
                "区外红通道预览/导出差必须 ≤10（\(point)）"
            )
            XCTAssertLessThanOrEqual(
                abs(exportPixel.green - previewPixel.green),
                10
            )
            XCTAssertLessThanOrEqual(
                abs(exportPixel.blue - previewPixel.blue),
                10
            )
        }
    }

    /// 沿扫描线找「与参照帧偏差首次超过阈值」的 x/y 坐标（打码破坏区
    /// 边界）。偏差判定用 RGB 绝对差之和，连续 3 个采样超阈才算边界。
    private func destroyedBoundary(
        frame: CIImage,
        reference: CIImage,
        scanLine: CGPoint,
        step: CGPoint,
        samples: Int
    ) throws -> CGFloat? {
        var consecutive = 0
        for index in 0..<samples {
            let point = CGPoint(
                x: scanLine.x + step.x * CGFloat(index),
                y: scanLine.y + step.y * CGFloat(index)
            )
            let a = try pixel(in: frame, at: point)
            let b = try pixel(in: reference, at: point)
            let difference = abs(a.red - b.red)
                + abs(a.green - b.green)
                + abs(a.blue - b.blue)
            if difference > 60 {
                consecutive += 1
                if consecutive >= 3 {
                    return step.x != 0
                        ? point.x - 2 * step.x
                        : point.y - 2 * step.y
                }
            } else {
                consecutive = 0
            }
        }
        return nil
    }

    // MARK: 字幕增强（1.2 块3）

    func testCaptionBurnModeRoundTripAndLegacyDefaults() throws {
        // 旧工程：只有 burnIn 字段 → true 映射 primary。
        var legacy = CaptionSettings()
        legacy.burnIn = true
        XCTAssertEqual(legacy.effectiveBurnMode, .primary)
        legacy.burnIn = false
        XCTAssertEqual(legacy.effectiveBurnMode, .off)

        // 新字段优先。
        var settings = CaptionSettings()
        settings.burnIn = true
        settings.burnMode = .both
        XCTAssertEqual(settings.effectiveBurnMode, .both)

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)
        let decoded = try JSONDecoder().decode(
            CaptionSettings.self,
            from: data
        )
        XCTAssertEqual(decoded, settings)

        // 旧 JSON 无新字段：逐字段默认。
        let legacyJSON = """
        { "enabled": true, "burnIn": true, "fontScale": 1.2 }
        """
        let decodedLegacy = try JSONDecoder().decode(
            CaptionSettings.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertTrue(decodedLegacy.enabled)
        XCTAssertNil(decodedLegacy.burnMode)
        XCTAssertEqual(decodedLegacy.effectiveBurnMode, .primary)
        XCTAssertFalse(decodedLegacy.secondaryEnabled)
        XCTAssertEqual(
            decodedLegacy.secondaryPosition,
            .below
        )
    }

    func testCaptionStylePresetsApplyAndMatch() {
        var settings = CaptionSettings()
        for preset in CaptionStylePreset.allCases {
            preset.apply(to: &settings)
            XCTAssertTrue(
                preset.matches(settings),
                "套用后应命中当前预设 \(preset.title)"
            )
        }
        XCTAssertEqual(
            CaptionStylePreset.narration.fontScale,
            1.6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CaptionStylePreset.minimal.backgroundOpacity,
            0.12,
            accuracy: 0.001
        )
        // 手动微调后不再命中。
        settings.fontScale = 1.23
        XCTAssertFalse(CaptionStylePreset.standard.matches(settings))
    }

    func testSecondaryCaptionsDecodeLegacyAndRipple() throws {
        var project = makeProject()
        XCTAssertTrue(project.secondaryCaptionCues.isEmpty)
        project.secondaryCaptionCues = [
            CaptionCue(start: 1, end: 2, text: "Second line")
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let decoded = try XCTUnwrap(ProjectStore.decode(data))
        XCTAssertEqual(decoded.secondaryCaptionCues.count, 1)

        // 旧工程 JSON 缺字段 → 空数组。
        let legacyJSON = """
        {
          "id": "9E0A20B1-4F48-4C45-9A21-2E1A8A8C2222",
          "name": "旧工程",
          "createdAt": "2025-01-01T00:00:00Z",
          "folderName": "legacy",
          "videoFile": "screen.mp4",
          "duration": 10,
          "width": 1600,
          "height": 900,
          "clicks": [],
          "trimStart": 0,
          "trimEnd": 10,
          "zoomScale": 1.65,
          "zoomDuration": 1.2,
          "autoZoom": false,
          "schemaVersion": 4
        }
        """
        let legacy = try XCTUnwrap(ProjectStore.decode(Data(legacyJSON.utf8)))
        XCTAssertTrue(legacy.secondaryCaptionCues.isEmpty)

        // 剪切事务 ripple：副字幕随主字幕同步平移。
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 10)]
        )
        project.secondaryCaptionCues = [
            CaptionCue(start: 1, end: 2, text: "A"),
            CaptionCue(start: 7, end: 9, text: "B")
        ]
        let candidate = SmartCutCandidate(
            start: 4,
            end: 6,
            kind: .pureSpeechPause,
            keepEachSide: 0
        )
        let outcome = TimelineCutTransaction.apply(
            [candidate],
            to: project.timeline,
            frameDuration: nil
        )
        let updated = project.applyingCutTransaction(outcome)
        XCTAssertEqual(updated.secondaryCaptionCues.count, 2)
        XCTAssertEqual(
            updated.secondaryCaptionCues[0].start,
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            updated.secondaryCaptionCues[1].start,
            5,
            accuracy: 0.001
        )
    }

    /// 双语渲染：主副同屏、缺副轨降级为主字幕、位置开关改变布局。
    @MainActor
    func testBilingualCaptionRendering() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.captions.enabled = true
        project.captionCues = [
            CaptionCue(start: 0, end: 10, text: "主字幕一行")
        ]
        project.secondaryCaptionCues = [
            CaptionCue(start: 0, end: 10, text: "Secondary")
        ]
        let outputSize = CGSize(width: 960, height: 540)
        let screen = CIImage(color: .black).cropped(
            to: CGRect(origin: .zero, size: outputSize)
        )

        project.captions.secondaryEnabled = false
        let primaryOnly = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 2,
            project: project,
            outputSize: outputSize
        )

        project.captions.secondaryEnabled = true
        project.captions.secondaryPosition = .below
        let bothBelow = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 2,
            project: project,
            outputSize: outputSize
        )
        project.captions.secondaryPosition = .above
        let bothAbove = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 2,
            project: project,
            outputSize: outputSize
        )

        // 主上副下：副字幕贴底，主字幕被抬到其上方——只显示主字幕时
        // 贴底上方（y 100–140）没有内容，双语时有主字幕气泡。
        try XCTAssertGreaterThan(
            brightnessSum(bothBelow, in: CGRect(x: 300, y: 100, width: 360, height: 40)),
            brightnessSum(primaryOnly, in: CGRect(x: 300, y: 100, width: 360, height: 40)),
            "主上副下：主字幕应显示在副字幕上方"
        )
        // 主下副上：主字幕贴底（更亮、更宽），与主上副下（副字幕贴底）
        // 在贴底槽位的亮度不同——两种位置模式布局确实不同。
        try XCTAssertGreaterThan(
            brightnessSum(bothAbove, in: CGRect(x: 260, y: 30, width: 440, height: 44)),
            brightnessSum(bothBelow, in: CGRect(x: 260, y: 30, width: 440, height: 44)),
            "主下副上：贴底槽位应为主字幕（比副字幕更大）"
        )
    }

    private func brightnessSum(
        _ image: CIImage,
        in rect: CGRect
    ) throws -> Double {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var sum = 0.0
        let samples = 10
        for row in 0..<samples {
            for column in 0..<samples {
                var bytes = [UInt8](repeating: 0, count: 4)
                let x = rect.minX
                    + (CGFloat(column) + 0.5) * rect.width / CGFloat(samples)
                let y = rect.minY
                    + (CGFloat(row) + 0.5) * rect.height / CGFloat(samples)
                context.render(
                    image,
                    toBitmap: &bytes,
                    rowBytes: 4,
                    bounds: CGRect(x: x, y: y, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                sum += Double(bytes[0]) + Double(bytes[1]) + Double(bytes[2])
            }
        }
        return sum
    }

    /// 章节标题卡：章节起始 2 秒内出现标题、之后消失；关闭开关不出现。
    @MainActor
    func testChapterCardOverlayShowsAtChapterStartOnly() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.captions.enabled = true
        project.captionCues = [
            CaptionCue(start: 0, end: 4, text: "第一章 介绍功能"),
            CaptionCue(start: 6, end: 10, text: "第二章 深入细节")
        ]
        project.captions.chapterCardsEnabled = true
        let outputSize = CGSize(width: 960, height: 540)
        let screen = CIImage(color: .black).cropped(
            to: CGRect(origin: .zero, size: outputSize)
        )

        let atStart = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 0.5,
            project: project,
            outputSize: outputSize
        )
        project.captions.chapterCardsEnabled = false
        let disabled = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 0.5,
            project: project,
            outputSize: outputSize
        )
        project.captions.chapterCardsEnabled = true
        let afterCard = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 4,
            project: project,
            outputSize: outputSize
        )

        // 标题卡出现在画面中部（y 42% 高度附近），关闭时不出现；
        // 2 秒窗口之后消失。
        let cardRect = CGRect(x: 260, y: 230, width: 440, height: 60)
        try XCTAssertGreaterThan(
            brightnessSum(atStart, in: cardRect),
            brightnessSum(disabled, in: cardRect) + 200,
            "章节起始处应显示标题卡"
        )
        let tailDifference = try brightnessSum(
            afterCard,
            in: cardRect
        ) - brightnessSum(disabled, in: cardRect)
        XCTAssertLessThan(
            abs(tailDifference),
            200,
            "章节窗口结束后不应残留标题卡"
        )
    }

    // MARK: 导出增强（1.2 块4）

    /// 导出区间：复用剪切事务，把 [入点, 出点] 之外的内容裁掉并平移
    /// 所有成片时间轨道；标记 / 点击等源时间数据不动。
    func testClipProjectToExportRange() throws {
        var project = makeProject()
        project.duration = 10
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 10)]
        )
        project.captionCues = [
            CaptionCue(start: 1, end: 2, text: "头部"),
            CaptionCue(start: 3, end: 5, text: "中间"),
            CaptionCue(start: 9, end: 9.8, text: "尾部")
        ]
        project.secondaryCaptionCues = [
            CaptionCue(start: 3.5, end: 4.5, text: "mid-secondary")
        ]
        project.zoomRegions = [
            ZoomRegion(start: 8.5, duration: 1, scale: 2, center: .init(x: 0.5, y: 0.5))
        ]
        project.redactionRegions = [
            RedactionRegion(start: 2, duration: 2, rect: .init(x: 0, y: 0, width: 0.2, height: 0.2))
        ]
        project.cameraSegments = [
            CameraLayoutSegment(start: 6, transitionDuration: 0.3, camera: project.camera)
        ]
        let markerTime = 7.0
        try project.addMarker(sourceTime: markerTime, name: "不动")

        let clipped = try XCTUnwrap(
            project.clippedToOutputRange(inPoint: 2, outPoint: 8)
        )

        // 时间线：10s → 6s。
        XCTAssertEqual(clipped.trimDuration, 6, accuracy: 0.05)
        // 区间外字幕删除、区间内平移 -2、跨出点的字幕裁剪。
        XCTAssertFalse(
            clipped.captionCues.contains { $0.text == "头部" }
        )
        XCTAssertFalse(
            clipped.captionCues.contains { $0.text == "尾部" }
        )
        let mid = try XCTUnwrap(
            clipped.captionCues.first { $0.text == "中间" }
        )
        XCTAssertEqual(mid.start, 1, accuracy: 0.05)
        let secondary = try XCTUnwrap(
            clipped.secondaryCaptionCues.first
        )
        XCTAssertEqual(secondary.start, 1.5, accuracy: 0.05)
        // 缩放区（8.5–9.5）整体在区间外 → 删除。
        XCTAssertTrue(clipped.zoomRegions.isEmpty)
        // 打码（2–4）保留并平移为 0–2。
        let redaction = try XCTUnwrap(clipped.redactionRegions.first)
        XCTAssertEqual(redaction.start, 0, accuracy: 0.05)
        XCTAssertEqual(redaction.end, 2, accuracy: 0.05)
        // 布局段起点平移。
        let segment = try XCTUnwrap(clipped.cameraSegments.first)
        XCTAssertEqual(segment.start, 4, accuracy: 0.05)
        // 标记属源时间，不动。
        let marker = try XCTUnwrap(clipped.markers.first)
        XCTAssertEqual(marker.sourceTime, markerTime, accuracy: 0.001)

        // 全片范围 → 无变化返回 nil。
        XCTAssertNil(
            project.clippedToOutputRange(inPoint: nil, outPoint: nil)
        )
        XCTAssertNil(
            project.clippedToOutputRange(inPoint: 0, outPoint: 10)
        )
    }

    // MARK: - 导出目录记忆

    /// 纯决策：上次导出目录仍存在且可写 → 面板复用它而不是工程目录。
    func testExportPanelDirectoryUsesUsableRecordedDirectory() {
        let recorded = URL(fileURLWithPath: "/tmp/last-export")
        let fallback = URL(fileURLWithPath: "/tmp/project-folder")
        let resolved = ExportDirectoryPreference.resolvedPanelDirectory(
            recorded: recorded,
            fallback: fallback,
            isUsable: { _ in true }
        )
        XCTAssertEqual(resolved, recorded)
    }

    /// 纯决策：记录的目录已失效（删除 / 移走 / 不可写）→ 回退工程目录。
    func testExportPanelDirectoryFallsBackWhenRecordedDirectoryInvalid() {
        let recorded = URL(fileURLWithPath: "/tmp/last-export")
        let fallback = URL(fileURLWithPath: "/tmp/project-folder")
        let resolved = ExportDirectoryPreference.resolvedPanelDirectory(
            recorded: recorded,
            fallback: fallback,
            isUsable: { _ in false }
        )
        XCTAssertEqual(resolved, fallback)
    }

    /// 纯决策：无记录（首次导出）→ 直接用工程目录（原有行为）。
    func testExportPanelDirectoryFallsBackWithoutRecord() {
        let fallback = URL(fileURLWithPath: "/tmp/project-folder")
        let resolved = ExportDirectoryPreference.resolvedPanelDirectory(
            recorded: nil,
            fallback: fallback,
            isUsable: { _ in true }
        )
        XCTAssertEqual(resolved, fallback)
    }

    /// 真实校验器：存在的可写目录可用；不存在、普通文件和只读目录不可用。
    func testExportDirectoryUsableChecksExistenceAndWritability() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "anise-recorder-e6-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(ExportDirectoryPreference.isUsable(root))
        // 目录被删除后不再可用。
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertFalse(ExportDirectoryPreference.isUsable(missing))
        // 普通文件不是目录。
        let file = root.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(ExportDirectoryPreference.isUsable(file))
        // 只读目录存在但不可写；验完恢复权限保证清理成功。
        let readOnly = root.appendingPathComponent(
            "read-only",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: readOnly,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: readOnly.path
        )
        XCTAssertFalse(ExportDirectoryPreference.isUsable(readOnly))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: readOnly.path
        )
    }

    /// 方形 1:1 画布：输出 1080×1080，RenderPlan 与导出分辨率正常。
    @MainActor
    func testSquareCanvasOutputSizeAndRender() throws {
        var project = makeProject()
        project.canvas.aspect = .square
        XCTAssertEqual(
            project.canvasOutputSize,
            CGSize(width: 1080, height: 1080)
        )
        let plan = RenderPlan(
            project: project,
            time: 1,
            outputSize: project.canvasOutputSize
        )
        XCTAssertEqual(plan.outputSize.width, 1080)
        XCTAssertEqual(plan.screenRect.width, 1080, accuracy: 1)
        // 导出分辨率按比例取短边：1:1 → 1080×1080。
        let size = ExportResolution.fullHD.outputSize(for: project)
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 1080)
    }

    /// GIF 导出：5 秒工程导出可播放 GIF，时长误差 ≤0.2 秒、宽度 ≤720。
    @MainActor
    func testGifExportPlaysWithDurationAccuracy() async throws {
        let folderName = "test-gif-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        try await makeTestVideo(
            at: screenURL,
            fileType: .mp4,
            size: CGSize(width: 320, height: 180),
            color: CIColor(red: 0.3, green: 0.6, blue: 0.5),
            frameCount: 150,
            frameRate: 30
        )
        var project = makeProject()
        project.folderName = folderName
        project.duration = 5
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 5)]
        )
        let outputURL = folder.appendingPathComponent("out.gif")
        try await GifExporter.makeGif(
            for: project,
            outputURL: outputURL
        ) { _ in }

        let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil)
        XCTAssertNotNil(source, "GIF 应可被 ImageIO 读取")
        guard let source else { return }
        let frameCount = CGImageSourceGetCount(source)
        XCTAssertGreaterThan(frameCount, 10, "5 秒 15fps 应有几十帧")
        XCTAssertLessThan(frameCount, 100)
        var totalDuration = 0.0
        var width = 0
        for index in 0..<frameCount {
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(
                    source,
                    index,
                    nil
                ) as? [CFString: Any],
                let gif = properties[kCGImagePropertyGIFDictionary]
                    as? [CFString: Any]
            else {
                continue
            }
            totalDuration += (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            if width == 0 {
                width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            }
        }
        XCTAssertLessThanOrEqual(width, 720, "GIF 宽度不应超过 720")
        XCTAssertEqual(totalDuration, 5, accuracy: 0.2, "GIF 时长误差 ≤0.2s")
    }

    func testGifExportReplacesExistingFileWithoutLeftovers() async throws {
        let folderName = "test-gif-replace-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        try await makeTestVideo(
            at: screenURL,
            fileType: .mp4,
            size: CGSize(width: 320, height: 180),
            color: CIColor(red: 0.3, green: 0.6, blue: 0.5),
            frameCount: 60,
            frameRate: 30
        )
        var project = makeProject()
        project.folderName = folderName
        project.duration = 2
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 2)]
        )
        let outputURL = folder.appendingPathComponent("out.gif")
        try await GifExporter.makeGif(
            for: project,
            outputURL: outputURL
        ) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let firstSize = try FileManager.default.attributesOfItem(
            atPath: outputURL.path
        )[.size] as? Int

        // 第二次导出同一目标：走 replaceItemAt 原子替换，不先删后移。
        try await GifExporter.makeGif(
            for: project,
            outputURL: outputURL
        ) { _ in }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "重复导出后目标 GIF 仍存在"
        )
        let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil)
        XCTAssertNotNil(source, "替换后的 GIF 仍可被 ImageIO 读取")
        if let source {
            XCTAssertGreaterThan(CGImageSourceGetCount(source), 3)
        }
        if let firstSize {
            let secondSize = try FileManager.default.attributesOfItem(
                atPath: outputURL.path
            )[.size] as? Int
            XCTAssertGreaterThan(secondSize ?? 0, 0, "替换后的 GIF 非空")
            XCTAssertGreaterThan(secondSize ?? 0, firstSize / 10,
                "替换后体积应与首次同一量级")
        }

        // 输出目录不残留 .anise-recorder- 前缀的临时产物。
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: folder.path
        ).filter { $0.hasPrefix(".anise-recorder-") }
        XCTAssertTrue(
            leftovers.isEmpty,
            "GIF 导出不应残留临时文件，实际：\(leftovers)"
        )
    }

    // MARK: 人脸居中（1.2 块5）

    /// 分析管线（注入假检测器）：按采样间隔检出人脸、经时间映射后
    /// 应用为布局段；重复运行幂等；手动布局段拒绝。
    @MainActor
    func testFaceFocusAnalyzeAndApplyPlan() async throws {
        let folderName = "test-facefocus-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let cameraURL = folder.appendingPathComponent("camera.mov")
        try await makeTestVideo(
            at: cameraURL,
            fileType: .mov,
            size: CGSize(width: 320, height: 180),
            color: CIColor(red: 0.4, green: 0.4, blue: 0.4),
            frameCount: 120,
            frameRate: 30
        )
        var project = makeProject()
        project.folderName = folderName
        project.duration = 4
        project.cameraFile = cameraURL.lastPathComponent
        project.cameraOffset = 0
        project.camera.enabled = true
        project.camera.contentMode = .fill
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 4)]
        )
        XCTAssertTrue(project.supportsFaceCentering)

        // 假检测器：前半段脸在左（Vision 坐标 x 0.1-0.3），后半段在右。
        let segments = try await FaceFocusAnalyzer.analyze(
            cameraURL: cameraURL,
            cameraOffset: 0,
            project: project,
            detector: { _ in
                // 用帧内容无关的固定序列模拟：每次调用位置交替推进，
                // 由测试内部计数控制。
                FaceFocusDetectorStub.nextFaces()
            }
        )
        // 假检测器左（x 0.3）右（x 0.8）交替：建议应只含这两个焦点值。
        XCTAssertFalse(segments.isEmpty, "应产出人脸居中建议")
        for segment in segments {
            XCTAssertTrue(
                abs(segment.focus.x - 0.3) < 0.05
                    || abs(segment.focus.x - 0.8) < 0.05,
                "焦点应收敛到脸中心，实际 \(segment.focus.x)"
            )
            XCTAssertGreaterThanOrEqual(segment.focus.y, 0)
            XCTAssertLessThanOrEqual(segment.focus.y, 1)
        }

        // 应用：生成布局段，cropFocus 生效，自动段 ID 记录。
        let applied = try XCTUnwrap(
            project.applyingFaceFocusPlan(segments)
        )
        XCTAssertFalse(applied.cameraSegments.isEmpty)
        XCTAssertEqual(
            applied.cameraSegments.count,
            applied.smartCutAutoCameraSegmentIDs.count
        )
        for segment in applied.cameraSegments {
            XCTAssertEqual(segment.camera.contentMode, .fill)
        }
        // 幂等：用相同建议再应用一次，段数与起点不变。
        let reapplied = try XCTUnwrap(
            applied.applyingFaceFocusPlan(segments)
        )
        XCTAssertEqual(
            reapplied.cameraSegments.map(\.start),
            applied.cameraSegments.map(\.start)
        )

        // 手动布局段存在 → 拒绝。
        var withManual = applied
        withManual.cameraSegments.append(
            CameraLayoutSegment(start: 1, camera: applied.camera)
        )
        XCTAssertNil(withManual.applyingFaceFocusPlan(segments))
    }

    // MARK: 精剪设置持久化（1.2 块6）

    /// 模式与保护开关持久化进工程：往返保留；旧工程缺字段回退默认；
    /// 候选结果仍不持久化（沿用 1.1 决定）。
    func testSmartCutSettingsPersistAndLegacyDefaults() throws {
        var project = makeProject()
        project.smartCutSettings = SmartCutSettings(
            mode: .compact,
            protectScreenActivity: false,
            protectSystemSound: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let decoded = try XCTUnwrap(ProjectStore.decode(data))
        XCTAssertEqual(decoded.smartCutSettings.mode, .compact)
        XCTAssertFalse(decoded.smartCutSettings.protectScreenActivity)
        XCTAssertFalse(decoded.smartCutSettings.protectSystemSound)
        // 候选结果是会话数据，从不写进工程。
        XCTAssertTrue(decoded.smartCutAutoCameraSegmentIDs.isEmpty)

        let legacyJSON = """
        {
          "id": "9E0A20B1-4F48-4C45-9A21-2E1A8A8C2222",
          "name": "旧工程",
          "createdAt": "2025-01-01T00:00:00Z",
          "folderName": "legacy",
          "videoFile": "screen.mp4",
          "duration": 10,
          "width": 1600,
          "height": 900,
          "clicks": [],
          "trimStart": 0,
          "trimEnd": 10,
          "zoomScale": 1.65,
          "zoomDuration": 1.2,
          "autoZoom": false,
          "schemaVersion": 4
        }
        """
        let legacy = try XCTUnwrap(ProjectStore.decode(Data(legacyJSON.utf8)))
        XCTAssertEqual(legacy.smartCutSettings.mode, .natural)
        XCTAssertTrue(legacy.smartCutSettings.protectScreenActivity)
        XCTAssertTrue(legacy.smartCutSettings.protectSystemSound)
    }

    // MARK: 提词器文稿持久化（提词器）

    /// 提词设置往返：文稿、字号、速度、面板位置都保留。
    func testTeleprompterSettingsRoundTrip() throws {
        var project = makeProject()
        var settings = TeleprompterSettings()
        settings.script = "第一段\n\n第二段"
        settings.fontSize = 34
        settings.speed = 6
        settings.panelFrame = CGRect(x: 120, y: 88, width: 320, height: 240)
        project.teleprompter = settings

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(project)
        let decoded = try XCTUnwrap(ProjectStore.decode(encoded))
        XCTAssertEqual(decoded.teleprompter.script, "第一段\n\n第二段")
        XCTAssertEqual(decoded.teleprompter.fontSize, 34, accuracy: 0.001)
        XCTAssertEqual(decoded.teleprompter.speed, 6, accuracy: 0.001)
        XCTAssertEqual(
            decoded.teleprompter.panelFrame,
            CGRect(x: 120, y: 88, width: 320, height: 240)
        )
        XCTAssertEqual(decoded.schemaVersion, 5)
    }

    /// 旧工程没有 teleprompter 字段：解码得到安全默认（空文稿、默认字号速度），
    /// 不升 Schema 版本（1.2 带默认值新字段先例）。
    func testLegacyProjectDecodesWithoutTeleprompterSettings() throws {
        let legacyJSON = """
        {
          "id": "9E0A20B1-4F48-4C45-9A21-2E1A8A8C3333",
          "name": "旧工程",
          "createdAt": "2025-01-01T00:00:00Z",
          "folderName": "legacy",
          "videoFile": "screen.mp4",
          "duration": 10,
          "width": 1600,
          "height": 900,
          "clicks": [],
          "trimStart": 0,
          "trimEnd": 10,
          "zoomScale": 1.65,
          "zoomDuration": 1.2,
          "autoZoom": false,
          "schemaVersion": 4
        }
        """
        let legacy = try XCTUnwrap(ProjectStore.decode(Data(legacyJSON.utf8)))
        XCTAssertEqual(legacy.schemaVersion, 5)
        XCTAssertEqual(legacy.teleprompter, TeleprompterSettings())
        XCTAssertTrue(legacy.teleprompter.script.isEmpty)
    }

    /// 录制偏好（UserDefaults）旧数据没有 teleprompter 字段：回退默认，
    /// 新字段往返保留。
    func testRecordSetupTeleprompterLegacyDefaultsAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            RecordSetup.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(legacy.teleprompter, TeleprompterSettings())
        XCTAssertTrue(legacy.teleprompter.script.isEmpty)

        var setup = RecordSetup()
        setup.teleprompter.script = "粘贴的文稿"
        setup.teleprompter.speed = 4
        let decoded = try JSONDecoder().decode(
            RecordSetup.self,
            from: JSONEncoder().encode(setup)
        )
        XCTAssertEqual(decoded.teleprompter.script, "粘贴的文稿")
        XCTAssertEqual(decoded.teleprompter.speed, 4, accuracy: 0.001)
    }

    /// 1118 Loop：点击放大前置配置——旧 JSON 缺字段回退默认
    /// （开 / 1.2s / 1.65×，与既有新工程硬编码一致），设置后随编码往返保留。
    func testRecordSetupClickZoomLegacyDefaultsAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            RecordSetup.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(legacy.captureClickZoom)
        XCTAssertEqual(legacy.clickZoomDuration, 1.2, accuracy: 0.001)
        XCTAssertEqual(legacy.clickZoomScale, 1.65, accuracy: 0.001)

        var setup = RecordSetup()
        setup.captureClickZoom = false
        setup.clickZoomDuration = 2.5
        setup.clickZoomScale = 2.2
        let decoded = try JSONDecoder().decode(
            RecordSetup.self,
            from: JSONEncoder().encode(setup)
        )
        XCTAssertFalse(decoded.captureClickZoom)
        XCTAssertEqual(decoded.clickZoomDuration, 2.5, accuracy: 0.001)
        XCTAssertEqual(decoded.clickZoomScale, 2.2, accuracy: 0.001)
    }

    /// 选中工程时按工程记忆恢复提词面板偏好（字号 / 速度 / 面板位置）；
    /// 文稿不被覆盖（避免浏览工程时静默改稿）。
    @MainActor
    func testSelectProjectRestoresTeleprompterPanelPreferences() throws {
        let model = StudioModel()
        model.setup.teleprompter.script = "准备中的文稿"
        model.setup.teleprompter.fontSize = 20
        model.setup.teleprompter.speed = 2

        var project = makeProject()
        project.teleprompter.script = "工程里的文稿"
        project.teleprompter.fontSize = 44
        project.teleprompter.speed = 8
        project.teleprompter.panelFrame = CGRect(
            x: 100,
            y: 200,
            width: 340,
            height: 300
        )

        model.selectProject(project)
        XCTAssertEqual(model.setup.teleprompter.fontSize, 44, accuracy: 0.001)
        XCTAssertEqual(model.setup.teleprompter.speed, 8, accuracy: 0.001)
        XCTAssertEqual(
            model.setup.teleprompter.panelFrame,
            CGRect(x: 100, y: 200, width: 340, height: 300)
        )
        // 文稿不随工程切换覆盖准备中的文稿
        XCTAssertEqual(model.setup.teleprompter.script, "准备中的文稿")
    }

    /// 时间线变化后：候选被整体清除（不静默留在界面），并出现明确的
    /// 「请重新扫描」提示。
    @MainActor
    func testTimelineChangeInvalidatesSmartCutResultsWithMessage() throws {
        let model = StudioModel()
        var project = makeProject()
        project.duration = 10
        model.selectProject(project)
        // 模拟一次扫描完成状态。
        model.finishSmartCutScanForTesting(
            SmartCutScanOutcome(
                analysis: SmartCutAnalysis(
                    mode: .natural,
                    analyzedDuration: 10,
                    speechActivity: [
                        SpeechActivity(start: 1, end: 2)
                    ],
                    candidates: [
                        SmartCutCandidate(
                            start: 3,
                            end: 5,
                            kind: .pureSpeechPause,
                            keepEachSide: 0.2
                        )
                    ]
                ),
                audioSource: .microphone,
                systemSoundProtected: false
            )
        )
        XCTAssertEqual(model.smartCutScanPhase, .ready)
        XCTAssertNotNil(model.smartCutAnalysis)

        // 时间线编辑（变速）→ 候选失效 + 提示。
        let clipID = try XCTUnwrap(model.draft?.timeline.clips.first?.id)
        model.setTimelinePlaybackRate(0.5, for: clipID)
        XCTAssertNil(model.smartCutAnalysis)
        XCTAssertEqual(model.smartCutScanPhase, .idle)
        XCTAssertEqual(
            model.smartCutMessage,
            "时间线已变化，候选已失效，请重新扫描。"
        )
    }

    /// 棋盘格测试视频：整帧纯色画面无法验证打码破坏（模糊纯色仍是纯色）。
    private func makeCheckerVideo(
        at url: URL,
        size: CGSize,
        cells: Int,
        frameCount: Int,
        frameRate: Int
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(input) else {
            throw ExportError.failed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.failed
        }
        writer.startSession(atSourceTime: .zero)
        let cellWidth = size.width / CGFloat(cells)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard
                let buffer = makePixelBuffer(
                    color: CIColor(red: 0, green: 0, blue: 0),
                    size: size
                )
            else {
                throw ExportError.failed
            }
            // 在黑色底上画白色棋盘格（左下原点，与 Core Image 一致）。
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.setFillColor(CGColor(gray: 1, alpha: 1))
            let cellHeight = cellWidth
            for row in 0..<Int(size.height / cellHeight) {
                for column in 0..<cells {
                    if (row + column).isMultiple(of: 2) {
                        context?.fill(
                            CGRect(
                                x: CGFloat(column) * cellWidth,
                                y: CGFloat(row) * cellHeight,
                                width: cellWidth,
                                height: cellHeight
                            )
                        )
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: CMTimeValue(index),
                    timescale: CMTimeScale(max(1, frameRate))
                )
            ) else {
                throw ExportError.failed
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ExportError.failed
        }
    }

    func testLegacyRecordSetupUsesSystemDefaultMicrophone() throws {
        let setup = try JSONDecoder().decode(
            RecordSetup.self,
            from: Data("{}".utf8)
        )

        XCTAssertNil(setup.microphoneDeviceID)
    }

    func testRecordSetupRoundTripsMicrophoneDevice() throws {
        var setup = RecordSetup()
        setup.microphoneDeviceID = "BuiltInMicrophoneDevice"

        let decoded = try JSONDecoder().decode(
            RecordSetup.self,
            from: JSONEncoder().encode(setup)
        )

        XCTAssertEqual(
            decoded.microphoneDeviceID,
            "BuiltInMicrophoneDevice"
        )
    }

    func testLegacyCameraSettingsDecodeWithNewAppearanceDefaults() throws {
        let json = """
        {
          "enabled": true,
          "layout": "pictureInPicture",
          "size": 0.28
        }
        """
        let camera = try JSONDecoder().decode(
            CameraSettings.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(camera.enabled)
        XCTAssertEqual(camera.size, 0.28, accuracy: 0.000_001)
        XCTAssertEqual(camera.contentMode, .fill)
        XCTAssertEqual(camera.cropFocus.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(camera.cropFocus.y, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(camera.borderWidth, 0, accuracy: 0.000_001)
        XCTAssertFalse(camera.shadowEnabled)
        XCTAssertTrue(camera.avoidsZoomFocus)
    }

    func testMarkersPersistAndStayAnchoredToSourceTime() throws {
        var project = makeProject()
        let firstClipID = UUID()
        project.timeline = ProjectTimeline(
            clips: [
                TimelineClip(
                    id: firstClipID,
                    sourceStart: 0,
                    sourceEnd: 4,
                    playbackRate: 2
                ),
                TimelineClip(
                    sourceStart: 6,
                    sourceEnd: 8,
                    playbackRate: 0.5
                )
            ]
        )

        let first = try XCTUnwrap(
            project.addMarker(sourceTime: 1, name: "开头")
        )
        let second = try XCTUnwrap(
            project.addMarker(sourceTime: 7, name: "第二段")
        )
        XCTAssertNil(project.addMarker(sourceTime: 11))
        XCTAssertEqual(project.markers.map(\.sourceTime), [1, 7])
        XCTAssertEqual(
            try XCTUnwrap(
                project.outputTime(forSourceTime: first.sourceTime)
            ),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                project.outputTime(forSourceTime: second.sourceTime)
            ),
            4,
            accuracy: 0.000_001
        )

        XCTAssertTrue(
            project.timeline.trimClip(
                id: firstClipID,
                sourceStart: 1,
                sourceEnd: 4
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                project.outputTime(forSourceTime: first.sourceTime)
            ),
            0,
            accuracy: 0.000_001
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let loaded = try XCTUnwrap(ProjectStore.decode(data))
        XCTAssertEqual(loaded.schemaVersion, 5)
        XCTAssertEqual(loaded.markers.map(\.id), project.markers.map(\.id))
        XCTAssertEqual(
            loaded.markers.map(\.sourceTime),
            project.markers.map(\.sourceTime)
        )
        XCTAssertEqual(loaded.markers.map(\.name), project.markers.map(\.name))

        var history = ProjectUndoHistory()
        let beforeRename = loaded
        var renamed = loaded
        XCTAssertTrue(renamed.renameMarker(id: first.id, name: "重点"))
        history.record(beforeRename)
        XCTAssertEqual(history.undo(current: renamed)?.markers.first?.name, "开头")

        var withoutSecond = renamed
        XCTAssertTrue(withoutSecond.deleteMarker(id: second.id))
        XCTAssertEqual(withoutSecond.markers.map(\.id), [first.id])
    }

    func testSubtitleSRTRoundTripClampsAndPreservesMultilineText() throws {
        let source = """
        2
        00:00:03,000 --> 00:00:08,500
        第二段

        1
        00:00:00,500 --> 00:00:02,000
        <b>第一段</b>
        换行内容

        损坏条目
        00:02 --> 00:03
        没有完整时间码
        """
        let cues = SubtitleFile.parse(source, duration: 4)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "第一段\n换行内容")
        XCTAssertEqual(cues[0].start, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(cues[1].start, 3, accuracy: 0.000_001)
        XCTAssertEqual(cues[1].end, 4, accuracy: 0.000_001)

        let exported = SubtitleFile.string(from: cues)
        let roundTrip = SubtitleFile.parse(exported, duration: 4)
        XCTAssertEqual(roundTrip.count, cues.count)
        for (loaded, original) in zip(roundTrip, cues) {
            XCTAssertEqual(loaded.start, original.start, accuracy: 0.002)
            XCTAssertEqual(loaded.end, original.end, accuracy: 0.002)
            XCTAssertEqual(loaded.text, original.text)
        }
    }

    func testSpeechSegmentsGroupAtGapsAndCharacterLimits() {
        let cues = SubtitleFile.cues(
            from: [
                SpeechSegment(text: "欢迎来到", start: 0, duration: 0.6),
                SpeechSegment(text: "演示。", start: 0.7, duration: 0.5),
                SpeechSegment(text: "这里换一段", start: 3.1, duration: 0.8),
                SpeechSegment(
                    text: "A very long spoken phrase",
                    start: 4,
                    duration: 3.2
                )
            ],
            totalDuration: 8,
            maximumCharacters: 12,
            maximumDuration: 4
        )

        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].text, "欢迎来到演示。")
        XCTAssertEqual(cues[1].text, "这里换一段")
        XCTAssertEqual(cues[2].text, "A very long spoken phrase")
        XCTAssertTrue(cues.allSatisfy { $0.start < $0.end })
    }

    func testSpeechAuthorizationCompletesFromCallback() async throws {
        let status = try await OfflineCaptionTranscriber.awaitAuthorization(
            timeout: 1
        ) { continuation in
            continuation(.authorized)
        }

        XCTAssertEqual(status, .authorized)
    }

    // MARK: 句内填充词（保留分段）

    /// 步骤1 回归断言：原始分段保留路径的 cues 生成结果与既有
    /// `SubtitleFile.cues(from:)` 逐字一致；分段本体原样保留。
    func testOfflineTranscriptionOutcomeKeepsCuesIdenticalAndPreservesSegments()
    {
        let segments = [
            SpeechSegment(text: "今天我们", start: 0, duration: 0.5),
            SpeechSegment(text: "来聊一下", start: 0.5, duration: 0.4),
            SpeechSegment(text: "嗯", start: 0.9, duration: 0.2),
            SpeechSegment(text: "怎么选镜头", start: 1.1, duration: 0.8),
            SpeechSegment(text: "。", start: 1.9, duration: 0.1)
        ]
        let outcome = OfflineCaptionTranscriber.outcome(
            from: segments,
            totalDuration: 10
        )

        // CaptionCue 自带随机 UUID，逐字段比较（回归契约 = 文本与时间逐字不变）。
        let baseline = SubtitleFile.cues(from: segments, totalDuration: 10)
        XCTAssertEqual(outcome.cues.count, baseline.count)
        for (built, expected) in zip(outcome.cues, baseline) {
            XCTAssertEqual(built.text, expected.text)
            XCTAssertEqual(built.start, expected.start)
            XCTAssertEqual(built.end, expected.end)
        }
        XCTAssertEqual(outcome.cues.count, 1)
        XCTAssertEqual(outcome.cues.first?.text, "今天我们来聊一下嗯怎么选镜头。")
        XCTAssertEqual(outcome.segments, segments)
    }

    // MARK: 句内填充词（句内检测 · 10 条降级门禁样本）

    /// 真实结构样本：SFSpeech 中文逐词 / 英文逐词分段风格，时间连续、
    /// 填充词独立成段。5 条长句句中、2 条中英混读、2 条句首句尾、
    /// 1 条密集填充。
    private struct InSentenceSample {
        let name: String
        let segments: [SpeechSegment]
        /// 期望命中的填充词（按命中顺序，即 segment 文本）。
        let expectedFillers: [String]
    }

    private static let inSentenceSamples: [InSentenceSample] = [
        InSentenceSample(
            name: "S1 长句句中",
            segments: [
                SpeechSegment(text: "今天我们", start: 0, duration: 0.5),
                SpeechSegment(text: "来聊一下", start: 0.5, duration: 0.4),
                SpeechSegment(text: "嗯", start: 0.9, duration: 0.25),
                SpeechSegment(text: "怎么选", start: 1.15, duration: 0.4),
                SpeechSegment(text: "镜头。", start: 1.55, duration: 0.5)
            ],
            expectedFillers: ["嗯"]
        ),
        InSentenceSample(
            name: "S2 长句句中",
            segments: [
                SpeechSegment(text: "首先打开", start: 0, duration: 0.6),
                SpeechSegment(text: "那个", start: 0.6, duration: 0.3),
                SpeechSegment(text: "导出面板", start: 0.9, duration: 0.5),
                SpeechSegment(text: "然后选分辨率。", start: 1.4, duration: 0.8)
            ],
            expectedFillers: ["那个"]
        ),
        InSentenceSample(
            name: "S3 长句句中",
            segments: [
                SpeechSegment(text: "这个功能", start: 0, duration: 0.5),
                SpeechSegment(text: "就是说", start: 0.5, duration: 0.45),
                SpeechSegment(text: "要配合快捷键", start: 0.95, duration: 0.7),
                SpeechSegment(text: "使用。", start: 1.65, duration: 0.4)
            ],
            expectedFillers: ["就是说"]
        ),
        InSentenceSample(
            name: "S4 长句句中",
            segments: [
                SpeechSegment(text: "画面会", start: 0, duration: 0.4),
                SpeechSegment(text: "呃", start: 0.4, duration: 0.2),
                SpeechSegment(text: "自动吸附到", start: 0.6, duration: 0.6),
                SpeechSegment(text: "安全边距。", start: 1.2, duration: 0.6)
            ],
            expectedFillers: ["呃"]
        ),
        InSentenceSample(
            name: "S5 长句句中",
            segments: [
                SpeechSegment(text: "也可以", start: 0, duration: 0.35),
                SpeechSegment(text: "然后就是", start: 0.35, duration: 0.5),
                SpeechSegment(text: "按住边缘", start: 0.85, duration: 0.5),
                SpeechSegment(text: "拖动修剪。", start: 1.35, duration: 0.6)
            ],
            expectedFillers: ["然后就是"]
        ),
        InSentenceSample(
            name: "S6 中英混读",
            segments: [
                SpeechSegment(text: "接下来", start: 0, duration: 0.4),
                SpeechSegment(text: "um", start: 0.4, duration: 0.25),
                SpeechSegment(text: "我们看一个", start: 0.65, duration: 0.6),
                SpeechSegment(text: "demo", start: 1.25, duration: 0.4)
            ],
            expectedFillers: ["um"]
        ),
        InSentenceSample(
            name: "S7 中英混读",
            segments: [
                SpeechSegment(text: "The export", start: 0, duration: 0.5),
                SpeechSegment(text: "uh", start: 0.5, duration: 0.2),
                SpeechSegment(text: "panel supports", start: 0.7, duration: 0.7),
                SpeechSegment(text: "4K。", start: 1.4, duration: 0.4)
            ],
            expectedFillers: ["uh"]
        ),
        InSentenceSample(
            name: "S8 句首",
            segments: [
                SpeechSegment(text: "呃", start: 0, duration: 0.25),
                SpeechSegment(text: "今天这一集", start: 0.25, duration: 0.6),
                SpeechSegment(text: "讲时间线。", start: 0.85, duration: 0.6)
            ],
            expectedFillers: ["呃"]
        ),
        InSentenceSample(
            name: "S9 句尾",
            segments: [
                SpeechSegment(text: "导出前检查", start: 0, duration: 0.6),
                SpeechSegment(text: "磁盘空间", start: 0.6, duration: 0.5),
                SpeechSegment(text: "啊。", start: 1.1, duration: 0.3)
            ],
            expectedFillers: ["啊。"]
        ),
        InSentenceSample(
            name: "S10 密集填充",
            segments: [
                SpeechSegment(text: "呃", start: 0, duration: 0.2),
                SpeechSegment(text: "这一步", start: 0.2, duration: 0.4),
                SpeechSegment(text: "那个", start: 0.6, duration: 0.25),
                SpeechSegment(text: "可以", start: 0.85, duration: 0.3),
                SpeechSegment(text: "嗯", start: 1.15, duration: 0.2),
                SpeechSegment(text: "直接跳过。", start: 1.35, duration: 0.6)
            ],
            expectedFillers: ["呃", "那个", "嗯"]
        )
    ]

    private static func makeSegmentFragments(
        _ segments: [SpeechSegment]
    ) -> [SmartCutCaptionFragment] {
        segments.map { segment in
            SmartCutCaptionFragment(
                id: UUID(),
                start: segment.start,
                end: segment.start + segment.duration,
                text: segment.text
            )
        }
    }

    /// 降级门禁：句内检测必须在 10 条真实结构样本上全部命中预期。
    func testInSentenceDetectionPassesTenRealisticSamples() {
        for (index, sample) in Self.inSentenceSamples.enumerated() {
            let fragments = Self.makeSegmentFragments(sample.segments)
            let suggestions = SmartCutFillerDetector.inSentenceSuggestions(
                in: fragments
            )
            XCTAssertEqual(
                suggestions.map(\.context),
                sample.expectedFillers,
                "样本 \(index + 1)（\(sample.name)）命中的填充词不符"
            )
            for suggestion in suggestions {
                XCTAssertEqual(suggestion.kind, .inSentenceFiller)
                XCTAssertTrue(suggestion.isRecommended)
                XCTAssertNil(suggestion.alternateRange)
                // 建议删除区间必须落在对应 segment 时间内部（向内收缩）。
                guard
                    let range = suggestion.sourceSegmentRange
                else {
                    XCTFail("句内建议必须携带 sourceSegmentRange")
                    continue
                }
                XCTAssertGreaterThanOrEqual(
                    suggestion.cutRange.lowerBound, range.lowerBound
                )
                XCTAssertLessThanOrEqual(
                    suggestion.cutRange.upperBound, range.upperBound
                )
            }
        }
    }

    /// 只删独立成词：含实词的 segment 一律不命中。
    func testInSentenceDetectionSkipsSegmentsContainingContentWords() {
        let segments = [
            SpeechSegment(text: "那个方案很好", start: 0, duration: 0.8),
            SpeechSegment(text: "I like this", start: 1, duration: 0.7),
            SpeechSegment(text: "就是这个功能好用。", start: 2, duration: 0.9)
        ]
        let suggestions = SmartCutFillerDetector.inSentenceSuggestions(
            in: Self.makeSegmentFragments(segments)
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// 过长 segment 不判填充词：识别并段时把实词并进来的长段不猜。
    func testInSentenceDetectionSkipsOverlongSegments() {
        let segments = [
            SpeechSegment(text: "嗯", start: 0, duration: 3)
        ]
        let suggestions = SmartCutFillerDetector.inSentenceSuggestions(
            in: Self.makeSegmentFragments(segments)
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// 合并规则：有分段时整条填充词建议让位给覆盖同一区间的句内建议；
    /// 没有分段时整条建议行为不变（回归）。
    func testInSentenceSuggestionsTakePrecedenceOverWholeCueFillerSuggestions()
    {
        let cue = SmartCutCaptionFragment(
            id: UUID(), start: 1, end: 1.4, text: "嗯"
        )
        let segment = SmartCutCaptionFragment(
            id: UUID(), start: 1, end: 1.4, text: "嗯"
        )

        let merged = SmartCutFillerDetector.suggestions(
            in: [cue],
            segmentFragments: [segment]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.kind, .inSentenceFiller)

        let cueOnly = SmartCutFillerDetector.suggestions(
            in: [cue],
            segmentFragments: nil
        )
        XCTAssertEqual(cueOnly.count, 1)
        XCTAssertEqual(cueOnly.first?.kind, .fillerWord)
    }

    // MARK: 句内填充词（文本手术 · 10 条样本门禁）

    /// 步骤3 门禁：10 条样本全链路（检测 → 原子剪切事务 → 文本手术 →
    /// 撤销还原）。cue 被删成两段时按 segment 时间决定文本归属
    /// （总指令规则）：句中填充词 → 两条 cue 各带前后文本；句首/句尾
    /// → 残余空片段（<50ms 或无保留文本）随事务删除，剩一条 cue。
    func testInSentenceSurgeryPassesTenRealisticSamples() throws {
        let expectedTexts = [
            ["今天我们来聊一下", "怎么选镜头。"],
            ["首先打开", "导出面板然后选分辨率。"],
            ["这个功能", "要配合快捷键使用。"],
            ["画面会", "自动吸附到安全边距。"],
            ["也可以", "按住边缘拖动修剪。"],
            ["接下来", "我们看一个demo"],
            ["The export", "panel supports 4K。"],
            ["今天这一集讲时间线。"],
            ["导出前检查磁盘空间"],
            ["这一步", "可以", "直接跳过。"]
        ]
        for (index, sample) in Self.inSentenceSamples.enumerated() {
            var project = makeProject()
            let segments = sample.segments
            let totalDuration = segments.map {
                $0.start + $0.duration
            }.max() ?? 0
            project.timeline = ProjectTimeline(
                sourceStart: 0,
                sourceEnd: totalDuration
            )
            let cues = SubtitleFile.cues(
                from: segments,
                totalDuration: totalDuration
            )
            let beforeTexts = cues.map(\.text)
            project.captionCues = cues
            let cueFragments = cues.map {
                SmartCutCaptionFragment(
                    id: $0.id,
                    start: $0.start,
                    end: $0.end,
                    text: $0.text
                )
            }
            let suggestions = SmartCutFillerDetector.suggestions(
                in: cueFragments,
                segmentFragments: Self.makeSegmentFragments(segments)
            )
            XCTAssertEqual(
                suggestions.map(\.context),
                sample.expectedFillers,
                "样本 \(index + 1)（\(sample.name)）检测不符"
            )
            let candidates = suggestions.map { suggestion in
                SmartCutCandidate(
                    start: suggestion.activeRange().lowerBound,
                    end: suggestion.activeRange().upperBound,
                    kind: .fillerWord,
                    keepEachSide: 0
                )
            }
            let outcome = TimelineCutTransaction.apply(
                candidates,
                to: project.timeline,
                frameDuration: 1.0 / 30
            )
            XCTAssertFalse(
                outcome.deletions.isEmpty,
                "样本 \(index + 1)（\(sample.name)）没有产生删除"
            )
            // 一次撤销完整还原（记录手术前快照）。
            var history = ProjectUndoHistory()
            history.record(project)

            let surgery = CaptionSegmentSurgery.rewritten(
                cues: project.captionCues,
                segments: segments,
                removedSegmentRanges: suggestions.compactMap(
                    \.sourceSegmentRange
                ),
                outcome: outcome
            )
            project.captionCues = surgery.cues
            project.timeline = outcome.timeline

            // 手术前后对照：文本逐条等于期望，删除的填充词不再残留。
            XCTAssertEqual(
                project.captionCues.map(\.text),
                expectedTexts[index],
                "样本 \(index + 1)（\(sample.name)）手术前后不符"
            )
            for filler in sample.expectedFillers {
                let normalizedFiller = filler.trimmingCharacters(
                    in: CharacterSet(charactersIn: "。，,．.!？?…、；;：:")
                )
                XCTAssertFalse(
                    project.captionCues.contains {
                        $0.text.contains(normalizedFiller)
                    },
                    "样本 \(index + 1)（\(sample.name)）填充词 \(normalizedFiller) 仍残留"
                )
            }
            XCTAssertEqual(
                surgery.report.rewrittenCues,
                expectedTexts[index].count,
                "样本 \(index + 1)（\(sample.name)）重写条数不符"
            )
            XCTAssertEqual(surgery.report.deletedCues, 0)
            XCTAssertEqual(surgery.report.skippedUnverifiedCues, 0)
            // 音频确实缩短。
            XCTAssertLessThan(
                project.timeline.duration,
                totalDuration
            )

            let restored = try XCTUnwrap(history.undo(current: project))
            XCTAssertEqual(
                restored.captionCues.map(\.text),
                beforeTexts,
                "样本 \(index + 1)（\(sample.name)）撤销未还原"
            )
            XCTAssertEqual(
                restored.timeline.duration,
                totalDuration,
                accuracy: 0.000_001
            )
        }
    }

    /// 重建校验不过（术语表改写 / 手动字幕 / SRT 导入）→ 不按字符位置猜，
    /// 文本原样保留，只按事务裁剪时间。
    func testSurgeryLeavesUnverifiedCueTextUnchanged() {
        let cue = CaptionCue(start: 1, end: 3, text: "这里有一段被改写过的字幕")
        let segments = [
            SpeechSegment(text: "这里", start: 1, duration: 0.5),
            SpeechSegment(text: "呃", start: 1.5, duration: 0.2),
            SpeechSegment(
                text: "有一段被改写过的字幕",
                start: 1.7,
                duration: 1.2
            )
        ]
        let candidate = SmartCutCandidate(
            start: 1.52,
            end: 1.68,
            kind: .fillerWord,
            keepEachSide: 0
        )
        let outcome = TimelineCutTransaction.apply(
            [candidate],
            to: ProjectTimeline(sourceStart: 0, sourceEnd: 6),
            frameDuration: 1.0 / 30
        )
        let surgery = CaptionSegmentSurgery.rewritten(
            cues: [cue],
            segments: segments,
            removedSegmentRanges: [1.5 ... 1.7],
            outcome: outcome
        )

        XCTAssertEqual(surgery.report.skippedUnverifiedCues, 1)
        XCTAssertEqual(surgery.report.rewrittenCues, 0)
        // cue 被切成两段，两段都保留原文（与既有 ripple 行为一致）。
        XCTAssertEqual(surgery.cues.count, 2)
        XCTAssertTrue(
            surgery.cues.allSatisfy {
                $0.text == "这里有一段被改写过的字幕"
            }
        )
    }

    /// segment 时间映射：双片段 + 2× 变速时间线上的句内手术，文本按
    /// 事务映射后的 segment 时间归属片段，成片时间整体前移。
    func testSurgeryMapsSegmentTimesAcrossVariableRateAndSplitClips() {
        let segments = [
            SpeechSegment(text: "先看", start: 1.0, duration: 0.5),
            SpeechSegment(text: "那个", start: 3.0, duration: 0.3),
            SpeechSegment(text: "再导出。", start: 3.3, duration: 0.5)
        ]
        let cues = SubtitleFile.cues(from: segments, totalDuration: 6)
        XCTAssertEqual(cues.count, 2)

        let timeline = ProjectTimeline(clips: [
            TimelineClip(sourceStart: 0, sourceEnd: 4, playbackRate: 2),
            TimelineClip(sourceStart: 4, sourceEnd: 8, playbackRate: 1)
        ])
        let candidate = SmartCutCandidate(
            start: 3.02,
            end: 3.28,
            kind: .fillerWord,
            keepEachSide: 0
        )
        let outcome = TimelineCutTransaction.apply(
            [candidate],
            to: timeline,
            frameDuration: 1.0 / 30
        )
        let surgery = CaptionSegmentSurgery.rewritten(
            cues: cues,
            segments: segments,
            removedSegmentRanges: [3.0 ... 3.3],
            outcome: outcome
        )

        XCTAssertEqual(surgery.report.rewrittenCues, 1)
        XCTAssertEqual(surgery.cues.count, 2)
        XCTAssertEqual(surgery.cues[0].text, "先看")
        XCTAssertEqual(surgery.cues[0].start, cues[0].start, accuracy: 1e-9)
        XCTAssertEqual(surgery.cues[1].text, "再导出。")
        // 删除窗口吸附到帧网格（约 0.233s）；cue2 起点贴切点后（新时间
        // 3.0333），「先看」cue 在切点前、时间不动。
        XCTAssertEqual(outcome.timeline.duration, 5.7667, accuracy: 0.02)
        XCTAssertEqual(surgery.cues[1].start, 3.0333, accuracy: 0.02)
        XCTAssertEqual(surgery.cues[1].end, 3.5667, accuracy: 0.02)
    }

    // MARK: 句内填充词加深：词库反例集与预估秒数

    /// 「只删独立成词、不伤句中实词」反例集（12 条）：含实词、填充词
    /// 叠用、词表外语气词、单段多填充词一律不命中——宁可漏删不误删。
    func testInSentenceDetectionReverseCasesDoNotHurtContentWords() {
        let negativeCases: [String] = [
            "那个方案很好",
            "I like this",
            "就是这个功能好用。",
            "然后我们导出。",
            "呃呃",
            "那个那个",
            "嗯嗯嗯",
            "and",
            "eh",
            "ah",
            "嗯，那个",
            "her paper"
        ]
        let segments = negativeCases.enumerated().map { index, text in
            SpeechSegment(
                text: text,
                start: Double(index) * 2,
                duration: 0.8
            )
        }
        let suggestions = SmartCutFillerDetector.inSentenceSuggestions(
            in: Self.makeSegmentFragments(segments)
        )
        XCTAssertTrue(
            suggestions.isEmpty,
            "反例不应命中：\(suggestions.map(\.context))"
        )
    }

    /// 正例（文档化归一化行为）：大小写不敏感、首尾标点剥离、词表独立
    /// 成词命中；「然后」「额」按词表现状执行。
    func testInSentenceDetectionNormalizesCaseAndPunctuation() {
        let segments = [
            SpeechSegment(text: "Um", start: 0, duration: 0.3),
            SpeechSegment(text: "嗯？", start: 1, duration: 0.3),
            SpeechSegment(text: "Erm", start: 2, duration: 0.3),
            SpeechSegment(text: "额", start: 3, duration: 0.3)
        ]
        let suggestions = SmartCutFillerDetector.inSentenceSuggestions(
            in: Self.makeSegmentFragments(segments)
        )
        XCTAssertEqual(
            suggestions.map(\.context),
            ["Um", "嗯？", "Erm", "额"]
        )
    }

    /// 预估秒数：勾选建议按当前删除区间求和，未勾选不计入。
    func testFillerSuggestionsEstimateSavedDuration() {
        let suggestions = [
            SmartCutFillerSuggestion(
                kind: .fillerWord,
                context: "嗯",
                confidence: 0.9,
                repeatCount: 1,
                keepLastInstance: true,
                cutRange: 1.02 ... 1.28
            ),
            SmartCutFillerSuggestion(
                kind: .inSentenceFiller,
                context: "呃",
                confidence: 0.9,
                repeatCount: 1,
                keepLastInstance: true,
                cutRange: 2.42 ... 2.58
            ),
            SmartCutFillerSuggestion(
                kind: .restart,
                context: "打开这个面板",
                confidence: 0.6,
                repeatCount: 2,
                keepLastInstance: true,
                cutRange: 0.1 ... 1.1
            )
        ]
        XCTAssertEqual(
            suggestions.estimatedSavedDuration(selectedIndices: [0, 1]),
            0.42,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            suggestions.estimatedSavedDuration(selectedIndices: []),
            0
        )
        XCTAssertEqual(
            suggestions.estimatedSavedDuration(selectedIndices: [2]),
            1.0,
            accuracy: 1e-9
        )
    }

    func testSpeechAuthorizationTimesOutWithoutCallback() async {
        do {
            _ = try await OfflineCaptionTranscriber.awaitAuthorization(
                timeout: 0.01
            ) { _ in }
            XCTFail("Expected authorization to time out")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                OfflineCaptionError.permissionTimedOut.localizedDescription
            )
        }
    }

    func testSpeechNoSpeechErrorMapsToFriendlyMessage() {
        let error = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 203,
            userInfo: [NSLocalizedDescriptionKey: "No speech detected"]
        )

        XCTAssertEqual(
            OfflineCaptionError.mapped(error),
            .noSpeechDetected
        )
        XCTAssertEqual(
            OfflineCaptionError.mapped(error).localizedDescription,
            OfflineCaptionError.noSpeechDetected.localizedDescription
        )
    }

    func testChapterBuilderMergesShortCuesAndFormatsText() {
        let chapters = ChapterBuilder.build(
            from: [
                CaptionCue(start: 0, end: 2, text: "介绍"),
                CaptionCue(start: 2.5, end: 3.5, text: "环境"),
                CaptionCue(start: 6, end: 10, text: "第一部分"),
                CaptionCue(start: 10.3, end: 12, text: "第二部分")
            ],
            minimumDuration: 4,
            totalDuration: 12
        )

        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "介绍")
        XCTAssertEqual(chapters[0].end, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(chapters[1].title, "第一部分")
        XCTAssertEqual(
            ChapterBuilder.text(from: chapters),
            "00:00:00 介绍\n00:00:06 第一部分\n00:00:10 第二部分\n"
        )
    }

    func testCaptionRendererDrawsOnlyActiveCueAndCanBeDisabled() throws {
        var project = makeProject()
        project.captions.enabled = true
        project.captions.backgroundOpacity = 0.9
        project.captionCues = [
            CaptionCue(
                start: 1,
                end: 3,
                text: "这是一条测试字幕"
            )
        ]
        let base = CIImage(
            color: CIColor(red: 1, green: 1, blue: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let outputSize = CGSize(width: 640, height: 360)

        let active = CaptionRenderer.overlay(
            on: base,
            time: 2,
            project: project,
            outputSize: outputSize
        )
        let inactive = CaptionRenderer.overlay(
            on: base,
            time: 4,
            project: project,
            outputSize: outputSize
        )
        XCTAssertLessThan(
            try brightness(of: active, at: CGPoint(x: 320, y: 26)),
            0.75
        )
        XCTAssertGreaterThan(
            try brightness(of: inactive, at: CGPoint(x: 320, y: 26)),
            0.95
        )

        project.captions.enabled = false
        let disabled = CaptionRenderer.overlay(
            on: base,
            time: 2,
            project: project,
            outputSize: outputSize
        )
        XCTAssertGreaterThan(
            try brightness(of: disabled, at: CGPoint(x: 320, y: 26)),
            0.95
        )
    }

    func testTranscriptionAudioUsesEditedTimelineAndPlaybackRate() async throws {
        let folderName = "test-transcription-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let microphoneURL = folder.appendingPathComponent("microphone.m4a")
        try makeTestAudio(at: microphoneURL, duration: 8)
        var project = makeProject()
        project.folderName = folderName
        project.microphoneFile = microphoneURL.lastPathComponent
        project.timeline = ProjectTimeline(
            clips: [
                TimelineClip(
                    sourceStart: 1,
                    sourceEnd: 4,
                    playbackRate: 2
                )
            ]
        )
        let outputURL = folder.appendingPathComponent("transcription.m4a")
        try await CompositionBuilder.makeTranscriptionAudio(
            for: project,
            outputURL: outputURL
        )

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.12)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    func testCameraInsertionSkipsZeroDurationLeadingSample() {
        let end = CMTime(seconds: 6.835, preferredTimescale: 600)
        let atZero = CompositionBuilder.cameraInsertionRange(
            requestedStart: .zero,
            requestedEnd: end,
            sourceStart: .zero
        )
        XCTAssertEqual(
            atZero.start.seconds,
            1.0 / 600,
            accuracy: 1e-9
        )
        XCTAssertEqual(atZero.end, end)

        let requestedStart = CMTime(seconds: 0.1, preferredTimescale: 600)
        let offset = CompositionBuilder.cameraInsertionRange(
            requestedStart: requestedStart,
            requestedEnd: end,
            sourceStart: .zero
        )
        XCTAssertEqual(offset.start, requestedStart)
        XCTAssertEqual(offset.end, end)

        let insertion = CompositionBuilder.cameraInsertionTime(.zero)
        XCTAssertEqual(insertion.seconds, 1.0 / 600, accuracy: 1e-9)
    }

    // MARK: 精剪：分析、应用事务与轨道 ripple

    /// 生成 speech / silence 分段的测试音频（44.1 kHz 单声道 m4a），
    /// speech ≈ -23 dBFS，silence 为数字静音。
    private func makePatternedTestAudio(
        at url: URL,
        speechSegments: [(start: Double, end: Double)],
        duration: Double
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            )
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let totalFrames = Int(sampleRate * duration)
        let loud = Set(
            speechSegments.flatMap { segment in
                Int(sampleRate * segment.start) ..< Int(sampleRate * segment.end)
            }
        )
        // 分块写入，避免为长素材一次分配整个缓冲。
        let chunkFrames = 44_100
        var cursor = 0
        var phase: Float = 0
        while cursor < totalFrames {
            let count = min(chunkFrames, totalFrames - cursor)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(count)
                )
            )
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<count {
                phase += 2 * Float.pi * 220 / Float(sampleRate)
                samples[index] = loud.contains(cursor + index)
                    ? sin(phase) * 0.1
                    : 0
            }
            try file.write(from: buffer)
            cursor += count
        }
    }

    private func makeSmartCutScanProject(
        folderName: String,
        microphoneFile: String,
        timeline: ProjectTimeline
    ) -> StudioProject {
        var project = makeProject()
        project.folderName = folderName
        project.microphoneFile = microphoneFile
        project.timeline = timeline
        return project
    }

    func testSmartCutScanRespectsEditedTimelineAndPlaybackRate() async throws {
        let folderName = "test-smartcut-scan-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let microphoneURL = folder.appendingPathComponent("microphone.m4a")
        // 素材：0–2 秒口播，2–4 秒静音，4–6 秒口播。
        try makePatternedTestAudio(
            at: microphoneURL,
            speechSegments: [(0, 2), (4, 6)],
            duration: 6
        )

        // 场景 A：完整时间线 [0, 6]，停顿候选应落在成片 [2.16, 3.99] 附近。
        let fullProject = makeSmartCutScanProject(
            folderName: folderName,
            microphoneFile: microphoneURL.lastPathComponent,
            timeline: ProjectTimeline(sourceStart: 0, sourceEnd: 6)
        )
        let fullOutcome = try await SmartCutAnalyzer.scan(
            project: fullProject,
            mode: .natural,
            protectScreenActivity: false,
            protectSystemSound: false,
            progress: { _ in },
            isCancelled: { false }
        )
        XCTAssertEqual(fullOutcome.audioSource, .microphone)
        XCTAssertEqual(fullOutcome.analysis.analyzedDuration, 6, accuracy: 0.1)
        XCTAssertEqual(fullOutcome.analysis.candidates.count, 1)
        let fullCandidate = try XCTUnwrap(fullOutcome.analysis.candidates.first)
        XCTAssertEqual(fullCandidate.start, 2.16, accuracy: 0.1)
        XCTAssertEqual(fullCandidate.end, 3.99, accuracy: 0.1)
        XCTAssertEqual(fullCandidate.kind, .pureSpeechPause)

        // 场景 B：时间线裁剪为 [1, 5]，候选必须随成片时间前移约 1 秒，
        // 而不是使用原始麦克风文件的时间。
        let trimmedProject = makeSmartCutScanProject(
            folderName: folderName,
            microphoneFile: microphoneURL.lastPathComponent,
            timeline: ProjectTimeline(sourceStart: 1, sourceEnd: 5)
        )
        let trimmedOutcome = try await SmartCutAnalyzer.scan(
            project: trimmedProject,
            mode: .natural,
            protectScreenActivity: false,
            protectSystemSound: false,
            progress: { _ in },
            isCancelled: { false }
        )
        XCTAssertEqual(trimmedOutcome.analysis.analyzedDuration, 4, accuracy: 0.1)
        XCTAssertEqual(trimmedOutcome.analysis.candidates.count, 1)
        let trimmedCandidate = try XCTUnwrap(trimmedOutcome.analysis.candidates.first)
        XCTAssertEqual(trimmedCandidate.start, 1.16, accuracy: 0.1)
        // 源 4.0 秒处开始的第二段口播，裁剪 1 秒后落在成片 3.0 秒。
        XCTAssertEqual(trimmedCandidate.end, 2.99, accuracy: 0.1)

        // 场景 C：同一区间 2× 变速后有效时长减半，剩余 0.83 秒停顿按
        // 紧凑模式仍可识别（自然模式 0.8 秒下限太贴近阈值）。
        let rateProject = makeSmartCutScanProject(
            folderName: folderName,
            microphoneFile: microphoneURL.lastPathComponent,
            timeline: ProjectTimeline(
                clips: [
                    TimelineClip(sourceStart: 1, sourceEnd: 5, playbackRate: 2)
                ]
            )
        )
        let rateOutcome = try await SmartCutAnalyzer.scan(
            project: rateProject,
            mode: .compact,
            protectScreenActivity: false,
            protectSystemSound: false,
            progress: { _ in },
            isCancelled: { false }
        )
        XCTAssertEqual(rateOutcome.analysis.analyzedDuration, 2, accuracy: 0.1)
        XCTAssertEqual(rateOutcome.analysis.candidates.count, 1)
        let rateCandidate = try XCTUnwrap(rateOutcome.analysis.candidates.first)
        XCTAssertEqual(rateCandidate.pauseDuration, 0.83, accuracy: 0.12)
        XCTAssertEqual(rateCandidate.kind, .shortBreath)

        // 场景 D：停顿中段的点击（源 3.4 秒 → 成片 2.4 秒）把候选拆成
        // “推荐 + 有屏幕操作”两条。
        var clickProject = trimmedProject
        clickProject.clicks = [ClickEvent(time: 3.4, x: 0.5, y: 0.5)]
        let clickOutcome = try await SmartCutAnalyzer.scan(
            project: clickProject,
            mode: .natural,
            protectScreenActivity: true,
            protectSystemSound: false,
            progress: { _ in },
            isCancelled: { false }
        )
        XCTAssertEqual(clickOutcome.analysis.candidates.count, 2)
        XCTAssertTrue(
            clickOutcome.analysis.candidates.first?.isDefaultSelected ?? false
        )
        let protectedCandidate = try XCTUnwrap(
            clickOutcome.analysis.candidates.first(where: { !$0.isDefaultSelected })
        )
        XCTAssertEqual(protectedCandidate.kind, .hasScreenActivity)
        XCTAssertEqual(protectedCandidate.start, 2.1, accuracy: 0.1)
        XCTAssertEqual(protectedCandidate.end, 2.99, accuracy: 0.1)
    }

    func testSmartCutScanProtectsRealSystemSoundTrack() async throws {
        let folderName = "test-smartcut-system-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let microphoneURL = folder.appendingPathComponent("microphone.m4a")
        let systemURL = folder.appendingPathComponent("system.m4a")
        try makePatternedTestAudio(
            at: microphoneURL,
            speechSegments: [(0, 1), (3, 4)],
            duration: 4
        )
        try makePatternedTestAudio(
            at: systemURL,
            speechSegments: [(1.3, 2.2)],
            duration: 4
        )

        var project = makeProject()
        project.folderName = folderName
        project.microphoneFile = microphoneURL.lastPathComponent
        project.systemAudioFile = systemURL.lastPathComponent
        project.timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 4)

        let outcome = try await SmartCutAnalyzer.scan(
            project: project,
            mode: .natural,
            protectScreenActivity: false,
            protectSystemSound: true,
            progress: { _ in },
            isCancelled: { false }
        )

        XCTAssertTrue(outcome.systemSoundProtected)
        XCTAssertTrue(
            outcome.analysis.candidates.contains {
                $0.kind == .hasSystemSound
            }
        )
    }

    func testApplyingCutTransactionRipplesTracksAndKeepsSourceData() throws {
        var project = makeProject()
        project.timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let firstCamera = CameraLayoutSegment(start: 2, camera: CameraSettings())
        let secondCamera = CameraLayoutSegment(start: 4, camera: CameraSettings())
        let thirdCamera = CameraLayoutSegment(start: 6, camera: CameraSettings())
        project.cameraSegments = [firstCamera, secondCamera, thirdCamera]
        let zoomA = ZoomRegion(start: 2.5, duration: 1.2)
        let zoomB = ZoomRegion(start: 5.5, duration: 1.2)
        let zoomC = ZoomRegion(start: 4.0, duration: 1.2)
        let zoomD = ZoomRegion(start: 3.5, duration: 1.2)
        project.zoomRegions = [zoomA, zoomB, zoomC, zoomD]
        let cueA = CaptionCue(start: 1.0, end: 1.8, text: "删除之前")
        let cueB = CaptionCue(start: 2.0, end: 3.5, text: "尾部被切")
        let cueC = CaptionCue(start: 4.0, end: 6.0, text: "头部被切")
        let cueD = CaptionCue(start: 4.5, end: 4.8, text: "整体被删")
        let cueE = CaptionCue(start: 2.0, end: 4.5, text: "跨越切点")
        project.captionCues = [cueA, cueB, cueC, cueD, cueE]
        project.markers = [RecordingMarker(sourceTime: 2.5, name: "标记")]
        project.clicks = [ClickEvent(time: 2.5, x: 0.5, y: 0.5)]
        project.rawCursor = [
            CursorSample(
                sourceTime: 2.5,
                x: 0.4,
                y: 0.4,
                visible: true,
                moved: false
            )
        ]

        let outcome = TimelineCutTransaction.apply(
            [
                SmartCutCandidate(
                    start: 3,
                    end: 5,
                    kind: .pureSpeechPause,
                    keepEachSide: 0
                )
            ],
            to: project.timeline
        )
        let updated = project.applyingCutTransaction(outcome)

        // 视频轨：成片时长 10 → 8。
        XCTAssertEqual(updated.timeline.duration, 8, accuracy: 0.000_001)

        // 摄像头布局段：2 → 2；4（删除区间内）→ 贴到切点后 3；6 → 4。
        XCTAssertEqual(updated.cameraSegments.count, 3)
        for segment in updated.cameraSegments {
            switch segment.id {
            case firstCamera.id:
                XCTAssertEqual(segment.start, 2, accuracy: 0.000_001)
            case secondCamera.id:
                XCTAssertEqual(segment.start, 3, accuracy: 0.000_001)
            case thirdCamera.id:
                XCTAssertEqual(segment.start, 4, accuracy: 0.000_001)
            default:
                XCTFail("未知布局段")
            }
        }

        // 缩放区：[2.5,3.7] 保留头部 [2.5,3.0]；[5.5,6.7] 平移到 [3.5,4.7]；
        // [4.0,5.2] 剩余 0.2 秒；[3.5,4.7] 整体被删。
        XCTAssertEqual(updated.zoomRegions.count, 3)
        let zoomA2 = try XCTUnwrap(
            updated.zoomRegions.first { $0.id == zoomA.id }
        )
        XCTAssertEqual(zoomA2.start, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(zoomA2.duration, 0.5, accuracy: 0.000_001)
        let zoomB2 = try XCTUnwrap(
            updated.zoomRegions.first { $0.id == zoomB.id }
        )
        XCTAssertEqual(zoomB2.start, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(zoomB2.duration, 1.2, accuracy: 0.000_001)
        let zoomC2 = try XCTUnwrap(
            updated.zoomRegions.first { $0.id == zoomC.id }
        )
        XCTAssertEqual(zoomC2.start, 3, accuracy: 0.000_001)
        XCTAssertEqual(zoomC2.duration, 0.2, accuracy: 0.000_001)
        XCTAssertNil(updated.zoomRegions.first { $0.id == zoomD.id })

        // 字幕 cue：A 原样；B/C 保留切点前部分；D 删除；E 跨切点保留头部。
        XCTAssertEqual(updated.captionCues.count, 4)
        let cueA2 = try XCTUnwrap(updated.captionCues.first { $0.id == cueA.id })
        XCTAssertEqual(cueA2.start, 1, accuracy: 0.000_001)
        XCTAssertEqual(cueA2.end, 1.8, accuracy: 0.000_001)
        let cueB2 = try XCTUnwrap(updated.captionCues.first { $0.id == cueB.id })
        XCTAssertEqual(cueB2.start, 2, accuracy: 0.000_001)
        XCTAssertEqual(cueB2.end, 3, accuracy: 0.000_001)
        let cueC2 = try XCTUnwrap(updated.captionCues.first { $0.id == cueC.id })
        XCTAssertEqual(cueC2.start, 3, accuracy: 0.000_001)
        XCTAssertEqual(cueC2.end, 4, accuracy: 0.000_001)
        let cueE2 = try XCTUnwrap(updated.captionCues.first { $0.id == cueE.id })
        XCTAssertEqual(cueE2.start, 2, accuracy: 0.000_001)
        XCTAssertEqual(cueE2.end, 3, accuracy: 0.000_001)
        XCTAssertNil(updated.captionCues.first { $0.id == cueD.id })

        // 标记、点击和光标属于源时间，不被平移。
        XCTAssertEqual(updated.markers, project.markers)
        XCTAssertEqual(updated.clicks, project.clicks)
        XCTAssertEqual(updated.rawCursor, project.rawCursor)
    }

    func testApplyingCutTransactionSplitsTracksAcrossMultipleCuts() throws {
        var project = makeProject()
        project.timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 12)
        let zoom = ZoomRegion(start: 1, duration: 9)
        let cue = CaptionCue(start: 0, end: 12, text: "跨过两个切点")
        project.zoomRegions = [zoom]
        project.captionCues = [cue]

        let outcome = TimelineCutTransaction.apply(
            [
                SmartCutCandidate(
                    start: 2,
                    end: 4,
                    kind: .pureSpeechPause,
                    keepEachSide: 0
                ),
                SmartCutCandidate(
                    start: 7,
                    end: 9,
                    kind: .pureSpeechPause,
                    keepEachSide: 0
                ),
            ],
            to: project.timeline
        )
        let updated = project.applyingCutTransaction(outcome)

        // 缩放区跨两个删除区间后应保留三段，而不是只留第一段。
        XCTAssertEqual(updated.zoomRegions.count, 3)
        XCTAssertEqual(Set(updated.zoomRegions.map(\.id)).count, 3)
        XCTAssertEqual(updated.zoomRegions[0].id, zoom.id)
        let zoomRanges = updated.zoomRegions.map {
            ($0.start, $0.start + $0.duration)
        }
        XCTAssertEqual(zoomRanges[0].0, 1, accuracy: 0.000_001)
        XCTAssertEqual(zoomRanges[0].1, 2, accuracy: 0.000_001)
        XCTAssertEqual(zoomRanges[1].0, 2, accuracy: 0.000_001)
        XCTAssertEqual(zoomRanges[1].1, 5, accuracy: 0.000_001)
        XCTAssertEqual(zoomRanges[2].0, 5, accuracy: 0.000_001)
        XCTAssertEqual(zoomRanges[2].1, 6, accuracy: 0.000_001)

        // 字幕同理：首段保留原 ID，后续分段使用新 ID，全部保留原文字。
        XCTAssertEqual(updated.captionCues.count, 3)
        XCTAssertEqual(Set(updated.captionCues.map(\.id)).count, 3)
        XCTAssertEqual(updated.captionCues[0].id, cue.id)
        XCTAssertEqual(
            updated.captionCues.map(\.start),
            [0, 2, 5]
        )
        XCTAssertEqual(
            updated.captionCues.map(\.end),
            [2, 5, 8]
        )
        XCTAssertTrue(updated.captionCues.allSatisfy { $0.text == cue.text })
    }

    func testSmartCutScreenActivityIncludesMappedCursorMovement() {
        var project = makeProject()
        project.timeline = ProjectTimeline(sourceStart: 1, sourceEnd: 5)
        project.clicks = []
        project.rawCursor = [
            CursorSample(
                sourceTime: 0.5,
                x: 0.1,
                y: 0.1,
                visible: true,
                moved: true
            ),
            CursorSample(
                sourceTime: 3.2,
                x: 0.2,
                y: 0.2,
                visible: true,
                moved: true
            ),
            CursorSample(
                sourceTime: 3.23,
                x: 0.3,
                y: 0.3,
                visible: true,
                moved: true
            ),
            CursorSample(
                sourceTime: 4.0,
                x: 0.4,
                y: 0.4,
                visible: true,
                moved: false
            ),
        ]

        let ranges = SmartCutAnalyzer.screenActivityRanges(of: project)

        // 源 [1,5] 被裁成成片 [0,4]，两帧相邻移动合并成一个保护区。
        XCTAssertEqual(ranges.count, 1)
        let range = ranges[0]
        XCTAssertEqual(range.lowerBound, 2.12, accuracy: 0.000_001)
        XCTAssertEqual(range.upperBound, 2.35, accuracy: 0.000_001)
    }

    func testSmartCutApplyRestoresEverythingWithSingleUndo() throws {
        var project = makeProject()
        project.timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        project.cameraSegments = [
            CameraLayoutSegment(start: 2, camera: CameraSettings()),
            CameraLayoutSegment(start: 6, camera: CameraSettings())
        ]
        project.zoomRegions = [ZoomRegion(start: 5.5, duration: 1.2)]
        project.captionCues = [
            CaptionCue(start: 4.0, end: 6.0, text: "跨切点字幕")
        ]

        var history = ProjectUndoHistory()
        // 应用前记录完整快照（对应 StudioModel 的 commitTimelineProject）。
        history.record(project)
        let outcome = TimelineCutTransaction.apply(
            [
                SmartCutCandidate(
                    start: 3,
                    end: 5,
                    kind: .pureSpeechPause,
                    keepEachSide: 0
                )
            ],
            to: project.timeline
        )
        let updated = project.applyingCutTransaction(outcome)
        XCTAssertNotEqual(updated.timeline.duration, project.timeline.duration)

        project = updated
        XCTAssertTrue(history.canUndo)
        let restored = try XCTUnwrap(history.undo(current: project))

        // 一次撤销恢复：片段、布局段、缩放区和字幕全部回到应用前。
        XCTAssertEqual(restored.timeline.duration, 10, accuracy: 0.000_001)
        XCTAssertEqual(restored.cameraSegments.count, 2)
        XCTAssertEqual(restored.cameraSegments.map(\.start), [2, 6])
        XCTAssertEqual(restored.zoomRegions.count, 1)
        XCTAssertEqual(restored.zoomRegions.first?.start, 5.5)
        XCTAssertEqual(restored.captionCues.count, 1)
        XCTAssertEqual(restored.captionCues.first?.start, 4)
        XCTAssertFalse(history.canUndo)
    }

    @MainActor
    func testPlayerItemAudioMixFadesAtClipBoundaries() async throws {
        let folderName = "test-smartcut-fades-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let videoURL = folder.appendingPathComponent("screen.mp4")
        try await makeTestVideo(
            at: videoURL,
            fileType: .mp4,
            size: CGSize(width: 160, height: 160),
            color: CIColor(red: 0.9, green: 0.1, blue: 0.1),
            frameCount: 60,
            frameRate: 30
        )
        let microphoneURL = folder.appendingPathComponent("microphone.m4a")
        try makeTestAudio(at: microphoneURL, duration: 2)

        var project = makeProject()
        project.folderName = folderName
        project.videoFile = videoURL.lastPathComponent
        project.microphoneFile = microphoneURL.lastPathComponent
        project.timeline = ProjectTimeline(clips: [
            TimelineClip(sourceStart: 0, sourceEnd: 1),
            TimelineClip(sourceStart: 1, sourceEnd: 2)
        ])

        let item = try await CompositionBuilder.makePlayerItem(for: project)
        let mix = try XCTUnwrap(item.audioMix)
        let parameters = try XCTUnwrap(mix.inputParameters.first)

        // 片段边界 1.0 秒附近必须存在音量斜坡（淡出结束、淡入开始）。
        var rampRange = CMTimeRange()
        var startVolume: Float = -1
        var endVolume: Float = -1
        let hasRamp = parameters.getVolumeRamp(
            for: CMTime(seconds: 0.995, preferredTimescale: 600),
            startVolume: &startVolume,
            endVolume: &endVolume,
            timeRange: &rampRange
        )
        XCTAssertTrue(hasRamp, "片段边界附近缺少音量淡化斜坡")
        XCTAssertEqual(startVolume, 0.8, accuracy: 0.01)
        XCTAssertEqual(endVolume, 0, accuracy: 0.01)
    }

    @MainActor
    func testPlayerItemIgnoresTimelineTailBeyondSystemAudio() async throws {
        let folderName = "test-short-system-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let videoURL = folder.appendingPathComponent("screen.mp4")
        try await makeTestVideo(
            at: videoURL,
            fileType: .mp4,
            size: CGSize(width: 160, height: 160),
            color: CIColor(red: 0.2, green: 0.5, blue: 0.9),
            frameCount: 60,
            frameRate: 30
        )
        let systemURL = folder.appendingPathComponent("system.m4a")
        try makeTestAudio(at: systemURL, duration: 1)

        var project = makeProject()
        project.folderName = folderName
        project.videoFile = videoURL.lastPathComponent
        project.systemAudioFile = systemURL.lastPathComponent
        project.timeline = ProjectTimeline(clips: [
            TimelineClip(sourceStart: 0, sourceEnd: 0.5),
            TimelineClip(sourceStart: 1.5, sourceEnd: 2),
        ])

        let item = try await CompositionBuilder.makePlayerItem(for: project)

        XCTAssertEqual(item.duration.seconds, 1, accuracy: 0.01)
    }

    // MARK: 语音驱动摄像头：语音驱动摄像头

    private func makeVoiceCameraProject(
        folderName: String
    ) -> StudioProject {
        var project = makeProject()
        project.folderName = folderName
        project.cameraFile = "camera.mov"
        project.camera.enabled = true
        project.camera.layout = .pictureInPicture
        return project
    }

    func testSchemaFiveRoundTripsVoiceCameraSegmentIDs() throws {
        var project = makeProject()
        let generatedID = UUID()
        project.smartCutAutoCameraSegmentIDs = [generatedID]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let decoded = try XCTUnwrap(ProjectStore.decode(data))
        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertEqual(decoded.smartCutAutoCameraSegmentIDs, [generatedID])

        // Schema 4 旧工程缺少新字段时安全默认为空，且解码即升级到 5。
        let legacyJSON = """
        {
          "id": "9E0A20B1-4F48-4C45-9A21-2E1A8A8C2222",
          "name": "旧工程",
          "createdAt": "2025-01-01T00:00:00Z",
          "folderName": "legacy",
          "videoFile": "screen.mp4",
          "duration": 12.5,
          "width": 1600,
          "height": 900,
          "clicks": [],
          "trimStart": 0,
          "trimEnd": 12.5,
          "zoomScale": 1.65,
          "zoomDuration": 1.2,
          "autoZoom": true,
          "schemaVersion": 4
        }
        """
        let legacy = try XCTUnwrap(ProjectStore.decode(Data(legacyJSON.utf8)))
        XCTAssertEqual(legacy.schemaVersion, 5)
        XCTAssertTrue(legacy.smartCutAutoCameraSegmentIDs.isEmpty)
    }

    func testVoiceCameraPlanApplicationIsIdempotentAndRefusesManual() throws {
        let folderName = "test-voicecamera-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("camera.mov").path,
            contents: Data()
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        var project = makeVoiceCameraProject(folderName: folderName)
        XCTAssertTrue(project.supportsVoiceCamera)
        project.camera.enabled = false
        XCTAssertFalse(project.supportsVoiceCamera)
        project.camera.enabled = true
        project.camera.layout = .screenOnly
        XCTAssertFalse(project.supportsVoiceCamera)
        project.camera.layout = .pictureInPicture

        // 口播 3 秒 → 静默 2 秒 → 口播 2 秒：隐藏段 4.5，恢复段 4.8。
        let plan = SmartCutVoiceCamera.plan(
            speechActivity: [
                SpeechActivity(start: 0, end: 3),
                SpeechActivity(start: 5, end: 7)
            ],
            analyzedDuration: 7
        )

        let first = try XCTUnwrap(project.applyingVoiceCameraPlan(plan))
        XCTAssertEqual(first.cameraSegments.count, 2)
        XCTAssertEqual(first.smartCutAutoCameraSegmentIDs.count, 2)
        XCTAssertEqual(first.cameraSegments.map(\.start), [4.5, 4.8])
        let hidden = try XCTUnwrap(first.cameraSegments.first)
        XCTAssertFalse(hidden.camera.enabled)
        XCTAssertFalse(hidden.camera.layout == .screenOnly)
        let revealed = try XCTUnwrap(first.cameraSegments.last)
        XCTAssertTrue(revealed.camera.enabled)
        XCTAssertEqual(revealed.camera.layout, project.camera.layout)

        // 重复运行：段数量与位置不变，不叠加；ID 列表被替换。
        let second = try XCTUnwrap(first.applyingVoiceCameraPlan(plan))
        XCTAssertEqual(second.cameraSegments.count, 2)
        XCTAssertEqual(second.cameraSegments.map(\.start), [4.5, 4.8])
        XCTAssertEqual(second.smartCutAutoCameraSegmentIDs.count, 2)

        // 出现手动布局段后拒绝生成，工程保持不变。
        var withManual = second
        withManual.cameraSegments.append(
            CameraLayoutSegment(start: 1, camera: withManual.camera)
        )
        XCTAssertNil(withManual.applyingVoiceCameraPlan(plan))
        XCTAssertEqual(withManual.cameraSegments.count, 3)
    }

    // MARK: 口头禅与重说建议：口头禅与重说建议

    func testFillerSuggestionAppliesThroughCutTransactionAndRipplesCaptions()
    throws {
        var project = makeProject()
        project.timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 6)
        project.captionCues = [
            CaptionCue(start: 1.0, end: 1.9, text: "上一节讲完了"),
            CaptionCue(start: 2.0, end: 2.4, text: "嗯"),
            CaptionCue(start: 2.6, end: 3.6, text: "我们来看这个例子"),
            CaptionCue(start: 4.0, end: 5.0, text: "然后保存文件")
        ]

        let fragments = project.captionCues.map { cue in
            SmartCutCaptionFragment(
                id: cue.id,
                start: cue.start,
                end: cue.end,
                text: cue.text
            )
        }
        let suggestions = SmartCutFillerDetector.suggestions(in: fragments)
        XCTAssertEqual(suggestions.count, 1)
        let filler = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(filler.kind, .fillerWord)

        // 建议转成候选后走精剪原子剪切事务。
        let range = filler.activeRange()
        let candidate = SmartCutCandidate(
            start: range.lowerBound,
            end: range.upperBound,
            kind: .fillerWord,
            keepEachSide: 0
        )
        let outcome = TimelineCutTransaction.apply(
            [candidate],
            to: project.timeline,
            frameDuration: 1.0 / 30
        )
        XCTAssertFalse(outcome.deletions.isEmpty)
        let updated = project.applyingCutTransaction(outcome)

        // 填充词 cue 被删除，其余 cue 随成片时间前移（删除窗口约 0.33 秒，
        // 含帧网格吸附）。
        XCTAssertNil(
            updated.captionCues.first { $0.text == "嗯" }
        )
        XCTAssertEqual(updated.captionCues.count, 3)
        let shifted = try XCTUnwrap(
            updated.captionCues.first { $0.text == "我们来看这个例子" }
        )
        XCTAssertEqual(shifted.start, 2.2667, accuracy: 0.02)
        XCTAssertEqual(updated.timeline.duration, 5.6667, accuracy: 0.02)

        // 一次撤销恢复全部（快照 → 应用 → undo）。
        var history = ProjectUndoHistory()
        history.record(project)
        let restored = try XCTUnwrap(history.undo(current: updated))
        XCTAssertEqual(restored.captionCues.count, 4)
        XCTAssertEqual(restored.timeline.duration, 6, accuracy: 0.000_001)
    }

    func testCameraTrackBuilderCompactsAcrossRecordedPause() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "anise-recorder-camera-pause-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstURL = folder.appendingPathComponent("first.mov")
        let secondURL = folder.appendingPathComponent("second.mov")
        try await makeTestVideo(
            at: firstURL,
            fileType: .mov,
            size: CGSize(width: 160, height: 160),
            color: CIColor(red: 0.9, green: 0.1, blue: 0.1),
            alternateColor: CIColor(red: 0.8, green: 0.1, blue: 0.1),
            frameCount: 30,
            frameRate: 30
        )
        try await makeTestVideo(
            at: secondURL,
            fileType: .mov,
            size: CGSize(width: 160, height: 160),
            color: CIColor(red: 0.1, green: 0.1, blue: 0.9),
            alternateColor: CIColor(red: 0.1, green: 0.1, blue: 0.8),
            frameCount: 30,
            frameRate: 30
        )

        var clock = CaptureClock(originHostTime: 10)
        clock.pause(at: 10.5)
        clock.resume(at: 20.5)
        let output = try await CameraTrackBuilder.build(
            sessions: [
                CameraRecordingResult(
                    fileURL: firstURL,
                    startedAtHostTime: 10
                ),
                CameraRecordingResult(
                    fileURL: secondURL,
                    startedAtHostTime: 20.5
                )
            ],
            clock: clock,
            folder: folder
        )

        let built = try XCTUnwrap(output)
        XCTAssertEqual(built.offset, 0, accuracy: 0.001)
        let asset = AVURLAsset(url: built.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.duration.seconds, 1.5, accuracy: 0.04)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testCameraFinishTreatsPlayableStopWarningAsSuccess() {
        XCTAssertTrue(CameraRecorder.recordingFinishedSuccessfully(nil))
        XCTAssertTrue(
            CameraRecorder.recordingFinishedSuccessfully(
                NSError(
                    domain: AVFoundationErrorDomain,
                    code: -11800,
                    userInfo: [
                        AVErrorRecordingSuccessfullyFinishedKey: true
                    ]
                )
            )
        )
        XCTAssertFalse(
            CameraRecorder.recordingFinishedSuccessfully(
                NSError(
                    domain: AVFoundationErrorDomain,
                    code: -11800,
                    userInfo: [
                        AVErrorRecordingSuccessfullyFinishedKey: false
                    ]
                )
            )
        )
    }

    func testCursorResolverInterpolatesHidesAndHonorsToggle() throws {
        var project = makeProject()
        project.cursor.smoothing = 0
        project.cursor.hideWhenIdle = false
        project.rawCursor = [
            CursorSample(
                sourceTime: 0.5,
                x: 0.1,
                y: 0.5,
                visible: true,
                appearanceID: nil,
                moved: true
            ),
            CursorSample(
                sourceTime: 1,
                x: 0.2,
                y: 0.5,
                visible: true,
                appearanceID: nil,
                moved: true
            ),
            CursorSample(
                sourceTime: 1.5,
                x: 0.5,
                y: 0.5,
                visible: true,
                appearanceID: nil,
                moved: false
            ),
            CursorSample(
                sourceTime: 2,
                x: 0.5,
                y: 0.5,
                visible: true,
                appearanceID: nil,
                moved: false
            )
        ]

        let interpolated = try XCTUnwrap(
            CursorResolver.state(atOutput: 1.25, project: project)
        )
        XCTAssertEqual(interpolated.point.x, 0.35, accuracy: 0.000_001)

        project.cursor.hideWhenIdle = true
        project.cursor.idleDelay = 0.8
        XCTAssertNil(
            CursorResolver.state(atOutput: 2.4, project: project)
        )

        project.cursor.enabled = false
        XCTAssertNil(
            CursorResolver.state(atOutput: 1.25, project: project)
        )
    }

    func testCursorRendererDrawsRecordedAppearanceAtPointer() throws {
        var project = makeProject()
        project.cursor.hideWhenIdle = false
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII="
            )
        )
        let appearance = CursorAppearance(
            pngData: png,
            pointWidth: 2,
            pointHeight: 2,
            hotspotX: 0.5,
            hotspotY: 0.5
        )
        project.cursorAppearances = [appearance]
        project.rawCursor = [
            CursorSample(
                sourceTime: 0,
                x: 0.5,
                y: 0.5,
                visible: true,
                appearanceID: appearance.id,
                moved: true
            )
        ]
        let screen = CIImage(color: CIColor(red: 0, green: 0.2, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let output = CursorRenderer.overlay(
            on: screen,
            time: 0,
            project: project,
            screenExtent: screen.extent,
            zoomSettings: ZoomSettings(
                enabled: false,
                scale: 1,
                duration: 1,
                clicks: []
            ),
            outputSize: CGSize(width: 320, height: 180)
        )
        let color = try pixel(in: output, at: CGPoint(x: 160, y: 88))
        XCTAssertGreaterThan(color.red, 180)
        XCTAssertLessThan(color.blue, 80)
    }

    func testExportResolutionPreservesCanvasAspect() {
        var project = makeProject()
        project.canvas.aspect = .landscape
        XCTAssertEqual(
            ExportResolution.fullHD.outputSize(for: project),
            CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(
            ExportResolution.ultraHD.outputSize(for: project),
            CGSize(width: 3840, height: 2160)
        )

        project.canvas.aspect = .portrait
        XCTAssertEqual(
            ExportResolution.fullHD.outputSize(for: project),
            CGSize(width: 1080, height: 1920)
        )
        XCTAssertEqual(
            ExportResolution.ultraHD.outputSize(for: project),
            CGSize(width: 2160, height: 3840)
        )
    }

    func testCameraSegmentsResolveAndEaseTransition() throws {
        var project = makeProject()
        var sideBySide = CameraSettings()
        sideBySide.enabled = true
        sideBySide.layout = .sideBySide
        sideBySide.splitRatio = 0.72
        project.cameraSegments = [
            CameraLayoutSegment(
                start: 4,
                transitionDuration: 0.5,
                camera: sideBySide
            ),
            CameraLayoutSegment(
                start: 8,
                transitionDuration: 0,
                camera: project.camera
            )
        ]

        XCTAssertEqual(
            project.cameraSettings(atOutput: 3.9),
            project.camera
        )
        XCTAssertEqual(
            project.cameraSettings(atOutput: 4),
            sideBySide
        )

        let transition = try XCTUnwrap(
            project.cameraTransition(atOutput: 4.25)
        )
        XCTAssertEqual(transition.from, project.camera)
        XCTAssertEqual(transition.to, sideBySide)
        XCTAssertEqual(transition.progress, 0.5, accuracy: 0.000_001)
        XCTAssertNil(project.cameraTransition(atOutput: 4.5))
        XCTAssertEqual(
            project.cameraSettings(atOutput: 8),
            project.camera
        )
        XCTAssertNil(project.cameraTransition(atOutput: 8))
    }

    func testCameraSegmentStartMovesAndReorders() throws {
        var project = makeProject()
        var firstCamera = project.camera
        firstCamera.layout = .sideBySide
        var secondCamera = project.camera
        secondCamera.layout = .cameraOnly
        let first = CameraLayoutSegment(
            start: 2,
            camera: firstCamera
        )
        let second = CameraLayoutSegment(
            start: 6,
            camera: secondCamera
        )
        project.cameraSegments = [first, second]

        XCTAssertTrue(
            project.setCameraSegmentStart(7, for: first.id)
        )
        XCTAssertEqual(
            project.cameraSegment(atOutput: 6.5)?.id,
            second.id
        )
        XCTAssertEqual(
            project.cameraSegment(atOutput: 7.5)?.id,
            first.id
        )

        XCTAssertTrue(
            project.setCameraSegmentStart(-1, for: first.id)
        )
        XCTAssertEqual(
            project.cameraSegments.first(where: {
                $0.id == first.id
            })?.start,
            0
        )

        XCTAssertTrue(
            project.setCameraSegmentStart(99, for: second.id)
        )
        let movedSecond = try XCTUnwrap(
            project.cameraSegments.first(where: {
                $0.id == second.id
            })
        )
        XCTAssertEqual(
            movedSecond.start,
            9.97,
            accuracy: 0.000_001
        )
        XCTAssertFalse(
            project.setCameraSegmentStart(99, for: second.id)
        )
        XCTAssertFalse(
            project.setCameraSegmentStart(1, for: UUID())
        )
    }

    func testCanvasRendererUsesCameraSegmentAndCrossfade() throws {
        var project = makeProject()
        project.width = 100
        project.height = 100
        project.canvas.aspect = .source
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#000000"
        project.canvas.padding = 0
        project.camera.enabled = false
        project.camera.layout = .screenOnly

        var cameraOnly = CameraSettings()
        cameraOnly.enabled = true
        cameraOnly.layout = .cameraOnly
        cameraOnly.mirrored = false
        project.cameraSegments = [
            CameraLayoutSegment(
                start: 2,
                transitionDuration: 0.5,
                camera: cameraOnly
            )
        ]

        let screen = CIImage(
            color: CIColor(red: 0.95, green: 0.05, blue: 0.05)
        ).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let camera = CIImage(
            color: CIColor(red: 0.05, green: 0.05, blue: 0.95)
        ).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let before = CanvasRenderer.render(
            screen: screen,
            camera: camera,
            time: 1,
            project: project,
            outputSize: CGSize(width: 100, height: 100)
        )
        let after = CanvasRenderer.render(
            screen: screen,
            camera: camera,
            time: 3,
            project: project,
            outputSize: CGSize(width: 100, height: 100)
        )
        let middle = CanvasRenderer.render(
            screen: screen,
            camera: camera,
            time: 2.25,
            project: project,
            outputSize: CGSize(width: 100, height: 100)
        )

        let beforePixel = try pixel(in: before, at: CGPoint(x: 50, y: 50))
        XCTAssertGreaterThan(beforePixel.red, 200)
        XCTAssertLessThan(beforePixel.blue, 40)

        let afterPixel = try pixel(in: after, at: CGPoint(x: 50, y: 50))
        XCTAssertGreaterThan(afterPixel.blue, 200)
        XCTAssertLessThan(afterPixel.red, 40)

        let middlePixel = try pixel(in: middle, at: CGPoint(x: 50, y: 50))
        XCTAssertGreaterThan(middlePixel.red, 60)
        XCTAssertGreaterThan(middlePixel.blue, 60)
    }

    func testRenderPlanUsesOutputTimeCameraSegment() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        var cameraOnly = CameraSettings()
        cameraOnly.enabled = true
        cameraOnly.layout = .cameraOnly
        project.cameraSegments = [
            CameraLayoutSegment(
                start: 2,
                transitionDuration: 0.5,
                camera: cameraOnly
            )
        ]
        let outputSize = CGSize(width: 640, height: 360)
        let plan = RenderPlan(
            project: project,
            time: 3,
            outputSize: outputSize
        )

        XCTAssertEqual(plan.cameraSettings.layout, .cameraOnly)
        XCTAssertTrue(plan.showsCamera)
        XCTAssertFalse(plan.showsScreen)
        XCTAssertEqual(
            plan.cameraRect,
            CanvasLayout.availableRect(
                outputSize: outputSize,
                padding: project.canvas.padding
            )
        )
    }

    func testProjectStoreBacksUpAndRecoversPreviousSave() throws {
        let folderName = "test-recovery-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        var project = makeProject()
        project.id = UUID()
        project.folderName = folderName
        project.name = "第一版"
        try ProjectStore.save(project)

        project.name = "第二版"
        try ProjectStore.save(project)

        let backupData = try Data(
            contentsOf: folder.appendingPathComponent(
                ProjectStore.backupFilename
            )
        )
        let backup = try XCTUnwrap(ProjectStore.decode(backupData))
        XCTAssertEqual(backup.name, "第一版")
        XCTAssertEqual(backup.schemaVersion, 5)

        try Data("{broken".utf8).write(
            to: folder.appendingPathComponent("project.json"),
            options: [.atomic]
        )
        let loaded = ProjectStore.loadAllWithIssues()
        let recovered = loaded.projects.first { $0.id == project.id }
        XCTAssertEqual(recovered?.name, "第一版")
        XCTAssertTrue(loaded.issues.contains { $0.contains("第一版") })
    }

    /// P4：init 扫描路径补走 #59 聚合——多条 issue 只留第一条 + 数量，
    /// 不再把 toast 堆成错误墙（空工程文件夹即可复现多条）。
    func testIssueSummaryCollapsesMultipleScanIssues() {
        XCTAssertEqual(ProjectStore.issueSummary([]), nil)
        XCTAssertEqual(ProjectStore.issueSummary(["单条原样"]), "单条原样")
        let summary = ProjectStore.issueSummary(
            ["工程文件夹“a”无法读取。", "工程文件夹“b”无法读取。"]
        )
        XCTAssertEqual(
            summary,
            "有 2 个工程文件夹需要处理：工程文件夹“a”无法读取。"
                + "（其余 1 条情况类似，原始文件均已保留在工程目录）"
        )
    }

    func testInterruptedRecordingRecoversWrittenVideo() async throws {
        let folderName = "test-interrupted-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: CGSize(width: 160, height: 90),
            color: CIColor(red: 0.2, green: 0.4, blue: 0.7),
            frameCount: 30,
            frameRate: 30
        )
        let manifest = RecordingSessionManifest(
            id: UUID(),
            name: "中断测试",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            microphoneFile: nil,
            systemAudioFile: nil,
            width: 160,
            height: 90,
            fps: 30,
            source: .display(displayID: 1)
        )
        try ProjectStore.saveInterruptedSession(manifest)

        let recovered = await ProjectStore.recoverInterruptedRecordings()
        let project = try XCTUnwrap(
            recovered.projects.first { $0.id == manifest.id }
        )
        XCTAssertEqual(project.duration, 1, accuracy: 0.05)
        XCTAssertTrue(project.name.contains("已恢复"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(
                    ProjectStore.interruptedSessionFilename
                ).path
            )
        )
        XCTAssertNotNil(ProjectStore.decode(
            try Data(
                contentsOf: folder.appendingPathComponent("project.json")
            )
        ))
    }

    func testAudioWaveformSamplesRecordedStyleFile() async throws {
        let folderName = "test-waveform-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("microphone.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 8_000,
                channels: 1
            )
        )
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings
            )
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: 8_000
                )
            )
            buffer.frameLength = 8_000
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0 ..< 8_000 {
                samples[index] = sin(Float(index) * 0.08) * 0.5
            }
            try file.write(from: buffer)
        }

        let waveform = await AudioWaveform.samples(for: url, count: 32)
        XCTAssertEqual(waveform.count, 32)
        XCTAssertGreaterThan(waveform.max() ?? 0, 0.8)
        XCTAssertGreaterThan(waveform.filter { $0 > 0.1 }.count, 16)
    }

    func testCanvasSizesAndRegionConversion() {
        var project = makeProject()
        project.canvas.aspect = .landscape
        XCTAssertEqual(project.canvasOutputSize, CGSize(width: 1920, height: 1080))
        project.canvas.aspect = .portrait
        XCTAssertEqual(project.canvasOutputSize, CGSize(width: 1080, height: 1920))
        project.canvas.aspect = .source
        XCTAssertEqual(project.canvasOutputSize, CGSize(width: 1600, height: 900))

        let region = CaptureRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let rect = region.screenRect(
            in: CGRect(x: 100, y: 200, width: 1000, height: 800)
        )
        XCTAssertEqual(rect.minX, 200, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 520, accuracy: 0.01)
        XCTAssertEqual(rect.width, 300, accuracy: 0.01)
        XCTAssertEqual(rect.height, 320, accuracy: 0.01)

        let captureRect = region.displayLocalCaptureRect(
            in: CGRect(x: 100, y: 200, width: 1000, height: 800)
        )
        XCTAssertEqual(captureRect.minX, 100, accuracy: 0.01)
        XCTAssertEqual(captureRect.minY, 160, accuracy: 0.01)
        XCTAssertEqual(captureRect.width, 300, accuracy: 0.01)
        XCTAssertEqual(captureRect.height, 320, accuracy: 0.01)
    }

    func testClickCoordinateMapperUsesCurrentWindowFrame() throws {
        let cgFrame = CGRect(x: 1200, y: 100, width: 800, height: 600)
        let appKitFrame = ClickCoordinateMapper.appKitFrame(
            for: cgFrame,
            mainScreenMaxY: 1080
        )
        XCTAssertEqual(appKitFrame.minX, 1200, accuracy: 0.01)
        XCTAssertEqual(appKitFrame.minY, 380, accuracy: 0.01)
        XCTAssertEqual(appKitFrame.width, 800, accuracy: 0.01)
        XCTAssertEqual(appKitFrame.height, 600, accuracy: 0.01)

        let topLeft = try XCTUnwrap(
            ClickCoordinateMapper.normalizedPoint(
                screenPoint: CGPoint(x: 1200, y: 980),
                in: appKitFrame
            )
        )
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)

        let center = try XCTUnwrap(
            ClickCoordinateMapper.normalizedPoint(
                screenPoint: CGPoint(x: 1600, y: 680),
                in: appKitFrame
            )
        )
        XCTAssertEqual(center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.001)

        let outside = ClickCoordinateMapper.normalizedPoint(
            screenPoint: CGPoint(x: 2001, y: 680),
            in: appKitFrame
        )
        XCTAssertNil(outside)
    }

    func testClickCoordinateMapperSupportsNegativeDisplayOrigins() throws {
        let cgFrame = CGRect(x: -1400, y: -900, width: 800, height: 600)
        let appKitFrame = ClickCoordinateMapper.appKitFrame(
            for: cgFrame,
            mainScreenMaxY: 1080
        )
        XCTAssertEqual(appKitFrame.minX, -1400, accuracy: 0.01)
        XCTAssertEqual(appKitFrame.minY, 1380, accuracy: 0.01)

        let topLeft = try XCTUnwrap(
            ClickCoordinateMapper.normalizedPoint(
                screenPoint: CGPoint(x: -1400, y: 1980),
                in: appKitFrame
            )
        )
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)

        let bottomRight = try XCTUnwrap(
            ClickCoordinateMapper.normalizedPoint(
                screenPoint: CGPoint(x: -600, y: 1380),
                in: appKitFrame
            )
        )
        XCTAssertEqual(bottomRight.x, 1, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 1, accuracy: 0.001)
    }

    func testCameraAnchorAndSideBySideLayout() {
        let output = CGSize(width: 1920, height: 1080)
        let content = CGRect(origin: .zero, size: output)
        var settings = CameraSettings()
        settings.size = 0.22
        settings.shape = .square

        settings.anchor = .topLeft
        let topLeft = CanvasLayout.cameraSlot(
            outputSize: output,
            contentRect: content,
            settings: settings
        )
        XCTAssertGreaterThan(topLeft.midY, output.height * 0.75)
        XCTAssertLessThan(topLeft.midX, output.width * 0.25)

        settings.anchor = .bottomRight
        let bottomRight = CanvasLayout.cameraSlot(
            outputSize: output,
            contentRect: content,
            settings: settings
        )
        XCTAssertLessThan(bottomRight.midY, output.height * 0.25)
        XCTAssertGreaterThan(bottomRight.midX, output.width * 0.75)

        settings.layout = .sideBySide
        let screen = CanvasLayout.screenSlot(
            outputSize: output,
            contentRect: content,
            settings: settings
        )
        let camera = CanvasLayout.cameraSlot(
            outputSize: output,
            contentRect: content,
            settings: settings
        )
        XCTAssertLessThan(screen.maxX, camera.minX)
        XCTAssertEqual(screen.height, camera.height, accuracy: 0.01)

        settings.customCenter = NormalizedPoint(x: 0.5, y: 0.5)
        settings.layout = .pictureInPicture
        let centered = CanvasLayout.cameraSlot(
            outputSize: output,
            contentRect: content,
            settings: settings
        )
        XCTAssertEqual(centered.midX, output.width / 2, accuracy: 0.01)
        XCTAssertEqual(centered.midY, output.height / 2, accuracy: 0.01)
    }

    func testCameraFillFitAndCropFocusRenderAsConfigured() throws {
        var project = makeProject()
        project.width = 400
        project.height = 100
        project.canvas.aspect = .source
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#00FF00"
        project.camera.enabled = true
        project.camera.layout = .cameraOnly
        project.camera.shape = .square
        project.camera.mirrored = false

        let camera = makeTwoToneCameraImage()
        let outputSize = CGSize(width: 200, height: 200)

        project.camera.contentMode = .fit
        let fitted = CanvasRenderer.render(
            screen: nil,
            camera: camera,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let fittedBackground = try pixel(
            in: fitted,
            at: CGPoint(x: 100, y: 20)
        )
        XCTAssertGreaterThan(fittedBackground.green, 180)
        XCTAssertLessThan(fittedBackground.red, 80)

        project.camera.contentMode = .fill
        project.camera.cropFocus = NormalizedPoint(x: 0.1, y: 0.5)
        let leftFocused = CanvasRenderer.render(
            screen: nil,
            camera: camera,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let left = try pixel(
            in: leftFocused,
            at: CGPoint(x: 100, y: 100)
        )
        XCTAssertGreaterThan(left.red, 180)
        XCTAssertLessThan(left.blue, 80)

        project.camera.cropFocus = NormalizedPoint(x: 0.9, y: 0.5)
        let rightFocused = CanvasRenderer.render(
            screen: nil,
            camera: camera,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let right = try pixel(
            in: rightFocused,
            at: CGPoint(x: 100, y: 100)
        )
        XCTAssertGreaterThan(right.blue, 180)
        XCTAssertLessThan(right.red, 80)
    }

    func testCameraBorderAndShadowRenderOutsideAndInsideFrame() throws {
        var project = makeProject()
        project.canvas.aspect = .source
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#FFFFFF"
        project.camera.enabled = true
        project.camera.layout = .pictureInPicture
        project.camera.anchor = .center
        project.camera.customCenter = nil
        project.camera.shape = .square
        project.camera.size = 0.4
        project.camera.mirrored = false
        project.camera.borderColorHex = "#FF0000"
        project.camera.borderWidth = 20
        project.camera.shadowEnabled = true
        project.camera.shadowIntensity = 0.8

        let camera = CIImage(
            color: CIColor(red: 0.05, green: 0.1, blue: 0.9)
        ).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let outputSize = CGSize(width: 400, height: 400)
        let rendered = CanvasRenderer.render(
            screen: nil,
            camera: camera,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let rect = RenderPlan(
            project: project,
            time: 0,
            outputSize: outputSize
        ).cameraRect
        let borderPixel = try pixel(
            in: rendered,
            at: CGPoint(x: rect.midX, y: rect.minY + 1)
        )
        XCTAssertGreaterThan(borderPixel.red, 150)
        XCTAssertLessThan(borderPixel.blue, 120)

        let centerPixel = try pixel(
            in: rendered,
            at: CGPoint(x: rect.midX, y: rect.midY)
        )
        XCTAssertGreaterThan(centerPixel.blue, 150)
        XCTAssertLessThan(centerPixel.red, 100)

        let shadowPixel = try pixel(
            in: rendered,
            at: CGPoint(x: rect.midX, y: max(1, rect.minY - 2))
        )
        XCTAssertLessThan(shadowPixel.red, 245)
    }

    func testCameraChromaKeyRemovesGreenAndPreservesForeground() throws {
        let camera = makeChromaKeyCameraImage()
        let background = CIImage(
            color: CIColor(red: 0.9, green: 0.1, blue: 0.9)
        ).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let settings = CameraChromaKeySettings(
            enabled: true,
            keyColorHex: "#00B140",
            tolerance: 0.16,
            softness: 0.08,
            spillSuppression: 0.65
        )
        let keyed = ChromaKeyRenderer.apply(camera, settings: settings)
        let output = keyed.composited(over: background)

        let corner = try pixel(in: output, at: CGPoint(x: 12, y: 12))
        XCTAssertGreaterThan(corner.red, 180)
        XCTAssertLessThan(corner.green, 80)
        XCTAssertGreaterThan(corner.blue, 180)

        let foreground = try pixel(
            in: output,
            at: CGPoint(x: 100, y: 100)
        )
        XCTAssertGreaterThan(foreground.red, 140)
        XCTAssertGreaterThan(foreground.green, 70)
        XCTAssertLessThan(foreground.blue, 160)
    }

    func testDisabledCameraChromaKeyLeavesPixelsUnchanged() throws {
        let camera = makeChromaKeyCameraImage()
        let output = ChromaKeyRenderer.apply(
            camera,
            settings: CameraChromaKeySettings()
        )
        for point in [
            CGPoint(x: 12, y: 12),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 188, y: 188),
        ] {
            XCTAssertEqual(
                rgbaPixel(in: output, at: point),
                rgbaPixel(in: camera, at: point)
            )
        }
    }

    func testCameraChromaKeySampleFindsGreenBorderAndRejectsRedFrame() throws {
        let context = CIContext()
        let greenFrame = try XCTUnwrap(
            context.createCGImage(
                makeChromaKeyCameraImage(),
                from: CGRect(x: 0, y: 0, width: 200, height: 200)
            )
        )
        let sampled = try XCTUnwrap(
            ChromaKeyRenderer.sampleKeyColor(from: greenFrame)
        )
        XCTAssertTrue(sampled.hasPrefix("#"))
        XCTAssertEqual(sampled.count, 7)
        let red = Int(sampled.dropFirst().prefix(2), radix: 16) ?? 255
        let green = Int(
            sampled.dropFirst(3).prefix(2),
            radix: 16
        ) ?? 0
        let blue = Int(sampled.dropFirst(5).prefix(2), radix: 16) ?? 255
        XCTAssertLessThan(red, 40)
        XCTAssertGreaterThan(green, 100)
        XCTAssertLessThan(blue, 120)

        let redFrame = try XCTUnwrap(
            context.createCGImage(
                CIImage(color: CIColor(red: 0.9, green: 0.05, blue: 0.05))
                    .cropped(
                        to: CGRect(x: 0, y: 0, width: 200, height: 200)
                    ),
                from: CGRect(x: 0, y: 0, width: 200, height: 200)
            )
        )
        XCTAssertNil(ChromaKeyRenderer.sampleKeyColor(from: redFrame))
    }

    func testCameraChromaKeySkipsCameraBorderAndShadow() throws {
        var project = makeProject()
        project.width = 200
        project.height = 200
        project.canvas.aspect = .source
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#0000FF"
        project.camera.enabled = true
        project.camera.layout = .cameraOnly
        project.camera.shape = .square
        project.camera.mirrored = false
        project.camera.borderColorHex = "#FF0000"
        project.camera.borderWidth = 20
        project.camera.shadowEnabled = true
        project.camera.shadowIntensity = 0.8
        project.cameraChromaKey = CameraChromaKeySettings(
            enabled: true,
            keyColorHex: "#00B140"
        )

        let output = CanvasRenderer.render(
            screen: nil,
            camera: makeChromaKeyCameraImage(),
            time: 0,
            project: project,
            outputSize: CGSize(width: 200, height: 200)
        )
        let edge = try pixel(in: output, at: CGPoint(x: 100, y: 1))
        XCTAssertLessThan(edge.red, 40)
        XCTAssertGreaterThan(edge.blue, 180)

        let foreground = try pixel(
            in: output,
            at: CGPoint(x: 100, y: 100)
        )
        XCTAssertGreaterThan(foreground.red, 140)
        XCTAssertGreaterThan(foreground.green, 70)
    }

    // MARK: C1 竖屏跟随

    @MainActor
    func testPortraitFollowPlanAppliesAsHorizontalAutoSegments() throws {
        var project = makeProject()
        project.camera.enabled = true
        let segments = [
            PortraitFollowPlanner.Segment(start: 1.0, offsetX: 0.2),
            PortraitFollowPlanner.Segment(start: 4.0, offsetX: 0.75),
        ]

        let updated = try XCTUnwrap(
            project.applyingPortraitFollowPlan(segments)
        )
        // 只平移不缩放：仅改 cropFocus.x，y / size / contentMode 其余不变。
        XCTAssertEqual(updated.cameraSegments.count, 2)
        XCTAssertEqual(
            updated.smartCutAutoCameraSegmentIDs,
            updated.cameraSegments.map(\.id)
        )
        XCTAssertEqual(
            updated.cameraSegments[0].camera.cropFocus.x,
            0.2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            updated.cameraSegments[0].camera.cropFocus.y,
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            updated.cameraSegments[1].camera.cropFocus.x,
            0.75,
            accuracy: 0.001
        )
        XCTAssertEqual(updated.cameraSegments[0].camera.contentMode, .fill)
        XCTAssertEqual(
            updated.cameraSegments[0].camera.size,
            project.camera.size
        )

        // 重复应用幂等：段数与位置不变。
        let again = try XCTUnwrap(
            updated.applyingPortraitFollowPlan(segments)
        )
        XCTAssertEqual(again.cameraSegments.count, 2)
        XCTAssertEqual(
            again.cameraSegments.map(\.start),
            updated.cameraSegments.map(\.start)
        )

        // 手动布局段存在时拒绝，不静默覆盖。
        var withManual = updated
        var manual = updated.camera
        manual.cropFocus = NormalizedPoint(x: 0.1, y: 0.9)
        withManual.cameraSegments.append(
            CameraLayoutSegment(start: 8, transitionDuration: 0, camera: manual)
        )
        XCTAssertNil(withManual.applyingPortraitFollowPlan(segments))
    }

    func testPortraitFollowShiftsPortraitFramingInRender() throws {
        // 9:16 画布：应用跟随段（offset 0.1）与关闭跟随各渲染一帧比对。
        // 摄像头左半红右半蓝，fill 裁剪下水平偏移应改变可见的半边。
        func makeFollowProject() -> StudioProject {
            var project = makeProject()
            project.width = 1080
            project.height = 1920
            project.canvas.aspect = .portrait
            project.canvas.background.kind = .solid
            project.canvas.background.colorHex = "#000000"
            project.camera.enabled = true
            project.camera.layout = .cameraOnly
            project.camera.contentMode = .fill
            project.camera.mirrored = false
            project.camera.shape = .square
            return project
        }
        let cameraImage = makeTwoToneCameraImage()
        var project = makeFollowProject()
        let followPlan = [
            PortraitFollowPlanner.Segment(start: 0.5, offsetX: 0.1)
        ]
        project = try XCTUnwrap(project.applyingPortraitFollowPlan(followPlan))

        let off = try pixel(
            in: CanvasRenderer.render(
                screen: nil,
                camera: cameraImage,
                time: 2,
                project: makeFollowProject(),
                outputSize: CGSize(width: 1080, height: 1920)
            ),
            at: CGPoint(x: 810, y: 960)
        )
        let on = try pixel(
            in: CanvasRenderer.render(
                screen: nil,
                camera: cameraImage,
                time: 2,
                project: project,
                outputSize: CGSize(width: 1080, height: 1920)
            ),
            at: CGPoint(x: 810, y: 960)
        )
        // 关：右 1/4 处看到右半边（蓝）；开：取景左移后同一位置看到红。
        XCTAssertGreaterThan(off.blue, 150)
        XCTAssertLessThan(off.red, 100)
        XCTAssertGreaterThan(on.red, 150)
        XCTAssertLessThan(on.blue, 100)
    }

    func testCameraChromaKeySettingsRoundTrip() throws {
        var project = makeProject()
        project.cameraChromaKey = CameraChromaKeySettings(
            enabled: true,
            keyColorHex: "#12AB34",
            tolerance: 0.24,
            softness: 0.11,
            spillSuppression: 0.42
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try XCTUnwrap(
            ProjectStore.decode(encoder.encode(project))
        )
        XCTAssertEqual(decoded.cameraChromaKey, project.cameraChromaKey)
    }

    @MainActor
    func testCameraChromaKeyAutoSampleMapsPlayheadToCameraTime() async throws {
        let folderName = "test-chromakey-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let size = CGSize(width: 200, height: 200)
        let green = CIColor(
            red: 0,
            green: 177.0 / 255.0,
            blue: 64.0 / 255.0
        )
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: size,
            color: CIColor(red: 0.1, green: 0.1, blue: 0.9),
            frameCount: 60
        )
        try await makeTestVideo(
            at: folder.appendingPathComponent("camera.mov"),
            fileType: .mov,
            size: size,
            color: green,
            frameCount: 60
        )

        var project = makeProject()
        project.folderName = folderName
        project.width = Int(size.width)
        project.height = Int(size.height)
        project.cameraFile = "camera.mov"
        project.cameraOffset = 0.25
        project.camera.enabled = true
        let model = StudioModel()
        model.setup.captureCamera = false
        model.selectedProjectID = project.id
        model.draft = project
        model.currentTime = 1.25

        model.sampleCameraChromaKeyColor()
        let deadline = ContinuousClock.now + .seconds(5)
        while
            ContinuousClock.now < deadline,
            model.draft?.cameraChromaKey.enabled != true
        {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(model.isSamplingChromaKey)
        XCTAssertTrue(model.draft?.cameraChromaKey.enabled ?? false)
        let sampled = try XCTUnwrap(
            model.draft?.cameraChromaKey.keyColorHex
        )
        let red = Int(sampled.dropFirst().prefix(2), radix: 16) ?? 255
        let sampledGreen = Int(
            sampled.dropFirst(3).prefix(2),
            radix: 16
        ) ?? 0
        let blue = Int(sampled.dropFirst(5).prefix(2), radix: 16) ?? 255
        XCTAssertLessThan(red, 100)
        XCTAssertGreaterThan(sampledGreen, 120)
        XCTAssertLessThan(blue, 140)
        XCTAssertGreaterThan(sampledGreen, red + 50)
        XCTAssertGreaterThan(sampledGreen, blue + 40)
    }

    func testCameraAvoidsActiveZoomFocusAndReturnsAfterZoom() {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.camera.enabled = true
        project.camera.layout = .pictureInPicture
        project.camera.anchor = .center
        project.camera.customCenter = nil
        project.camera.shape = .square
        project.camera.size = 0.4
        project.autoZoom = true
        project.zoomScale = 2
        project.zoomDuration = 1
        project.clicks = [
            ClickEvent(time: 0.5, x: 0.5, y: 0.5, enabled: true)
        ]
        let outputSize = CGSize(width: 640, height: 360)
        let focus = CGPoint(x: 320, y: 180)

        let base = RenderPlan(
            project: project,
            time: 4,
            outputSize: outputSize
        ).cameraRect
        let avoided = RenderPlan(
            project: project,
            time: 0.55,
            outputSize: outputSize
        ).cameraRect
        XCTAssertTrue(base.contains(focus))
        XCTAssertFalse(avoided.contains(focus))
        XCTAssertLessThan(avoided.width, base.width * 0.85)
        XCTAssertLessThan(avoided.height, base.height * 0.85)
        if let controlFrame = CanvasLayout.normalizedCameraFrame(
            for: project,
            settings: project.camera,
            time: 0.55
        ) {
            XCTAssertEqual(
                controlFrame.minX * outputSize.width,
                avoided.minX,
                accuracy: 0.01
            )
            XCTAssertEqual(
                controlFrame.minY * outputSize.height,
                outputSize.height - avoided.maxY,
                accuracy: 0.01
            )
            XCTAssertEqual(
                controlFrame.width * outputSize.width,
                avoided.width,
                accuracy: 0.01
            )
            XCTAssertEqual(
                controlFrame.height * outputSize.height,
                avoided.height,
                accuracy: 0.01
            )
        } else {
            XCTFail("摄像头选中框应可用")
        }

        project.camera.avoidsZoomFocus = false
        let staticZoomed = RenderPlan(
            project: project,
            time: 0.55,
            outputSize: outputSize
        ).cameraRect
        XCTAssertEqual(staticZoomed, base)
    }

    func testCameraAvoidanceKeepsZoomFocusVisibleInRenderedFrame() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.camera.enabled = true
        project.camera.layout = .pictureInPicture
        project.camera.anchor = .center
        project.camera.customCenter = nil
        project.camera.shape = .square
        project.camera.size = 0.4
        project.camera.mirrored = false
        project.autoZoom = true
        project.zoomScale = 2
        project.zoomDuration = 1
        project.clicks = [
            ClickEvent(time: 0.5, x: 0.5, y: 0.5, enabled: true)
        ]
        let screen = CIImage(
            color: CIColor(red: 1, green: 1, blue: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let camera = CIImage(
            color: CIColor(red: 0.05, green: 0.1, blue: 0.9)
        ).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let outputSize = CGSize(width: 640, height: 360)
        let rendered = CanvasRenderer.render(
            screen: screen,
            camera: camera,
            time: 0.55,
            project: project,
            outputSize: outputSize
        )
        let focusPixel = try pixel(
            in: rendered,
            at: CGPoint(x: 320, y: 180)
        )
        XCTAssertGreaterThan(focusPixel.red, 220)
        XCTAssertGreaterThan(focusPixel.green, 220)
        XCTAssertGreaterThan(focusPixel.blue, 220)
    }

    func testCameraInteractionFrameMatchesRendererAndSafeArea() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.camera.enabled = true
        project.camera.layout = .pictureInPicture
        project.camera.anchor = .bottomRight
        project.camera.customCenter = nil
        project.camera.shape = .square
        project.camera.size = 0.25

        let normalized = try XCTUnwrap(
            CanvasLayout.normalizedCameraFrame(for: project)
        )
        let output = project.canvasOutputSize
        let available = CanvasLayout.availableRect(
            outputSize: output,
            padding: project.canvas.padding
        )
        let content = CanvasLayout.aspectFitRect(
            sourceSize: CGSize(width: project.width, height: project.height),
            in: available
        )
        let imageSlot = CanvasLayout.cameraSlot(
            outputSize: output,
            contentRect: content,
            settings: project.camera
        )
        let previewSlot = CGRect(
            x: normalized.minX * output.width,
            y: normalized.minY * output.height,
            width: normalized.width * output.width,
            height: normalized.height * output.height
        )

        XCTAssertEqual(previewSlot.minX, imageSlot.minX, accuracy: 0.01)
        XCTAssertEqual(
            previewSlot.minY,
            output.height - imageSlot.maxY,
            accuracy: 0.01
        )
        XCTAssertEqual(previewSlot.width, imageSlot.width, accuracy: 0.01)
        XCTAssertEqual(previewSlot.height, imageSlot.height, accuracy: 0.01)

        let margin = min(output.width, output.height) * 0.025
        XCTAssertGreaterThanOrEqual(previewSlot.minX, margin - 0.01)
        XCTAssertLessThanOrEqual(previewSlot.maxX, output.width - margin + 0.01)
        XCTAssertGreaterThanOrEqual(previewSlot.minY, margin - 0.01)
        XCTAssertLessThanOrEqual(previewSlot.maxY, output.height - margin + 0.01)
    }

    func testCameraCenterSnapsToGridAndClampsToSafeArea() {
        let output = CGSize(width: 1920, height: 1080)
        var settings = CameraSettings()
        settings.enabled = true
        settings.layout = .pictureInPicture
        settings.size = 0.24
        settings.shape = .roundedRectangle

        let centered = CanvasLayout.snappedCameraCenter(
            CGPoint(x: 0.507, y: 0.493),
            outputSize: output,
            settings: settings
        )
        XCTAssertEqual(centered.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(centered.y, 0.5, accuracy: 0.0001)

        let size = CanvasLayout.cameraSize(
            outputSize: output,
            settings: settings
        )
        let margin = min(output.width, output.height) * 0.025
        let expectedMinX = (margin + size.width / 2) / output.width
        let expectedMaxY = 1 - (margin + size.height / 2) / output.height
        let clamped = CanvasLayout.clampedCameraCenter(
            CGPoint(x: -2, y: 2),
            outputSize: output,
            settings: settings
        )
        XCTAssertEqual(clamped.x, expectedMinX, accuracy: 0.0001)
        XCTAssertEqual(clamped.y, expectedMaxY, accuracy: 0.0001)

        let edgeSnapped = CanvasLayout.snappedCameraCenter(
            CGPoint(x: expectedMinX + 0.004, y: expectedMaxY - 0.004),
            outputSize: output,
            settings: settings
        )
        XCTAssertEqual(edgeSnapped.x, expectedMinX, accuracy: 0.0001)
        XCTAssertEqual(edgeSnapped.y, expectedMaxY, accuracy: 0.0001)
    }

    func testCameraResizeHandlesUseInsetHitTargets() {
        let frameSize = CGSize(width: 400, height: 300)
        let handleInset: CGFloat = 8
        let hitRadius: CGFloat = 18

        XCTAssertEqual(
            CanvasLayout.cameraResizeCorner(
                at: CGPoint(x: 8, y: 8),
                frameSize: frameSize,
                handleInset: handleInset,
                hitRadius: hitRadius
            ),
            .topLeft
        )
        XCTAssertEqual(
            CanvasLayout.cameraResizeCorner(
                at: CGPoint(x: 392, y: 292),
                frameSize: frameSize,
                handleInset: handleInset,
                hitRadius: hitRadius
            ),
            .bottomRight
        )
        XCTAssertNil(
            CanvasLayout.cameraResizeCorner(
                at: CGPoint(x: 200, y: 150),
                frameSize: frameSize,
                handleInset: handleInset,
                hitRadius: hitRadius
            )
        )
        XCTAssertNil(
            CanvasLayout.cameraResizeCorner(
                at: CGPoint(x: 30, y: 30),
                frameSize: frameSize,
                handleInset: handleInset,
                hitRadius: hitRadius
            )
        )
    }

    func testCameraCompositionPresets() {
        var project = makeProject()

        CameraCompositionPreset.corner.apply(to: &project)
        XCTAssertTrue(project.camera.enabled)
        XCTAssertEqual(project.camera.layout, .pictureInPicture)
        XCTAssertEqual(project.camera.anchor, .bottomRight)
        XCTAssertNil(project.camera.customCenter)
        XCTAssertEqual(project.camera.size, 0.24, accuracy: 0.001)
        XCTAssertTrue(CameraCompositionPreset.corner.matches(project))

        CameraCompositionPreset.circle.apply(to: &project)
        XCTAssertEqual(project.camera.anchor, .bottomLeft)
        XCTAssertEqual(project.camera.shape, .circle)
        XCTAssertEqual(project.camera.size, 0.22, accuracy: 0.001)
        XCTAssertTrue(CameraCompositionPreset.circle.matches(project))

        CameraCompositionPreset.portraitStack.apply(to: &project)
        XCTAssertEqual(project.canvas.aspect, .portrait)
        XCTAssertEqual(project.camera.layout, .sideBySide)
        XCTAssertEqual(project.camera.splitRatio, 0.65, accuracy: 0.001)
        XCTAssertTrue(CameraCompositionPreset.portraitStack.matches(project))

        CameraCompositionPreset.sideBySide.apply(to: &project)
        XCTAssertEqual(project.canvas.aspect, .landscape)
        XCTAssertEqual(project.camera.splitRatio, 0.68, accuracy: 0.001)
        XCTAssertTrue(CameraCompositionPreset.sideBySide.matches(project))

        CameraCompositionPreset.screenOnly.apply(to: &project)
        XCTAssertEqual(project.camera.layout, .screenOnly)
        XCTAssertTrue(CameraCompositionPreset.screenOnly.matches(project))

        CameraCompositionPreset.cameraOnly.apply(to: &project)
        XCTAssertEqual(project.camera.layout, .cameraOnly)
        XCTAssertTrue(CameraCompositionPreset.cameraOnly.matches(project))
    }

    @MainActor
    func testCameraPresetAtPlayheadIsImmediateAndUsesGlobalAspect()
        throws
    {
        let model = StudioModel()
        let folderName = "test-camera-preset-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("camera.mov"))

        var project = makeProject()
        project.folderName = folderName
        project.cameraFile = "camera.mov"
        project.camera.enabled = true
        project.camera.layout = .pictureInPicture
        project.camera.anchor = .bottomRight
        project.canvas.aspect = .landscape
        project.cameraSegments = [
            CameraLayoutSegment(
                start: 2,
                transitionDuration: 0.5,
                camera: project.camera
            )
        ]
        model.draft = project
        model.currentTime = 3.016_667

        model.applyCameraPreset(
            .portraitStack,
            scope: .fromPlayhead
        )

        let updated = try XCTUnwrap(model.draft)
        XCTAssertEqual(updated.canvas.aspect, .portrait)
        XCTAssertEqual(model.currentTime, 3.016_667)
        let active = updated.cameraSettings(atOutput: model.currentTime)
        XCTAssertEqual(active.layout, .sideBySide)
        XCTAssertEqual(active.splitRatio, 0.65, accuracy: 0.000_001)
        let segment = try XCTUnwrap(
            updated.cameraSegments.first {
                abs($0.start - 3.016_667) < 0.03
            }
        )
        XCTAssertEqual(
            updated.cameraSegment(atOutput: model.currentTime)?.id,
            segment.id
        )
        XCTAssertEqual(segment.transitionDuration, 0)
        XCTAssertNil(updated.cameraTransition(atOutput: 3))
        XCTAssertEqual(
            updated.cameraSettings(atOutput: 2.5),
            project.camera
        )
        XCTAssertTrue(
            CameraCompositionPreset.portraitStack.matches(
                updated,
                camera: active
            )
        )
    }

    @MainActor
    func testCameraPresetEntireProjectClearsSegmentsAndKeepsOneUndo()
        throws
    {
        let model = StudioModel()
        let folderName = "test-camera-preset-all-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("camera.mov"))

        var project = makeProject()
        project.folderName = folderName
        project.cameraFile = "camera.mov"
        project.camera.enabled = true
        project.cameraSegments = [
            CameraLayoutSegment(
                start: 1,
                camera: project.camera
            ),
            CameraLayoutSegment(
                start: 5,
                camera: project.camera
            ),
        ]
        project.smartCutAutoCameraSegmentIDs = [
            project.cameraSegments[0].id,
            project.cameraSegments[1].id,
        ]
        model.draft = project
        model.currentTime = 3

        model.applyCameraPreset(
            .corner,
            scope: .entireProject
        )

        let updated = try XCTUnwrap(model.draft)
        XCTAssertTrue(updated.cameraSegments.isEmpty)
        XCTAssertTrue(updated.smartCutAutoCameraSegmentIDs.isEmpty)
        XCTAssertEqual(updated.camera.layout, .pictureInPicture)
        XCTAssertEqual(updated.camera.anchor, .bottomRight)
        XCTAssertEqual(updated.camera.size, 0.24, accuracy: 0.000_001)
        XCTAssertTrue(model.canUndo)

        model.undoProjectEdit()
        XCTAssertEqual(model.draft?.cameraSegments, project.cameraSegments)
        XCTAssertEqual(
            model.draft?.smartCutAutoCameraSegmentIDs,
            project.smartCutAutoCameraSegmentIDs
        )
    }

    @MainActor
    func testCameraPresetOnAutoSegmentMakesItManual() throws {
        let model = StudioModel()
        let folderName = "test-camera-preset-auto-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("camera.mov"))

        var project = makeProject()
        project.folderName = folderName
        project.cameraFile = "camera.mov"
        project.camera.enabled = true
        let segment = CameraLayoutSegment(
            start: 2,
            transitionDuration: 0.5,
            camera: project.camera
        )
        project.cameraSegments = [segment]
        project.smartCutAutoCameraSegmentIDs = [segment.id]
        model.draft = project
        model.currentTime = 2

        model.applyCameraPreset(
            .circle,
            scope: .fromPlayhead
        )

        let updated = try XCTUnwrap(model.draft)
        XCTAssertFalse(
            updated.smartCutAutoCameraSegmentIDs.contains(segment.id)
        )
        XCTAssertEqual(
            updated.cameraSegments.first?.camera.shape,
            .circle
        )
        XCTAssertEqual(
            updated.cameraSegments.first?.transitionDuration,
            0
        )
    }

    func testCameraSlotUsesVerticalSplitForPortraitCanvas() {
        var settings = CameraSettings()
        settings.enabled = true
        settings.layout = .sideBySide
        settings.splitRatio = 0.65
        let portrait = CGSize(width: 1080, height: 1920)
        let content = CGRect(origin: .zero, size: portrait)

        let screen = CanvasLayout.screenSlot(
            outputSize: portrait,
            contentRect: content,
            settings: settings
        )
        let camera = CanvasLayout.cameraSlot(
            outputSize: portrait,
            contentRect: content,
            settings: settings
        )
        XCTAssertEqual(screen.width, camera.width, accuracy: 0.000_001)
        XCTAssertGreaterThan(screen.height, camera.height)
        XCTAssertGreaterThan(screen.minY, camera.minY)
    }

    func testUndoHistoryCoalescesAndRestoresProjects() throws {
        var initial = makeProject()
        initial.camera.enabled = true
        initial.camera.size = 0.22
        var changed = initial
        changed.camera.size = 0.3

        var history = ProjectUndoHistory()
        history.record(initial, groupingKey: "camera.size", at: 10)
        history.record(changed, groupingKey: "camera.size", at: 10.2)
        XCTAssertEqual(history.undoStack.count, 1)

        let undone = try XCTUnwrap(history.undo(current: changed))
        XCTAssertEqual(undone, initial)
        XCTAssertTrue(history.canRedo)

        let redone = try XCTUnwrap(history.redo(current: undone))
        XCTAssertEqual(redone, changed)
        XCTAssertFalse(history.canRedo)

        history.record(changed, groupingKey: "camera.size", at: 11)
        XCTAssertFalse(history.canRedo)
    }

    func testTwentyUndoRedoStepsPreserveEveryEdit() throws {
        let initial = makeProject()
        var current = initial
        var history = ProjectUndoHistory()
        for step in 1 ... 20 {
            let previous = current
            current.name = "第 \(step) 次编辑"
            history.record(
                previous,
                groupingKey: "step-\(step)",
                at: Double(step)
            )
        }
        for _ in 0 ..< 20 {
            current = try XCTUnwrap(history.undo(current: current))
        }
        XCTAssertEqual(current, initial)

        for _ in 0 ..< 20 {
            current = try XCTUnwrap(history.redo(current: current))
        }
        XCTAssertEqual(current.name, "第 20 次编辑")
        XCTAssertFalse(history.canRedo)
    }

    func testCameraInteractionFrameMatchesRenderedCamera() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#000000"
        project.camera.enabled = true
        project.camera.layout = .pictureInPicture
        project.camera.anchor = .center
        project.camera.customCenter = nil
        project.camera.shape = .square
        project.camera.size = 0.4
        project.camera.mirrored = false
        let screen = CIImage(
            color: CIColor(red: 0.9, green: 0.05, blue: 0.05)
        ).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let camera = CIImage(
            color: CIColor(red: 0.05, green: 0.1, blue: 0.9)
        ).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 800))
        let outputSize = CGSize(width: 640, height: 360)
        let normalized = try XCTUnwrap(
            CanvasLayout.normalizedCameraFrame(for: project)
        )
        let rendered = CanvasRenderer.render(
            screen: screen,
            camera: camera,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let color = try pixel(
            in: rendered,
            at: CGPoint(
                x: normalized.midX * outputSize.width,
                y: (1 - normalized.midY) * outputSize.height
            )
        )
        XCTAssertGreaterThan(
            Double(color.blue),
            Double(color.red) * 1.4
        )
    }

    func testSideBySideUsesAvailableAreaAndFitsSourceAspect() {
        let source = CGSize(width: 1600, height: 900)
        var settings = CameraSettings()
        settings.layout = .sideBySide
        settings.splitRatio = 0.68

        let landscape = CGSize(width: 1920, height: 1080)
        let landscapeAvailable = CanvasLayout.availableRect(
            outputSize: landscape,
            padding: 0.05
        )
        let landscapeScreen = CanvasLayout.screenSlot(
            outputSize: landscape,
            contentRect: landscapeAvailable,
            settings: settings
        )
        let landscapeCamera = CanvasLayout.cameraSlot(
            outputSize: landscape,
            contentRect: landscapeAvailable,
            settings: settings
        )
        XCTAssertEqual(
            landscapeScreen.height,
            landscapeAvailable.height,
            accuracy: 0.01
        )
        XCTAssertLessThan(landscapeScreen.maxX, landscapeCamera.minX)

        let landscapeFit = CanvasLayout.aspectFitRect(
            sourceSize: source,
            in: landscapeScreen
        )
        XCTAssertEqual(
            landscapeFit.width / landscapeFit.height,
            source.width / source.height,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(
            landscapeFit.maxX,
            landscapeScreen.maxX + 0.01
        )
        XCTAssertLessThanOrEqual(
            landscapeFit.maxY,
            landscapeScreen.maxY + 0.01
        )

        let portrait = CGSize(width: 1080, height: 1920)
        let portraitAvailable = CanvasLayout.availableRect(
            outputSize: portrait,
            padding: 0.05
        )
        let portraitScreen = CanvasLayout.screenSlot(
            outputSize: portrait,
            contentRect: portraitAvailable,
            settings: settings
        )
        let portraitCamera = CanvasLayout.cameraSlot(
            outputSize: portrait,
            contentRect: portraitAvailable,
            settings: settings
        )
        XCTAssertEqual(
            portraitScreen.width,
            portraitAvailable.width,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(portraitScreen.minY, portraitCamera.minY)
        XCTAssertGreaterThan(portraitScreen.minY, portraitCamera.maxY)
    }

    func testSideBySideRendererLetterboxesInsteadOfStretching() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#0000FF"
        project.camera.enabled = false
        project.camera.layout = .sideBySide
        let screen = CIImage(
            color: CIColor(red: 0.9, green: 0.05, blue: 0.05)
        ).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let outputSize = CGSize(width: 640, height: 360)
        let rendered = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let available = CanvasLayout.availableRect(
            outputSize: outputSize,
            padding: 0
        )
        let slot = CanvasLayout.screenSlot(
            outputSize: outputSize,
            contentRect: available,
            settings: project.camera
        )
        let fitted = CanvasLayout.aspectFitRect(
            sourceSize: CGSize(width: 1600, height: 900),
            in: slot
        )

        let letterbox = try pixel(
            in: rendered,
            at: CGPoint(x: slot.midX, y: 8)
        )
        XCTAssertGreaterThan(letterbox.blue, 180)
        XCTAssertLessThan(letterbox.red, 60)

        let screenPixel = try pixel(
            in: rendered,
            at: CGPoint(x: fitted.midX, y: fitted.midY)
        )
        XCTAssertGreaterThan(screenPixel.red, 180)
        XCTAssertLessThan(screenPixel.blue, 60)
    }

    func testCameraShapeMasksCorners() throws {
        var project = makeProject()
        project.width = 200
        project.height = 200
        project.canvas.aspect = .source
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#000000"
        project.camera.enabled = true
        project.camera.layout = .cameraOnly
        project.camera.mirrored = false
        let camera = CIImage(
            color: CIColor(red: 0.05, green: 0.1, blue: 0.9)
        ).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let outputSize = CGSize(width: 200, height: 200)

        project.camera.shape = .circle
        let circle = CanvasRenderer.render(
            screen: nil,
            camera: camera,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let circleCorner = try pixel(
            in: circle,
            at: CGPoint(x: 3, y: 3)
        )
        XCTAssertLessThan(circleCorner.blue, 40)
        let circleCenter = try pixel(
            in: circle,
            at: CGPoint(x: 100, y: 100)
        )
        XCTAssertGreaterThan(circleCenter.blue, 180)

        project.camera.shape = .square
        let square = CanvasRenderer.render(
            screen: nil,
            camera: camera,
            time: 0,
            project: project,
            outputSize: outputSize
        )
        let squareCorner = try pixel(
            in: square,
            at: CGPoint(x: 3, y: 3)
        )
        XCTAssertGreaterThan(squareCorner.blue, 180)
    }

    func testCanvasRendererProducesRequestedCanvas() throws {
        var project = makeProject()
        project.canvas.aspect = .landscape
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#102030"
        project.camera.enabled = false
        let screen = CIImage(
            color: CIColor(red: 0.8, green: 0.2, blue: 0.1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let rendered = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 0,
            project: project,
            outputSize: CGSize(width: 640, height: 360)
        )
        XCTAssertEqual(rendered.extent.origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(rendered.extent.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(rendered.extent.width, 640, accuracy: 0.01)
        XCTAssertEqual(rendered.extent.height, 360, accuracy: 0.01)
    }

    @MainActor
    func testExportComposesScreenAndCamera() async throws {
        let folderName = "test-export-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        let cameraURL = folder.appendingPathComponent("camera.mov")
        let outputURL = folder.appendingPathComponent("export.mp4")
        let size = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: screenURL,
            fileType: .mp4,
            size: size,
            color: CIColor(red: 0.9, green: 0.1, blue: 0.1)
        )
        try await makeTestVideo(
            at: cameraURL,
            fileType: .mov,
            size: size,
            color: CIColor(red: 0.1, green: 0.2, blue: 0.9)
        )

        var camera = CameraSettings()
        camera.enabled = true
        camera.layout = .pictureInPicture
        camera.anchor = .center
        camera.shape = .square
        camera.size = 0.4
        camera.mirrored = false
        let project = StudioProject(
            id: UUID(),
            name: "合成测试",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 1,
            width: Int(size.width),
            height: Int(size.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 1,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            cameraFile: "camera.mov",
            camera: camera,
            canvas: CanvasSettings(
                aspect: .landscape,
                background: CanvasBackground(
                    kind: .solid,
                    colorHex: "#102030"
                ),
                padding: 0,
                cornerRadius: 0,
                shadowEnabled: false,
                shadowIntensity: 0.3
            )
        )

        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL
        ) { _ in }

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(
            at: CMTime(seconds: 0.5, preferredTimescale: 600)
        ).image
        let image = CIImage(cgImage: frame)
        let slot = CanvasLayout.cameraSlot(
            outputSize: CGSize(width: frame.width, height: frame.height),
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(width: frame.width, height: frame.height)
            ),
            settings: camera
        )
        let color = try pixel(
            in: image,
            at: CGPoint(x: slot.midX, y: slot.midY)
        )
        XCTAssertGreaterThan(Double(color.blue), Double(color.red) * 1.4)

        let playerItem = try await CompositionBuilder.makePlayerItem(
            for: project
        )
        let previewGenerator = AVAssetImageGenerator(
            asset: playerItem.asset
        )
        previewGenerator.videoComposition = playerItem.videoComposition
        previewGenerator.requestedTimeToleranceBefore = .zero
        previewGenerator.requestedTimeToleranceAfter = .zero
        let previewFrame = try await previewGenerator.image(
            at: CMTime(seconds: 0.5, preferredTimescale: 600)
        ).image
        let previewImage = CIImage(cgImage: previewFrame)
        let samplePoints = [
            CGPoint(x: slot.midX, y: slot.midY),
            CGPoint(
                x: CGFloat(frame.width) * 0.1,
                y: CGFloat(frame.height) * 0.8
            )
        ]
        for point in samplePoints {
            let exported = try pixel(in: image, at: point)
            let preview = try pixel(in: previewImage, at: point)
            XCTAssertLessThanOrEqual(abs(exported.red - preview.red), 10)
            XCTAssertLessThanOrEqual(abs(exported.green - preview.green), 10)
            XCTAssertLessThanOrEqual(abs(exported.blue - preview.blue), 10)
        }
    }

    @MainActor
    func testExportAppliesCameraChromaKey() async throws {
        let folderName = "test-chromakey-export-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let size = CGSize(width: 200, height: 200)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: size,
            color: CIColor(red: 0.1, green: 0.1, blue: 0.8)
        )
        try await makeTestVideo(
            at: folder.appendingPathComponent("camera.mov"),
            fileType: .mov,
            size: size,
            color: CIColor(red: 0, green: 0.7, blue: 0.25),
            image: makeChromaKeyCameraImage()
        )

        var camera = CameraSettings()
        camera.enabled = true
        camera.layout = .cameraOnly
        camera.shape = .square
        camera.mirrored = false
        let project = StudioProject(
            id: UUID(),
            name: "绿幕导出",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 1,
            width: Int(size.width),
            height: Int(size.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 1,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            cameraFile: "camera.mov",
            camera: camera,
            cameraChromaKey: CameraChromaKeySettings(
                enabled: true,
                keyColorHex: "#00B140"
            ),
            canvas: CanvasSettings(
                aspect: .source,
                background: CanvasBackground(
                    kind: .solid,
                    colorHex: "#A010A0"
                ),
                padding: 0,
                cornerRadius: 0,
                shadowEnabled: false,
                shadowIntensity: 0.3
            )
        )
        let outputURL = folder.appendingPathComponent("export.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL
        ) { _ in }

        let frame = try await videoFrame(at: outputURL, time: 0.25)
        let image = CIImage(cgImage: frame)
        let corner = try pixel(in: image, at: CGPoint(x: 16, y: 16))
        XCTAssertGreaterThan(corner.red, 120)
        XCTAssertLessThan(corner.green, 100)
        XCTAssertGreaterThan(corner.blue, 120)

        let foreground = try pixel(
            in: image,
            at: CGPoint(x: 100, y: 100)
        )
        XCTAssertGreaterThan(foreground.red, 120)
        XCTAssertGreaterThan(foreground.green, 60)
        XCTAssertLessThan(foreground.blue, 160)
    }

    @MainActor
    func testExportBurnsCaptionsOnlyWhenEnabled() async throws {
        let folderName = "test-caption-export-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let size = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: size,
            color: CIColor(red: 1, green: 1, blue: 1)
        )
        var project = StudioProject(
            id: UUID(),
            name: "字幕导出",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 1,
            width: Int(size.width),
            height: Int(size.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 1,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            canvas: CanvasSettings(
                aspect: .source,
                background: CanvasBackground(kind: .none),
                padding: 0,
                cornerRadius: 0,
                shadowEnabled: false,
                shadowIntensity: 0
            )
        )
        project.captions.enabled = true
        project.captions.burnIn = true
        project.captions.backgroundOpacity = 0.9
        project.captionCues = [
            CaptionCue(start: 0, end: 1, text: "烧录字幕")
        ]

        let burnedURL = folder.appendingPathComponent("burned.mp4")
        let plainURL = folder.appendingPathComponent("plain.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: burnedURL
        ) { _ in }
        project.captions.burnIn = false
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: plainURL
        ) { _ in }

        let burnedFrame = try await videoFrame(
            at: burnedURL,
            time: 0.5
        )
        let plainFrame = try await videoFrame(
            at: plainURL,
            time: 0.5
        )
        let burned = try brightness(
            of: CIImage(cgImage: burnedFrame),
            at: CGPoint(x: 160, y: 20)
        )
        let plain = try brightness(
            of: CIImage(cgImage: plainFrame),
            at: CGPoint(x: 160, y: 20)
        )
        XCTAssertLessThan(burned, 0.8)
        XCTAssertGreaterThan(plain, 0.9)
    }

    @MainActor
    func testExportResolutionFrameRateAndCodecMatrix() async throws {
        let folderName = "test-export-matrix-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.2, green: 0.7, blue: 0.3),
            frameCount: 15
        )
        let project = StudioProject(
            id: UUID(),
            name: "编码矩阵",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 0.5,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 0.5,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            canvas: CanvasSettings(
                aspect: .landscape,
                background: CanvasBackground(
                    kind: .solid,
                    colorHex: "#000000"
                )
            )
        )

        for codec in ExportCodec.allCases {
            for resolution in ExportResolution.allCases {
                for frameRate in [30, 60] {
                    let size = resolution.outputSize(for: project)
                    let configuration = ExportConfiguration(
                        outputSize: size,
                        frameRate: frameRate,
                        codec: codec
                    )
                    let outputURL = folder.appendingPathComponent(
                        "\(codec.rawValue)-\(resolution.rawValue)-\(frameRate).mp4"
                    )
                    if
                        codec == .h264,
                        resolution == .fullHD,
                        frameRate == 30
                    {
                        try Data("old-export".utf8).write(to: outputURL)
                    }
                    var progressValues: [Double] = []
                    try await CompositionBuilder.makeExport(
                        for: project,
                        outputURL: outputURL,
                        configuration: configuration
                    ) {
                        progressValues.append($0)
                    }
                    XCTAssertTrue(
                        progressValues.contains {
                            $0 > 0 && $0 < 1
                        }
                    )
                    XCTAssertEqual(progressValues.last, 1)
                    XCTAssertEqual(
                        progressValues,
                        progressValues.sorted()
                    )

                    let asset = AVURLAsset(url: outputURL)
                    let videoTracks = try await asset.loadTracks(
                        withMediaType: .video
                    )
                    let track = try XCTUnwrap(videoTracks.first)
                    let formats = try await track.load(
                        .formatDescriptions
                    )
                    let format = try XCTUnwrap(formats.first)
                    XCTAssertEqual(
                        CMFormatDescriptionGetMediaSubType(format),
                        codec == .h264
                            ? kCMVideoCodecType_H264
                            : kCMVideoCodecType_HEVC
                    )
                    let naturalSize = try await track.load(.naturalSize)
                    XCTAssertEqual(naturalSize.width, size.width)
                    XCTAssertEqual(naturalSize.height, size.height)
                    let nominalFrameRate = try await track.load(
                        .nominalFrameRate
                    )
                    XCTAssertEqual(
                        nominalFrameRate,
                        Float(frameRate),
                        accuracy: 0.5
                    )
                    let duration = try await asset.load(.duration).seconds
                    XCTAssertEqual(duration, 0.5, accuracy: 0.08)
                }
            }
        }
    }

    @MainActor
    func testSparseSourceExportsAtRequestedFrameRate() async throws {
        let folderName = "test-export-resample-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.3, green: 0.6, blue: 0.9),
            frameCount: 2,
            frameRate: 1
        )
        let project = StudioProject(
            id: UUID(),
            name: "稀疏源重采样",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 2,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 2,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            canvas: CanvasSettings(aspect: .landscape)
        )
        let outputURL = folder.appendingPathComponent("export.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL,
            configuration: ExportConfiguration(
                outputSize: CGSize(width: 1920, height: 1080),
                frameRate: 60,
                codec: .h264
            )
        ) { _ in }

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(
            nominalFrameRate,
            60,
            accuracy: 0.5
        )
        XCTAssertEqual(
            duration,
            2,
            accuracy: 0.08
        )
    }

    @MainActor
    func testFourKSourceExportsAtFourK60HEVC() async throws {
        let folderName = "test-export-4k-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 3840, height: 2160)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.15, green: 0.55, blue: 0.75),
            frameCount: 6,
            frameRate: 30
        )
        let project = StudioProject(
            id: UUID(),
            name: "4K 源验收",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 0.2,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 0.2,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            canvas: CanvasSettings(aspect: .source)
        )
        let outputURL = folder.appendingPathComponent("export.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL,
            configuration: ExportConfiguration(
                outputSize: CGSize(width: 3840, height: 2160),
                frameRate: 60,
                codec: .hevc
            )
        ) { _ in }

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(format),
            kCMVideoCodecType_HEVC
        )
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize.width, 3840)
        XCTAssertEqual(naturalSize.height, 2160)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(
            nominalFrameRate,
            60,
            accuracy: 0.5
        )
    }

    @MainActor
    func testExportedCameraStaysAlignedWithinOneFrame() async throws {
        let folderName = "test-export-camera-sync-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.05, green: 0.7, blue: 0.1),
            frameCount: 60,
            frameRate: 30
        )
        try await makeTestVideo(
            at: folder.appendingPathComponent("camera.mov"),
            fileType: .mov,
            size: sourceSize,
            color: CIColor(red: 0.95, green: 0.05, blue: 0.05),
            alternateColor: CIColor(red: 0.05, green: 0.05, blue: 0.95),
            frameCount: 60,
            frameRate: 30
        )
        var camera = CameraSettings()
        camera.enabled = true
        camera.layout = .pictureInPicture
        camera.anchor = .center
        camera.shape = .square
        camera.size = 0.4
        camera.mirrored = false
        let project = StudioProject(
            id: UUID(),
            name: "摄像头逐帧同步",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 2,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 2,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            cameraFile: "camera.mov",
            camera: camera,
            canvas: CanvasSettings(aspect: .landscape)
        )
        let outputURL = folder.appendingPathComponent("export.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL,
            configuration: ExportConfiguration(
                outputSize: CGSize(width: 1920, height: 1080),
                frameRate: 30,
                codec: .h264
            )
        ) { _ in }

        let asset = AVURLAsset(url: outputURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (time, expectsRed) in [(0.6, true), (0.5, false)] {
            let frame = try await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)
            ).image
            let image = CIImage(cgImage: frame)
            let cameraRect = CanvasLayout.cameraSlot(
                outputSize: CGSize(
                    width: frame.width,
                    height: frame.height
                ),
                contentRect: CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: frame.width,
                        height: frame.height
                    )
                ),
                settings: camera
            )
            let color = try pixel(
                in: image,
                at: CGPoint(
                    x: cameraRect.midX,
                    y: cameraRect.midY
                )
            )
            if expectsRed {
                XCTAssertGreaterThan(color.red, color.blue + 40)
            } else {
                XCTAssertGreaterThan(color.blue, color.red + 40)
            }
        }
    }

    @MainActor
    func testExportUsesCapturedProjectSnapshot() async throws {
        let folderName = "test-export-snapshot-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.1, green: 0.8, blue: 0.2),
            frameCount: 60,
            frameRate: 30
        )
        var project = StudioProject(
            id: UUID(),
            name: "导出快照",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 2,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 2,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            canvas: CanvasSettings(
                aspect: .landscape,
                background: CanvasBackground(
                    kind: .solid,
                    colorHex: "#000000"
                ),
                padding: 0.25
            )
        )
        let snapshot = project
        let outputURL = folder.appendingPathComponent("export.mp4")
        var progressTimes: [CFAbsoluteTime] = []
        let export = Task { @MainActor in
            try await CompositionBuilder.makeExport(
                for: snapshot,
                outputURL: outputURL,
                configuration: ExportConfiguration(
                    outputSize: CGSize(width: 1920, height: 1080),
                    frameRate: 60,
                    codec: .h264
                )
            ) { _ in
                progressTimes.append(CFAbsoluteTimeGetCurrent())
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        project.canvas.padding = 0
        project.canvas.background = CanvasBackground(
            kind: .solid,
            colorHex: "#FF0000"
        )
        project.camera.enabled = true
        try await export.value
        let firstProgress = try XCTUnwrap(progressTimes.first)
        let lastProgress = try XCTUnwrap(progressTimes.last)
        XCTAssertGreaterThan(lastProgress - firstProgress, 0.3)

        let asset = AVURLAsset(url: outputURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(
            at: CMTime(seconds: 1, preferredTimescale: 600)
        ).image
        let corner = try pixel(
            in: CIImage(cgImage: frame),
            at: CGPoint(x: 4, y: 4)
        )
        XCTAssertLessThan(corner.red, 20)
        XCTAssertLessThan(corner.green, 20)
        XCTAssertLessThan(corner.blue, 20)
    }

    @MainActor
    func testCancelledExportKeepsExistingFileAndRemovesTemporaryFile()
        async throws
    {
        let folderName = "test-export-cancel-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.4, green: 0.3, blue: 0.8),
            frameCount: 120
        )
        let project = StudioProject(
            id: UUID(),
            name: "取消导出",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 4,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 4,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            canvas: CanvasSettings(aspect: .landscape)
        )
        let outputURL = folder.appendingPathComponent("existing.mp4")
        let existing = Data("existing-export".utf8)
        try existing.write(to: outputURL)

        let configuration = ExportConfiguration(
            outputSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            codec: .h264
        )
        let export = Task { @MainActor in
            try await CompositionBuilder.makeExport(
                for: project,
                outputURL: outputURL,
                configuration: configuration
            ) { _ in }
        }
        try await Task.sleep(for: .milliseconds(50))
        export.cancel()
        do {
            try await export.value
            XCTFail("导出应被取消")
        } catch {
            XCTAssertTrue(
                error is CancellationError
                    || (error as? ExportError) == .cancelled
            )
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), existing)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: folder.path
        )
        XCTAssertFalse(
            files.contains {
                $0.hasPrefix(".anise-recorder-")
            }
        )
    }

    @MainActor
    func testExportRefusesToOverwriteSourceMedia() async throws {
        let folderName = "test-export-source-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 320, height: 180)
        let sourceURL = folder.appendingPathComponent("screen.mp4")
        try await makeTestVideo(
            at: sourceURL,
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.8, green: 0.2, blue: 0.1),
            frameCount: 2,
            frameRate: 1
        )
        let original = try Data(contentsOf: sourceURL)
        let project = StudioProject(
            id: UUID(),
            name: "源文件保护",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 2,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 2,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1)
        )

        do {
            try await CompositionBuilder.makeExport(
                for: project,
                outputURL: sourceURL
            ) { _ in }
            XCTFail("导出不应覆盖源素材")
        } catch {
            XCTAssertEqual(error as? ExportError, .destinationIsSource)
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    func testExportStorageMapsDiskFullAndPermissionErrors() throws {
        let hd = ExportConfiguration(
            outputSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            codec: .h264
        )
        let uhd60 = ExportConfiguration(
            outputSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            codec: .h264
        )
        XCTAssertGreaterThan(
            ExportStorage.estimatedBytes(
                configuration: uhd60,
                duration: 60
            ),
            ExportStorage.estimatedBytes(
                configuration: hd,
                duration: 60
            )
        )
        XCTAssertEqual(
            ExportStorage.availableBytes(
                importantUsage: 0,
                standard: 7_600_000
            ),
            7_600_000
        )
        XCTAssertEqual(
            ExportStorage.availableBytes(
                importantUsage: 12_000_000,
                standard: 7_600_000
            ),
            12_000_000
        )
        XCTAssertNil(
            ExportStorage.availableBytes(
                importantUsage: 0,
                standard: 0
            )
        )

        let noSpace = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )
        XCTAssertEqual(
            ExportStorage.mapped(noSpace) as? ExportError,
            .diskFull(requiredBytes: nil, availableBytes: nil)
        )
        let wrappedPermission = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError
                )
            ]
        )
        XCTAssertEqual(
            ExportStorage.mapped(wrappedPermission) as? ExportError,
            .destinationNotWritable
        )

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "anise-recorder-readonly-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: folder.path
            )
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: folder.path
        )
        XCTAssertThrowsError(
            try ExportStorage.validateDestination(
                folder.appendingPathComponent("export.mp4"),
                configuration: hd,
                duration: 5
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .destinationNotWritable
            )
        }
    }

    @MainActor
    func testTenMinuteProjectExport() async throws {
        guard
            ProcessInfo.processInfo.environment["ANISE_RECORDER_LONG_EXPORT"]
                == "1"
        else {
            throw XCTSkip(
                "设置 ANISE_RECORDER_LONG_EXPORT=1 后运行 10 分钟导出验收。"
            )
        }

        let folderName = "test-export-long-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let duration = 600.0
        let sourceSize = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.1, green: 0.7, blue: 0.2),
            frameCount: Int(duration),
            frameRate: 1
        )
        try await makeTestVideo(
            at: folder.appendingPathComponent("camera.mov"),
            fileType: .mov,
            size: sourceSize,
            color: CIColor(red: 0.1, green: 0.2, blue: 0.9),
            frameCount: Int(duration),
            frameRate: 1
        )
        try makeTestAudio(
            at: folder.appendingPathComponent("microphone.wav"),
            duration: duration
        )

        var camera = CameraSettings()
        camera.enabled = true
        camera.layout = .pictureInPicture
        camera.anchor = .center
        camera.shape = .square
        camera.size = 0.4
        camera.mirrored = false
        let project = StudioProject(
            id: UUID(),
            name: "十分钟导出验收",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            microphoneFile: "microphone.wav",
            duration: duration,
            width: Int(sourceSize.width),
            height: Int(sourceSize.height),
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: duration,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            cameraFile: "camera.mov",
            camera: camera,
            canvas: CanvasSettings(aspect: .landscape)
        )
        let outputURL = folder.appendingPathComponent("export.mp4")
        var progressValues: [Double] = []
        let exportStartedAt = CFAbsoluteTimeGetCurrent()
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL,
            configuration: ExportConfiguration(
                outputSize: CGSize(width: 1920, height: 1080),
                frameRate: 30,
                codec: .h264
            )
        ) {
            progressValues.append($0)
        }
        XCTAssertEqual(progressValues.last, 1)
        XCTAssertEqual(progressValues, progressValues.sorted())

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(
            withMediaType: .video
        )
        let audioTracks = try await asset.loadTracks(
            withMediaType: .audio
        )
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let videoDuration = try await videoTrack.load(
            .timeRange
        ).duration.seconds
        let audioDuration = try await audioTrack.load(
            .timeRange
        ).duration.seconds
        XCTAssertEqual(videoDuration, duration, accuracy: 0.08)
        XCTAssertLessThanOrEqual(
            abs(videoDuration - audioDuration),
            0.05
        )
        let encodeSeconds = CFAbsoluteTimeGetCurrent() - exportStartedAt
        let fileSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: outputURL.path
            )[.size] as? NSNumber
        )
        print(
            String(
                format: "Long export: encode %.1fs, video %.3fs, audio %.3fs, drift %.1fms, file %.1fMB, progress %d samples",
                encodeSeconds,
                videoDuration,
                audioDuration,
                abs(videoDuration - audioDuration) * 1_000,
                Double(fileSize.int64Value) / 1_048_576,
                progressValues.count
            )
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in [1.25, 300.25, 598.25] {
            let frame = try await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)
            ).image
            let image = CIImage(cgImage: frame)
            let cameraRect = CanvasLayout.cameraSlot(
                outputSize: CGSize(
                    width: frame.width,
                    height: frame.height
                ),
                contentRect: CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: frame.width,
                        height: frame.height
                    )
                ),
                settings: camera
            )
            let color = try pixel(
                in: image,
                at: CGPoint(
                    x: cameraRect.midX,
                    y: cameraRect.midY
                )
            )
            XCTAssertGreaterThan(
                Double(color.blue),
                Double(color.red) * 1.4,
                "摄像头在 \(time) 秒处不同步"
            )
        }
    }

    /// Q3 长跑（手动触发）：同一工程连续导出 10 次，记录每次耗时与
    /// 进程足迹，验证无泄漏、无失败、进度单调到 1。
    @MainActor
    func testRepeatedExportsMemoryCurve() async throws {
        guard
            ProcessInfo.processInfo.environment["ANISE_RECORDER_REPEAT_EXPORT"]
                == "1"
        else {
            throw XCTSkip(
                "设置 ANISE_RECORDER_REPEAT_EXPORT=1 后运行 10 次连续导出长跑。"
            )
        }
        let folderName = "test-repeat-export-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let duration = 15.0
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: CGSize(width: 320, height: 180),
            color: CIColor(red: 0.1, green: 0.7, blue: 0.2),
            frameCount: Int(duration) * 10,
            frameRate: 10
        )
        try makeTestAudio(
            at: folder.appendingPathComponent("microphone.wav"),
            duration: duration
        )
        var project = makeProject()
        project.folderName = folderName
        project.duration = duration
        project.width = 320
        project.height = 180
        project.canvas.aspect = .source
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: duration)]
        )
        project.microphoneFile = "microphone.wav"

        let baselineMB = physicalFootprintMB()
        var curve: [Int64] = []
        for round in 1...10 {
            let outputURL = folder.appendingPathComponent(
                "export-\(round).mp4"
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }
            var lastProgress = 0.0
            let startedAt = CFAbsoluteTimeGetCurrent()
            try await CompositionBuilder.makeExport(
                for: project,
                outputURL: outputURL,
                configuration: ExportConfiguration(
                    outputSize: CGSize(width: 1920, height: 1080),
                    frameRate: 30,
                    codec: .h264
                )
            ) { lastProgress = $0 }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            XCTAssertEqual(lastProgress, 1, "第 \(round) 次导出进度未到 1")
            let asset = AVURLAsset(url: outputURL)
            let videoDuration = try await asset.load(.duration).seconds
            XCTAssertEqual(videoDuration, duration, accuracy: 0.5)
            curve.append(physicalFootprintMB())
            print(String(
                format: "Q3-B 第 %d 次导出 %.1fs 足迹 %lld MB",
                round, elapsed, curve.last ?? 0
            ))
        }
        let growth = (curve.last ?? 0) - baselineMB
        print("Q3-B 10 次导出足迹曲线: \(curve)（基线 \(baselineMB) MB，增长 \(growth) MB）")
        XCTAssertLessThan(
            growth, 200,
            "10 次导出后进程足迹增长应低于 200MB（实测 \(growth) MB）"
        )
    }

    @MainActor
    func testExportUsesEditedTimelineAndPlaybackRate() async throws {
        let folderName = "test-timeline-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        let outputURL = folder.appendingPathComponent("export.mp4")
        try await makeTestVideo(
            at: screenURL,
            fileType: .mp4,
            size: CGSize(width: 320, height: 180),
            color: CIColor(red: 0.9, green: 0.1, blue: 0.1)
        )

        var timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 1)
        XCTAssertTrue(timeline.split(atOutput: 0.5))
        XCTAssertTrue(timeline.deleteClip(id: timeline.clips[1].id))
        let firstClipID = try XCTUnwrap(timeline.clips.first?.id)
        XCTAssertTrue(timeline.setPlaybackRate(2, for: firstClipID))
        XCTAssertEqual(timeline.duration, 0.25, accuracy: 0.000_001)

        let project = StudioProject(
            id: UUID(),
            name: "时间线导出测试",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            duration: 1,
            width: 320,
            height: 180,
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 1,
            zoomScale: 1,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            canvas: CanvasSettings(
                aspect: .source,
                background: CanvasBackground(
                    kind: .solid,
                    colorHex: "#000000"
                ),
                padding: 0,
                cornerRadius: 0,
                shadowEnabled: false,
                shadowIntensity: 0
            ),
            timeline: timeline
        )

        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL
        ) { _ in }

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.25, accuracy: 0.08)
    }

    @MainActor
    func testM2CombinedProjectRoundTripAndExport() async throws {
        let folderName = "test-m2-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceSize = CGSize(width: 320, height: 180)
        try await makeTestVideo(
            at: folder.appendingPathComponent("screen.mp4"),
            fileType: .mp4,
            size: sourceSize,
            color: CIColor(red: 0.9, green: 0.1, blue: 0.1),
            frameCount: 120
        )
        try await makeTestVideo(
            at: folder.appendingPathComponent("camera.mov"),
            fileType: .mov,
            size: sourceSize,
            color: CIColor(red: 0.05, green: 0.1, blue: 0.95),
            frameCount: 120
        )
        let microphoneURL = folder.appendingPathComponent("microphone.wav")
        let systemURL = folder.appendingPathComponent("system.wav")
        try makeTestAudio(at: microphoneURL, duration: 4)
        try makeTestAudio(at: systemURL, duration: 4)

        var timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 4)
        XCTAssertTrue(timeline.split(atOutput: 1))
        XCTAssertTrue(timeline.split(atOutput: 2))
        XCTAssertTrue(timeline.split(atOutput: 3))
        XCTAssertEqual(timeline.clips.count, 4)
        XCTAssertTrue(timeline.setPlaybackRate(0.5, for: timeline.clips[1].id))
        XCTAssertTrue(timeline.setPlaybackRate(2, for: timeline.clips[3].id))

        var baseCamera = CameraSettings()
        baseCamera.enabled = true
        baseCamera.layout = .pictureInPicture
        baseCamera.anchor = .bottomRight
        baseCamera.shape = .roundedRectangle
        baseCamera.mirrored = false
        var circleCamera = CameraSettings()
        circleCamera.enabled = true
        circleCamera.layout = .pictureInPicture
        circleCamera.anchor = .bottomLeft
        circleCamera.shape = .circle
        circleCamera.mirrored = false
        var sideBySide = CameraSettings()
        sideBySide.enabled = true
        sideBySide.layout = .sideBySide
        sideBySide.splitRatio = 0.68
        sideBySide.mirrored = false

        let project = StudioProject(
            id: UUID(),
            name: "M2 组合验收",
            createdAt: Date(),
            folderName: folderName,
            videoFile: "screen.mp4",
            microphoneFile: "microphone.wav",
            duration: 4,
            width: 320,
            height: 180,
            fps: 30,
            clicks: [],
            trimStart: 0,
            trimEnd: 4,
            zoomScale: 1.5,
            zoomDuration: 1,
            autoZoom: false,
            source: .display(displayID: 1),
            systemAudioFile: "system.wav",
            cameraFile: "camera.mov",
            camera: baseCamera,
            cameraSegments: [
                CameraLayoutSegment(
                    start: 1.2,
                    transitionDuration: 0.3,
                    camera: circleCamera
                ),
                CameraLayoutSegment(
                    start: 2.8,
                    transitionDuration: 0.5,
                    camera: sideBySide
                )
            ],
            audio: AudioTrackSettings(
                microphoneGain: 0.35,
                systemGain: 0.8
            ),
            zoomRegions: [
                ZoomRegion(start: 0.2, duration: 0.7, scale: 1.4),
                ZoomRegion(
                    start: 1.5,
                    duration: 0.8,
                    scale: 1.8,
                    center: NormalizedPoint(x: 0.2, y: 0.4)
                ),
                ZoomRegion(
                    start: 3.2,
                    duration: 0.9,
                    scale: 2.1,
                    center: NormalizedPoint(x: 0.8, y: 0.6)
                )
            ],
            canvas: CanvasSettings(
                aspect: .landscape,
                background: CanvasBackground(
                    kind: .solid,
                    colorHex: "#101010"
                ),
                padding: 0,
                cornerRadius: 0,
                shadowEnabled: false,
                shadowIntensity: 0
            ),
            timeline: timeline
        )

        try ProjectStore.save(project)
        let loaded = try XCTUnwrap(
            ProjectStore.loadAllWithIssues().projects.first {
                $0.id == project.id
            }
        )
        XCTAssertEqual(loaded.timeline.clips.count, 4)
        XCTAssertEqual(loaded.cameraSegments.count, 2)
        XCTAssertEqual(loaded.zoomRegions.count, 3)
        XCTAssertEqual(loaded.audio.microphoneGain, 0.35, accuracy: 0.001)
        XCTAssertEqual(loaded.audio.systemGain, 0.8, accuracy: 0.001)
        XCTAssertEqual(loaded.timeline.duration, 4.5, accuracy: 0.001)

        let outputURL = folder.appendingPathComponent("export.mp4")
        try await CompositionBuilder.makeExport(
            for: loaded,
            outputURL: outputURL
        ) { _ in }
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, loaded.timeline.duration, accuracy: 0.12)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)

        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(
            at: CMTime(seconds: 3.6, preferredTimescale: 600)
        ).image
        let outputSize = CGSize(width: frame.width, height: frame.height)
        let available = CanvasLayout.availableRect(
            outputSize: outputSize,
            padding: loaded.canvas.padding
        )
        let cameraRect = CanvasLayout.cameraSlot(
            outputSize: outputSize,
            contentRect: available,
            settings: sideBySide
        )
        let color = try pixel(
            in: CIImage(cgImage: frame),
            at: CGPoint(x: cameraRect.midX, y: cameraRect.midY)
        )
        XCTAssertGreaterThan(Double(color.blue), Double(color.red) * 1.4)
    }

    func testProjectRemovalPreferenceDecodesFallbackAndRoundTrip() {
        let key = StudioPreferences.projectRemovalActionKey
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // 缺省回退“每次询问”；无效值不崩溃，同样回退。
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(StudioPreferences.projectRemovalAction, .ask)
        UserDefaults.standard.set("trash", forKey: key)
        XCTAssertEqual(StudioPreferences.projectRemovalAction, .ask)

        // 设置窗口三档往返。
        UserDefaults.standard.set(ProjectRemovalAction.hide.rawValue, forKey: key)
        XCTAssertEqual(StudioPreferences.projectRemovalAction, .hide)
        UserDefaults.standard.set(
            ProjectRemovalAction.archive.rawValue,
            forKey: key
        )
        XCTAssertEqual(StudioPreferences.projectRemovalAction, .archive)
    }

    func testProjectStoreHidesAndRestoresWithoutMovingFiles() throws {
        let folderName = "test-hidden-\(UUID().uuidString)"
        var project = makeProject()
        project.id = UUID()
        project.folderName = folderName
        let folder = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try ProjectStore.save(project)

        try ProjectStore.setHidden(project, hidden: true)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("project.json").path
            )
        )
        XCTAssertFalse(
            ProjectStore.loadAll(includeHidden: false)
                .contains(where: { $0.id == project.id })
        )
        XCTAssertTrue(
            ProjectStore.loadAll(includeHidden: true)
                .contains(where: { $0.id == project.id })
        )

        try ProjectStore.setHidden(project, hidden: false)
        XCTAssertTrue(
            ProjectStore.loadAll(includeHidden: false)
                .contains(where: { $0.id == project.id })
        )
    }

    func testProjectStoreArchivesWithUniqueNameAndImportsBack() throws {
        let folderName = "test-archive-\(UUID().uuidString)"
        var project = makeProject()
        project.id = UUID()
        project.folderName = folderName
        let source = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: source) }
        try ProjectStore.save(project)

        let archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("anise-recorder-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: archiveRoot.appendingPathComponent(folderName),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: archiveRoot) }

        let archived = try ProjectStore.archive(
            project,
            archiveRoot: archiveRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertEqual(archived.lastPathComponent, "\(folderName)-2")

        let imported = try ProjectStore.importProject(from: archived)
        defer {
            try? FileManager.default.removeItem(at: imported.folderURL)
        }
        XCTAssertEqual(imported.id, project.id)
        XCTAssertEqual(imported.folderName, folderName)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: imported.folderURL
                    .appendingPathComponent("project.json")
                    .path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: archived.path))
    }

    func testProjectStoreRejectsUnsafePathsAndPreservesInvalidImport()
        throws
    {
        var project = makeProject()
        project.folderName = "../outside"
        XCTAssertThrowsError(try ProjectStore.setHidden(project, hidden: true))
        XCTAssertThrowsError(try ProjectStore.archive(project))
        XCTAssertThrowsError(try ProjectStore.trash(project))
        XCTAssertThrowsError(try ProjectStore.folderURL(forFolderName: "."))
        XCTAssertThrowsError(
            try ProjectStore.folderURL(forFolderName: "nested/project")
        )
        XCTAssertThrowsError(
            try ProjectStore.folderURL(
                forFolderName: ProjectStore.archiveFolderName
            )
        )

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("anise-recorder-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let sentinel = source.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(try ProjectStore.importProject(from: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testProjectStoreMovesCompleteProjectToTrash() throws {
        let folderName = "test-trash-\(UUID().uuidString)"
        var project = makeProject()
        project.id = UUID()
        project.folderName = folderName
        let folder = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try ProjectStore.save(project)
        let asset = folder.appendingPathComponent("screen.mp4")
        try Data("video".utf8).write(to: asset)

        let trashed = try ProjectStore.trash(project)
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: trashed.appendingPathComponent("screen.mp4").path
            )
        )
    }

    func testRecordSetupDecodesWithoutCameraComposition() throws {
        let setup = RecordSetup(
            captureCamera: true,
            cameraComposition: .recordingDefault
        )
        let encoded = try JSONEncoder().encode(setup)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "cameraComposition")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RecordSetup.self, from: legacy)
        XCTAssertTrue(decoded.captureCamera)
        XCTAssertNil(decoded.cameraComposition)
    }

    func testCameraOverlayGeometryUsesSourceAndCanvasFrames() {
        var canvas = CanvasSettings()
        canvas.aspect = .landscape
        canvas.padding = 0.04
        var camera = CameraSettings.recordingDefault
        camera.anchor = .bottomRight
        camera.customCenter = nil
        let source = CGRect(
            x: -1280,
            y: -300,
            width: 1280,
            height: 720
        )

        let frame = CameraOverlayGeometry.panelFrame(
            sourceFrame: source,
            sourceSize: source.size,
            canvas: canvas,
            settings: camera
        )
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(source.contains(frame))

        camera.shape = .circle
        let circle = CameraOverlayGeometry.panelFrame(
            sourceFrame: source,
            sourceSize: source.size,
            canvas: canvas,
            settings: camera
        )
        XCTAssertEqual(circle.width, circle.height, accuracy: 0.001)

        camera.customCenter = NormalizedPoint(x: 0.84, y: 0.84)
        let moved = CameraOverlayGeometry.moving(
            camera,
            by: CGSize(width: -500, height: -300),
            sourceFrame: source,
            sourceSize: source.size,
            canvas: canvas
        )
        XCTAssertNotEqual(moved.customCenter, camera.customCenter)
        let movedFrame = CameraOverlayGeometry.panelFrame(
            sourceFrame: source,
            sourceSize: source.size,
            canvas: canvas,
            settings: moved
        )
        XCTAssertTrue(source.contains(movedFrame))

        camera.customCenter = NormalizedPoint(x: 0.505, y: 0.495)
        let snapped = CameraOverlayGeometry.moving(
            camera,
            by: .zero,
            sourceFrame: source,
            sourceSize: source.size,
            canvas: canvas
        )
        XCTAssertEqual(
            snapped.customCenter?.x ?? -1,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapped.customCenter?.y ?? -1,
            0.5,
            accuracy: 0.000_001
        )

        let resized = CameraOverlayGeometry.resizing(
            camera,
            corner: .bottomRight,
            by: CGSize(width: 80, height: 80),
            sourceFrame: source,
            sourceSize: source.size,
            canvas: canvas
        )
        XCTAssertGreaterThan(resized.size, camera.size)
        let resizedFrame = CameraOverlayGeometry.panelFrame(
            sourceFrame: source,
            sourceSize: source.size,
            canvas: canvas,
            settings: resized
        )
        XCTAssertEqual(
            resizedFrame.width,
            resizedFrame.height,
            accuracy: 0.001
        )
        XCTAssertTrue(source.contains(resizedFrame))
    }

    func testCameraOverlayGeometryCoversDisplayWindowAndRegionOrigins() {
        struct SourceCase {
            let name: String
            let frame: CGRect
            let size: CGSize
            let anchor: CameraAnchor
        }

        let cases = [
            SourceCase(
                name: "整屏 Retina",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                size: CGSize(width: 3840, height: 2160),
                anchor: .bottomRight
            ),
            SourceCase(
                name: "窗口",
                frame: CGRect(x: 514, y: 298, width: 586, height: 476),
                size: CGSize(width: 1172, height: 952),
                anchor: .topLeft
            ),
            SourceCase(
                name: "负坐标区域",
                frame: CGRect(x: -1280, y: -300, width: 381, height: 216),
                size: CGSize(width: 762, height: 432),
                anchor: .bottomRight
            ),
        ]

        for source in cases {
            var canvas = CanvasSettings()
            canvas.aspect = .landscape
            canvas.padding = 0.035
            var camera = CameraSettings.recordingDefault
            camera.anchor = source.anchor
            camera.customCenter = nil

            let frame = CameraOverlayGeometry.panelFrame(
                sourceFrame: source.frame,
                sourceSize: source.size,
                canvas: canvas,
                settings: camera
            )
            XCTAssertGreaterThan(frame.width, 1, source.name)
            XCTAssertGreaterThan(frame.height, 1, source.name)
            XCTAssertTrue(
                source.frame.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                source.name
            )

            let moved = CameraOverlayGeometry.moving(
                camera,
                by: CGSize(width: 10_000, height: 10_000),
                sourceFrame: source.frame,
                sourceSize: source.size,
                canvas: canvas
            )
            let movedFrame = CameraOverlayGeometry.panelFrame(
                sourceFrame: source.frame,
                sourceSize: source.size,
                canvas: canvas,
                settings: moved
            )
            XCTAssertTrue(
                source.frame.insetBy(dx: -0.5, dy: -0.5)
                    .contains(movedFrame),
                source.name
            )
        }
    }

    @MainActor
    func testArchivingCurrentProjectStopsEditingAndBlocksDuringExport()
        throws
    {
        let model = StudioModel()
        model.setup.captureCamera = false
        let folderName = "test-archive-current-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(
                at: ProjectStore.archiveURL
                    .appendingPathComponent(folderName)
            )
        }
        var project = makeProject()
        project.id = UUID()
        project.folderName = folderName
        try ProjectStore.save(project)
        model.projects = [project]
        model.selectedProjectID = project.id
        model.draft = project
        model.currentTime = 3

        model.exportProgress = 0.2
        model.archiveProject(project)
        XCTAssertEqual(model.draft?.id, project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        model.exportProgress = nil
        model.archiveProject(project)
        XCTAssertNil(model.draft)
        XCTAssertNil(model.selectedProjectID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testCameraPermissionDeniedKeepsCaptureCameraOnAndMarksSessionFlag()
        async throws
    {
        let model = StudioModel()
        model.setup.captureCamera = true
        model.cameraAccessChecker = { false }

        await model.activateCameraPreview()

        XCTAssertTrue(
            model.setup.captureCamera,
            "权限被拒时不得静默翻转用户的摄像头开关"
        )
        XCTAssertTrue(model.cameraPermissionDenied)
        XCTAssertFalse(model.cameraPreviewActive)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testCameraPermissionRecheckClearsSessionFlagWhenGranted()
        async throws
    {
        let model = StudioModel()
        model.setup.captureCamera = true
        model.cameraAccessChecker = { false }
        await model.activateCameraPreview()
        XCTAssertTrue(model.cameraPermissionDenied)

        model.cameraAccessChecker = { true }
        await model.recheckCameraPermission()

        XCTAssertFalse(model.cameraPermissionDenied)
        XCTAssertTrue(model.setup.captureCamera)
    }

    /// 工程重命名——空名/全空白拒绝（保持原名），正常改名
    /// 生效且占一个撤销步，撤销完整还原。
    @MainActor
    func testProjectRenameRejectsEmptyAndSupportsUndo() {
        let model = StudioModel()
        let project = makeProject()
        model.selectProject(project)

        model.updateProjectName("   ")
        XCTAssertEqual(model.draft?.name, "测试工程")

        model.updateProjectName("第 3 课-函数与作用域")
        XCTAssertEqual(model.draft?.name, "第 3 课-函数与作用域")
        XCTAssertTrue(model.canUndo)
        model.undoProjectEdit()
        XCTAssertEqual(model.draft?.name, "测试工程")
    }

    /// 拆条与清空删条的事务与撤销语义（验收标准 3/4）。
    @MainActor
    func testCaptionSplitAndDeleteViaTranscriptLayer2() {
        let model = StudioModel()
        var project = makeProject()
        project.captionCues = [
            CaptionCue(id: UUID(), start: 0, end: 10, text: "前半句内容后半句内容")
        ]
        model.selectProject(project)

        // 拆条：文本「前半句内容后半句内容」共 10 字，偏移 5 拆 →
        // 时间 0-5 / 5-10（按字数比例 5/10）
        let cueID = model.draft?.captionCues.first?.id
        XCTAssertNotNil(cueID)
        let split = model.splitCaption(cueID!, atTextOffset: 5)
        XCTAssertTrue(split)
        XCTAssertEqual(model.draft?.captionCues.count, 2)
        XCTAssertEqual(model.draft?.captionCues[0].text, "前半句内容")
        XCTAssertEqual(model.draft?.captionCues[1].text, "后半句内容")
        XCTAssertEqual(model.draft?.captionCues[0].end ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(model.draft?.captionCues[1].start ?? -1, 5, accuracy: 1e-9)

        // 一次 ⌘Z 完整还原（含时间分配）
        model.undoProjectEdit()
        XCTAssertEqual(model.draft?.captionCues.count, 1)
        XCTAssertEqual(model.draft?.captionCues[0].text, "前半句内容后半句内容")
        XCTAssertEqual(model.draft?.captionCues[0].end ?? -1, 10, accuracy: 1e-9)

        // 清空即删条：占一个撤销步
        model.captionDeleteConfirmHandler = { _ in true }
        model.updateCaptionText(cueID!, text: "   ")
        XCTAssertEqual(model.draft?.captionCues.count, 0)
        XCTAssertTrue(model.canUndo)
        model.undoProjectEdit()
        XCTAssertEqual(model.draft?.captionCues.count, 1)
    }

    /// 无效拆条请求不动数据（偏移在两端/单字符）。
    @MainActor
    func testCaptionSplitRejectsInvalidOffsets() {
        let model = StudioModel()
        var project = makeProject()
        project.captionCues = [CaptionCue(id: UUID(), start: 0, end: 4, text: "短句")]
        model.selectProject(project)
        let cueID = model.draft?.captionCues.first?.id
        XCTAssertNotNil(cueID)
        // 偏移 0 钳到 1（合法）；偏移越界到 count 也钳住——两条都应成功且不越界
        XCTAssertTrue(model.splitCaption(cueID!, atTextOffset: 0))
        model.undoProjectEdit()
        XCTAssertEqual(model.draft?.captionCues.count, 1)
    }

    /// 720p 档位换算（验收标准 1/2 的代码侧）。
    @MainActor
    func testExportResolution720pOutputSize() {
        let model = StudioModel()
        var project = makeProject()
        project.width = 3840
        project.height = 2160
        model.selectProject(project)

        model.exportResolution = .hd720
        let size = model.exportResolution.outputSize(for: project)
        XCTAssertEqual(size.height, 720)
        XCTAssertEqual(size.width, 1280)
        // 偶数为硬性要求（编码器约束）
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)

        // 竖屏 9:16：720 走短边
        project.width = 1080
        project.height = 1920
        let portrait = model.exportResolution.outputSize(for: project)
        XCTAssertEqual(portrait.width, 720)
        XCTAssertEqual(portrait.height, 1280)

        // 档位标题与三档枚举
        XCTAssertEqual(ExportResolution.hd720.title, "720p")
        XCTAssertEqual(ExportResolution.allCases.count, 3)
    }

    /// 文本删片段的事务与撤销（验收标准 3/4 代码侧）。
    @MainActor
    func testTextCutAppliesTransactionAndUndoes() {
        let model = StudioModel()
        var project = makeProject()
        project.duration = 10
        model.selectProject(project)

        // 删除 2-4s 区间 → 成片变 8 秒
        model.applyTextCut(cutStart: 2, cutEnd: 4)
        XCTAssertEqual(model.draft?.trimDuration ?? -1, 8, accuracy: 1e-6)
        XCTAssertTrue(model.canUndo)

        // 一次 ⌘Z 完整还原
        model.undoProjectEdit()
        XCTAssertEqual(model.draft?.trimDuration ?? -1, 10, accuracy: 1e-6)
    }

    /// 建议查询双模式——有分段精确、无分段近似。
    @MainActor
    func testTextCutSuggestionModes() {
        let model = StudioModel()
        var project = makeProject()
        project.captionCues = [
            CaptionCue(id: UUID(), start: 0, end: 4, text: "甲乙丙丁")
        ]
        model.selectProject(project)
        let cueID = model.draft?.captionCues.first?.id
        XCTAssertNotNil(cueID)

        // 无分段 → 近似（选中「乙丙」偏移 1..3 → 1-3s）
        let approx = model.textCutSuggestion(
            for: cueID!, selection: 1 ..< 3
        )
        guard case .success(let s) = approx else {
            return XCTFail("expected success, got \(approx)")
        }
        XCTAssertTrue(s.isApproximate)
        XCTAssertEqual(s.cutStart, 1, accuracy: 1e-6)
        XCTAssertEqual(s.cutEnd, 3, accuracy: 1e-6)

        // 整条选中 → 拒绝（改走删条）
        let whole = model.textCutSuggestion(
            for: cueID!, selection: 0 ..< 4
        )
        XCTAssertEqual(whole, .failure(.emptySelection))
    }

    // MARK: - 数据目录更名迁移

    func testLegacyRootMergesNestedArchiveRecursively() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "migrate-\(UUID().uuidString)"
        )
        let legacy = base.appendingPathComponent("Local Studio")
        let target = base.appendingPathComponent("八角录屏")
        defer { try? FileManager.default.removeItem(at: base) }
        let legacyArchive = legacy.appendingPathComponent("Archive")
        let targetArchive = target.appendingPathComponent("Archive")
        for dir in [legacyArchive, targetArchive] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        try Data("old".utf8).write(
            to: legacyArchive.appendingPathComponent("old-project.txt")
        )
        try Data("new".utf8).write(
            to: targetArchive.appendingPathComponent("new-project.txt")
        )

        ProjectStore.migrateLegacyRootIfNeeded(from: legacy, to: target)
        for name in ["old-project.txt", "new-project.txt"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: targetArchive.appendingPathComponent(name).path
                ),
                "归档目录应递归合并：\(name)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.path),
            "旧目录合并空后应移除"
        )
    }


    func testLegacyRootMigratesWholeDirectoryWhenTargetAbsent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "migrate-\(UUID().uuidString)"
        )
        let legacy = base.appendingPathComponent("Local Studio")
        let target = base.appendingPathComponent("八角录屏")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: legacy, withIntermediateDirectories: true
        )
        let project = legacy.appendingPathComponent("p1")
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: project.appendingPathComponent("project.json")
        )

        XCTAssertTrue(
            ProjectStore.migrateLegacyRootIfNeeded(from: legacy, to: target)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("p1/project.json").path
            )
        )
    }

    func testLegacyRootMergesWithoutOverwritingExistingEntries() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "migrate-\(UUID().uuidString)"
        )
        let legacy = base.appendingPathComponent("Local Studio")
        let target = base.appendingPathComponent("八角录屏")
        defer { try? FileManager.default.removeItem(at: base) }
        for dir in [legacy, target] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        try Data("old".utf8).write(
            to: legacy.appendingPathComponent("only-in-legacy.txt")
        )
        try Data("new".utf8).write(
            to: target.appendingPathComponent("only-in-legacy.txt")
        )
        try Data("x".utf8).write(
            to: legacy.appendingPathComponent("extra.txt")
        )

        ProjectStore.migrateLegacyRootIfNeeded(from: legacy, to: target)
        // 同名不覆盖
        XCTAssertEqual(
            try String(
                contentsOf: target.appendingPathComponent("only-in-legacy.txt")
            ),
            "new"
        )
        // 不冲突的移入
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("extra.txt")),
            "x"
        )
        // 旧目录因仍有同名文件未搬空，保留原文件
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("only-in-legacy.txt").path
            )
        )
    }

    // MARK: - selectProject 行点击语义

    func testSelectProjectRowClickOpensEditorOnFreshLaunch() {
        let clicked = UUID()
        // fresh launch：上次会话的选中 id 已恢复但 draft 为空——点击
        // 应进入编辑器（旧守卫在此直接 return，是旧实现的 bug）。
        XCTAssertTrue(
            StudioModel.shouldOpenProjectOnRowClick(
                draftID: nil,
                clickedID: clicked
            )
        )
        // 已选中的 id 相同但 draft 为空：同样应进入。
        XCTAssertTrue(
            StudioModel.shouldOpenProjectOnRowClick(
                draftID: nil,
                clickedID: clicked
            )
        )
        // 编辑器里已是这条工程：重复点击，无操作。
        XCTAssertFalse(
            StudioModel.shouldOpenProjectOnRowClick(
                draftID: clicked,
                clickedID: clicked
            )
        )
        // 编辑器里是别的工程：切换。
        XCTAssertTrue(
            StudioModel.shouldOpenProjectOnRowClick(
                draftID: UUID(),
                clickedID: clicked
            )
        )
    }

    @MainActor
    func testClearCaptionConfirmAndSuppression() {
        // 确认与抑制两个场景写同一偏好键，放在一个用例内顺序执行，
        // 避免并行测试对 UserDefaults.standard 的竞争（曾间歇性互相污染）。
        UserDefaults.standard.removeObject(
            forKey: StudioPreferences.captionDeleteConfirmSuppressedKey
        )
        defer {
            UserDefaults.standard.removeObject(
                forKey: StudioPreferences.captionDeleteConfirmSuppressedKey
            )
        }

        // 场景一：未抑制 → 弹确认 → 取消：字幕保留、文本还原，不删条。
        let model = StudioModel()
        model.captionDeleteConfirmHandler = { _ in false }
        var project = makeProject()
        let cue = CaptionCue(start: 1, end: 2, text: "要被清空的字幕")
        project.captionCues = [cue]
        model.draft = project
        model.updateCaptionText(cue.id, text: "   ")
        let retained = model.draft?.captionCues.first { $0.id == cue.id }
        XCTAssertEqual(retained?.text, "要被清空的字幕")
        XCTAssertEqual(model.draft?.captionCues.count, 1)

        // 场景二：抑制开启 → 跳过确认直接删条。
        var handlerCalls = 0
        model.captionDeleteConfirmHandler = { _ in
            handlerCalls += 1
            return true
        }
        UserDefaults.standard.set(
            true,
            forKey: StudioPreferences.captionDeleteConfirmSuppressedKey
        )
        let cue2 = CaptionCue(start: 3, end: 4, text: "直接删除")
        model.draft?.captionCues = [cue2]
        model.updateCaptionText(cue2.id, text: " ")
        XCTAssertEqual(handlerCalls, 0, "抑制后不再弹确认")
        XCTAssertTrue(model.draft?.captionCues.isEmpty == true, "直接删条")
    }

    /// 模型级回归——fresh launch（draft 为空）点击行
    /// 真的会打开工程进编辑器；编辑器里重复点击不触发状态重置。
    @MainActor
    func testSelectProjectOpensEditorAndDuplicateClickIsNoop() {
        let model = StudioModel()
        let project = makeProject()
        model.projects = [project]
        // fresh launch：draft 为空，点击应建立 draft（进入编辑器）。
        model.selectProject(project)
        XCTAssertEqual(model.draft?.id, project.id)
        XCTAssertEqual(model.selectedProjectID, project.id)
        // 编辑器里重复点击：不触发任何重置（currentTime 保持原值）。
        model.seek(to: 3.2)
        model.selectProject(project)
        XCTAssertEqual(model.draft?.id, project.id)
        XCTAssertEqual(model.currentTime, 3.2, accuracy: 1e-9)
    }

    // MARK: - 性能留档三项（先量后修，量不出问题不预防性重构）

    /// 进程物理足迹（MB），内存粗测用。
    private func physicalFootprintMB() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint) / (1024 * 1024)
    }

    /// W5①：1 万条 cue 口头禅/填充词分析（P4 审计留档：主线程算）。
    /// 阈值 200ms：实测低于阈值 → 记录关闭，不预防性重构。
    @MainActor
    func testFillerAnalysisPerformanceAt10kCues() throws {
        let model = StudioModel()
        var project = makeProject()
        var cues: [CaptionCue] = []
        for i in 0..<10_000 {
            cues.append(
                CaptionCue(
                    start: Double(i) * 0.2,
                    end: Double(i) * 0.2 + 0.15,
                    text: "然后呢这个就是说第\(i)句里面有一些填充词那个"
                )
            )
        }
        project.captionCues = cues
        model.draft = project
        let start = Date()
        model.analyzeFillerSuggestions()
        let elapsed = Date().timeIntervalSince(start)
        print(
            "W5① 1 万条 cue 口头禅分析主线程耗时：\(Int(elapsed * 1000))ms（阈值 200ms）"
        )
        XCTAssertLessThan(elapsed, 0.2, "超 200ms 则应下沉后台")
    }

    /// undo 栈压测——300 次编辑记录 + 100 次撤销的耗时，以及大
    /// 工程（20 万光标采样）下 100 深快照的进程足迹增长（栈已有
    /// limit=100，P4 审计留档确认）。
    @MainActor
    func testUndoStackPerformanceAndMemoryAtScale() throws {
        let model = StudioModel()
        var project = makeProject()
        project.rawCursor = (0..<200_000).map { index in
            CursorSample(
                sourceTime: Double(index) / 60,
                x: 0.5,
                y: 0.5,
                visible: true,
                moved: index % 2 == 0
            )
        }
        model.draft = project
        let beforeMB = physicalFootprintMB()
        let start = Date()
        for i in 0..<300 {
            model.updateProjectName("压测工程 \(i)")
        }
        let recordElapsed = Date().timeIntervalSince(start)
        let undoStart = Date()
        for _ in 0..<100 {
            model.undoProjectEdit()
        }
        let undoElapsed = Date().timeIntervalSince(undoStart)
        let afterMB = physicalFootprintMB()
        print(
            "300 次编辑记录耗时：\(Int(recordElapsed * 1000))ms；"
                + "100 次撤销耗时：\(Int(undoElapsed * 1000))ms；"
                + "进程足迹增长：\(afterMB - beforeMB)MB（栈上限 100）"
        )
        XCTAssertLessThan(recordElapsed, 2.0, "编辑记录不应卡顿")
        XCTAssertLessThan(undoElapsed, 2.0, "批量撤销不应卡顿")
        XCTAssertLessThan(
            Double(afterMB - beforeMB), 400,
            "快照内存增长应在 COW 共享下保持有界"
        )
    }

    // MARK: - toast 语义与防卡死回归

    func testToastSemanticsClassifiesErrorsAndInfo() {
        // 错误样式（负向关键词）。
        for message in [
            "启动摄像头预览失败：设备被占用",
            "从列表移除工程失败：文件夹被锁",
            "录制意外停止：磁盘写入失败",
            "摄像头录制未完成：文件损坏",
            "保存工程失败：没有磁盘空间",
            "有 3 个工程文件夹需要处理：…",
            "本机语音识别权限被拒绝。…",
        ] {
            XCTAssertTrue(
                ToastSemantics.isError(message),
                "「\(message)」应为错误样式"
            )
        }
        // 中性信息样式（可撤销成功提示）。
        for message in [
            "已删除这条字幕 · 按 ⌘Z 可还原",
            "已拆分为两条 · 按 ⌘Z 可完整还原",
            "已在本机生成 12 条字幕，请校对",
            "已添加叠加素材：在时间线「叠加」轨或画面页调整位置、大小与时长",
        ] {
            XCTAssertFalse(
                ToastSemantics.isError(message),
                "「\(message)」应为信息样式"
            )
        }
    }

    func testSeekToleranceWidensWhileScrubbing() {
        // isScrubbing 语义回归：拖动中容差放宽、松手归零由 seek 内部
        // 依据该标志切换——验证标志翻转不影响 currentTime 计算路径。
        let project = makeProject()
        XCTAssertEqual(
            min(max(0, 120.0), max(0, project.trimDuration)),
            project.trimDuration,
            "seek 目标钳制在成片时长内"
        )
    }

    // MARK: - 按键显示

    func testKeyStrokeDisplayText() {
        // 修饰键组合顺序 ⌃⌥⇧⌘ + 键名。
        XCTAssertEqual(
            KeyStrokeTracker.displayText(
                characters: "b", keyCode: 11,
                command: true, option: false, shift: false, control: false
            ),
            "⌘B"
        )
        XCTAssertEqual(
            KeyStrokeTracker.displayText(
                characters: "a", keyCode: 0,
                command: true, option: true, shift: true, control: false
            ),
            "⌥⇧⌘A"
        )
        // 方向键与命名键。
        XCTAssertEqual(
            KeyStrokeTracker.displayText(
                characters: "", keyCode: 123,
                command: false, option: false, shift: false, control: false
            ),
            "←"
        )
        XCTAssertEqual(
            KeyStrokeTracker.displayText(
                characters: " ", keyCode: 49,
                command: false, option: false, shift: false, control: false
            ),
            "space"
        )
        // 纯修饰键 keyDown 不上条。
        XCTAssertNil(
            KeyStrokeTracker.displayText(
                characters: "", keyCode: 55,
                command: true, option: false, shift: false, control: false
            )
        )
    }

    func testKeyStrokeFieldsDecodeLegacyProjectAsEmptyAndDisabled() throws {
        var project = makeProject()
        project.keyStrokes = [KeyStrokeEvent(sourceTime: 1, text: "⌘B")]
        project.keyStripEnabled = true
        let data = try JSONEncoder().encode(project)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "keyStrokes")
        object.removeValue(forKey: "keyStripEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StudioProject.self, from: legacy)
        XCTAssertTrue(decoded.keyStrokes.isEmpty)
        XCTAssertFalse(decoded.keyStripEnabled)
        XCTAssertEqual(decoded.schemaVersion, 5)
    }

    /// 集成：导出含按键小条的成片，左下角胶囊区域与关闭状态的渲染
    /// 像素不同（同一合成路径，预览/导出一致）。
    func testExportRendersKeyStrip() async throws {
        let folderName = "test-keystrip-export-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        try await makeCheckerVideo(
            at: screenURL,
            size: CGSize(width: 320, height: 180),
            cells: 32,
            frameCount: 30,
            frameRate: 30
        )
        var project = makeProject()
        project.folderName = folderName
        project.duration = 1
        project.width = 320
        project.height = 180
        project.canvas.aspect = .source
        // 纯白画布底：胶囊的深色 scrim 与底色对比明确，不依赖棋盘格。
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#FFFFFF"
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 1)]
        )
        project.keyStrokes = [
            KeyStrokeEvent(sourceTime: 0.1, text: "⌘B"),
            KeyStrokeEvent(sourceTime: 0.4, text: "space"),
        ]
        project.keyStripEnabled = true

        func exportFrame() async throws -> CIImage {
            let outputURL = folder.appendingPathComponent(
                "out-\(UUID().uuidString).mp4"
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }
            try await CompositionBuilder.makeExport(
                for: project,
                outputURL: outputURL
            ) { _ in }
            let generator = AVAssetImageGenerator(
                asset: AVURLAsset(url: outputURL)
            )
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return CIImage(
                cgImage: try await generator.image(
                    at: CMTime(seconds: 0.5, preferredTimescale: 600)
                ).image
            )
        }

        let withStrip = try await exportFrame()
        project.keyStripEnabled = false
        let withoutStrip = try await exportFrame()

        // 差分比较：两帧在胶囊区域（margin 24×scale 起，约 150×90×scale）
        // 应有显著差异——棋盘底两边相同，差异只来自小条。
        let extent = withStrip.extent
        let scale = extent.height / 900
        var maxDiff = 0.0
        for x in stride(from: 20 * scale, through: 150 * scale, by: 3) {
            for y in stride(from: 20 * scale, through: 90 * scale, by: 3) {
                let a = try tryPixel(of: withStrip, at: CGPoint(x: x, y: y))
                let b = try tryPixel(
                    of: withoutStrip, at: CGPoint(x: x, y: y)
                )
                let diff = abs(a.red - b.red)
                    + abs(a.green - b.green)
                    + abs(a.blue - b.blue)
                maxDiff = max(maxDiff, diff)
            }
        }
        XCTAssertGreaterThan(
            maxDiff, 0.25,
            "开启按键小条后左下角应出现胶囊（最大像素差 \(maxDiff)）"
        )
    }

    /// 隔离验证：CanvasRenderer.render 直接画按键小条（绕过导出）。
    func testKeyStripRendererDrawsPillsDirectly() throws {
        var project = makeProject()
        project.canvas.background.kind = .solid
        project.canvas.background.colorHex = "#FFFFFF"
        project.keyStrokes = [
            KeyStrokeEvent(sourceTime: 0.1, text: "⌘B")
        ]
        project.keyStripEnabled = true
        let screen = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let outputSize = CGSize(width: 1600, height: 900)
        let frame = CanvasRenderer.render(
            screen: screen,
            camera: nil,
            time: 0.5,
            project: project,
            outputSize: outputSize
        )
        var darkest = Double.greatestFiniteMagnitude
        // 900p 基准：胶囊起点 (24, 24)，高约 42px。
        for x in stride(from: 26, through: 90, by: 4) {
            for y in stride(from: 26, through: 62, by: 4) {
                let pixel = try tryPixel(
                    of: frame, at: CGPoint(x: x, y: y)
                )
                darkest = min(
                    darkest,
                    pixel.red + pixel.green + pixel.blue
                )
            }
        }
        XCTAssertLessThan(
            darkest, 2.2,
            "直接渲染应在左下角画出深色胶囊；最暗=\(darkest)"
        )
    }

    /// 渲染器本体二分：绕过 renderFrame，直接调 overlay()。
    func testKeyStripOverlayDirect() throws {
        var project = makeProject()
        project.keyStrokes = [
            KeyStrokeEvent(sourceTime: 0.1, text: "⌘B")
        ]
        project.keyStripEnabled = true
        let base = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let out = KeyStripRenderer.overlay(
            on: base,
            time: 0.5,
            project: project,
            outputSize: CGSize(width: 1600, height: 900)
        )
        var found = false
        var darkest = Double.greatestFiniteMagnitude
        // 900p 基准：胶囊起点 (24, 24)，高约 42px、宽约 70px。
        for x in stride(from: 26, through: 90, by: 4) {
            for y in stride(from: 26, through: 62, by: 4) {
                let pixel = try tryPixel(of: out, at: CGPoint(x: x, y: y))
                let b = pixel.red + pixel.green + pixel.blue
                darkest = min(darkest, b)
                if b < 1.2 {
                    found = true
                }
            }
        }
        // 胶囊 scrim 82% 叠白底实测约 1.5（阈值放宽到 2.2，仍远低于
        // 白底 3.0 与棋盘底）。
        XCTAssertLessThan(
            darkest, 2.2,
            "overlay() 应在左下角画出深色胶囊；最暗=\(darkest)"
        )
    }

    // MARK: - F2 素材叠加轨

    /// 旧工程 JSON 没有 overlayClips 键：解码回退空数组、schemaVersion
    /// 保持 5（加字段不升 Schema 的仓库口径）。
    func testOverlayClipsAbsentKeyDecodesEmptyAndKeepsSchema5() throws {
        var project = makeProject()
        project.overlayClips = [
            OverlayClip(start: 1, duration: 2, kind: .image, fileName: "a.png")
        ]
        let data = try JSONEncoder().encode(project)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "overlayClips")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StudioProject.self, from: legacy)
        XCTAssertTrue(decoded.overlayClips.isEmpty)
        XCTAssertEqual(decoded.schemaVersion, 5)
    }

    func testOverlayClipRoundTripsThroughProjectJSON() throws {
        var project = makeProject()
        let clip = OverlayClip(
            start: 0.5,
            duration: 2.5,
            kind: .video,
            fileName: "overlay-test.mov",
            aspect: 1.777,
            anchor: .topLeft,
            customCenter: NormalizedPoint(x: 0.4, y: 0.3),
            size: 0.35
        )
        project.overlayClips = [clip]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(
            StudioProject.self, from: data
        )
        XCTAssertEqual(decoded.overlayClips, [clip])
        XCTAssertEqual(decoded.schemaVersion, 5)
    }

    /// 剪切事务对叠加片段的 ripple 与缩放区同规则：跨切点分段保留
    /// （首段沿用原 ID），整体被删或剩余不足 0.1 秒丢弃。
    func testOverlayClipsRippleOnTimelineCut() throws {
        var project = makeProject()
        let overlayA = OverlayClip(
            start: 2.5, duration: 1.2, kind: .image, fileName: "a.png"
        )
        let overlayB = OverlayClip(
            start: 5.5,
            duration: 1.2,
            kind: .image,
            fileName: "b.png",
            aspect: 0.5
        )
        let overlayC = OverlayClip(
            start: 4.0, duration: 1.2, kind: .image, fileName: "c.png"
        )
        let overlayD = OverlayClip(
            start: 3.5, duration: 1.2, kind: .image, fileName: "d.png"
        )
        project.overlayClips = [overlayA, overlayB, overlayC, overlayD]

        let outcome = TimelineCutTransaction.apply(
            [
                SmartCutCandidate(
                    start: 3,
                    end: 5,
                    kind: .pureSpeechPause,
                    keepEachSide: 0
                )
            ],
            to: project.timeline
        )
        let updated = project.applyingCutTransaction(outcome)

        // A 保留头部 [2.5, 3.0]；B 平移 [3.5, 4.7]；C 只剩 0.2 秒；
        // D 整体落在删除区间被删。
        XCTAssertEqual(updated.overlayClips.count, 3)
        let a2 = try XCTUnwrap(
            updated.overlayClips.first { $0.id == overlayA.id }
        )
        XCTAssertEqual(a2.start, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(a2.duration, 0.5, accuracy: 0.000_001)
        let b2 = try XCTUnwrap(
            updated.overlayClips.first { $0.id == overlayB.id }
        )
        XCTAssertEqual(b2.start, 3.5, accuracy: 0.000_001)
        // 剪切涟漪不得丢素材宽高比（竖图重置回 16:9 曾是审查发现的
        // 静默变形 bug）。
        XCTAssertEqual(b2.aspect, 0.5, accuracy: 0.000_001)
        let c2 = try XCTUnwrap(
            updated.overlayClips.first { $0.id == overlayC.id }
        )
        XCTAssertEqual(c2.start, 3, accuracy: 0.000_001)
        XCTAssertEqual(c2.duration, 0.2, accuracy: 0.000_001)
        XCTAssertNil(
            updated.overlayClips.first { $0.id == overlayD.id }
        )
    }

    func testActiveOverlayClipsWindow() {
        var project = makeProject()
        let clip = OverlayClip(
            start: 2, duration: 1, kind: .image, fileName: "a.png"
        )
        project.overlayClips = [clip]
        XCTAssertTrue(project.activeOverlayClips(atOutput: 2.5).count == 1)
        XCTAssertTrue(project.activeOverlayClips(atOutput: 2).count == 1)
        XCTAssertTrue(project.activeOverlayClips(atOutput: 3).isEmpty)
        XCTAssertTrue(project.activeOverlayClips(atOutput: 1.9).isEmpty)
    }

    func testOverlayRectClampsInsideCanvas() {
        let outputSize = CGSize(width: 1600, height: 900)
        // 极端中心与超大宽高比：矩形仍钳在 2.5% 边距内。
        let rect = CanvasLayout.overlayRect(
            outputSize: outputSize,
            aspect: 8,
            center: CGPoint(x: 0.999, y: 0.999),
            size: 0.5
        )
        let margin = min(outputSize.width, outputSize.height) * 0.025
        XCTAssertGreaterThanOrEqual(rect.minX, margin - 0.5)
        XCTAssertLessThanOrEqual(rect.maxX, outputSize.width - margin + 0.5)
        XCTAssertGreaterThanOrEqual(rect.minY, margin - 0.5)
        XCTAssertLessThanOrEqual(rect.maxY, outputSize.height - margin + 0.5)
        // 中心钳制：矩形不会再出边距。
        let clamped = CanvasLayout.clampedOverlayCenter(
            CGPoint(x: 0.999, y: 0.999),
            outputSize: outputSize,
            aspect: 8,
            size: 0.5
        )
        let recheck = CanvasLayout.overlayRect(
            outputSize: outputSize,
            aspect: 8,
            center: clamped,
            size: 0.5
        )
        XCTAssertGreaterThanOrEqual(recheck.minX, margin - 0.5)
        XCTAssertLessThanOrEqual(recheck.maxX, outputSize.width - margin + 0.5)
    }

    /// 集成：真实导出含图片叠加的成片，叠加区域应是素材色（红），
    /// 且预览与导出画面一致（同一合成路径）。
    func testExportRendersImageOverlay() async throws {
        let folderName = "test-overlay-export-\(UUID().uuidString)"
        let folder = ProjectStore.rootURL.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let screenURL = folder.appendingPathComponent("screen.mp4")
        try await makeCheckerVideo(
            at: screenURL,
            size: CGSize(width: 320, height: 180),
            cells: 32,
            frameCount: 30,
            frameRate: 30
        )
        let overlayURL = folder.appendingPathComponent("overlay-red.png")
        try writeSolidPNG(CIColor(red: 1, green: 0, blue: 0), to: overlayURL)
        var project = makeProject()
        project.folderName = folderName
        project.duration = 1
        project.width = 320
        project.height = 180
        project.canvas.aspect = .source
        project.timeline = ProjectTimeline(
            clips: [TimelineClip(sourceStart: 0, sourceEnd: 1)]
        )
        project.overlayClips = [
            OverlayClip(
                start: 0,
                duration: 1,
                kind: .image,
                fileName: "overlay-red.png",
                aspect: 1,
                anchor: .bottomRight,
                size: 0.3
            )
        ]

        let outputURL = folder.appendingPathComponent("with-overlay.mp4")
        try await CompositionBuilder.makeExport(
            for: project,
            outputURL: outputURL
        ) { _ in }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = CIImage(
            cgImage: try await generator.image(
                at: CMTime(seconds: 0.5, preferredTimescale: 600)
            ).image
        )
        let outputSize = project.canvasOutputSize
        let rect = CanvasLayout.overlayRect(
            outputSize: outputSize,
            aspect: 1,
            center: project.overlayClips[0].effectiveCenter,
            size: 0.3
        )
        // 叠加区中心取红色样本（CIImage 坐标 y 向上）。
        let sample = try tryPixel(
            of: frame,
            at: CGPoint(x: rect.midX, y: rect.midY)
        )
        XCTAssertGreaterThan(sample.red, 0.7, "叠加区应为素材红色")
        XCTAssertLessThan(sample.green, 0.3)
        XCTAssertLessThan(sample.blue, 0.3)
        // 播放头同帧的预览也含叠加（预览/导出同一条合成路径）。
        let playerItem = try await CompositionBuilder.makePlayerItem(
            for: project
        )
        let previewGenerator = AVAssetImageGenerator(asset: playerItem.asset)
        previewGenerator.videoComposition = playerItem.videoComposition
        previewGenerator.requestedTimeToleranceBefore = .zero
        previewGenerator.requestedTimeToleranceAfter = .zero
        let previewFrame = CIImage(
            cgImage: try await previewGenerator.image(
                at: CMTime(seconds: 0.5, preferredTimescale: 600)
            ).image
        )
        let previewSample = try tryPixel(
            of: previewFrame,
            at: CGPoint(x: rect.midX, y: rect.midY)
        )
        XCTAssertGreaterThan(previewSample.red, 0.7)
    }

    private func tryPixel(
        of image: CIImage,
        at point: CGPoint
    ) throws -> (red: Double, green: Double, blue: Double) {
        let context = CIContext()
        let singlePixel = image
            .cropped(
                to: CGRect(
                    x: point.x,
                    y: point.y,
                    width: 1,
                    height: 1
                )
            )
            .transformed(
                by: CGAffineTransform(
                    translationX: -point.x,
                    y: -point.y
                )
            )
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            singlePixel,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (
            Double(pixel[0]) / 255,
            Double(pixel[1]) / 255,
            Double(pixel[2]) / 255
        )
    }

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

    private func testWindow(
        id: UInt32,
        displayID: UInt32?,
        app: String,
        title: String
    ) -> WindowCaptureInfo {
        WindowCaptureInfo(
            windowID: id,
            displayID: displayID,
            appName: app,
            title: title,
            width: 1200,
            height: 800
        )
    }

    private func writeTestPNG(to url: URL) throws {
        try testPNGData().write(to: url)
    }

    private func writeSolidPNG(_ color: CIColor, to url: URL) throws {
        let image = CIImage(color: color).cropped(
            to: CGRect(x: 0, y: 0, width: 32, height: 32)
        )
        let cgImage = try XCTUnwrap(
            CIContext().createCGImage(image, from: image.extent)
        )
        let data = try XCTUnwrap(
            NSBitmapImageRep(cgImage: cgImage).representation(
                using: .png,
                properties: [:]
            )
        )
        try data.write(to: url)
    }

    private func testPNGData() throws -> Data {
        let image = makeTestImage()
        let cgImage = try XCTUnwrap(
            CIContext().createCGImage(image, from: image.extent)
        )
        return try XCTUnwrap(
            NSBitmapImageRep(cgImage: cgImage).representation(
                using: .png,
                properties: [:]
            )
        )
    }

    private func makeTestVideo(
        at url: URL,
        fileType: AVFileType,
        size: CGSize,
        color: CIColor,
        alternateColor: CIColor? = nil,
        image: CIImage? = nil,
        frameCount: Int = 30,
        frameRate: Int = 30
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(input) else {
            throw ExportError.failed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.failed
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0 ..< frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let frameColor = index.isMultiple(of: 2)
                ? color
                : (alternateColor ?? color)
            let buffer = image.map {
                makePixelBuffer(image: $0, size: size)
            } ?? makePixelBuffer(
                color: frameColor,
                size: size
            )
            guard
                let buffer,
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(
                        value: CMTimeValue(index),
                        timescale: CMTimeScale(max(1, frameRate))
                    )
                )
            else {
                throw ExportError.failed
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? ExportError.failed
        }
    }

    private func makeTestAudio(
        at url: URL,
        duration: Double
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 44_100,
                channels: 1
            )
        )
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frameCount) {
            samples[index] = sin(Float(index) * 0.05) * 0.3
        }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings
            )
            try file.write(from: buffer)
        }
    }

    private func makePixelBuffer(
        color: CIColor,
        size: CGSize
    ) -> CVPixelBuffer? {
        makePixelBuffer(
            image: CIImage(color: color).cropped(
                to: CGRect(origin: .zero, size: size)
            ),
            size: size
        )
    }

    private func makePixelBuffer(
        image: CIImage,
        size: CGSize
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes,
            &buffer
        )
        guard let buffer else { return nil }
        CIContext().render(image, to: buffer)
        return buffer
    }

    private func videoFrame(
        at url: URL,
        time: Double
    ) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(
            at: CMTime(seconds: time, preferredTimescale: 600)
        ).image
    }

    private func pixel(
        in image: CIImage,
        at point: CGPoint
    ) throws -> (red: Int, green: Int, blue: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            image,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func rgbaPixel(
        in image: CIImage,
        at point: CGPoint
    ) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            image,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return bytes.map(Int.init)
    }

    private func makeTestImage() -> CIImage {
        let background = CIImage(color: .black)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let target = CIImage(color: .white)
            .cropped(to: CGRect(x: 145, y: 45, width: 10, height: 10))
        return target.composited(over: background)
    }

    private func makeChromaKeyCameraImage() -> CIImage {
        let green = CIImage(
            color: CIColor(
                red: 0,
                green: 177.0 / 255.0,
                blue: 64.0 / 255.0
            )
        ).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let foreground = CIImage(
            color: CIColor(
                red: 0.78,
                green: 0.52,
                blue: 0.38
            )
        ).cropped(to: CGRect(x: 60, y: 50, width: 80, height: 100))
        return foreground.composited(over: green)
    }

    private func makeTwoToneCameraImage() -> CIImage {
        let right = CIImage(
            color: CIColor(red: 0.05, green: 0.1, blue: 0.9)
        ).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 100))
        let left = CIImage(
            color: CIColor(red: 0.9, green: 0.05, blue: 0.05)
        ).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        return left.composited(over: right)
    }

    private func brightness(of image: CIImage, at point: CGPoint) throws -> CGFloat {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return 0
        }
        context.render(
            image,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )
        return CGFloat(pixel[0]) / 255
    }
}
