import AVFoundation
import AppKit
import Foundation
import QuartzCore
import SwiftUI

struct CameraDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String

    static func available() -> [CameraDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CameraDeviceOption(id: $0.uniqueID, name: $0.localizedName)
        }
    }
}

struct CameraRecordingStart {
    let fileURL: URL
    let startedAtHostTime: Double
}

struct CameraRecordingResult {
    let fileURL: URL
    let startedAtHostTime: Double
}

struct CameraRecordingStop {
    let result: CameraRecordingResult?
    let failure: Error?
}

enum CameraRecorderError: LocalizedError {
    case permission
    case deviceUnavailable
    case session(String)
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .permission:
            return "没有摄像头权限。请在“\(PrivacySettingsPane.camera.pathDescription)”里允许“八角录屏”。"
        case .deviceUnavailable:
            return "找不到可用的摄像头。"
        case let .session(message):
            return "摄像头启动失败：\(message)"
        case let .writer(message):
            return "摄像头录制失败：\(message)"
        }
    }
}

final class CameraRecorder: NSObject {
    let session = AVCaptureSession()
    var onUnexpectedFinish: ((Error) -> Void)?

    private let sessionQueue = DispatchQueue(
        label: "com.localstudio.camera",
        qos: .userInitiated
    )
    private var movieOutput: AVCaptureMovieFileOutput?
    private var configuredDeviceID: String?
    private var configuredResolution: CameraResolution?
    private var startContinuation: CheckedContinuation<CameraRecordingStart, Error>?
    private var stopContinuation: CheckedContinuation<CameraRecordingStop, Never>?
    private var recordingURL: URL?
    private var recordingStartedAt: Double?
    private var isRecording = false
    private var isPreviewRunning = false

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func recordingFinishedSuccessfully(_ error: Error?) -> Bool {
        guard let error else { return true }
        return (error as NSError).userInfo[
            AVErrorRecordingSuccessfullyFinishedKey
        ] as? Bool == true
    }

    func configure(
        deviceID: String?,
        resolution: CameraResolution
    ) async throws {
        if configuredDeviceID == deviceID, configuredResolution == resolution {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let device = try self.resolveDevice(deviceID: deviceID)
                    self.session.beginConfiguration()
                    self.session.inputs.forEach { self.session.removeInput($0) }
                    self.session.outputs.forEach { self.session.removeOutput($0) }
                    if self.session.canSetSessionPreset(resolution.preset) {
                        self.session.sessionPreset = resolution.preset
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else {
                        throw CameraRecorderError.session("无法添加摄像头输入")
                    }
                    self.session.addInput(input)
                    let output = AVCaptureMovieFileOutput()
                    guard self.session.canAddOutput(output) else {
                        throw CameraRecorderError.session("无法添加摄像头输出")
                    }
                    self.session.addOutput(output)
                    self.movieOutput = output
                    self.configuredDeviceID = deviceID ?? device.uniqueID
                    self.configuredResolution = resolution
                    self.session.commitConfiguration()
                    continuation.resume()
                } catch {
                    self.session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startPreview() async throws {
        if isPreviewRunning { return }
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.isPreviewRunning = self.session.isRunning
                if self.session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: CameraRecorderError.session("预览没有启动")
                    )
                }
            }
        }
    }

    func stopPreview() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.isPreviewRunning = false
                continuation.resume()
            }
        }
    }

    func startRecording(folder: URL) async throws -> CameraRecordingStart {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard let output = self.movieOutput else {
                    continuation.resume(
                        throwing: CameraRecorderError.deviceUnavailable
                    )
                    return
                }
                guard !output.isRecording else {
                    continuation.resume(
                        throwing: CameraRecorderError.writer("摄像头已经在录制")
                    )
                    return
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let url = folder.appendingPathComponent(
                    "camera-session-\(UUID().uuidString).mov"
                )
                try? FileManager.default.removeItem(at: url)
                self.recordingURL = url
                self.startContinuation = continuation
                self.stopContinuation = nil
                self.isRecording = true
                output.startRecording(
                    to: url,
                    recordingDelegate: self
                )
            }
        }
    }

    func stopRecording() async -> CameraRecordingStop {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard
                    self.isRecording,
                    let output = self.movieOutput,
                    output.isRecording
                else {
                    continuation.resume(
                        returning: CameraRecordingStop(
                            result: nil,
                            failure: nil
                        )
                    )
                    return
                }
                self.stopContinuation = continuation
                output.stopRecording()
            }
        }
    }

    func cancelRecording() {
        sessionQueue.async {
            if self.movieOutput?.isRecording == true {
                self.movieOutput?.stopRecording()
            }
            self.isRecording = false
            if let url = self.recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
            self.recordingURL = nil
            self.recordingStartedAt = nil
        }
    }

    private func resolveDevice(deviceID: String?) throws -> AVCaptureDevice {
        if let deviceID {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera,
                    .external,
                    .continuityCamera,
                    .deskViewCamera
                ],
                mediaType: .video,
                position: .unspecified
            )
            if let device = discovery.devices.first(where: {
                $0.uniqueID == deviceID
            }) {
                return device
            }
        }
        if let device = AVCaptureDevice.default(for: .video) {
            return device
        }
        throw CameraRecorderError.deviceUnavailable
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        sessionQueue.async {
            let startedAt = CACurrentMediaTime()
            self.recordingStartedAt = startedAt
            let info = CameraRecordingStart(
                fileURL: fileURL,
                startedAtHostTime: startedAt
            )
            self.startContinuation?.resume(returning: info)
            self.startContinuation = nil
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async {
            self.isRecording = false
            let succeeded = Self.recordingFinishedSuccessfully(error)
            if let error, !succeeded {
                let wasUnexpected = self.startContinuation == nil
                    && self.stopContinuation == nil
                self.startContinuation?.resume(throwing: error)
                self.startContinuation = nil
                self.stopContinuation?.resume(
                    returning: CameraRecordingStop(
                        result: nil,
                        failure: error
                    )
                )
                self.stopContinuation = nil
                try? FileManager.default.removeItem(at: outputFileURL)
                self.recordingURL = nil
                self.recordingStartedAt = nil
                if wasUnexpected {
                    let callback = self.onUnexpectedFinish
                    DispatchQueue.main.async {
                        callback?(error)
                    }
                }
                return
            }
            let result: CameraRecordingResult?
            if let startedAt = self.recordingStartedAt {
                result = CameraRecordingResult(
                    fileURL: outputFileURL,
                    startedAtHostTime: startedAt
                )
            } else {
                result = nil
            }
            self.startContinuation?.resume(
                throwing: CameraRecorderError.writer("摄像头没有开始录制")
            )
            self.startContinuation = nil
            self.stopContinuation?.resume(
                returning: CameraRecordingStop(
                    result: result,
                    failure: result == nil
                        ? CameraRecorderError.writer("摄像头没有开始录制")
                        : nil
                )
            )
            self.stopContinuation = nil
            self.recordingURL = nil
            self.recordingStartedAt = nil
        }
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = true

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.setMirrored(mirrored)
    }
}

enum CameraPreviewRegistry {
    private static let layers = NSHashTable<AVCaptureVideoPreviewLayer>
        .weakObjects()

    static func register(_ layer: AVCaptureVideoPreviewLayer) {
        layers.add(layer)
    }

    static func unregister(_ layer: AVCaptureVideoPreviewLayer) {
        layers.remove(layer)
    }

    static func detachAll() {
        for layer in layers.allObjects {
            layer.session = nil
        }
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        CameraPreviewRegistry.register(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    deinit {
        CameraPreviewRegistry.unregister(previewLayer)
    }

    func setMirrored(_ mirrored: Bool) {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}
