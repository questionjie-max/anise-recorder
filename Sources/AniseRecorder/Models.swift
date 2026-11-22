import AppKit
import AVFoundation
import Foundation
import AniseRecorderCore

enum CaptureQuality: String, CaseIterable, Codable, Identifiable {
    case fullHD
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullHD:
            return "清晰 1080p"
        case .original:
            return "原始分辨率"
        }
    }

    var detail: String {
        switch self {
        case .fullHD:
            return "体积更小，足够演示"
        case .original:
            return "最清晰，文件更大"
        }
    }
}

enum CaptureSourceKind: String, CaseIterable, Codable, Identifiable {
    case display
    case window
    case region

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display:
            return "屏幕"
        case .window:
            return "窗口"
        case .region:
            return "区域"
        }
    }

    var icon: String {
        switch self {
        case .display:
            return "display"
        case .window:
            return "macwindow"
        case .region:
            return "rectangle.dashed"
        }
    }
}

struct CaptureRegion: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isValid: Bool {
        width >= 0.01 && height >= 0.01
    }

    var normalizedRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func screenRect(in displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + x * displayFrame.width,
            y: displayFrame.minY + (1 - y - height) * displayFrame.height,
            width: width * displayFrame.width,
            height: height * displayFrame.height
        )
    }

    func displayLocalCaptureRect(in displayFrame: CGRect) -> CGRect {
        CGRect(
            x: x * displayFrame.width,
            y: y * displayFrame.height,
            width: width * displayFrame.width,
            height: height * displayFrame.height
        )
    }
}

struct WindowCaptureInfo: Codable, Hashable, Identifiable {
    var windowID: UInt32
    var displayID: UInt32?
    var appName: String
    var title: String
    var width: Int
    var height: Int
    var bundleIdentifier: String? = nil
    var screenFrame: CGRect? = nil
    /// 枚举时窗口是否在当前 macOS 桌面上可见；旧工程没有该字段时按可见处理。
    var isOnScreen: Bool? = nil

    var id: UInt32 { windowID }

    var isCurrentlyVisible: Bool { isOnScreen ?? true }

    var displayTitle: String {
        let name = title.isEmpty ? appName : title
        return "\(appName) · \(name)"
    }
}

enum CaptureSource: Codable, Hashable {
    case display(displayID: UInt32)
    case window(WindowCaptureInfo)
    case region(displayID: UInt32, region: CaptureRegion)

    var kind: CaptureSourceKind {
        switch self {
        case .display:
            return .display
        case .window:
            return .window
        case .region:
            return .region
        }
    }

    var displayID: UInt32? {
        switch self {
        case let .display(displayID):
            return displayID
        case .window:
            return nil
        case let .region(displayID, _):
            return displayID
        }
    }
}

enum CameraResolution: String, CaseIterable, Codable, Identifiable {
    case hd720
    case fullHD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd720:
            return "720p"
        case .fullHD:
            return "1080p"
        }
    }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720:
            return .hd1280x720
        case .fullHD:
            return .hd1920x1080
        }
    }
}

enum CameraShape: String, CaseIterable, Codable, Identifiable {
    case square
    case circle
    case roundedRectangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square:
            return "方形"
        case .circle:
            return "圆形"
        case .roundedRectangle:
            return "圆角"
        }
    }
}

enum CameraContentMode: String, CaseIterable, Codable, Identifiable {
    case fill
    case fit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill:
            return "填满"
        case .fit:
            return "完整显示"
        }
    }
}

enum CameraLayoutMode: String, CaseIterable, Codable, Identifiable {
    case pictureInPicture
    case sideBySide
    case screenOnly
    case cameraOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pictureInPicture:
            return "画面 + 摄像头"
        case .sideBySide:
            return "并排"
        case .screenOnly:
            return "只有画面"
        case .cameraOnly:
            return "只有摄像头"
        }
    }
}

enum CameraAnchor: String, CaseIterable, Codable, Identifiable {
    case topLeft
    case top
    case topRight
    case left
    case center
    case right
    case bottomLeft
    case bottom
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft:
            return "左上"
        case .top:
            return "上方"
        case .topRight:
            return "右上"
        case .left:
            return "左侧"
        case .center:
            return "居中"
        case .right:
            return "右侧"
        case .bottomLeft:
            return "左下"
        case .bottom:
            return "下方"
        case .bottomRight:
            return "右下"
        }
    }

    var normalizedCenter: CGPoint {
        let horizontal: CGFloat
        let vertical: CGFloat
        switch self {
        case .topLeft, .left, .bottomLeft:
            horizontal = 0.16
        case .top, .center, .bottom:
            horizontal = 0.5
        case .topRight, .right, .bottomRight:
            horizontal = 0.84
        }
        switch self {
        case .topLeft, .top, .topRight:
            vertical = 0.16
        case .left, .center, .right:
            vertical = 0.5
        case .bottomLeft, .bottom, .bottomRight:
            vertical = 0.84
        }
        return CGPoint(x: horizontal, y: vertical)
    }
}

struct CameraSettings: Codable, Hashable {
    var enabled: Bool = false
    var layout: CameraLayoutMode = .pictureInPicture
    var anchor: CameraAnchor = .bottomRight
    var customCenter: NormalizedPoint?
    var size: Double = 0.22
    var shape: CameraShape = .roundedRectangle
    var cornerRadius: Double = 0.14
    var mirrored: Bool = true
    var splitRatio: Double = 0.68
    var contentMode: CameraContentMode = .fill
    var cropFocus: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5)
    var borderColorHex: String = "#FFFFFF"
    var borderWidth: Double = 0
    var shadowEnabled: Bool = false
    var shadowIntensity: Double = 0.32
    var avoidsZoomFocus: Bool = true

    var hasCustomPosition: Bool {
        customCenter != nil
    }
}

extension CameraSettings {
    static var recordingDefault: CameraSettings {
        var settings = CameraSettings()
        settings.enabled = true
        settings.layout = .pictureInPicture
        settings.anchor = .bottomRight
        settings.customCenter = nil
        settings.size = 0.24
        settings.shape = .roundedRectangle
        settings.cornerRadius = 0.14
        return settings
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case layout
        case anchor
        case customCenter
        case size
        case shape
        case cornerRadius
        case mirrored
        case splitRatio
        case contentMode
        case cropFocus
        case borderColorHex
        case borderWidth
        case shadowEnabled
        case shadowIntensity
        case avoidsZoomFocus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .enabled
        ) ?? false
        layout = try values.decodeIfPresent(
            CameraLayoutMode.self,
            forKey: .layout
        ) ?? .pictureInPicture
        anchor = try values.decodeIfPresent(
            CameraAnchor.self,
            forKey: .anchor
        ) ?? .bottomRight
        customCenter = try values.decodeIfPresent(
            NormalizedPoint.self,
            forKey: .customCenter
        )
        size = try values.decodeIfPresent(Double.self, forKey: .size) ?? 0.22
        shape = try values.decodeIfPresent(
            CameraShape.self,
            forKey: .shape
        ) ?? .roundedRectangle
        cornerRadius = try values.decodeIfPresent(
            Double.self,
            forKey: .cornerRadius
        ) ?? 0.14
        mirrored = try values.decodeIfPresent(
            Bool.self,
            forKey: .mirrored
        ) ?? true
        splitRatio = try values.decodeIfPresent(
            Double.self,
            forKey: .splitRatio
        ) ?? 0.68
        contentMode = try values.decodeIfPresent(
            CameraContentMode.self,
            forKey: .contentMode
        ) ?? .fill
        cropFocus = try values.decodeIfPresent(
            NormalizedPoint.self,
            forKey: .cropFocus
        ) ?? NormalizedPoint(x: 0.5, y: 0.5)
        borderColorHex = try values.decodeIfPresent(
            String.self,
            forKey: .borderColorHex
        ) ?? "#FFFFFF"
        borderWidth = try values.decodeIfPresent(
            Double.self,
            forKey: .borderWidth
        ) ?? 0
        shadowEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .shadowEnabled
        ) ?? false
        shadowIntensity = try values.decodeIfPresent(
            Double.self,
            forKey: .shadowIntensity
        ) ?? 0.32
        avoidsZoomFocus = try values.decodeIfPresent(
            Bool.self,
            forKey: .avoidsZoomFocus
        ) ?? true
    }
}

/// C3 抠像模式三态（UI 用）：关闭 / 绿幕 / 自动分割。
enum CameraChromaKeyMode: String, CaseIterable, Identifiable {
    case off
    case greenScreen
    case personSegment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "关闭"
        case .greenScreen:
            return "绿幕"
        case .personSegment:
            return "自动分割"
        }
    }
}

struct CameraChromaKeySettings: Codable, Hashable {
    var enabled: Bool = false
    var keyColorHex: String = "#00B140"
    var tolerance: Double = 0.16
    var softness: Double = 0.08
    var spillSuppression: Double = 0.65
    /// 自动取色估计的低分辨率背景色场（12×7 网格 base64）。
    /// nil = 单点模式（手动取色或旧工程），用 keyColorHex 作均匀色场。
    var backgroundFieldData: String?
    /// C2 边缘三件套：哑光向内收缩（px，去绿边）与 alpha 小半径柔化
    /// （px，告别二值硬切边）。默认各 1px；旧工程缺省即此值。
    var edgeShrinkPixels: Double = 1
    var edgeFeatherPixels: Double = 1
    /// C3 人像自动分割（Vision 本机，accurate）：真 = 抠像模式为
    /// 「自动分割」（enabled 仍作总开关），假 = 「绿幕」；三态 =
    /// 关闭（enabled=false）/ 绿幕 / 自动分割。旧工程缺省 false →
    /// 映射为绿幕语义，不升 schema。
    var personSegmentation: Bool = false
    /// C3 分割背景呈现：false = 透明（默认），true = 摄像头自身背景
    /// 重模糊；不做替换指定图片。
    var segmentationBackgroundBlurred: Bool = false
    /// 边缘光包裹（light wrap）：把画布背景光沿 alpha
    /// 边缘环带叠回前景，消除人物「贴」在背景上的贴纸感。0 = 关闭，
    /// 1 = 满强度；默认 0.25（ Subtle ）。旧工程缺省即此值。
    var lightWrap: Double = 0.25

    private enum CodingKeys: String, CodingKey {
        case enabled
        case keyColorHex
        case tolerance
        case softness
        case spillSuppression
        case backgroundFieldData
        case edgeShrinkPixels
        case edgeFeatherPixels
        case personSegmentation
        case segmentationBackgroundBlurred
        case lightWrap
    }

    init(
        enabled: Bool = false,
        keyColorHex: String = "#00B140",
        tolerance: Double = 0.16,
        softness: Double = 0.08,
        spillSuppression: Double = 0.65,
        backgroundFieldData: String? = nil,
        edgeShrinkPixels: Double = 1,
        edgeFeatherPixels: Double = 1,
        personSegmentation: Bool = false,
        segmentationBackgroundBlurred: Bool = false,
        lightWrap: Double = 0.25
    ) {
        self.enabled = enabled
        self.keyColorHex = keyColorHex
        self.tolerance = tolerance
        self.softness = softness
        self.spillSuppression = spillSuppression
        self.backgroundFieldData = backgroundFieldData
        self.edgeShrinkPixels = edgeShrinkPixels
        self.edgeFeatherPixels = edgeFeatherPixels
        self.personSegmentation = personSegmentation
        self.segmentationBackgroundBlurred = segmentationBackgroundBlurred
        self.lightWrap = lightWrap
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .enabled
        ) ?? false
        keyColorHex = try values.decodeIfPresent(
            String.self,
            forKey: .keyColorHex
        ) ?? "#00B140"
        tolerance = try values.decodeIfPresent(
            Double.self,
            forKey: .tolerance
        ) ?? 0.16
        softness = try values.decodeIfPresent(
            Double.self,
            forKey: .softness
        ) ?? 0.08
        spillSuppression = try values.decodeIfPresent(
            Double.self,
            forKey: .spillSuppression
        ) ?? 0.65
        // 旧工程迁移：缺省为 nil → 单点模式（沿用 keyColorHex），行为
        // 按映射规则对齐（度量升级为色度距离，其余语义不变）。
        backgroundFieldData = try values.decodeIfPresent(
            String.self,
            forKey: .backgroundFieldData
        )
        edgeShrinkPixels = try values.decodeIfPresent(
            Double.self,
            forKey: .edgeShrinkPixels
        ) ?? 1
        edgeFeatherPixels = try values.decodeIfPresent(
            Double.self,
            forKey: .edgeFeatherPixels
        ) ?? 1
        // C3 旧工程迁移：缺省 false → 绿幕语义（enabled 语义不变）。
        personSegmentation = try values.decodeIfPresent(
            Bool.self,
            forKey: .personSegmentation
        ) ?? false
        segmentationBackgroundBlurred = try values.decodeIfPresent(
            Bool.self,
            forKey: .segmentationBackgroundBlurred
        ) ?? false
        // 迁移：缺省 0.25（边缘光包裹默认开启，subtle）。
        lightWrap = try values.decodeIfPresent(
            Double.self,
            forKey: .lightWrap
        ) ?? 0.25
    }
}

/// 加深队列：绿幕参数三套成套预设——一键套用后可继续微调。只改键控
/// 参数，不动幕布色 / 色场（建议先取色再套预设）。
enum CameraChromaKeyPreset: String, CaseIterable, Identifiable {
    case studioScreen
    case homeFabric
    case heavyShadow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studioScreen:
            return "影棚纯色幕"
        case .homeFabric:
            return "家用皱褶幕"
        case .heavyShadow:
            return "阴影重幕"
        }
    }

    var tolerance: Double {
        switch self {
        case .studioScreen:
            return 0.14
        case .homeFabric:
            return 0.2
        case .heavyShadow:
            return 0.26
        }
    }

    var softness: Double {
        switch self {
        case .studioScreen:
            return 0.06
        case .homeFabric:
            return 0.12
        case .heavyShadow:
            return 0.18
        }
    }

    var spillSuppression: Double {
        switch self {
        case .studioScreen:
            return 0.6
        case .homeFabric:
            return 0.7
        case .heavyShadow:
            return 0.8
        }
    }

    var edgeShrinkPixels: Double {
        switch self {
        case .studioScreen:
            return 1
        case .homeFabric:
            return 1.5
        case .heavyShadow:
            return 1
        }
    }

    var edgeFeatherPixels: Double {
        switch self {
        case .studioScreen:
            return 1
        case .homeFabric:
            return 1.5
        case .heavyShadow:
            return 2
        }
    }
}

struct CameraLayoutSegment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Double
    var transitionDuration: Double = 0.5
    var camera: CameraSettings
}

struct CameraTransition {
    let from: CameraSettings
    let to: CameraSettings
    let progress: Double
}

struct AudioTrackSettings: Codable, Hashable {
    var microphoneGain: Double = 0.8
    var systemGain: Double = 0.55
    var microphoneMuted: Bool = false
    var systemMuted: Bool = false
    /// 1.2 音频一键优化设置（Core `AudioEnhanceSettings`）。旧工程缺省
    /// 全关；增益值由分析建议、用户确认后写入。
    var processing: AudioEnhanceSettings = AudioEnhanceSettings()

    var microphoneVolume: Float {
        microphoneMuted ? 0 : Float(min(1, max(0, microphoneGain)))
    }

    var systemVolume: Float {
        systemMuted ? 0 : Float(min(1, max(0, systemGain)))
    }

    private enum CodingKeys: String, CodingKey {
        case microphoneGain
        case systemGain
        case microphoneMuted
        case systemMuted
        case processing
    }

    init(
        microphoneGain: Double = 0.8,
        systemGain: Double = 0.55,
        microphoneMuted: Bool = false,
        systemMuted: Bool = false,
        processing: AudioEnhanceSettings = AudioEnhanceSettings()
    ) {
        self.microphoneGain = microphoneGain
        self.systemGain = systemGain
        self.microphoneMuted = microphoneMuted
        self.systemMuted = systemMuted
        self.processing = processing
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        microphoneGain = try values.decodeIfPresent(
            Double.self,
            forKey: .microphoneGain
        ) ?? 0.8
        systemGain = try values.decodeIfPresent(
            Double.self,
            forKey: .systemGain
        ) ?? 0.55
        microphoneMuted = try values.decodeIfPresent(
            Bool.self,
            forKey: .microphoneMuted
        ) ?? false
        systemMuted = try values.decodeIfPresent(
            Bool.self,
            forKey: .systemMuted
        ) ?? false
        processing = try values.decodeIfPresent(
            AudioEnhanceSettings.self,
            forKey: .processing
        ) ?? AudioEnhanceSettings()
    }
}

struct ZoomRegion: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Double
    var duration: Double = 1.2
    var scale: Double = 1.65
    var center: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5)
    var enabled: Bool = true

    var end: Double {
        start + max(0.1, duration)
    }
}

/// F2 素材叠加轨（画中画）：把工程目录内的图片/视频素材叠在主画面
/// 之上。时间表达与 ZoomRegion 同构（成片时间 start+显式 duration），
/// 位置表达与 CameraSettings 同构（anchor 预设 + customCenter 归一化
/// 中心 + size 占 min(输出宽,高) 比例）。旧工程缺字段解码回退空数组，
/// 不升 Schema。
struct OverlayClip: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case image
        case video
    }

    static let minimumDuration: Double = 0.1
    static let sizeRange: ClosedRange<Double> = 0.1 ... 0.5

    var id: UUID = UUID()
    var start: Double
    var duration: Double
    var kind: Kind
    /// 工程目录内相对文件名（背景图同约定，不存绝对路径）。
    var fileName: String
    /// 素材宽高比（宽/高），渲染矩形按它折算高度。
    var aspect: Double = 16 / 9
    var anchor: CameraAnchor = .bottomRight
    var customCenter: NormalizedPoint?
    var size: Double = 0.22

    var end: Double {
        start + max(Self.minimumDuration, duration)
    }

    /// 生效中心：拖动过的 customCenter 优先，否则九宫格预设。
    var effectiveCenter: CGPoint {
        if let customCenter {
            return CGPoint(x: customCenter.x, y: customCenter.y)
        }
        return anchor.normalizedCenter
    }

    init(
        id: UUID = UUID(),
        start: Double,
        duration: Double,
        kind: Kind,
        fileName: String,
        aspect: Double = 16 / 9,
        anchor: CameraAnchor = .bottomRight,
        customCenter: NormalizedPoint? = nil,
        size: Double = 0.22
    ) {
        self.id = id
        self.start = start
        self.duration = duration
        self.kind = kind
        self.fileName = fileName
        self.aspect = aspect
        self.anchor = anchor
        self.customCenter = customCenter
        self.size = size
    }

    /// 容错解码：全字段 decodeIfPresent + 默认值——后续加字段不升
    /// Schema 时旧工程文件仍可解码（仓库既定口径）。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try values.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try values.decodeIfPresent(
            Double.self, forKey: .duration
        ) ?? 3
        kind = try values.decodeIfPresent(
            Kind.self, forKey: .kind
        ) ?? .image
        fileName = try values.decodeIfPresent(
            String.self, forKey: .fileName
        ) ?? ""
        aspect = try values.decodeIfPresent(
            Double.self, forKey: .aspect
        ) ?? 16 / 9
        anchor = try values.decodeIfPresent(
            CameraAnchor.self, forKey: .anchor
        ) ?? .bottomRight
        customCenter = try values.decodeIfPresent(
            NormalizedPoint.self, forKey: .customCenter
        )
        size = try values.decodeIfPresent(
            Double.self, forKey: .size
        ) ?? 0.22
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, duration, kind, fileName, aspect
        case anchor, customCenter, size
    }
}

/// 按键显示：录制期按键（源时间 + 小条文本）。源时间数据，剪切
/// 时与点击/标记一样原样保留；显示由 keyStripEnabled 控制。
struct KeyStrokeEvent: Codable, Hashable {
    var sourceTime: Double
    var text: String
}

enum CameraCompositionPreset: String, CaseIterable, Identifiable {
    case screenOnly
    case corner
    case circle
    case sideBySide
    case portraitStack
    case cameraOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenOnly:
            return "纯画面"
        case .corner:
            return "角落讲解"
        case .circle:
            return "圆形主讲师"
        case .sideBySide:
            return "并排讲解"
        case .portraitStack:
            return "竖屏上下"
        case .cameraOnly:
            return "纯摄像头"
        }
    }

    var icon: String {
        switch self {
        case .screenOnly:
            return "rectangle.inset.filled"
        case .corner:
            return "person.crop.circle"
        case .circle:
            return "circle.dashed"
        case .sideBySide:
            return "rectangle.split.2x1"
        case .portraitStack:
            return "rectangle.split.1x2"
        case .cameraOnly:
            return "person.crop.rectangle"
        }
    }

    func apply(to project: inout StudioProject) {
        project.camera = camera(applyingTo: project.camera)
        if let aspect = canvasAspectOverride {
            project.canvas.aspect = aspect
        }
    }

    func camera(applyingTo current: CameraSettings) -> CameraSettings {
        var camera = current
        switch self {
        case .screenOnly:
            camera.layout = .screenOnly
        case .corner:
            camera.enabled = true
            camera.layout = .pictureInPicture
            camera.anchor = .bottomRight
            camera.customCenter = nil
            camera.size = 0.24
            camera.shape = .roundedRectangle
            camera.cornerRadius = 0.14
            camera.splitRatio = 0.68
        case .circle:
            camera.enabled = true
            camera.layout = .pictureInPicture
            camera.anchor = .bottomLeft
            camera.customCenter = nil
            camera.size = 0.22
            camera.shape = .circle
        case .sideBySide:
            camera.enabled = true
            camera.layout = .sideBySide
            camera.splitRatio = 0.68
        case .portraitStack:
            camera.enabled = true
            camera.layout = .sideBySide
            camera.splitRatio = 0.65
        case .cameraOnly:
            camera.enabled = true
            camera.layout = .cameraOnly
        }
        return camera
    }

    var canvasAspectOverride: CanvasAspect? {
        switch self {
        case .sideBySide:
            return .landscape
        case .portraitStack:
            return .portrait
        case .screenOnly, .corner, .circle, .cameraOnly:
            return nil
        }
    }

    func matches(_ project: StudioProject) -> Bool {
        matches(project, camera: project.camera)
    }

    func matches(
        _ project: StudioProject,
        camera: CameraSettings
    ) -> Bool {
        switch self {
        case .screenOnly:
            return camera.layout == .screenOnly
        case .corner:
            return camera.layout == .pictureInPicture
                && camera.anchor == .bottomRight
                && camera.customCenter == nil
                && camera.shape == .roundedRectangle
                && abs(camera.size - 0.24) < 0.001
        case .circle:
            return camera.layout == .pictureInPicture
                && camera.anchor == .bottomLeft
                && camera.customCenter == nil
                && camera.shape == .circle
                && abs(camera.size - 0.22) < 0.001
        case .sideBySide:
            return camera.layout == .sideBySide
                && abs(camera.splitRatio - 0.68) < 0.001
                && project.canvas.aspect != .portrait
        case .portraitStack:
            return camera.layout == .sideBySide
                && abs(camera.splitRatio - 0.65) < 0.001
                && project.canvas.aspect == .portrait
        case .cameraOnly:
            return camera.layout == .cameraOnly
        }
    }
}

enum CameraPresetApplicationScope: String, CaseIterable, Identifiable {
    case fromPlayhead
    case entireProject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fromPlayhead:
            return "从播放头生效"
        case .entireProject:
            return "应用到全片"
        }
    }
}

enum CameraResizeCorner: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var horizontalSign: CGFloat {
        switch self {
        case .topLeft, .bottomLeft:
            return -1
        case .topRight, .bottomRight:
            return 1
        }
    }

    var verticalSign: CGFloat {
        switch self {
        case .topLeft, .topRight:
            return -1
        case .bottomLeft, .bottomRight:
            return 1
        }
    }
}

enum CanvasAspect: String, CaseIterable, Codable, Identifiable {
    case landscape
    case portrait
    case square
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape:
            return "横屏 16:9"
        case .portrait:
            return "竖屏 9:16"
        case .square:
            return "方形 1:1"
        case .source:
            return "原始比例"
        }
    }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    // 补 720p 档——4K 屏录的课程要发微信/文档，
    // 此前只能 1080p 起。枚举值域扩张，不进 project.json（会话态），
    // 不升 SchemaVersion（同 1.2 先例决策）。
    case hd720
    case fullHD
    case ultraHD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd720:
            return "720p"
        case .fullHD:
            return "1080p"
        case .ultraHD:
            return "4K"
        }
    }

    func outputSize(for project: StudioProject) -> CGSize {
        let canvasSize = project.canvasOutputSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return canvasSize
        }
        let shortEdge: CGFloat
        switch self {
        case .hd720:
            shortEdge = 720
        case .fullHD:
            shortEdge = 1080
        case .ultraHD:
            shortEdge = 2160
        }
        let ratio = canvasSize.width / canvasSize.height
        let width: CGFloat
        let height: CGFloat
        if ratio >= 1 {
            height = shortEdge
            width = shortEdge * ratio
        } else {
            width = shortEdge
            height = shortEdge / ratio
        }
        return CGSize(
            width: max(2, (width / 2).rounded() * 2),
            height: max(2, (height / 2).rounded() * 2)
        )
    }
}

enum ExportCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264:
            return "H.264"
        case .hevc:
            return "HEVC"
        }
    }

    var detail: String {
        switch self {
        case .h264:
            return "兼容性最好"
        case .hevc:
            return "同画质文件更小"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264:
            return .h264
        case .hevc:
            return .hevc
        }
    }
}

/// 导出平台预设：一键填充分辨率 / 帧率 / 编码 / 画布比例的组合。
/// 纯数据 + 纯映射，便于单测；nil 字段表示保持现状不动（手调后的值
/// 不被预设覆盖）。选中状态存应用偏好（UserDefaults），不进
/// project.json（Schema 保持 5）。
struct ExportPreset: Identifiable, Hashable {
    let id: String
    let title: String
    var resolution: ExportResolution?
    var frameRate: Int?
    var codec: ExportCodec?
    var canvasAspect: CanvasAspect?
    /// 下拉下方展示的说明；画布比例联动时必须带「作用于全片」提示。
    var note: String

    /// 恒等预设：不改任何字段，作为「不套用预设」的选项。
    static let originalID = "original"

    static let all: [ExportPreset] = [
        ExportPreset(
            id: ExportPreset.originalID,
            title: "原始画质",
            resolution: nil,
            frameRate: nil,
            codec: nil,
            canvasAspect: nil,
            note: "保持当前导出设置。"
        ),
        ExportPreset(
            id: "wechat-doc",
            title: "微信 / 文档 1080p30 H.264",
            resolution: .fullHD,
            frameRate: 30,
            codec: .h264,
            canvasAspect: nil,
            note: "兼容性最好，适合微信与文档分享。"
        ),
        ExportPreset(
            id: "portrait-916",
            title: "9:16 短视频",
            resolution: .fullHD,
            frameRate: 30,
            codec: .h264,
            canvasAspect: .portrait,
            note: "画布改为竖屏 9:16，作用于全片，可撤销。"
        ),
        ExportPreset(
            id: "master-4k-hevc",
            title: "4K 60fps HEVC",
            resolution: .ultraHD,
            frameRate: 60,
            codec: .hevc,
            canvasAspect: nil,
            note: "本地高清母版，同画质文件更小。"
        ),
        ExportPreset(
            id: "gif-attachment",
            title: "GIF 附件",
            resolution: nil,
            frameRate: nil,
            codec: nil,
            canvasAspect: .square,
            note: "GIF 走下方独立导出（15fps · 最长边 720）；画布改为方形 1:1，作用于全片，可撤销。"
        ),
    ]

    static func preset(id: String) -> ExportPreset? {
        all.first { $0.id == id }
    }

    /// 纯映射：把预设填充进当前导出设置，nil 字段保持原值。
    /// 画布比例不走这里，走 setCanvasAspect（与手动改比例同路径、可撤销）。
    static func applying(
        _ preset: ExportPreset,
        resolution: ExportResolution,
        frameRate: Int,
        codec: ExportCodec
    ) -> (resolution: ExportResolution, frameRate: Int, codec: ExportCodec) {
        (
            preset.resolution ?? resolution,
            preset.frameRate ?? frameRate,
            preset.codec ?? codec
        )
    }
}

/// 预设选中项偏好：存应用偏好（UserDefaults），不进单个工程
/// （沿用 1.2 术语表偏好先例）。
enum ExportPresetPreferences {
    /// 历史标识：偏好 key 前缀保持旧名，改名会丢用户已有设置。
    static let selectionKey = "LocalStudio.exportPresetSelection"

    static func loadSelectionID() -> String {
        UserDefaults.standard.string(forKey: selectionKey)
            ?? ExportPreset.originalID
    }

    static func saveSelectionID(_ id: String) {
        UserDefaults.standard.set(id, forKey: selectionKey)
    }
}

enum CanvasBackgroundKind: String, CaseIterable, Codable, Identifiable {
    case none
    case solid
    case gradient
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "无背景"
        case .solid:
            return "纯色"
        case .gradient:
            return "渐变"
        case .image:
            return "图片"
        }
    }
}

struct CanvasBackground: Codable, Hashable {
    var kind: CanvasBackgroundKind = .none
    var colorHex: String = "#101414"
    var gradientStartHex: String = "#17201E"
    var gradientEndHex: String = "#2B3830"
    var imageFile: String?
}

struct CanvasSettings: Codable, Hashable {
    var aspect: CanvasAspect = .source
    var background: CanvasBackground = CanvasBackground()
    var padding: Double = 0
    var cornerRadius: Double = 0
    var shadowEnabled: Bool = false
    var shadowIntensity: Double = 0.32

    static func forNewProject(source: CaptureSource) -> CanvasSettings {
        var settings = CanvasSettings()
        settings.aspect = .landscape
        switch source {
        case .display:
            settings.background.kind = .none
        case .window, .region:
            settings.background.kind = .gradient
            settings.padding = 0.035
            settings.cornerRadius = 0.03
            settings.shadowEnabled = true
        }
        return settings
    }
}

/// 提词器设置（提词器）：文稿与面板偏好。随工程持久化（旧工程缺字段
/// 回退默认，不升 Schema），也作为录制偏好的一部分在录制准备阶段使用。
struct TeleprompterSettings: Codable, Hashable {
    var script: String = ""
    var fontSize: Double = 28
    var speed: Double = 5
    /// 面板上次位置（屏幕坐标）；nil 表示尚未拖动过，使用默认位置
    /// （主屏右下、摄像头悬浮窗上方）。
    var panelFrame: CGRect?

    var hasScript: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case script
        case fontSize
        case speed
        case panelFrame
    }

    init(
        script: String = "",
        fontSize: Double = 28,
        speed: Double = 5,
        panelFrame: CGRect? = nil
    ) {
        self.script = script
        self.fontSize = fontSize
        self.speed = speed
        self.panelFrame = panelFrame
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        script = try values.decodeIfPresent(String.self, forKey: .script) ?? ""
        fontSize = try values.decodeIfPresent(
            Double.self,
            forKey: .fontSize
        ) ?? 28
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 5
        panelFrame = try values.decodeIfPresent(
            CGRect.self,
            forKey: .panelFrame
        )
    }
}

struct RecordSetup: Codable, Equatable {
    var displayID: UInt32
    var sourceKind: CaptureSourceKind
    var window: WindowCaptureInfo?
    var region: CaptureRegion?
    var fps: Int
    var quality: CaptureQuality
    var captureMicrophone: Bool
    var microphoneDeviceID: String?
    var captureSystemAudio: Bool
    var captureCamera: Bool
    var cameraDeviceID: String?
    var cameraResolution: CameraResolution
    var cameraComposition: CameraSettings?
    var countdown: Int
    /// 录制期记录按键（用于画面角落的小条显示）。
    var captureKeyStrokes: Bool
    /// 1118 Loop：点击放大前置配置——渲染期点击缩放的开关与参数，
    /// 开始录制时随新工程写入 project.json，录制后仍可在编辑器调整。
    var captureClickZoom: Bool
    var clickZoomDuration: Double
    var clickZoomScale: Double
    /// 录制准备阶段的提词器设置；开始录制后随工程写入 project.json。
    var teleprompter: TeleprompterSettings

    init(
        displayID: UInt32 = CGMainDisplayID(),
        sourceKind: CaptureSourceKind = .display,
        window: WindowCaptureInfo? = nil,
        region: CaptureRegion? = nil,
        fps: Int = 30,
        quality: CaptureQuality = .fullHD,
        captureMicrophone: Bool = true,
        microphoneDeviceID: String? = nil,
        captureSystemAudio: Bool = true,
        captureCamera: Bool = false,
        cameraDeviceID: String? = nil,
        cameraResolution: CameraResolution = .fullHD,
        cameraComposition: CameraSettings? = nil,
        countdown: Int = 3,
        captureKeyStrokes: Bool = false,
        captureClickZoom: Bool = true,
        clickZoomDuration: Double = 1.2,
        clickZoomScale: Double = 1.65,
        teleprompter: TeleprompterSettings = TeleprompterSettings()
    ) {
        self.displayID = displayID
        self.sourceKind = sourceKind
        self.window = window
        self.region = region
        self.fps = fps
        self.quality = quality
        self.captureMicrophone = captureMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.captureSystemAudio = captureSystemAudio
        self.captureCamera = captureCamera
        self.cameraDeviceID = cameraDeviceID
        self.cameraResolution = cameraResolution
        self.cameraComposition = cameraComposition
        self.countdown = countdown
        self.captureKeyStrokes = captureKeyStrokes
        self.captureClickZoom = captureClickZoom
        self.clickZoomDuration = clickZoomDuration
        self.clickZoomScale = clickZoomScale
        self.teleprompter = teleprompter
    }

    private enum CodingKeys: String, CodingKey {
        case displayID
        case sourceKind
        case window
        case region
        case fps
        case quality
        case captureMicrophone
        case microphoneDeviceID
        case captureSystemAudio
        case captureCamera
        case cameraDeviceID
        case cameraResolution
        case cameraComposition
        case countdown
        case captureKeyStrokes
        case captureClickZoom
        case clickZoomDuration
        case clickZoomScale
        case teleprompter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try values.decodeIfPresent(UInt32.self, forKey: .displayID)
            ?? CGMainDisplayID()
        sourceKind = try values.decodeIfPresent(
            CaptureSourceKind.self,
            forKey: .sourceKind
        ) ?? .display
        window = try values.decodeIfPresent(
            WindowCaptureInfo.self,
            forKey: .window
        )
        region = try values.decodeIfPresent(CaptureRegion.self, forKey: .region)
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        quality = try values.decodeIfPresent(
            CaptureQuality.self,
            forKey: .quality
        ) ?? .fullHD
        captureMicrophone = try values.decodeIfPresent(
            Bool.self,
            forKey: .captureMicrophone
        ) ?? true
        microphoneDeviceID = try values.decodeIfPresent(
            String.self,
            forKey: .microphoneDeviceID
        )
        captureSystemAudio = try values.decodeIfPresent(
            Bool.self,
            forKey: .captureSystemAudio
        ) ?? true
        captureCamera = try values.decodeIfPresent(
            Bool.self,
            forKey: .captureCamera
        ) ?? false
        cameraDeviceID = try values.decodeIfPresent(
            String.self,
            forKey: .cameraDeviceID
        )
        cameraResolution = try values.decodeIfPresent(
            CameraResolution.self,
            forKey: .cameraResolution
        ) ?? .fullHD
        cameraComposition = try values.decodeIfPresent(
            CameraSettings.self,
            forKey: .cameraComposition
        )
        countdown = try values.decodeIfPresent(Int.self, forKey: .countdown) ?? 3
        captureKeyStrokes = try values.decodeIfPresent(
            Bool.self, forKey: .captureKeyStrokes
        ) ?? false
        captureClickZoom = try values.decodeIfPresent(
            Bool.self, forKey: .captureClickZoom
        ) ?? true
        clickZoomDuration = try values.decodeIfPresent(
            Double.self, forKey: .clickZoomDuration
        ) ?? 1.2
        clickZoomScale = try values.decodeIfPresent(
            Double.self, forKey: .clickZoomScale
        ) ?? 1.65
        teleprompter = try values.decodeIfPresent(
            TeleprompterSettings.self,
            forKey: .teleprompter
        ) ?? TeleprompterSettings()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(displayID, forKey: .displayID)
        try values.encode(sourceKind, forKey: .sourceKind)
        try values.encodeIfPresent(window, forKey: .window)
        try values.encodeIfPresent(region, forKey: .region)
        try values.encode(fps, forKey: .fps)
        try values.encode(quality, forKey: .quality)
        try values.encode(captureMicrophone, forKey: .captureMicrophone)
        try values.encodeIfPresent(
            microphoneDeviceID,
            forKey: .microphoneDeviceID
        )
        try values.encode(captureSystemAudio, forKey: .captureSystemAudio)
        try values.encode(captureCamera, forKey: .captureCamera)
        try values.encodeIfPresent(cameraDeviceID, forKey: .cameraDeviceID)
        try values.encode(teleprompter, forKey: .teleprompter)
        try values.encode(cameraResolution, forKey: .cameraResolution)
        try values.encodeIfPresent(
            cameraComposition,
            forKey: .cameraComposition
        )
        try values.encode(countdown, forKey: .countdown)
        try values.encode(captureKeyStrokes, forKey: .captureKeyStrokes)
        try values.encode(captureClickZoom, forKey: .captureClickZoom)
        try values.encode(clickZoomDuration, forKey: .clickZoomDuration)
        try values.encode(clickZoomScale, forKey: .clickZoomScale)
    }

    var source: CaptureSource {
        switch sourceKind {
        case .display:
            return .display(displayID: displayID)
        case .window:
            if let window {
                return .window(window)
            }
            return .display(displayID: displayID)
        case .region:
            if let region, region.isValid {
                return .region(displayID: displayID, region: region)
            }
            return .display(displayID: displayID)
        }
    }
}

struct DisplayOption: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let resolution: String
    let isMain: Bool

    static func current() -> [DisplayOption] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            let displayID = number?.uint32Value ?? UInt32(index + 1)
            let scale = screen.backingScaleFactor
            let width = Int((screen.frame.width * scale).rounded())
            let height = Int((screen.frame.height * scale).rounded())
            let isMain = displayID == mainID
            return DisplayOption(
                id: displayID,
                name: "\(screen.localizedName)\(isMain ? " · 主屏" : "")",
                resolution: "\(width) × \(height)",
                isMain: isMain
            )
        }
    }
}

struct ClickEvent: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var time: Double
    var x: Double
    var y: Double
    var enabled: Bool = true
}

struct CursorSettings: Codable, Hashable {
    var enabled: Bool = true
    var size: Double = 1
    var smoothing: Double = 0.55
    var hideWhenIdle: Bool = true
    var idleDelay: Double = 1.2
    var clickHighlight: Bool = true
}

struct CursorAppearance: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var pngData: Data
    var pointWidth: Double
    var pointHeight: Double
    var hotspotX: Double
    var hotspotY: Double
}

struct CursorSample: Codable, Hashable {
    var sourceTime: Double
    var x: Double
    var y: Double
    var visible: Bool
    var appearanceID: UUID?
    var moved: Bool
}

/// 1.2 块6：精剪模式与保护开关的工程持久化（候选结果仍不持久化，
/// 沿用 1.1 决定）。旧工程缺字段时解码为默认值。
struct SmartCutSettings: Codable, Hashable {
    var mode: SmartCutMode = .natural
    var protectScreenActivity: Bool = true
    var protectSystemSound: Bool = true
}

struct CaptionCue: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var text: String
    var language: String?
}

/// 归一化矩形（左上角原点、y 向下，取值 0...1），1.2 打码区域锚定
/// 屏幕画面内容用。与 `CaptureRegion` 的坐标系约定一致（AGENTS.md）。
struct NormalizedRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isValid: Bool {
        width >= 0.005 && height >= 0.005
    }

    var cgRect: CGRect {
        CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    /// 钳制到 0...1，宽度 / 高度不足最小值时收缩，保证仍在画布内。
    func clamped() -> NormalizedRect {
        let maxWidth = max(0, 1 - x)
        let maxHeight = max(0, 1 - y)
        return NormalizedRect(
            x: min(1, max(0, x)),
            y: min(1, max(0, y)),
            width: min(maxWidth, max(0.005, width)),
            height: min(maxHeight, max(0.005, height))
        )
    }

    /// 归一化坐标 → Core Image 坐标（左下原点、y 向上）内的像素矩形。
    /// `container` 是渲染目标（画布或屏幕槽位）的像素矩形。
    func pixelRect(in container: CGRect) -> CGRect {
        CGRect(
            x: container.minX + x * container.width,
            y: container.minY + (1 - y - height) * container.height,
            width: width * container.width,
            height: height * container.height
        )
    }
}

enum RedactionStyle: String, CaseIterable, Codable, Identifiable {
    case blur
    case mosaic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur:
            return "高斯模糊"
        case .mosaic:
            return "马赛克"
        }
    }
}

/// 定时区域打码（1.2 块2）。`rect` 锚定**屏幕画面内容**的归一化坐标
/// （左上原点、y 向下、0...1），布局变化时跟画面走；`start / duration`
/// 是成片时间。导出像素不可逆——渲染直接破坏最终输出像素，不是可关的
/// 遮罩层。
struct RedactionRegion: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Double
    var duration: Double = 3
    var rect: NormalizedRect
    var style: RedactionStyle = .blur
    /// 强度 0.2...1：模糊半径 / 马赛克粒度随强度增大，默认 0.55。
    var intensity: Double = 0.55
    var enabled: Bool = true

    var end: Double {
        start + max(0.1, duration)
    }

    func isActive(atOutput time: Double) -> Bool {
        enabled && start <= time + 0.000_001 && time < end
    }

    /// 屏幕内容归一化矩形 → 最终输出像素矩形（Core Image 坐标，左下
    /// 原点、y 向上）。
    ///
    /// 合成顺序决策（写进注释与日志）：打码作用于**最终输出像素**——
    /// 矩形先经点击 / 手动缩放的投影映射再定位，放大后区域内内容依然
    /// 不可辨认；若作用于缩放前的原始画面，放大反而会暴露打码区细节。
    /// 布局变化时矩形锚定屏幕画面内容随之移动（screenRect 由 RenderPlan
    /// 按当前布局解析）。多显示器负坐标不影响此映射：打码锚定的是
    /// 裁剪后画面的归一化内容坐标，与显示器屏幕坐标无关。
    func outputRect(
        screenRect: CGRect,
        sourceSize: CGSize,
        zoomSettings: ZoomSettings,
        time: Double
    ) -> CGRect? {
        guard
            screenRect.width > 1,
            screenRect.height > 1,
            sourceSize.width > 1,
            sourceSize.height > 1
        else {
            return nil
        }
        let sourceExtent = CGRect(origin: .zero, size: sourceSize)
        guard
            let projection = ZoomRenderer.projection(
                sourceExtent: sourceExtent,
                time: time,
                settings: zoomSettings,
                outputSize: screenRect.size
            )
        else {
            return nil
        }
        let topLeft = projection.map(
            CGPoint(x: rect.x, y: rect.y),
            from: sourceExtent
        )
        let bottomRight = projection.map(
            CGPoint(
                x: rect.x + rect.width,
                y: rect.y + rect.height
            ),
            from: sourceExtent
        )
        let mapped = CGRect(
            x: screenRect.minX + min(topLeft.x, bottomRight.x),
            y: screenRect.minY + min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        ).intersection(screenRect)
        return mapped.width > 1 && mapped.height > 1 ? mapped : nil
    }
}

struct CaptionSettings: Codable, Hashable {
    var enabled: Bool = true
    var burnIn: Bool = false
    var fontScale: Double = 1
    var backgroundOpacity: Double = 0.58
    /// 1.2 双语字幕：副字幕轨开关（渲染与导出共用）。
    var secondaryEnabled: Bool = false
    /// 1.2 烧录模式：主 / 副 / 双。nil 时回退旧字段 `burnIn`
    /// （true → primary，false → off），旧工程行为不变。
    var burnMode: CaptionBurnMode?
    /// 副字幕相对主字幕的位置：主上副下（默认）或主下副上。
    var secondaryPosition: CaptionSecondaryPosition = .below
    /// 1.2 章节标题卡：每个章节起始处叠加约 2 秒章节标题（预览与导出
    /// 都显示，样式跟随字幕预设；章节数据来自现有字幕合并，不新造来源）。
    var chapterCardsEnabled: Bool = false

    /// 烧录模式的生效值（兼容旧工程）。
    var effectiveBurnMode: CaptionBurnMode {
        burnMode ?? (burnIn ? .primary : .off)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case burnIn
        case fontScale
        case backgroundOpacity
        case secondaryEnabled
        case burnMode
        case secondaryPosition
        case chapterCardsEnabled
    }

    init(
        enabled: Bool = true,
        burnIn: Bool = false,
        fontScale: Double = 1,
        backgroundOpacity: Double = 0.58,
        secondaryEnabled: Bool = false,
        burnMode: CaptionBurnMode? = nil,
        secondaryPosition: CaptionSecondaryPosition = .below,
        chapterCardsEnabled: Bool = false
    ) {
        self.enabled = enabled
        self.burnIn = burnIn
        self.fontScale = fontScale
        self.backgroundOpacity = backgroundOpacity
        self.secondaryEnabled = secondaryEnabled
        self.burnMode = burnMode
        self.secondaryPosition = secondaryPosition
        self.chapterCardsEnabled = chapterCardsEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        burnIn = try values.decodeIfPresent(Bool.self, forKey: .burnIn) ?? false
        fontScale = try values.decodeIfPresent(
            Double.self,
            forKey: .fontScale
        ) ?? 1
        backgroundOpacity = try values.decodeIfPresent(
            Double.self,
            forKey: .backgroundOpacity
        ) ?? 0.58
        secondaryEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .secondaryEnabled
        ) ?? false
        burnMode = try values.decodeIfPresent(
            CaptionBurnMode.self,
            forKey: .burnMode
        )
        secondaryPosition = try values.decodeIfPresent(
            CaptionSecondaryPosition.self,
            forKey: .secondaryPosition
        ) ?? .below
        chapterCardsEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .chapterCardsEnabled
        ) ?? false
    }
}

enum CaptionBurnMode: String, CaseIterable, Codable, Identifiable, Hashable {
    /// 不烧录（仍写旁车 SRT）。
    case off
    /// 只烧主字幕。
    case primary
    /// 只烧副字幕。
    case secondary
    /// 主副同烧。
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "不烧录"
        case .primary:
            return "主字幕"
        case .secondary:
            return "副字幕"
        case .both:
            return "双语"
        }
    }
}

enum CaptionSecondaryPosition: String, CaseIterable, Codable, Identifiable {
    /// 主上副下（默认，译文贴底）。
    case below
    /// 主下副上。
    case above

    var id: String { rawValue }

    var title: String {
        switch self {
        case .below:
            return "主上副下"
        case .above:
            return "主下副上"
        }
    }
}

/// 1.2 字幕样式预设：只是现有字幕参数的成套组合，不新增渲染路径，
/// 预览 / 导出共用 CaptionRenderer。
enum CaptionStylePreset: String, CaseIterable, Identifiable {
    case narration
    case standard
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .narration:
            return "解说大字"
        case .standard:
            return "标准双行"
        case .minimal:
            return "极简"
        }
    }

    var fontScale: Double {
        switch self {
        case .narration:
            return 1.6
        case .standard:
            return 1.0
        case .minimal:
            return 0.8
        }
    }

    var backgroundOpacity: Double {
        switch self {
        case .narration:
            return 0.6
        case .standard:
            return 0.58
        case .minimal:
            return 0.12
        }
    }

    func apply(to settings: inout CaptionSettings) {
        settings.fontScale = fontScale
        settings.backgroundOpacity = backgroundOpacity
    }

    func matches(_ settings: CaptionSettings) -> Bool {
        abs(settings.fontScale - fontScale) < 0.001
            && abs(settings.backgroundOpacity - backgroundOpacity) < 0.001
    }
}

/// 1.2 字幕术语表偏好：存应用偏好（UserDefaults），不进单个工程。
/// 偏好 key 前缀 `LocalStudio.` 为历史标识，改名会丢用户已有设置。
struct GlossaryPreferences {
    static let entriesKey = "LocalStudio.captionGlossary"
    static let autoApplyKey = "LocalStudio.captionGlossaryAutoApply"

    static func loadEntries() -> [GlossaryEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: entriesKey),
            let entries = try? JSONDecoder().decode(
                [GlossaryEntry].self,
                from: data
            )
        else {
            return []
        }
        return entries
    }

    static func saveEntries(_ entries: [GlossaryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    static func loadAutoApply() -> Bool {
        UserDefaults.standard.object(forKey: autoApplyKey) as? Bool ?? true
    }

    static func saveAutoApply(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoApplyKey)
    }
}

struct RecordingMarker: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var sourceTime: Double
    var name: String
    var createdAt: Date = Date()
}

struct StudioProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var folderName: String
    var videoFile: String
    var microphoneFile: String?
    var thumbnailFile: String?
    var duration: Double
    var width: Int
    var height: Int
    var fps: Int
    var clicks: [ClickEvent]
    var timeline: ProjectTimeline
    var zoomScale: Double
    var zoomDuration: Double
    var autoZoom: Bool
    var schemaVersion: Int
    var source: CaptureSource
    var systemAudioFile: String?
    var cameraFile: String?
    var cameraOffset: Double
    var camera: CameraSettings
    var cameraSegments: [CameraLayoutSegment]
    var cameraChromaKey: CameraChromaKeySettings
    var markers: [RecordingMarker]
    var rawCursor: [CursorSample]
    var cursor: CursorSettings
    var cursorAppearances: [CursorAppearance]
    var captions: CaptionSettings
    var captionCues: [CaptionCue]
    /// 1.2 双语字幕的副字幕轨（成片时间），第二份 SRT 导入。
    var secondaryCaptionCues: [CaptionCue]
    var audio: AudioTrackSettings
    var zoomRegions: [ZoomRegion]
    /// F2 素材叠加轨：可选字段，旧工程解码回退空数组，不升 Schema。
    var overlayClips: [OverlayClip]
    /// 按键显示：录制期按键与显示开关（可选字段，缺省关闭）。
    var keyStrokes: [KeyStrokeEvent]
    var keyStripEnabled: Bool
    var canvas: CanvasSettings
    var redactionRegions: [RedactionRegion]
    /// 语音驱动摄像头生成的布局段 ID；重复运行时按此幂等替换，
    /// 不会叠加，也不会触碰手动布局段。
    var smartCutAutoCameraSegmentIDs: [UUID]
    /// 1.2 块6 精剪设置持久化：模式与保护开关存工程（候选仍不持久化，
    /// 沿用 1.1 决定）。nil = 旧工程 / 未设置，解码时回退会话默认。
    var smartCutSettings: SmartCutSettings
    /// 提词器设置（提词器）：录制开始时由录制偏好带入，面板位置、字号、
    /// 速度按工程记忆恢复。旧工程缺字段解码回退默认，不升 Schema。
    var teleprompter: TeleprompterSettings

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        folderName: String,
        videoFile: String,
        microphoneFile: String? = nil,
        thumbnailFile: String? = nil,
        duration: Double,
        width: Int,
        height: Int,
        fps: Int,
        clicks: [ClickEvent],
        trimStart: Double,
        trimEnd: Double,
        zoomScale: Double,
        zoomDuration: Double,
        autoZoom: Bool,
        schemaVersion: Int = 5,
        source: CaptureSource = .display(displayID: CGMainDisplayID()),
        systemAudioFile: String? = nil,
        cameraFile: String? = nil,
        cameraOffset: Double = 0,
        camera: CameraSettings = CameraSettings(),
        cameraSegments: [CameraLayoutSegment] = [],
        cameraChromaKey: CameraChromaKeySettings = CameraChromaKeySettings(),
        markers: [RecordingMarker] = [],
        rawCursor: [CursorSample] = [],
        cursor: CursorSettings = CursorSettings(),
        cursorAppearances: [CursorAppearance] = [],
        captions: CaptionSettings = CaptionSettings(),
        captionCues: [CaptionCue] = [],
        secondaryCaptionCues: [CaptionCue] = [],
        audio: AudioTrackSettings = AudioTrackSettings(),
        zoomRegions: [ZoomRegion] = [],
        overlayClips: [OverlayClip] = [],
        keyStrokes: [KeyStrokeEvent] = [],
        keyStripEnabled: Bool = false,
        canvas: CanvasSettings = CanvasSettings(),
        redactionRegions: [RedactionRegion] = [],
        timeline: ProjectTimeline? = nil,
        smartCutAutoCameraSegmentIDs: [UUID] = [],
        smartCutSettings: SmartCutSettings = SmartCutSettings(),
        teleprompter: TeleprompterSettings = TeleprompterSettings()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.folderName = folderName
        self.videoFile = videoFile
        self.microphoneFile = microphoneFile
        self.thumbnailFile = thumbnailFile
        self.duration = duration
        self.width = width
        self.height = height
        self.fps = fps
        self.clicks = clicks
        self.timeline = timeline ?? ProjectTimeline(
            sourceStart: trimStart,
            sourceEnd: trimEnd
        )
        self.zoomScale = zoomScale
        self.zoomDuration = zoomDuration
        self.autoZoom = autoZoom
        self.schemaVersion = schemaVersion
        self.source = source
        self.systemAudioFile = systemAudioFile
        self.cameraFile = cameraFile
        self.cameraOffset = cameraOffset
        self.camera = camera
        self.cameraSegments = cameraSegments
        self.cameraChromaKey = cameraChromaKey
        self.markers = markers
        self.rawCursor = rawCursor
        self.cursor = cursor
        self.cursorAppearances = cursorAppearances
        self.captions = captions
        self.captionCues = captionCues
        self.secondaryCaptionCues = secondaryCaptionCues
        self.audio = audio
        self.zoomRegions = zoomRegions
        self.overlayClips = overlayClips
        self.keyStrokes = keyStrokes
        self.keyStripEnabled = keyStripEnabled
        self.canvas = canvas
        self.redactionRegions = redactionRegions
        self.smartCutAutoCameraSegmentIDs = smartCutAutoCameraSegmentIDs
        self.smartCutSettings = smartCutSettings
        self.teleprompter = teleprompter
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case folderName
        case videoFile
        case microphoneFile
        case thumbnailFile
        case duration
        case width
        case height
        case fps
        case clicks
        case trimStart
        case trimEnd
        case timeline
        case zoomScale
        case zoomDuration
        case autoZoom
        case schemaVersion
        case source
        case systemAudioFile
        case cameraFile
        case cameraOffset
        case camera
        case cameraSegments
        case cameraChromaKey
        case markers
        case rawCursor
        case cursor
        case cursorAppearances
        case captions
        case captionCues
        case secondaryCaptionCues
        case audio
        case zoomRegions
        case overlayClips
        case keyStrokes
        case keyStripEnabled
        case canvas
        case redactionRegions
        case smartCutAutoCameraSegmentIDs
        case smartCutSettings
        case teleprompter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        folderName = try values.decode(String.self, forKey: .folderName)
        videoFile = try values.decode(String.self, forKey: .videoFile)
        microphoneFile = try values.decodeIfPresent(
            String.self,
            forKey: .microphoneFile
        )
        thumbnailFile = try values.decodeIfPresent(
            String.self,
            forKey: .thumbnailFile
        )
        duration = try values.decode(Double.self, forKey: .duration)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        clicks = try values.decodeIfPresent(
            [ClickEvent].self,
            forKey: .clicks
        ) ?? []
        zoomScale = try values.decodeIfPresent(
            Double.self,
            forKey: .zoomScale
        ) ?? 1
        zoomDuration = try values.decodeIfPresent(
            Double.self,
            forKey: .zoomDuration
        ) ?? 1.2
        autoZoom = try values.decodeIfPresent(
            Bool.self,
            forKey: .autoZoom
        ) ?? false
        schemaVersion = 5
        source = try values.decodeIfPresent(
            CaptureSource.self,
            forKey: .source
        ) ?? .display(displayID: CGMainDisplayID())
        systemAudioFile = try values.decodeIfPresent(
            String.self,
            forKey: .systemAudioFile
        )
        cameraFile = try values.decodeIfPresent(
            String.self,
            forKey: .cameraFile
        )
        cameraOffset = try values.decodeIfPresent(
            Double.self,
            forKey: .cameraOffset
        ) ?? 0
        camera = try values.decodeIfPresent(
            CameraSettings.self,
            forKey: .camera
        ) ?? CameraSettings()
        cameraSegments = try values.decodeIfPresent(
            [CameraLayoutSegment].self,
            forKey: .cameraSegments
        ) ?? []
        cameraChromaKey = try values.decodeIfPresent(
            CameraChromaKeySettings.self,
            forKey: .cameraChromaKey
        ) ?? CameraChromaKeySettings()
        markers = try values.decodeIfPresent(
            [RecordingMarker].self,
            forKey: .markers
        ) ?? []
        rawCursor = try values.decodeIfPresent(
            [CursorSample].self,
            forKey: .rawCursor
        ) ?? []
        cursor = try values.decodeIfPresent(
            CursorSettings.self,
            forKey: .cursor
        ) ?? CursorSettings()
        cursorAppearances = try values.decodeIfPresent(
            [CursorAppearance].self,
            forKey: .cursorAppearances
        ) ?? []
        captions = try values.decodeIfPresent(
            CaptionSettings.self,
            forKey: .captions
        ) ?? CaptionSettings()
        captionCues = try values.decodeIfPresent(
            [CaptionCue].self,
            forKey: .captionCues
        ) ?? []
        secondaryCaptionCues = try values.decodeIfPresent(
            [CaptionCue].self,
            forKey: .secondaryCaptionCues
        ) ?? []
        audio = try values.decodeIfPresent(
            AudioTrackSettings.self,
            forKey: .audio
        ) ?? AudioTrackSettings()
        zoomRegions = try values.decodeIfPresent(
            [ZoomRegion].self,
            forKey: .zoomRegions
        ) ?? []
        // F2 素材叠加轨：可选字段，旧工程缺键回退空数组，不升 Schema。
        overlayClips = try values.decodeIfPresent(
            [OverlayClip].self,
            forKey: .overlayClips
        ) ?? []
        // 按键显示：可选字段，旧工程缺键回退空数组/关闭。
        keyStrokes = try values.decodeIfPresent(
            [KeyStrokeEvent].self,
            forKey: .keyStrokes
        ) ?? []
        keyStripEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .keyStripEnabled
        ) ?? false
        canvas = try values.decodeIfPresent(
            CanvasSettings.self,
            forKey: .canvas
        ) ?? CanvasSettings()
        redactionRegions = try values.decodeIfPresent(
            [RedactionRegion].self,
            forKey: .redactionRegions
        ) ?? []
        smartCutAutoCameraSegmentIDs = try values.decodeIfPresent(
            [UUID].self,
            forKey: .smartCutAutoCameraSegmentIDs
        ) ?? []
        smartCutSettings = try values.decodeIfPresent(
            SmartCutSettings.self,
            forKey: .smartCutSettings
        ) ?? SmartCutSettings()
        teleprompter = try values.decodeIfPresent(
            TeleprompterSettings.self,
            forKey: .teleprompter
        ) ?? TeleprompterSettings()

        if let decodedTimeline = try values.decodeIfPresent(
            ProjectTimeline.self,
            forKey: .timeline
        ) {
            timeline = decodedTimeline
        } else {
            let legacyStart = try values.decodeIfPresent(
                Double.self,
                forKey: .trimStart
            ) ?? 0
            let legacyEnd = try values.decodeIfPresent(
                Double.self,
                forKey: .trimEnd
            ) ?? duration
            let safeStart = min(
                max(0, legacyStart),
                max(0, duration - TimelineClip.minimumSourceDuration)
            )
            let safeEnd = min(
                max(
                    safeStart + TimelineClip.minimumSourceDuration,
                    legacyEnd
                ),
                max(duration, safeStart + TimelineClip.minimumSourceDuration)
            )
            timeline = ProjectTimeline(
                sourceStart: safeStart,
                sourceEnd: safeEnd
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(folderName, forKey: .folderName)
        try values.encode(videoFile, forKey: .videoFile)
        try values.encodeIfPresent(microphoneFile, forKey: .microphoneFile)
        try values.encodeIfPresent(thumbnailFile, forKey: .thumbnailFile)
        try values.encode(duration, forKey: .duration)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(fps, forKey: .fps)
        try values.encode(clicks, forKey: .clicks)
        try values.encode(timeline, forKey: .timeline)
        try values.encode(zoomScale, forKey: .zoomScale)
        try values.encode(zoomDuration, forKey: .zoomDuration)
        try values.encode(autoZoom, forKey: .autoZoom)
        try values.encode(5, forKey: .schemaVersion)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(
            systemAudioFile,
            forKey: .systemAudioFile
        )
        try values.encodeIfPresent(cameraFile, forKey: .cameraFile)
        try values.encode(cameraOffset, forKey: .cameraOffset)
        try values.encode(camera, forKey: .camera)
        try values.encode(cameraSegments, forKey: .cameraSegments)
        try values.encode(cameraChromaKey, forKey: .cameraChromaKey)
        try values.encode(markers, forKey: .markers)
        try values.encode(rawCursor, forKey: .rawCursor)
        try values.encode(cursor, forKey: .cursor)
        try values.encode(cursorAppearances, forKey: .cursorAppearances)
        try values.encode(captions, forKey: .captions)
        try values.encode(captionCues, forKey: .captionCues)
        try values.encode(secondaryCaptionCues, forKey: .secondaryCaptionCues)
        try values.encode(audio, forKey: .audio)
        try values.encode(zoomRegions, forKey: .zoomRegions)
        try values.encode(overlayClips, forKey: .overlayClips)
        try values.encode(keyStrokes, forKey: .keyStrokes)
        try values.encode(keyStripEnabled, forKey: .keyStripEnabled)
        try values.encode(canvas, forKey: .canvas)
        try values.encode(redactionRegions, forKey: .redactionRegions)
        try values.encode(
            smartCutAutoCameraSegmentIDs,
            forKey: .smartCutAutoCameraSegmentIDs
        )
        try values.encode(smartCutSettings, forKey: .smartCutSettings)
        try values.encode(teleprompter, forKey: .teleprompter)
    }

    var folderURL: URL {
        ProjectStore.rootURL.appendingPathComponent(folderName, isDirectory: true)
    }

    var videoURL: URL {
        folderURL.appendingPathComponent(videoFile)
    }

    var microphoneURL: URL? {
        fileURL(named: microphoneFile)
    }

    var systemAudioURL: URL? {
        fileURL(named: systemAudioFile)
    }

    var cameraURL: URL? {
        fileURL(named: cameraFile)
    }

    var thumbnailURL: URL? {
        fileURL(named: thumbnailFile)
    }

    var backgroundImageURL: URL? {
        fileURL(named: canvas.background.imageFile)
    }

    /// 导出卡「声音」行摘要：按真实录制轨组合显示（双轨 / 仅麦克风 /
    /// 仅系统声音 / 无声音），纯函数便于单测覆盖四种组合。
    static func audioTrackSummary(mic: String?, system: String?) -> String {
        switch (mic != nil, system != nil) {
        case (true, true): return "麦克风 + 系统声音"
        case (true, false): return "麦克风"
        case (false, true): return "系统声音"
        case (false, false): return "无声音"
        }
    }

    var trimStart: Double {
        timeline.clips.first?.sourceStart ?? 0
    }

    var trimEnd: Double {
        timeline.clips.map(\.sourceEnd).max() ?? duration
    }

    var trimDuration: Double {
        max(0, timeline.duration)
    }

    var sortedCameraSegments: [CameraLayoutSegment] {
        cameraSegments.sorted {
            if abs($0.start - $1.start) > 0.000_001 {
                return $0.start < $1.start
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func cameraSegmentIndex(atOutput time: Double) -> Int? {
        guard time.isFinite else { return nil }
        var activeIndex: Int?
        for (index, segment) in sortedCameraSegments.enumerated() {
            guard segment.start <= time + 0.000_001 else { break }
            activeIndex = index
        }
        return activeIndex
    }

    func cameraSegment(atOutput time: Double) -> CameraLayoutSegment? {
        guard let index = cameraSegmentIndex(atOutput: time) else {
            return nil
        }
        return sortedCameraSegments[index]
    }

    func cameraSettings(atOutput time: Double) -> CameraSettings {
        cameraSegment(atOutput: time)?.camera ?? camera
    }

    mutating func setCameraSegmentStart(
        _ start: Double,
        for segmentID: UUID
    ) -> Bool {
        guard
            let index = cameraSegments.firstIndex(where: {
                $0.id == segmentID
            })
        else {
            return false
        }
        let latestStart = max(0, trimDuration - 0.03)
        let clamped = min(max(0, start), latestStart)
        guard abs(cameraSegments[index].start - clamped) > 0.000_001 else {
            return false
        }
        cameraSegments[index].start = clamped
        return true
    }

    func cameraTransition(atOutput time: Double) -> CameraTransition? {
        guard
            time.isFinite,
            time >= 0,
            let index = cameraSegmentIndex(atOutput: time)
        else {
            return nil
        }
        let segments = sortedCameraSegments
        let segment = segments[index]
        let duration = min(2, max(0, segment.transitionDuration))
        guard segment.start > 0.000_001, duration > 0.000_001 else {
            return nil
        }
        let elapsed = time - segment.start
        guard elapsed >= 0, elapsed < duration else { return nil }
        let previous = index > 0 ? segments[index - 1].camera : camera
        guard previous != segment.camera else { return nil }
        let linear = min(1, max(0, elapsed / duration))
        return CameraTransition(
            from: previous,
            to: segment.camera,
            progress: linear * linear * (3 - 2 * linear)
        )
    }

    func zoomRegion(atOutput time: Double) -> ZoomRegion? {
        zoomRegions
            .filter {
                $0.start <= time + 0.000_001
                    && time < $0.end - 0.000_001
            }
            .max { $0.start < $1.start }
    }

    /// 当前时刻生效的打码区域（按开始时间排序）。
    func activeRedactionRegions(atOutput time: Double) -> [RedactionRegion] {
        redactionRegions
            .filter { $0.isActive(atOutput: time) }
            .sorted { $0.start < $1.start }
    }

    func outputTime(forSourceTime time: Double) -> Double? {
        timeline.outputTime(forSource: time)
    }

    @discardableResult
    mutating func addMarker(
        sourceTime: Double,
        name: String? = nil
    ) -> RecordingMarker? {
        guard
            sourceTime.isFinite,
            sourceTime >= 0,
            sourceTime <= duration
        else {
            return nil
        }
        let marker = RecordingMarker(
            sourceTime: sourceTime,
            name: name ?? "标记 \(markers.count + 1)"
        )
        markers.append(marker)
        sortMarkers()
        return marker
    }

    @discardableResult
    mutating func renameMarker(id: UUID, name: String) -> Bool {
        guard let index = markers.firstIndex(where: { $0.id == id }) else {
            return false
        }
        markers[index].name = String(name.prefix(80))
        return true
    }

    @discardableResult
    mutating func deleteMarker(id: UUID) -> Bool {
        guard let index = markers.firstIndex(where: { $0.id == id }) else {
            return false
        }
        markers.remove(at: index)
        return true
    }

    private mutating func sortMarkers() {
        markers.sort {
            if abs($0.sourceTime - $1.sourceTime) > 0.000_001 {
                return $0.sourceTime < $1.sourceTime
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var sourceAspectRatio: CGFloat {
        guard height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    var canvasOutputSize: CGSize {
        CanvasLayout.outputSize(for: self)
    }

    var aspectRatio: CGFloat {
        guard canvasOutputSize.height > 0 else { return 16 / 9 }
        return canvasOutputSize.width / canvasOutputSize.height
    }

    private func fileURL(named name: String?) -> URL? {
        guard let name else { return nil }
        let url = folderURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: 精剪应用

    /// 把剪切事务结果落进工程（路线图 4.5 第 5 步：裁剪 / 平移 / 删除规则
    /// 集中在这一个纯函数）。视频轨使用事务返回的时间线；摄像头布局段、
    /// 缩放区和字幕 cue 按删除区间同步 ripple；标记、点击和光标属于源时间，
    /// 原样保留。
    func applyingCutTransaction(
        _ outcome: TimelineCutTransaction.Outcome
    ) -> StudioProject {
        var updated = self
        updated.timeline = outcome.timeline
        updated.cameraSegments = rippledCameraSegments(outcome)
        updated.zoomRegions = rippledZoomRegions(outcome)
        updated.overlayClips = rippledOverlayClips(outcome)
        updated.captionCues = rippledCaptionCues(outcome)
        updated.secondaryCaptionCues = rippledCaptionCues(
            outcome,
            from: secondaryCaptionCues
        )
        updated.redactionRegions = rippledRedactionRegions(outcome)
        return updated
    }

    /// 布局段起点平移；起点落在删除区间内时贴到切点之后，不静默删除手动
    /// 布局段。两个布局段被剪到同一起点时保留较晚的一段。
    private func rippledCameraSegments(
        _ outcome: TimelineCutTransaction.Outcome
    ) -> [CameraLayoutSegment] {
        var mapped: [(origin: Double, segment: CameraLayoutSegment)] = []
        for segment in cameraSegments {
            guard
                let start = outcome.mappedTimeSnappingAfterCut(segment.start)
            else {
                continue
            }
            mapped.append(
                (
                    segment.start,
                    CameraLayoutSegment(
                        id: segment.id,
                        start: max(0, start),
                        transitionDuration: segment.transitionDuration,
                        camera: segment.camera
                    )
                )
            )
        }
        mapped.sort { $0.origin < $1.origin }
        let latestStart = max(0, outcome.timeline.duration - 0.03)
        var result: [CameraLayoutSegment] = []
        for entry in mapped {
            var segment = entry.segment
            segment.start = min(segment.start, latestStart)
            if
                let last = result.last,
                abs(last.start - segment.start) <= 1e-6
            {
                result[result.count - 1] = segment
            } else {
                result.append(segment)
            }
        }
        return result
    }

    /// 缩放区按删除区间裁剪；跨过切点时每段有效内容都保留，首段沿用原
    /// ID，后续分段生成新 ID。整体被删或剩余不足模型最短显示时长
    /// （0.1 秒）的片段丢弃。
    private func rippledZoomRegions(
        _ outcome: TimelineCutTransaction.Outcome
    ) -> [ZoomRegion] {
        var result: [ZoomRegion] = []
        for region in zoomRegions {
            var reusedOriginalID = false
            for piece in outcome.keptRanges(in: region.start...region.end) {
                let duration = piece.upperBound - piece.lowerBound
                guard duration >= 0.1 else { continue }
                result.append(
                    ZoomRegion(
                        id: reusedOriginalID ? UUID() : region.id,
                        start: piece.lowerBound,
                        duration: duration,
                        scale: region.scale,
                        center: region.center,
                        enabled: region.enabled
                    )
                )
                reusedOriginalID = true
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// 素材叠加片段按删除区间裁剪平移；跨切点分段保留，首段沿用原 ID，
    /// 后续分段生成新 ID；整体被删或剩余不足 0.1 秒的片段丢弃（与缩放区
    /// 同一规则）。素材文件本身不随剪切删除（可继续被其他片段引用）。
    private func rippledOverlayClips(
        _ outcome: TimelineCutTransaction.Outcome
    ) -> [OverlayClip] {
        var result: [OverlayClip] = []
        for clip in overlayClips {
            var reusedOriginalID = false
            for piece in outcome.keptRanges(in: clip.start ... clip.end) {
                let duration = piece.upperBound - piece.lowerBound
                guard duration >= OverlayClip.minimumDuration else { continue }
                result.append(
                    OverlayClip(
                        id: reusedOriginalID ? UUID() : clip.id,
                        start: piece.lowerBound,
                        duration: duration,
                        kind: clip.kind,
                        fileName: clip.fileName,
                        aspect: clip.aspect,
                        anchor: clip.anchor,
                        customCenter: clip.customCenter,
                        size: clip.size
                    )
                )
                reusedOriginalID = true
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// 输出时间上生效的叠加片段（按数组序叠放，先出现的在下层）。
    func activeOverlayClips(atOutput time: Double) -> [OverlayClip] {
        overlayClips.filter { $0.start <= time && time < $0.end }
    }

    /// 工程目录内素材的绝对路径（背景图同约定）。
    func overlayMediaURL(for clip: OverlayClip) -> URL? {
        fileURL(named: clip.fileName)
    }

    /// 打码区域按删除区间裁剪平移；跨切点分段保留，整体被删或剩余不足
    /// 0.1 秒的片段丢弃（与缩放区同一规则）。
    private func rippledRedactionRegions(
        _ outcome: TimelineCutTransaction.Outcome
    ) -> [RedactionRegion] {
        var result: [RedactionRegion] = []
        for region in redactionRegions {
            var reusedOriginalID = false
            for piece in outcome.keptRanges(in: region.start...region.end) {
                let duration = piece.upperBound - piece.lowerBound
                guard duration >= 0.1 else { continue }
                result.append(
                    RedactionRegion(
                        id: reusedOriginalID ? UUID() : region.id,
                        start: piece.lowerBound,
                        duration: duration,
                        rect: region.rect,
                        style: region.style,
                        intensity: region.intensity,
                        enabled: region.enabled
                    )
                )
                reusedOriginalID = true
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// 字幕 cue 按删除区间裁剪；跨过切点时每段有效内容都保留，首段沿用
    /// 原 ID，后续分段生成新 ID。整体被删或剩余不足 50 ms 的片段丢弃，
    /// 避免残留一闪而过的字幕。
    private func rippledCaptionCues(
        _ outcome: TimelineCutTransaction.Outcome,
        from cues: [CaptionCue]? = nil
    ) -> [CaptionCue] {
        var result: [CaptionCue] = []
        for cue in cues ?? captionCues {
            var reusedOriginalID = false
            for piece in outcome.keptRanges(in: cue.start...cue.end) {
                guard piece.upperBound - piece.lowerBound > 0.05 else {
                    continue
                }
                result.append(
                    CaptionCue(
                        id: reusedOriginalID ? UUID() : cue.id,
                        start: piece.lowerBound,
                        end: piece.upperBound,
                        text: cue.text,
                        language: cue.language
                    )
                )
                reusedOriginalID = true
            }
        }
        result.sort { $0.start < $1.start }
        return result
    }

    // MARK: 导出区间（1.2 块4）

    /// 只保留成片时间 [inPoint, outPoint] 的工程副本（导出「全片 /
    /// 入出点区间」用；编辑数据不受影响）。
    ///
    /// 实现**复用精剪原子剪切事务**：把 [0, inPoint) 和 [outPoint, 成片
    /// 时长) 当作两条候选删除交给 `TimelineCutTransaction`，摄像头布局段、
    /// 缩放区、字幕、打码和副字幕按既有 ripple 规则统一裁剪平移；标记、
    /// 点击和光标属源时间，原样保留。区间外没有内容可删时返回 nil。
    func clippedToOutputRange(
        inPoint: Double?,
        outPoint: Double?
    ) -> StudioProject? {
        let duration = trimDuration
        guard duration > 0.2 else { return nil }
        let inValue = min(max(0, inPoint ?? 0), duration)
        let outValue = min(
            max(inValue + 0.1, outPoint ?? duration),
            duration
        )
        guard inValue > 0.01 || outValue < duration - 0.01 else {
            return nil
        }
        var candidates: [SmartCutCandidate] = []
        if inValue > 0.01 {
            candidates.append(
                SmartCutCandidate(
                    start: 0,
                    end: inValue,
                    kind: .pureSpeechPause,
                    keepEachSide: 0
                )
            )
        }
        if outValue < duration - 0.01 {
            candidates.append(
                SmartCutCandidate(
                    start: outValue,
                    end: duration,
                    kind: .pureSpeechPause,
                    keepEachSide: 0
                )
            )
        }
        let outcome = TimelineCutTransaction.apply(
            candidates,
            to: timeline,
            frameDuration: fps > 0 ? 1.0 / Double(fps) : nil
        )
        guard !outcome.deletions.isEmpty else { return nil }
        return applyingCutTransaction(outcome)
    }

    // MARK: 语音驱动摄像头

    /// 人脸居中是否可用：与语音显隐相同的入口条件。
    var supportsFaceCentering: Bool {
        supportsVoiceCamera
    }

    /// C1 竖屏智能跟随应用：每个建议段生成一个自动布局段——沿用工程
    /// 默认摄像头设置，仅改 cropFocus.x（左上原点水平偏移，fill 模式下
    /// 生效），只平移不缩放：size、缩放区、cropFocus.y 全部不动。
    ///
    /// 与 1.2 人脸居中的作用域关系（约定写死，UI 同步说明）：竖屏跟随管
    /// 「取景」（9:16 画布下摄像头的水平裁剪位置），人脸居中管「焦点」
    /// （通用画布下的 x+y 取景焦点建议）。两者共用 `smartCutAutoCameraSegmentIDs`
    /// 自动段池，竖屏画布下冲突时以竖屏跟随为准：跟随应用整体替换自动段
    /// （含人脸居中段），重复运行幂等；存在手动布局段时拒绝并返回 nil，
    /// 绝不静默覆盖。
    func applyingPortraitFollowPlan(
        _ segments: [PortraitFollowPlanner.Segment]
    ) -> StudioProject? {
        let manualSegments = cameraSegments.filter {
            !smartCutAutoCameraSegmentIDs.contains($0.id)
        }
        guard manualSegments.isEmpty else { return nil }
        let duration = trimDuration
        let base = camera
        var followCamera = base
        followCamera.contentMode = .fill
        var generated: [CameraLayoutSegment] = []
        var generatedIDs: [UUID] = []
        for segment in segments {
            guard segment.start > 0.03, segment.start < duration - 0.03 else {
                continue
            }
            let clampedOffset = min(1, max(0, segment.offsetX))
            // 与上一段偏移几乎相同则合并，避免生成大量无意义切换。
            if let last = generated.last,
               abs(last.camera.cropFocus.x - clampedOffset) < 0.031
            {
                continue
            }
            var segmentCamera = followCamera
            segmentCamera.cropFocus = NormalizedPoint(
                x: clampedOffset,
                y: base.cropFocus.y
            )
            generated.append(
                CameraLayoutSegment(
                    start: segment.start,
                    transitionDuration: 0.5,
                    camera: segmentCamera
                )
            )
            generatedIDs.append(generated[generated.count - 1].id)
        }
        guard !generated.isEmpty else { return nil }
        var updated = self
        updated.cameraSegments = generated
        updated.smartCutAutoCameraSegmentIDs = generatedIDs
        return updated
    }

    /// 应用人脸居中建议（1.2 块5）：每个建议段生成一个布局段——沿用工程
    /// 默认摄像头设置，仅改 cropFocus（fill 模式下生效）并吸附到 0...1；
    /// 段起点按成片时间钳制、相邻同焦点合并。与语音显隐共用自动段来源
    /// 标识：整体替换自动段（含语音显隐段），重复运行幂等；存在手动布局
    /// 段时拒绝并返回 nil（应用层给出提示），绝不静默覆盖。
    func applyingFaceFocusPlan(
        _ segments: [FaceFocusPlanner.Segment]
    ) -> StudioProject? {
        let manualSegments = cameraSegments.filter {
            !smartCutAutoCameraSegmentIDs.contains($0.id)
        }
        guard manualSegments.isEmpty else { return nil }
        let duration = trimDuration
        let base = camera
        var focusCamera = base
        focusCamera.contentMode = .fill
        var generated: [CameraLayoutSegment] = []
        var generatedIDs: [UUID] = []
        for segment in segments {
            guard segment.start > 0.03, segment.start < duration - 0.03 else {
                continue
            }
            let clampedFocus = NormalizedPoint(
                x: min(1, max(0, segment.focus.x)),
                y: min(1, max(0, segment.focus.y))
            )
            // 与上一段焦点几乎相同则合并，避免生成大量无意义切换。
            if let last = generated.last,
               abs(last.camera.cropFocus.x - clampedFocus.x) < 0.031,
               abs(last.camera.cropFocus.y - clampedFocus.y) < 0.031
            {
                continue
            }
            var segmentCamera = focusCamera
            segmentCamera.cropFocus = clampedFocus
            generated.append(
                CameraLayoutSegment(
                    start: segment.start,
                    transitionDuration: 0.5,
                    camera: segmentCamera
                )
            )
            generatedIDs.append(generated[generated.count - 1].id)
        }
        guard !generated.isEmpty else { return nil }
        var updated = self
        updated.cameraSegments = generated
        updated.smartCutAutoCameraSegmentIDs = generatedIDs
        return updated
    }

    /// 语音显隐是否可用：没有摄像头文件、摄像头关闭或纯画面布局时不提供
    /// 生成入口（路线图第 5 节）。
    var supportsVoiceCamera: Bool {
        guard cameraURL != nil else { return false }
        guard camera.enabled else { return false }
        return camera.layout != .screenOnly
    }

    /// 生成语音显隐布局段（路线图第 5 节策略一）：已有**手动**布局段时拒绝
    /// 并返回 nil，应用层据此给出可见提示；上一次生成的自动段整体替换，
    /// 重复运行不会叠加。显隐设置直接取工程默认摄像头设置。
    func applyingVoiceCameraPlan(
        _ plan: SmartCutVoiceCamera.Plan,
        transitionDuration: Double = 0.5
    ) -> StudioProject? {
        let manualSegments = cameraSegments.filter {
            !smartCutAutoCameraSegmentIDs.contains($0.id)
        }
        guard manualSegments.isEmpty else { return nil }
        let duration = trimDuration
        let visible = camera
        var hidden = visible
        hidden.enabled = false
        var segments: [CameraLayoutSegment] = []
        var generatedIDs: [UUID] = []
        for interval in plan.intervals {
            guard interval.hideStart < duration - 0.03 else { continue }
            segments.append(
                CameraLayoutSegment(
                    start: interval.hideStart,
                    transitionDuration: transitionDuration,
                    camera: hidden
                )
            )
            generatedIDs.append(segments[segments.count - 1].id)
            if let revealStart = interval.revealStart,
               revealStart < duration - 0.03 {
                segments.append(
                    CameraLayoutSegment(
                        start: revealStart,
                        transitionDuration: transitionDuration,
                        camera: visible
                    )
                )
                generatedIDs.append(segments[segments.count - 1].id)
            }
        }
        segments.sort { $0.start < $1.start }
        var updated = self
        updated.cameraSegments = segments
        updated.smartCutAutoCameraSegmentIDs = generatedIDs
        return updated
    }
}

struct ProjectUndoHistory {
    private(set) var undoStack: [StudioProject] = []
    private(set) var redoStack: [StudioProject] = []
    private var lastGroupingKey: String?
    private var lastGroupingTime: TimeInterval?
    private let limit = 100
    private let groupingInterval: TimeInterval = 0.7

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    mutating func record(
        _ snapshot: StudioProject,
        groupingKey: String? = nil,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if
            let groupingKey,
            groupingKey == lastGroupingKey,
            let lastGroupingTime,
            time - lastGroupingTime <= groupingInterval
        {
            self.lastGroupingTime = time
            redoStack.removeAll()
            return
        }

        lastGroupingKey = groupingKey
        lastGroupingTime = time
        undoStack.append(snapshot)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
    }

    mutating func breakGrouping() {
        lastGroupingKey = nil
        lastGroupingTime = nil
    }

    mutating func undo(current: StudioProject) -> StudioProject? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        breakGrouping()
        return previous
    }

    mutating func redo(current: StudioProject) -> StudioProject? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        breakGrouping()
        return next
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
        breakGrouping()
    }
}

struct RawClick {
    let hostTime: Double
    let x: Double
    let y: Double
}

struct RecordingResult {
    let project: StudioProject
    let screenStartHostTime: Double
    let clock: CaptureClock
}

struct RecordingSessionManifest: Codable {
    var id: UUID
    var name: String
    var createdAt: Date
    var folderName: String
    var videoFile: String
    var microphoneFile: String?
    var systemAudioFile: String?
    var width: Int
    var height: Int
    var fps: Int
    var source: CaptureSource
}

private struct StudioProjectV1: Codable {
    var id: UUID
    var name: String
    var createdAt: Date
    var folderName: String
    var videoFile: String
    var microphoneFile: String?
    var thumbnailFile: String?
    var duration: Double
    var width: Int
    var height: Int
    var fps: Int
    var clicks: [ClickEvent]
    var trimStart: Double
    var trimEnd: Double
    var zoomScale: Double
    var zoomDuration: Double
    var autoZoom: Bool

    var migrated: StudioProject {
        StudioProject(
            id: id,
            name: name,
            createdAt: createdAt,
            folderName: folderName,
            videoFile: videoFile,
            microphoneFile: microphoneFile,
            thumbnailFile: thumbnailFile,
            duration: duration,
            width: width,
            height: height,
            fps: fps,
            clicks: clicks,
            trimStart: trimStart,
            trimEnd: trimEnd,
            zoomScale: zoomScale,
            zoomDuration: zoomDuration,
            autoZoom: autoZoom,
            source: .display(displayID: CGMainDisplayID()),
            canvas: CanvasSettings()
        )
    }
}

enum ProjectRemovalAction: String, CaseIterable, Identifiable {
    case ask
    case hide
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask:
            return "每次询问"
        case .hide:
            return "从列表移除"
        case .archive:
            return "归档"
        }
    }
}

/// 系统设置「隐私与安全性」各面板：显示名称与一键跳转。
/// 名称必须与 macOS 系统设置里的中文标题一致（用户照着找得到），
/// 深链走 x-apple.systempreferences 的 privacy_<服务>。
enum PrivacySettingsPane: String, CaseIterable {
    case screenRecording
    case camera
    case microphone
    case speechRecognition

    /// 系统设置里该面板的标题（macOS 15 简体中文）。
    var title: String {
        switch self {
        case .screenRecording:
            return "录屏与系统录音"
        case .camera:
            return "摄像头"
        case .microphone:
            return "麦克风"
        case .speechRecognition:
            return "语音识别"
        }
    }

    /// 「系统设置 › 隐私与安全性 › 摄像头」这种可照读的路径。
    var pathDescription: String {
        "系统设置 › 隐私与安全性 › \(title)"
    }

    /// `tccutil reset <服务名>` 使用的服务名（大小写敏感）。
    var tccServiceName: String {
        switch self {
        case .screenRecording:
            return "ScreenCapture"
        case .camera:
            return "Camera"
        case .microphone:
            return "Microphone"
        case .speechRecognition:
            return "SpeechRecognition"
        }
    }

    var urlString: String {
        "x-apple.systempreferences:com.apple.preference.security.privacy_\(tccServiceName)"
    }

    var url: URL? {
        URL(string: urlString)
    }

    @MainActor
    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 版本显示（从 App bundle 读取；发版 bump Info.plist 后自动跟随）。
enum AppVersion {
    static func short(in bundle: Bundle = .main) -> String? {
        bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
    }

    static func build(in bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// 「v0.4.0」；读不到时显示占位而不是空。
    static func display(in bundle: Bundle = .main) -> String {
        guard let short = short(in: bundle), !short.isEmpty else {
            return "v—"
        }
        return "v\(short)"
    }

    /// 「八角录屏 0.4.0（构建 4）」——悬停提示用。
    static func detailedDescription(in bundle: Bundle = .main) -> String {
        let short = short(in: bundle) ?? "—"
        if let build = build(in: bundle), !build.isEmpty {
            return "八角录屏 \(short)（构建 \(build)）"
        }
        return "八角录屏 \(short)"
    }
}

enum StudioPreferences {
    // 偏好 key 前缀 `LocalStudio.` 为历史标识，改名会丢用户已有设置。
    static let projectRemovalActionKey =
        "LocalStudio.projectRemovalAction"
    static let showHiddenProjectsKey = "LocalStudio.showHiddenProjects"
    static let sidebarCollapsedKey = "LocalStudio.sidebarCollapsed"
    static let editorOnboardingShownKey = "LocalStudio.editorOnboardingShown"
    /// 时间线折叠（全局偏好，跨工程跨重启）。
    static let editorTimelineCollapsedKey = "editorTimelineCollapsed"
    /// Esc 停止前需确认（应用偏好，不进工程数据 Schema 不变）。
    /// 默认 false = Esc 直接停止，现状不变。
    static let stopRequiresConfirmationKey =
        "LocalStudio.stopRequiresConfirmation"
    /// 清空删条首次确认的「不再提示」（应用偏好，默认 false =
    /// 首次弹确认）。
    static let captionDeleteConfirmSuppressedKey =
        "LocalStudio.captionDeleteConfirmSuppressed"

    static var projectRemovalAction: ProjectRemovalAction {
        guard
            let raw = UserDefaults.standard.string(
                forKey: projectRemovalActionKey
            ),
            let action = ProjectRemovalAction(rawValue: raw)
        else {
            return .ask
        }
        return action
    }

    static var showHiddenProjects: Bool {
        UserDefaults.standard.bool(forKey: showHiddenProjectsKey)
    }

    static var stopRequiresConfirmation: Bool {
        UserDefaults.standard.bool(forKey: stopRequiresConfirmationKey)
    }
}

enum ProjectStoreError: LocalizedError {
    case invalidFolderName
    case projectFolderMissing
    case notProjectFolder
    case reservedFolder
    case invalidProject
    case alreadyInLibrary
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolderName:
            return "工程目录名称无效，只能操作工程库根目录下的直接子目录。"
        case .projectFolderMissing:
            return "工程目录不存在或已被移动。"
        case .notProjectFolder:
            return "所选目录不是有效的八角录屏工程。"
        case .reservedFolder:
            return "工程库中的归档目录不能作为普通工程操作。"
        case .invalidProject:
            return "工程文件 project.json 无法读取。"
        case .alreadyInLibrary:
            return "这个工程已经在八角录屏工程库中。"
        case let .operationFailed(message):
            return "工程操作失败：\(message)"
        }
    }
}

enum ProjectStore {
    static let backupFilename = "project.previous.json"
    static let interruptedSessionFilename = "recording.json"
    /// 历史标识：标记文件名保持旧前缀；改名会让已移除的工程重新出现在列表。
    static let hiddenMarkerFilename = ".localstudio-hidden"
    static let archiveFolderName = "Archive"
    /// 工程数据目录名（与产品名统一为「八角录屏」）。
    static let rootFolderName = "八角录屏"
    /// 旧目录名（更名前）；App 启动时一次性迁移到新目录。
    static let legacyRootFolderName = "Local Studio"

    static var rootURL: URL {
        let movies = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
        let base = movies.appendingPathComponent(
            rootFolderName,
            isDirectory: true
        )
        // 只在 App 进程里做迁移（测试进程不触碰真实数据目录）。
        // bundle id 是历史标识：TCC 权限与旧目录迁移守卫都绑定在它上面，
        // 产品改名时不随之变更。
        if Bundle.main.bundleIdentifier == "com.localstudio.recorder" {
            migrateLegacyRootIfNeeded(
                from: movies.appendingPathComponent(
                    legacyRootFolderName,
                    isDirectory: true
                ),
                to: base
            )
        }
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        return base
    }

    /// 旧目录 → 新目录的一次性迁移：同卷优先整体 rename；目标已存在时
    /// 逐项合并（不覆盖同名，保留双方），迁移完的旧空目录移除。
    /// 幂等：旧目录不存在时立即返回。返回是否发生了移动。
    @discardableResult
    static func migrateLegacyRootIfNeeded(
        from legacy: URL,
        to target: URL
    ) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard
            manager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }
        if !manager.fileExists(atPath: target.path) {
            if (try? manager.moveItem(at: legacy, to: target)) != nil {
                return true
            }
        }
        guard
            let children = try? manager.contentsOfDirectory(
                at: legacy,
                includingPropertiesForKeys: nil
            )
        else {
            return false
        }
        let moved = mergeDirectory(from: legacy, to: target)
        if
            let remaining = try? manager.contentsOfDirectory(atPath: legacy.path),
            remaining.isEmpty
        {
            try? manager.removeItem(at: legacy)
        }
        return moved
    }

    /// 递归合并：目标不存在则整体移动；两边都是目录则继续下钻；
    /// 同名文件保留目标版本、旧文件留在原地（不覆盖、不丢数据）。
    private static func mergeDirectory(from source: URL, to target: URL) -> Bool {
        let manager = FileManager.default
        guard
            let children = try? manager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else {
            return false
        }
        var moved = false
        for child in children {
            let destination = target.appendingPathComponent(
                child.lastPathComponent
            )
            var childIsDirectory: ObjCBool = false
            let childExists = manager.fileExists(
                atPath: child.path,
                isDirectory: &childIsDirectory
            )
            guard childExists else { continue }
            var destinationIsDirectory: ObjCBool = false
            let destinationExists = manager.fileExists(
                atPath: destination.path,
                isDirectory: &destinationIsDirectory
            )
            if !destinationExists {
                if (try? manager.moveItem(at: child, to: destination)) != nil {
                    moved = true
                }
                continue
            }
            if childIsDirectory.boolValue && destinationIsDirectory.boolValue {
                if mergeDirectory(from: child, to: destination) {
                    moved = true
                }
                if
                    let remaining = try? manager.contentsOfDirectory(
                        atPath: child.path
                    ),
                    remaining.isEmpty
                {
                    try? manager.removeItem(at: child)
                }
            }
            // 同名文件：保留目标版本，旧文件留在原地等人工确认。
        }
        return moved
    }

    static var archiveURL: URL {
        let url = rootURL.appendingPathComponent(
            archiveFolderName,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let saveLock = NSLock()

    static func newFolder() -> (id: UUID, name: String, url: URL) {
        let id = UUID()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: Date()))-\(id.uuidString.prefix(6))"
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return (id, name, url)
    }

    static func saveInterruptedSession(
        _ manifest: RecordingSessionManifest
    ) throws {
        let url = rootURL
            .appendingPathComponent(manifest.folderName, isDirectory: true)
            .appendingPathComponent(interruptedSessionFilename)
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    static func removeInterruptedSession(in folder: URL) {
        try? FileManager.default.removeItem(
            at: folder.appendingPathComponent(interruptedSessionFilename)
        )
    }

    static func recoverInterruptedRecordings() async -> (
        projects: [StudioProject],
        issues: [String]
    ) {
        let manager = FileManager.default
        guard
            let folders = try? manager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return ([], [])
        }
        var projects: [StudioProject] = []
        var issues: [String] = []
        for folder in folders {
            let manifestURL = folder.appendingPathComponent(
                interruptedSessionFilename
            )
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? decoder.decode(
                    RecordingSessionManifest.self,
                    from: data
                )
            else {
                continue
            }
            let metadata = folder.appendingPathComponent("project.json")
            if
                let existing = try? Data(contentsOf: metadata),
                decode(existing) != nil
            {
                removeInterruptedSession(in: folder)
                continue
            }
            do {
                let project = try await recover(
                    manifest: manifest,
                    folder: folder
                )
                try save(project)
                removeInterruptedSession(in: folder)
                projects.append(project)
                issues.append(
                    "“\(project.name)”曾意外中断，已恢复前 \(Int(project.duration)) 秒的屏幕和声音；最后约两秒可能缺失。"
                )
            } catch {
                issues.append(
                    "“\(manifest.name)”的上次录制未能自动恢复，原始文件仍保留在工程目录：\(error.localizedDescription)"
                )
            }
        }
        return (projects, issues)
    }

    static func loadAll(includeHidden: Bool = false) -> [StudioProject] {
        loadAllWithIssues(includeHidden: includeHidden).projects
    }

    /// 把一次扫描的多条提示压成一条可读文案（toast 不能撑成一面墙）。
    /// 单条原样返回；多条只留第一条 + 数量，其余折叠。
    static func issueSummary(_ issues: [String]) -> String? {
        guard !issues.isEmpty else { return nil }
        if issues.count == 1 {
            return issues[0]
        }
        return "有 \(issues.count) 个工程文件夹需要处理：\(issues[0])"
            + "（其余 \(issues.count - 1) 条情况类似，原始文件均已保留在工程目录）"
    }

    static func loadAllWithIssues(includeHidden: Bool = false) -> (
        projects: [StudioProject],
        issues: [String]
    ) {
        let manager = FileManager.default
        guard
            let folders = try? manager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return ([], [])
        }
        var projects: [StudioProject] = []
        var issues: [String] = []
        for folder in folders {
            let folderName = folder.lastPathComponent
            guard folderName != archiveFolderName else { continue }
            guard
                (try? validatedFolderURL(named: folderName)) != nil
            else {
                continue
            }
            if !includeHidden, isHidden(folder: folder) {
                continue
            }
            let metadata = folder.appendingPathComponent("project.json")
            if
                let data = try? Data(contentsOf: metadata),
                let project = decode(data)
            {
                projects.append(project)
                continue
            }
            let backup = folder.appendingPathComponent(backupFilename)
            if
                let data = try? Data(contentsOf: backup),
                let project = decode(data)
            {
                projects.append(project)
                issues.append(
                    "“\(project.name)”的工程信息无法读取，已恢复上一份成功保存。原始文件仍保留在工程目录。"
                )
                continue
            }
            if manager.fileExists(
                atPath: folder.appendingPathComponent(
                    interruptedSessionFilename
                ).path
            ) {
                continue
            }
            issues.append(
                "工程文件夹“\(folder.lastPathComponent)”的主文件和备份都无法读取，已保留原文件以便手动恢复。"
            )
        }
        return (
            projects.sorted { $0.createdAt > $1.createdAt },
            issues
        )
    }

    static func save(_ project: StudioProject) throws {
        saveLock.lock()
        defer { saveLock.unlock() }
        let metadata = project.folderURL.appendingPathComponent("project.json")
        let data = try encoder.encode(project)
        if
            let current = try? Data(contentsOf: metadata),
            decode(current) != nil
        {
            let previous = project.folderURL
                .appendingPathComponent(backupFilename)
            try current.write(to: previous, options: [.atomic])
        }
        try data.write(to: metadata, options: [.atomic])
    }

    static func folderURL(forFolderName name: String) throws -> URL {
        try validatedFolderURL(named: name)
    }

    static func isHidden(_ project: StudioProject) -> Bool {
        (try? isHidden(project: project)) ?? false
    }

    static func setHidden(
        _ project: StudioProject,
        hidden: Bool
    ) throws {
        let folder = try validatedFolderURL(for: project)
        let marker = folder.appendingPathComponent(hiddenMarkerFilename)
        if hidden {
            try Data().write(to: marker, options: [.atomic])
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    @discardableResult
    static func archive(
        _ project: StudioProject,
        archiveRoot: URL? = nil
    ) throws -> URL {
        let source = try validatedFolderURL(for: project)
        let destinationRoot = archiveRoot ?? archiveURL
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        let destination = uniqueFolderURL(
            named: source.lastPathComponent,
            in: destinationRoot
        )
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            throw ProjectStoreError.operationFailed(
                error.localizedDescription
            )
        }
    }

    static func importProject(from source: URL) throws -> StudioProject {
        let fileManager = FileManager.default
        let sourceURL = source.standardizedFileURL
        let metadata = sourceURL.appendingPathComponent("project.json")
        guard
            let data = try? Data(contentsOf: metadata),
            let decoded = decode(data)
        else {
            throw ProjectStoreError.invalidProject
        }
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: sourceURL.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw ProjectStoreError.notProjectFolder
        }
        if
            let values = try? sourceURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ),
            values.isSymbolicLink == true
        {
            throw ProjectStoreError.notProjectFolder
        }
        if sourceURL.deletingLastPathComponent().standardizedFileURL
            == rootURL.standardizedFileURL
        {
            throw ProjectStoreError.alreadyInLibrary
        }

        let proposedName = (
            try? validatedFolderURL(named: decoded.folderName)
        ) != nil
            ? decoded.folderName
            : sourceURL.lastPathComponent
        _ = try validatedFolderURL(named: proposedName)
        let destination = uniqueFolderURL(named: proposedName, in: rootURL)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw ProjectStoreError.operationFailed(
                error.localizedDescription
            )
        }
        let hiddenMarker = destination.appendingPathComponent(
            hiddenMarkerFilename
        )
        if fileManager.fileExists(atPath: hiddenMarker.path) {
            try? fileManager.removeItem(at: hiddenMarker)
        }

        var imported = decoded
        if imported.folderName != destination.lastPathComponent {
            imported.folderName = destination.lastPathComponent
            do {
                try save(imported)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw ProjectStoreError.operationFailed(
                    error.localizedDescription
                )
            }
        }
        try? fileManager.removeItem(at: sourceURL)
        return imported
    }

    @discardableResult
    static func trash(_ project: StudioProject) throws -> URL {
        let folder = try validatedFolderURL(for: project)
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(
                at: folder,
                resultingItemURL: &resultingURL
            )
            return resultingURL as URL? ?? folder
        } catch {
            throw ProjectStoreError.operationFailed(
                error.localizedDescription
            )
        }
    }

    static func delete(_ project: StudioProject) throws {
        _ = try trash(project)
    }

    private static func validatedFolderURL(
        for project: StudioProject
    ) throws -> URL {
        let folder = try validatedFolderURL(named: project.folderName)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: folder.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw ProjectStoreError.projectFolderMissing
        }
        return folder
    }

    private static func validatedFolderURL(named name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed != ".",
            trimmed != "..",
            trimmed != archiveFolderName,
            !trimmed.contains("/"),
            !trimmed.contains("\\"),
            (trimmed as NSString).lastPathComponent == trimmed
        else {
            throw ProjectStoreError.invalidFolderName
        }
        let root = rootURL.standardizedFileURL
        let candidate = root
            .appendingPathComponent(trimmed, isDirectory: true)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else {
            throw ProjectStoreError.invalidFolderName
        }
        if
            let values = try? candidate.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ),
            values.isSymbolicLink == true
        {
            throw ProjectStoreError.invalidFolderName
        }
        return candidate
    }

    private static func isHidden(project: StudioProject) throws -> Bool {
        let folder = try validatedFolderURL(for: project)
        return isHidden(folder: folder)
    }

    private static func isHidden(folder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(
                hiddenMarkerFilename
            ).path
        )
    }

    private static func uniqueFolderURL(
        named name: String,
        in parent: URL
    ) -> URL {
        let manager = FileManager.default
        var candidate = parent.appendingPathComponent(
            name,
            isDirectory: true
        )
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent(
                "\(name)-\(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }

    static func decode(_ data: Data) -> StudioProject? {
        if let project = try? decoder.decode(StudioProject.self, from: data) {
            return project
        }
        if let old = try? decoder.decode(StudioProjectV1.self, from: data) {
            return old.migrated
        }
        return nil
    }

    private static func recover(
        manifest: RecordingSessionManifest,
        folder: URL
    ) async throws -> StudioProject {
        let screenURL = folder.appendingPathComponent(manifest.videoFile)
        let asset = AVURLAsset(url: screenURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.1 else {
            throw RecorderError.noVideo
        }
        let microphoneURL = manifest.microphoneFile.map {
            folder.appendingPathComponent($0)
        }
        let systemAudioURL = manifest.systemAudioFile.map {
            folder.appendingPathComponent($0)
        }
        return StudioProject(
            id: manifest.id,
            name: "\(manifest.name)（已恢复）",
            createdAt: manifest.createdAt,
            folderName: manifest.folderName,
            videoFile: manifest.videoFile,
            microphoneFile: existingAudioFile(microphoneURL)?.lastPathComponent,
            duration: (duration * 1000).rounded() / 1000,
            width: manifest.width,
            height: manifest.height,
            fps: manifest.fps,
            clicks: [],
            trimStart: 0,
            trimEnd: (duration * 1000).rounded() / 1000,
            zoomScale: 1.65,
            zoomDuration: 1.2,
            autoZoom: false,
            source: manifest.source,
            systemAudioFile: existingAudioFile(systemAudioURL)?.lastPathComponent,
            canvas: CanvasSettings.forNewProject(source: manifest.source)
        )
    }

    private static func existingAudioFile(_ url: URL?) -> URL? {
        guard
            let url,
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ),
            (values.fileSize ?? 0) > 512
        else {
            return nil
        }
        return url
    }
}

enum CanvasLayout {
    static func outputSize(for project: StudioProject) -> CGSize {
        outputSize(
            aspect: project.canvas.aspect,
            sourceSize: CGSize(width: project.width, height: project.height)
        )
    }

    static func outputSize(
        aspect: CanvasAspect,
        sourceSize: CGSize
    ) -> CGSize {
        switch aspect {
        case .landscape:
            return CGSize(width: 1920, height: 1080)
        case .portrait:
            return CGSize(width: 1080, height: 1920)
        case .square:
            return CGSize(width: 1080, height: 1080)
        case .source:
            return CGSize(
                width: max(2, sourceSize.width),
                height: max(2, sourceSize.height)
            )
        }
    }

    static func contentRect(
        outputSize: CGSize,
        sourceSize: CGSize,
        padding: Double
    ) -> CGRect {
        aspectFitRect(
            sourceSize: sourceSize,
            in: availableRect(outputSize: outputSize, padding: padding)
        )
    }

    static func availableRect(
        outputSize: CGSize,
        padding: Double
    ) -> CGRect {
        let inset = min(outputSize.width, outputSize.height) * padding
        return CGRect(origin: .zero, size: outputSize)
            .insetBy(dx: inset, dy: inset)
    }

    static func aspectFitRect(
        sourceSize: CGSize,
        in available: CGRect
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return available
        }
        let scale = min(
            available.width / sourceSize.width,
            available.height / sourceSize.height
        )
        let size = CGSize(
            width: max(2, sourceSize.width * scale),
            height: max(2, sourceSize.height * scale)
        )
        return CGRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func cameraSlot(
        outputSize: CGSize,
        contentRect: CGRect,
        settings: CameraSettings
    ) -> CGRect {
        switch settings.layout {
        case .cameraOnly:
            return contentRect
        case .sideBySide:
            let gap = min(outputSize.width, outputSize.height) * 0.025
            if outputSize.width >= outputSize.height {
                let split = min(0.8, max(0.5, settings.splitRatio))
                let screenWidth = contentRect.width * split - gap / 2
                let cameraX = contentRect.minX + screenWidth + gap
                return CGRect(
                    x: cameraX,
                    y: contentRect.minY,
                    width: contentRect.maxX - cameraX,
                    height: contentRect.height
                )
            }
            let split = min(0.8, max(0.5, settings.splitRatio))
            let cameraHeight = contentRect.height * (1 - split) - gap / 2
            return CGRect(
                x: contentRect.minX,
                y: contentRect.minY,
                width: contentRect.width,
                height: max(2, cameraHeight)
            )
        case .screenOnly, .pictureInPicture:
            let base = min(outputSize.width, outputSize.height)
            let normalizedCenter: CGPoint
            if let custom = settings.customCenter {
                normalizedCenter = CGPoint(
                    x: min(0.95, max(0.05, custom.x)),
                    y: min(0.95, max(0.05, custom.y))
                )
            } else {
                normalizedCenter = settings.anchor.normalizedCenter
            }
            let center = CGPoint(
                x: outputSize.width * normalizedCenter.x,
                y: outputSize.height * (1 - normalizedCenter.y)
            )
            let size = cameraSize(outputSize: outputSize, settings: settings)
            let margin = base * 0.025
            let x = min(
                max(margin, center.x - size.width / 2),
                outputSize.width - size.width - margin
            )
            let y = min(
                max(margin, center.y - size.height / 2),
                outputSize.height - size.height - margin
            )
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    static func cameraRectAvoidingZoomFocus(
        baseRect: CGRect,
        focusPoint: CGPoint,
        weight: CGFloat,
        outputSize: CGSize,
        settings: CameraSettings
    ) -> CGRect {
        let safePadding = min(baseRect.width, baseRect.height) * 0.04
        guard
            baseRect
                .insetBy(dx: -safePadding, dy: -safePadding)
                .contains(focusPoint)
        else {
            return baseRect
        }

        let shrink = 0.75
        let size = CGSize(
            width: baseRect.width * shrink,
            height: baseRect.height * shrink
        )
        var target = CGRect(
            x: baseRect.midX - size.width / 2,
            y: baseRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        if target
            .insetBy(dx: -safePadding, dy: -safePadding)
            .contains(focusPoint)
        {
            let margin = min(outputSize.width, outputSize.height) * 0.025
            let left = margin
            let right = max(left, outputSize.width - margin - size.width)
            let bottom = margin
            let top = max(bottom, outputSize.height - margin - size.height)
            let corners = [
                CGRect(origin: CGPoint(x: left, y: top), size: size),
                CGRect(origin: CGPoint(x: right, y: top), size: size),
                CGRect(origin: CGPoint(x: left, y: bottom), size: size),
                CGRect(origin: CGPoint(x: right, y: bottom), size: size)
            ]
            let emptyCorners = corners.filter {
                !$0
                    .insetBy(dx: -safePadding, dy: -safePadding)
                    .contains(focusPoint)
            }
            if let nearest = emptyCorners.min(by: {
                squaredDistance($0.center, baseRect.center)
                    < squaredDistance($1.center, baseRect.center)
            }) {
                target = nearest
            } else if let farthest = corners.max(by: {
                squaredDistance($0.center, focusPoint)
                    < squaredDistance($1.center, focusPoint)
            }) {
                target = farthest
            }
        }

        let progress = min(1, max(0, weight))
        guard progress > 0.000_001 else { return baseRect }
        return CGRect(
            x: baseRect.minX + (target.minX - baseRect.minX) * progress,
            y: baseRect.minY + (target.minY - baseRect.minY) * progress,
            width: baseRect.width
                + (target.width - baseRect.width) * progress,
            height: baseRect.height
                + (target.height - baseRect.height) * progress
        )
    }

    static func cameraSize(
        outputSize: CGSize,
        settings: CameraSettings
    ) -> CGSize {
        let base = min(outputSize.width, outputSize.height)
        let side = base * min(0.5, max(0.1, settings.size))
        if settings.shape == .roundedRectangle {
            return CGSize(width: side, height: side * 9 / 16)
        }
        return CGSize(width: side, height: side)
    }

    // MARK: F2 素材叠加轨几何（与摄像头语义无关的归一化矩形计算）

    /// 叠加片段的输出像素矩形：中心 = 归一化中心（左上原点、y 向下口径
    /// 与摄像头一致），宽 = size × min(输出宽,高)，高按素材宽高比折算，
    /// 钳制在 2.5% 边距内。
    static func overlayRect(
        outputSize: CGSize,
        aspect: CGFloat,
        center: CGPoint,
        size: Double
    ) -> CGRect {
        guard outputSize.width > 1, outputSize.height > 1, aspect > 0 else {
            return CGRect(origin: .zero, size: outputSize)
        }
        let dims = overlaySize(
            outputSize: outputSize, aspect: aspect, size: size
        )
        let clampedCenter = CGPoint(
            x: min(0.95, max(0.05, center.x)),
            y: min(0.95, max(0.05, center.y))
        )
        let centerPoint = CGPoint(
            x: outputSize.width * clampedCenter.x,
            y: outputSize.height * (1 - clampedCenter.y)
        )
        let margin = baseInset(outputSize: outputSize)
        let x = min(
            max(margin, centerPoint.x - dims.width / 2),
            max(margin, outputSize.width - dims.width - margin)
        )
        let y = min(
            max(margin, centerPoint.y - dims.height / 2),
            max(margin, outputSize.height - dims.height - margin)
        )
        return CGRect(
            origin: CGPoint(x: x, y: y),
            size: CGSize(width: dims.width, height: dims.height)
        )
    }

    static func overlaySize(
        outputSize: CGSize,
        aspect: CGFloat,
        size: Double
    ) -> CGSize {
        let base = min(outputSize.width, outputSize.height)
        let width = base * CGFloat(min(0.5, max(0.1, size)))
        let height = min(width / max(aspect, 0.01), base * 0.9)
        return CGSize(width: width, height: height)
    }

    static func clampedOverlayCenter(
        _ point: CGPoint,
        outputSize: CGSize,
        aspect: CGFloat,
        size: Double
    ) -> CGPoint {
        guard outputSize.width > 1, outputSize.height > 1, aspect > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let dims = overlaySize(
            outputSize: outputSize, aspect: aspect, size: size
        )
        let margin = baseInset(outputSize: outputSize)
        let minX = (margin + dims.width / 2) / outputSize.width
        let maxX = 1 - minX
        let minY = (margin + dims.height / 2) / outputSize.height
        let maxY = 1 - minY
        let cx = minX <= maxX ? min(maxX, max(minX, point.x)) : 0.5
        let cy = minY <= maxY ? min(maxY, max(minY, point.y)) : 0.5
        return CGPoint(x: cx, y: cy)
    }

    static func snappedOverlayCenter(
        _ point: CGPoint,
        outputSize: CGSize,
        aspect: CGFloat,
        size: Double,
        threshold: CGFloat = 0.012
    ) -> CGPoint {
        let clamped = clampedOverlayCenter(
            point,
            outputSize: outputSize,
            aspect: aspect,
            size: size
        )
        guard outputSize.width > 1, outputSize.height > 1, aspect > 0 else {
            return clamped
        }
        let dims = overlaySize(
            outputSize: outputSize, aspect: aspect, size: size
        )
        let margin = baseInset(outputSize: outputSize)
        let minX = (margin + dims.width / 2) / outputSize.width
        let maxX = 1 - minX
        let minY = (margin + dims.height / 2) / outputSize.height
        let maxY = 1 - minY
        return CGPoint(
            x: snap(
                clamped.x,
                to: [minX, 0.16, 0.5, 0.84, maxX]
                    .filter { $0 >= minX && $0 <= maxX },
                threshold: threshold
            ),
            y: snap(
                clamped.y,
                to: [minY, 0.16, 0.5, 0.84, maxY]
                    .filter { $0 >= minY && $0 <= maxY },
                threshold: threshold
            )
        )
    }

    /// F2：播放头时刻可见叠加片段的归一化矩形（左上原点口径，供画布
    /// 交互层把输出像素矩形映射到预览视图）。
    static func normalizedOverlayFrames(
        for project: StudioProject,
        time: TimeInterval
    ) -> [(clip: OverlayClip, frame: CGRect)] {
        let outputSize = project.canvasOutputSize
        guard outputSize.width > 1, outputSize.height > 1 else {
            return []
        }
        return project.activeOverlayClips(atOutput: time).map { clip in
            let rect = overlayRect(
                outputSize: outputSize,
                aspect: CGFloat(max(clip.aspect, 0.01)),
                center: clip.effectiveCenter,
                size: clip.size
            )
            let topLeft = CGRect(
                x: rect.minX,
                y: outputSize.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            let frame = CGRect(
                x: topLeft.minX / outputSize.width,
                y: topLeft.minY / outputSize.height,
                width: topLeft.width / outputSize.width,
                height: topLeft.height / outputSize.height
            )
            return (clip, frame)
        }
    }

    private static func baseInset(outputSize: CGSize) -> CGFloat {
        min(outputSize.width, outputSize.height) * 0.025
    }

    static func cameraResizeCorner(
        at location: CGPoint,
        frameSize: CGSize,
        handleInset: CGFloat,
        hitRadius: CGFloat
    ) -> CameraResizeCorner? {
        CameraResizeCorner.allCases.first { corner in
            let center = CGPoint(
                x: corner.horizontalSign < 0
                    ? handleInset
                    : frameSize.width - handleInset,
                y: corner.verticalSign < 0
                    ? handleInset
                    : frameSize.height - handleInset
            )
            return hypot(location.x - center.x, location.y - center.y)
                <= hitRadius
        }
    }

    static func clampedCameraCenter(
        _ point: CGPoint,
        outputSize: CGSize,
        settings: CameraSettings
    ) -> CGPoint {
        guard outputSize.width > 1, outputSize.height > 1 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let size = cameraSize(outputSize: outputSize, settings: settings)
        let margin = min(outputSize.width, outputSize.height) * 0.025
        let minX = (margin + size.width / 2) / outputSize.width
        let maxX = 1 - minX
        let minY = (margin + size.height / 2) / outputSize.height
        let maxY = 1 - minY
        return CGPoint(
            x: min(maxX, max(minX, point.x)),
            y: min(maxY, max(minY, point.y))
        )
    }

    static func snappedCameraCenter(
        _ point: CGPoint,
        outputSize: CGSize,
        settings: CameraSettings,
        threshold: CGFloat = 0.012
    ) -> CGPoint {
        let clamped = clampedCameraCenter(
            point,
            outputSize: outputSize,
            settings: settings
        )
        guard outputSize.width > 1, outputSize.height > 1 else {
            return clamped
        }

        let size = cameraSize(outputSize: outputSize, settings: settings)
        let margin = min(outputSize.width, outputSize.height) * 0.025
        let minX = (margin + size.width / 2) / outputSize.width
        let maxX = 1 - minX
        let minY = (margin + size.height / 2) / outputSize.height
        let maxY = 1 - minY
        return CGPoint(
            x: snap(
                clamped.x,
                to: [minX, 0.16, 0.5, 0.84, maxX],
                threshold: threshold
            ),
            y: snap(
                clamped.y,
                to: [minY, 0.16, 0.5, 0.84, maxY],
                threshold: threshold
            )
        )
    }

    static func normalizedCameraFrame(
        for project: StudioProject
    ) -> CGRect? {
        normalizedCameraFrame(for: project, settings: project.camera)
    }

    static func normalizedCameraFrame(
        for project: StudioProject,
        settings: CameraSettings,
        time: TimeInterval = 0
    ) -> CGRect? {
        guard
            settings.enabled,
            settings.layout == .pictureInPicture
        else {
            return nil
        }
        let outputSize = project.canvasOutputSize
        let plan = RenderPlan(
            project: project,
            time: time,
            outputSize: outputSize,
            settings: settings,
            burnsCaptions: false
        )
        let imageRect = plan.cameraRect
        let topLeftRect = CGRect(
            x: imageRect.minX,
            y: outputSize.height - imageRect.maxY,
            width: imageRect.width,
            height: imageRect.height
        )
        return CGRect(
            x: topLeftRect.minX / outputSize.width,
            y: topLeftRect.minY / outputSize.height,
            width: topLeftRect.width / outputSize.width,
            height: topLeftRect.height / outputSize.height
        )
    }

    static func screenSlot(
        outputSize: CGSize,
        contentRect: CGRect,
        settings: CameraSettings
    ) -> CGRect {
        guard settings.layout == .sideBySide else {
            return contentRect
        }
        let gap = min(outputSize.width, outputSize.height) * 0.025
        let cameraSlot = cameraSlot(
            outputSize: outputSize,
            contentRect: contentRect,
            settings: settings
        )
        if outputSize.width >= outputSize.height {
            return CGRect(
                x: contentRect.minX,
                y: contentRect.minY,
                width: max(2, cameraSlot.minX - gap - contentRect.minX),
                height: contentRect.height
            )
        }
        return CGRect(
            x: contentRect.minX,
            y: cameraSlot.maxY + gap,
            width: contentRect.width,
            height: max(2, contentRect.maxY - cameraSlot.maxY - gap)
        )
    }

    private static func snap(
        _ value: CGFloat,
        to targets: [CGFloat],
        threshold: CGFloat
    ) -> CGFloat {
        targets
            .min { abs($0 - value) < abs($1 - value) }
            .flatMap { abs($0 - value) <= threshold ? $0 : value }
            ?? value
    }

    private static func squaredDistance(
        _ left: CGPoint,
        _ right: CGPoint
    ) -> CGFloat {
        let dx = left.x - right.x
        let dy = left.y - right.y
        return dx * dx + dy * dy
    }
}

enum CameraOverlayGeometry {
    static func normalizedCameraRect(
        sourceSize: CGSize,
        canvas: CanvasSettings,
        settings: CameraSettings
    ) -> CGRect {
        let outputSize = CanvasLayout.outputSize(
            aspect: canvas.aspect,
            sourceSize: sourceSize
        )
        let contentRect = CanvasLayout.contentRect(
            outputSize: outputSize,
            sourceSize: sourceSize,
            padding: canvas.padding
        )
        let rect = CanvasLayout.cameraSlot(
            outputSize: outputSize,
            contentRect: contentRect,
            settings: settings
        )
        return CGRect(
            x: rect.minX / outputSize.width,
            y: (outputSize.height - rect.maxY) / outputSize.height,
            width: rect.width / outputSize.width,
            height: rect.height / outputSize.height
        )
    }

    static func panelFrame(
        sourceFrame: CGRect,
        sourceSize: CGSize,
        canvas: CanvasSettings,
        settings: CameraSettings
    ) -> CGRect {
        let normalized = normalizedCameraRect(
            sourceSize: sourceSize,
            canvas: canvas,
            settings: settings
        )
        return CGRect(
            x: sourceFrame.minX + normalized.minX * sourceFrame.width,
            y: sourceFrame.maxY
                - (normalized.minY + normalized.height) * sourceFrame.height,
            width: normalized.width * sourceFrame.width,
            height: normalized.height * sourceFrame.height
        )
    }

    static func moving(
        _ settings: CameraSettings,
        by translation: CGSize,
        sourceFrame: CGRect,
        sourceSize: CGSize,
        canvas: CanvasSettings
    ) -> CameraSettings {
        guard sourceFrame.width > 1, sourceFrame.height > 1 else {
            return settings
        }
        let outputSize = CanvasLayout.outputSize(
            aspect: canvas.aspect,
            sourceSize: sourceSize
        )
        let current = normalizedCameraRect(
            sourceSize: sourceSize,
            canvas: canvas,
            settings: settings
        )
        let desired = CGPoint(
            x: current.midX + translation.width / sourceFrame.width,
            y: current.midY + translation.height / sourceFrame.height
        )
        let center = CanvasLayout.snappedCameraCenter(
            desired,
            outputSize: outputSize,
            settings: settings
        )
        var updated = settings
        updated.customCenter = NormalizedPoint(x: center.x, y: center.y)
        return updated
    }

    static func resizing(
        _ settings: CameraSettings,
        corner: CameraResizeCorner,
        by translation: CGSize,
        sourceFrame: CGRect,
        sourceSize: CGSize,
        canvas: CanvasSettings
    ) -> CameraSettings {
        guard sourceFrame.width > 1, sourceFrame.height > 1 else {
            return settings
        }
        let minimumEdge = min(sourceFrame.width, sourceFrame.height)
        let signed = (
            translation.width * corner.horizontalSign
                + translation.height * corner.verticalSign
        ) / 2
        let size = min(0.5, max(0.1, settings.size + signed / minimumEdge))
        var updated = settings
        updated.size = size
        let current = normalizedCameraRect(
            sourceSize: sourceSize,
            canvas: canvas,
            settings: settings
        )
        let resized = normalizedCameraRect(
            sourceSize: sourceSize,
            canvas: canvas,
            settings: updated
        )
        let center = CGPoint(
            x: current.midX
                + corner.horizontalSign * (resized.width - current.width) / 2,
            y: current.midY
                + corner.verticalSign * (resized.height - current.height) / 2
        )
        let outputSize = CanvasLayout.outputSize(
            aspect: canvas.aspect,
            sourceSize: sourceSize
        )
        let clamped = CanvasLayout.clampedCameraCenter(
            center,
            outputSize: outputSize,
            settings: updated
        )
        updated.customCenter = NormalizedPoint(x: clamped.x, y: clamped.y)
        return updated
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

func formatDuration(_ seconds: Double, precise: Bool = false) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remaining = total % 60
    if precise {
        let hundredths = Int(((seconds - Double(total)) * 100).rounded())
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d.%02d",
                hours,
                minutes,
                remaining,
                hundredths
            )
        }
        return String(
            format: "%02d:%02d.%02d",
            minutes,
            remaining,
            hundredths
        )
    }
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remaining)
    }
    return String(format: "%d:%02d", minutes, remaining)
}

func formatFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

@MainActor
func loadAssetDuration(url: URL) async -> Double {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return 0 }
    return max(0, duration.seconds)
}
