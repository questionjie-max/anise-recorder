import AVFoundation
import Foundation
import AniseRecorderCore

enum CameraTrackBuilderError: LocalizedError {
    case missingTrack
    case cannotCreateWriter
    case cannotRead
    case cannotWrite
    case noFrames

    var errorDescription: String? {
        switch self {
        case .missingTrack:
            return "摄像头文件里没有视频轨道。"
        case .cannotCreateWriter:
            return "无法整理摄像头录制文件。"
        case .cannotRead:
            return "无法读取摄像头录制文件。"
        case .cannotWrite:
            return "无法写入摄像头录制文件。"
        case .noFrames:
            return "摄像头没有产生可用画面。"
        }
    }
}

enum CameraTrackBuilder {
    struct Output {
        let url: URL
        let offset: Double
    }

    static func build(
        sessions: [CameraRecordingResult],
        clock: CaptureClock,
        folder: URL
    ) async throws -> Output? {
        guard !sessions.isEmpty else { return nil }
        let outputURL = folder.appendingPathComponent("camera.mov")

        if sessions.count == 1, !clock.hasPauses {
            let session = sessions[0]
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(
                at: session.fileURL,
                to: outputURL
            )
            let origin = clock.originHostTime ?? session.startedAtHostTime
            return Output(
                url: outputURL,
                offset: max(0, session.startedAtHostTime - origin)
            )
        }

        let firstActiveTime = try await findFirstActiveTime(
            sessions: sessions,
            clock: clock
        )
        guard let firstActiveTime else {
            throw CameraTrackBuilderError.noFrames
        }
        let prepared = try await prepareWriter(
            sessions: sessions,
            outputURL: outputURL
        )
        let temporaryURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let writer = try AVAssetWriter(
            outputURL: temporaryURL,
            fileType: .mov
        )
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: prepared.format
        )
        input.expectsMediaDataInRealTime = false
        input.transform = prepared.transform
        guard writer.canAdd(input) else {
            throw CameraTrackBuilderError.cannotCreateWriter
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CameraTrackBuilderError.cannotCreateWriter
        }
        writer.startSession(atSourceTime: .zero)

        var lastOutputTime = -Double.infinity
        var wroteFrame = false
        for session in sessions {
            let asset = AVURLAsset(url: session.fileURL)
            guard
                let track = try await asset.loadTracks(
                    withMediaType: .video
                ).first
            else {
                continue
            }
            let trackRange = try await track.load(.timeRange)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw CameraTrackBuilderError.cannotRead
            }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? CameraTrackBuilderError.cannotRead
            }

            while let sample = output.copyNextSampleBuffer() {
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                let hostTime = session.startedAtHostTime
                    + sourceTime
                    - trackRange.start.seconds
                guard
                    let activeTime = clock.outputTime(
                        forHostTime: hostTime
                    )
                else {
                    continue
                }
                let outputTime = activeTime - firstActiveTime
                guard
                    outputTime >= 0,
                    outputTime > lastOutputTime + 0.000_001
                else {
                    continue
                }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let retimed = retime(sample, to: outputTime) else {
                    continue
                }
                guard input.append(retimed) else {
                    throw writer.error ?? CameraTrackBuilderError.cannotWrite
                }
                lastOutputTime = outputTime
                wroteFrame = true
            }
            if reader.status == .failed {
                throw reader.error ?? CameraTrackBuilderError.cannotRead
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard
            wroteFrame,
            writer.status == .completed
        else {
            throw writer.error ?? CameraTrackBuilderError.noFrames
        }
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        for session in sessions {
            try? FileManager.default.removeItem(at: session.fileURL)
        }
        return Output(url: outputURL, offset: firstActiveTime)
    }

    private static func prepareWriter(
        sessions: [CameraRecordingResult],
        outputURL: URL
    ) async throws -> (format: CMFormatDescription, transform: CGAffineTransform) {
        for session in sessions {
            let asset = AVURLAsset(url: session.fileURL)
            guard
                let track = try await asset.loadTracks(
                    withMediaType: .video
                ).first,
                let format = try await track.load(.formatDescriptions).first
            else {
                continue
            }
            return (
                format,
                try await track.load(.preferredTransform)
            )
        }
        _ = outputURL
        throw CameraTrackBuilderError.missingTrack
    }

    private static func findFirstActiveTime(
        sessions: [CameraRecordingResult],
        clock: CaptureClock
    ) async throws -> Double? {
        for session in sessions {
            let asset = AVURLAsset(url: session.fileURL)
            guard
                let track = try await asset.loadTracks(
                    withMediaType: .video
                ).first
            else {
                continue
            }
            let trackRange = try await track.load(.timeRange)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw CameraTrackBuilderError.cannotRead
            }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? CameraTrackBuilderError.cannotRead
            }
            while let sample = output.copyNextSampleBuffer() {
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                let hostTime = session.startedAtHostTime
                    + sourceTime
                    - trackRange.start.seconds
                if let outputTime = clock.outputTime(forHostTime: hostTime) {
                    reader.cancelReading()
                    return outputTime
                }
            }
            if reader.status == .failed {
                throw reader.error ?? CameraTrackBuilderError.cannotRead
            }
        }
        return nil
    }

    private static func retime(
        _ sampleBuffer: CMSampleBuffer,
        to seconds: Double
    ) -> CMSampleBuffer? {
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid || duration.seconds <= 0 {
            duration = CMTime(value: 1, timescale: 30)
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMTime(
                seconds: seconds,
                preferredTimescale: 600
            ),
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
