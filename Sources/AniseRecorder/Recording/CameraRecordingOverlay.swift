import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class CameraRecordingOverlaySession: ObservableObject {
    @Published var settings: CameraSettings
    @Published var isAdjusting = false
    var sourceFrame: CGRect
    var sourceSize: CGSize
    var canvas: CanvasSettings

    init(
        settings: CameraSettings,
        sourceFrame: CGRect,
        sourceSize: CGSize,
        canvas: CanvasSettings
    ) {
        self.settings = settings
        self.sourceFrame = sourceFrame
        self.sourceSize = sourceSize
        self.canvas = canvas
    }
}

@MainActor
final class CameraRecordingOverlayController {
    private var panel: NSPanel?
    private var session: CameraRecordingOverlaySession?
    private var cameraSession: AVCaptureSession?
    private var onCommit: ((CameraSettings) -> Void)?
    private var isAdjusting = false

    /// 当前悬浮窗屏幕坐标（供提词面板默认位置参考）；未显示时为 nil。
    var currentPanelFrame: CGRect? {
        panel?.frame
    }

    func show(
        cameraSession: AVCaptureSession,
        settings: CameraSettings,
        sourceFrame: CGRect,
        sourceSize: CGSize,
        canvas: CanvasSettings,
        onCommit: @escaping (CameraSettings) -> Void
    ) {
        hide()
        var settings = settings
        settings.enabled = true
        settings.layout = .pictureInPicture
        let session = CameraRecordingOverlaySession(
            settings: settings,
            sourceFrame: sourceFrame,
            sourceSize: sourceSize,
            canvas: canvas
        )
        self.session = session
        self.cameraSession = cameraSession
        self.onCommit = onCommit
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 240, height: 140)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(
            rootView: CameraRecordingOverlayView(
                overlay: session,
                cameraSession: cameraSession,
                onMoveChanged: { [weak self] start, translation in
                    self?.moveSettings(
                        from: start,
                        translation: translation
                    )
                },
                onMoveEnded: { [weak self] start, translation in
                    guard let self else { return }
                    self.moveSettings(from: start, translation: translation)
                    self.commit()
                },
                onResizeChanged: { [weak self] start, corner, translation in
                    self?.resizeSettings(
                        from: start,
                        corner: corner,
                        translation: translation
                    )
                },
                onResizeEnded: { [weak self] start, corner, translation in
                    guard let self else { return }
                    self.resizeSettings(
                        from: start,
                        corner: corner,
                        translation: translation
                    )
                    self.commit()
                }
            )
        )
        self.panel = panel
        updatePanelFrame()
        panel.orderFrontRegardless()
    }

    func updateSource(
        frame: CGRect,
        size: CGSize,
        canvas: CanvasSettings
    ) {
        guard let session else { return }
        session.sourceFrame = frame
        session.sourceSize = size
        session.canvas = canvas
        updatePanelFrame()
    }

    func updateSettings(_ settings: CameraSettings) {
        guard let session else { return }
        session.settings = settings
        updatePanelFrame()
    }

    func setAdjusting(_ adjusting: Bool) {
        guard let panel, let session else { return }
        isAdjusting = adjusting
        session.isAdjusting = adjusting
        panel.ignoresMouseEvents = !adjusting
        if adjusting {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        isAdjusting = false
        panel?.orderOut(nil)
        panel = nil
        session = nil
        cameraSession = nil
        onCommit = nil
    }

    private func moveSettings(
        from start: CameraSettings,
        translation: CGSize
    ) {
        guard let session else { return }
        session.settings = CameraOverlayGeometry.moving(
            start,
            by: translation,
            sourceFrame: session.sourceFrame,
            sourceSize: session.sourceSize,
            canvas: session.canvas
        )
        updatePanelFrame()
    }

    private func resizeSettings(
        from start: CameraSettings,
        corner: CameraResizeCorner,
        translation: CGSize
    ) {
        guard let session else { return }
        session.settings = CameraOverlayGeometry.resizing(
            start,
            corner: corner,
            by: translation,
            sourceFrame: session.sourceFrame,
            sourceSize: session.sourceSize,
            canvas: session.canvas
        )
        updatePanelFrame()
    }

    private func commit() {
        guard let settings = session?.settings else { return }
        onCommit?(settings)
    }

    private func updatePanelFrame() {
        guard let panel, let session else { return }
        let frame = CameraOverlayGeometry.panelFrame(
            sourceFrame: session.sourceFrame,
            sourceSize: session.sourceSize,
            canvas: session.canvas,
            settings: session.settings
        )
        panel.setFrame(frame, display: true)
    }
}

private struct CameraRecordingOverlayView: View {
    @ObservedObject var overlay: CameraRecordingOverlaySession
    let cameraSession: AVCaptureSession
    let onMoveChanged: (CameraSettings, CGSize) -> Void
    let onMoveEnded: (CameraSettings, CGSize) -> Void
    let onResizeChanged:
        (CameraSettings, CameraResizeCorner, CGSize) -> Void
    let onResizeEnded:
        (CameraSettings, CameraResizeCorner, CGSize) -> Void

    @State private var moveStart: CameraSettings?
    @State private var resizeStart: CameraSettings?

    var body: some View {
        ZStack {
            preview
                .contentShape(Rectangle())
                .gesture(moveGesture)

            if overlay.isAdjusting {
                adjustmentOutline
                    .allowsHitTesting(false)
                resizeHandles
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 17)
                .fill(Color.black.opacity(0.12))
        )
    }

    @ViewBuilder
    private var adjustmentOutline: some View {
        if overlay.settings.shape == .circle {
            Circle()
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        } else {
            RoundedRectangle(
                cornerRadius: overlay.settings.shape == .square ? 8 : 14
            )
            .stroke(Color.white.opacity(0.72), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if overlay.settings.shape == .circle {
            CameraPreviewView(session: cameraSession, mirrored: true)
                .clipShape(Circle())
        } else {
            CameraPreviewView(session: cameraSession, mirrored: true)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: overlay.settings.shape == .square ? 8 : 14
                    )
                )
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = moveStart ?? overlay.settings
                if moveStart == nil {
                    moveStart = start
                }
                onMoveChanged(start, value.translation)
            }
            .onEnded { value in
                let start = moveStart ?? overlay.settings
                onMoveEnded(start, value.translation)
                moveStart = nil
            }
    }

    private var resizeHandles: some View {
        GeometryReader { geometry in
            ZStack {
                resizeHandle(.topLeft, at: CGPoint(x: 8, y: 8))
                resizeHandle(
                    .topRight,
                    at: CGPoint(x: geometry.size.width - 8, y: 8)
                )
                resizeHandle(
                    .bottomLeft,
                    at: CGPoint(x: 8, y: geometry.size.height - 8)
                )
                resizeHandle(
                    .bottomRight,
                    at: CGPoint(
                        x: geometry.size.width - 8,
                        y: geometry.size.height - 8
                    )
                )
            }
        }
    }

    private func resizeHandle(
        _ corner: CameraResizeCorner,
        at point: CGPoint
    ) -> some View {
        Circle()
            .fill(Color.white.opacity(0.92))
            .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1))
            .frame(width: 11, height: 11)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStart ?? overlay.settings
                        if resizeStart == nil {
                            resizeStart = start
                        }
                        onResizeChanged(start, corner, value.translation)
                    }
                    .onEnded { value in
                        let start = resizeStart ?? overlay.settings
                        onResizeEnded(start, corner, value.translation)
                        resizeStart = nil
                    }
            )
    }
}
