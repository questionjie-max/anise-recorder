import AppKit
import AVFoundation
import CoreImage
import Foundation
import AniseRecorderCore

struct ZoomSettings {
    let enabled: Bool
    let scale: CGFloat
    let duration: TimeInterval
    let clicks: [ClickEvent]
    var regions: [ZoomRegion] = []
}

struct ExportConfiguration: Equatable {
    let outputSize: CGSize
    let frameRate: Int
    let codec: ExportCodec

    init(outputSize: CGSize, frameRate: Int, codec: ExportCodec) {
        self.outputSize = CGSize(
            width: max(2, (outputSize.width / 2).rounded() * 2),
            height: max(2, (outputSize.height / 2).rounded() * 2)
        )
        self.frameRate = min(120, max(1, frameRate))
        self.codec = codec
    }

    static func standard(for project: StudioProject) -> ExportConfiguration {
        ExportConfiguration(
            outputSize: project.canvasOutputSize,
            frameRate: project.fps,
            codec: .h264
        )
    }
}

struct ComposedAsset {
    let composition: AVMutableComposition
    /// F2 视频叠加轨（图片叠加不需要 composition track）。
    var overlayTracks: [OverlayTrackRef] = []
    let audioMix: AVAudioMix?
    let cameraTrackID: CMPersistentTrackID?
}

private struct ActiveZoom {
    let point: CGPoint
    let weight: CGFloat
    let scale: CGFloat
}

struct ZoomFocus {
    let point: CGPoint
    let weight: CGFloat
}

/// 精剪分析实际使用的音轨来源（路线图 4.1）。
enum SmartCutAudioSource: Equatable, Sendable {
    case microphone
    case systemAudio
    case videoTrack

    var reliabilityHint: String? {
        switch self {
        case .microphone:
            return nil
        case .systemAudio:
            return "当前工程没有麦克风音轨，已改用系统声音分析，停顿判断可能不可靠。"
        case .videoTrack:
            return "当前工程没有独立人声音轨，已改用录屏内嵌声音分析，停顿判断可能不可靠。"
        }
    }
}

struct ZoomProjection {
    let crop: CGRect
    let scaleX: CGFloat
    let scaleY: CGFloat

    func map(
        _ point: CGPoint,
        from sourceExtent: CGRect
    ) -> CGPoint {
        let sourceX = sourceExtent.minX + point.x * sourceExtent.width
        let sourceY = sourceExtent.minY
            + (1 - point.y) * sourceExtent.height
        return CGPoint(
            x: (sourceX - crop.minX) * scaleX,
            y: (sourceY - crop.minY) * scaleY
        )
    }
}

enum ZoomRenderer {
    static func image(
        source: CIImage,
        time: TimeInterval,
        settings: ZoomSettings,
        outputSize: CGSize
    ) -> CIImage {
        let extent = source.extent
        guard extent.width > 1, extent.height > 1 else { return source }

        guard
            let projection = projection(
                sourceExtent: extent,
                time: time,
                settings: settings,
                outputSize: outputSize
            )
        else {
            return source
        }
        let moved = source
            .cropped(to: projection.crop)
            .transformed(
                by: CGAffineTransform(
                    translationX: -projection.crop.minX,
                    y: -projection.crop.minY
                )
            )
        let scaled = moved.transformed(
            by: CGAffineTransform(
                scaleX: projection.scaleX,
                y: projection.scaleY
            )
        )
        return scaled.cropped(
            to: CGRect(origin: .zero, size: outputSize)
        )
    }

    static func projection(
        sourceExtent extent: CGRect,
        time: TimeInterval,
        settings: ZoomSettings,
        outputSize: CGSize
    ) -> ZoomProjection? {
        guard extent.width > 1, extent.height > 1 else { return nil }
        let active = activeZoom(at: time, settings: settings)
        let strength = min(max(active?.weight ?? 0, 0), 1)
        let zoom = 1
            + (max(1, active?.scale ?? settings.scale) - 1) * strength
        let point = active?.point ?? CGPoint(x: 0.5, y: 0.5)

        let cropWidth = extent.width / zoom
        let cropHeight = extent.height / zoom
        let rawCenterX = extent.minX + point.x * extent.width
        let rawCenterY = extent.minY + (1 - point.y) * extent.height
        let centerX = min(
            max(rawCenterX, extent.minX + cropWidth / 2),
            extent.maxX - cropWidth / 2
        )
        let centerY = min(
            max(rawCenterY, extent.minY + cropHeight / 2),
            extent.maxY - cropHeight / 2
        )
        let crop = CGRect(
            x: centerX - cropWidth / 2,
            y: centerY - cropHeight / 2,
            width: cropWidth,
            height: cropHeight
        )

        return ZoomProjection(
            crop: crop,
            scaleX: outputSize.width / crop.width,
            scaleY: outputSize.height / crop.height
        )
    }

    static func activeFocus(
        at time: TimeInterval,
        settings: ZoomSettings
    ) -> ZoomFocus? {
        guard let active = activeZoom(at: time, settings: settings) else {
            return nil
        }
        return ZoomFocus(
            point: CGPoint(
                x: min(1, max(0, active.point.x)),
                y: min(1, max(0, active.point.y))
            ),
            weight: min(1, max(0, active.weight))
        )
    }

    private static func activeZoom(
        at time: TimeInterval,
        settings: ZoomSettings
    ) -> ActiveZoom? {
        if let manual = activeManualZoom(at: time, settings: settings) {
            return manual
        }
        guard settings.enabled else { return nil }
        guard settings.scale > 1.001 else { return nil }
        let holdDuration = max(0.35, settings.duration)
        var totalWeight: CGFloat = 0
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0
        var strongest: CGFloat = 0

        for click in settings.clicks where click.enabled {
            let clickTime = click.time
            let starts = clickTime - 0.24
            let fullIn = clickTime + 0.04
            let fullOut = clickTime + holdDuration
            let ends = fullOut + 0.34
            guard time >= starts, time <= ends else { continue }

            let weight: CGFloat
            if time < fullIn {
                weight = smoothstep((time - starts) / max(0.001, fullIn - starts))
            } else if time <= fullOut {
                weight = 1
            } else {
                weight = 1 - smoothstep(
                    (time - fullOut) / max(0.001, ends - fullOut)
                )
            }
            guard weight > 0.001 else { continue }
            totalWeight += weight
            weightedX += CGFloat(click.x) * weight
            weightedY += CGFloat(click.y) * weight
            strongest = max(strongest, weight)
        }

        guard totalWeight > 0, strongest > 0.01 else { return nil }
        return ActiveZoom(
            point: CGPoint(
                x: weightedX / totalWeight,
                y: weightedY / totalWeight
            ),
            weight: strongest,
            scale: settings.scale
        )
    }

    private static func activeManualZoom(
        at time: TimeInterval,
        settings: ZoomSettings
    ) -> ActiveZoom? {
        let regions = settings.regions
            .filter {
                $0.enabled
                    && $0.start <= time
                    && time < $0.end
                    && $0.scale > 1.001
            }
            .sorted { $0.start < $1.start }
        guard let region = regions.last else { return nil }
        let duration = max(0.1, region.duration)
        let ramp = min(0.3, duration / 3)
        let elapsed = time - region.start
        let remaining = region.end - time
        let weight: CGFloat
        if elapsed < ramp {
            weight = smoothstep(elapsed / max(0.001, ramp))
        } else if remaining < ramp {
            weight = smoothstep(remaining / max(0.001, ramp))
        } else {
            weight = 1
        }
        guard weight > 0.001 else { return nil }
        return ActiveZoom(
            point: CGPoint(
                x: min(1, max(0, region.center.x)),
                y: min(1, max(0, region.center.y))
            ),
            weight: weight,
            scale: CGFloat(max(1, region.scale))
        )
    }

    private static func smoothstep(_ value: Double) -> CGFloat {
        let x = min(max(value, 0), 1)
        return CGFloat(x * x * (3 - 2 * x))
    }
}

enum CompositionBuilder {
    /// W5③：去掉 makePlayerItem 的 @MainActor 锚点——函数体内没有
    /// 主线程约束（AVPlayerItem/AVMutableVideoComposition 构造非主线程
    /// 绑定），重活本就在非隔离 makeComposition；预览调用方（MainActor）
    /// await 它不受影响。389+ 全量测试含真实导出/预览集成测试守护。
    static func makePlayerItem(
        for project: StudioProject,
        bypassAudioProcessing: Bool = false
    ) async throws -> AVPlayerItem {
        let composed = try await makeComposition(
            for: project,
            audioProcessingMode: bypassAudioProcessing ? .bypass : .useCache
        )
        let videoComposition = makeVideoComposition(
            for: composed.composition,
            project: project,
            cameraTrackID: composed.cameraTrackID,
            overlayTracks: composed.overlayTracks
        )
        let item = AVPlayerItem(asset: composed.composition)
        item.videoComposition = videoComposition
        item.audioMix = composed.audioMix
        item.audioTimePitchAlgorithm = .timeDomain
        return item
    }

    static func makeExport(
        for project: StudioProject,
        outputURL: URL,
        configuration: ExportConfiguration? = nil,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !outputURL.conflicts(withSourceFilesOf: project) else {
            throw ExportError.destinationIsSource
        }
        let configuration = configuration
            ?? ExportConfiguration.standard(for: project)
        try ExportStorage.validateDestination(
            outputURL,
            configuration: configuration,
            duration: project.trimDuration
        )
        let composed = try await makeComposition(
            for: project,
            audioProcessingMode: .ensure
        )
        try Task.checkCancellation()
        let burnMode = project.captions.effectiveBurnMode
        let videoComposition = makeVideoComposition(
            for: composed.composition,
            project: project,
            cameraTrackID: composed.cameraTrackID,
            overlayTracks: composed.overlayTracks,
            outputSize: configuration.outputSize,
            frameRate: configuration.frameRate,
            burnsCaptions: burnMode != .off,
            captionBurnMode: burnMode
        )
        let temporaryURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".anise-recorder-(UUID().uuidString).mp4"
            )
        try? FileManager.default.removeItem(at: temporaryURL)
        defer {
            cleanupTemporaryArtifacts(temporaryURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: temporaryURL,
                fileType: .mp4
            )
        } catch {
            throw ExportStorage.mapped(error)
        }
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings(
                configuration: configuration
            )
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.cannotAddOutput
        }
        writer.add(videoInput)

        let reader = try AVAssetReader(asset: composed.composition)
        let videoTracks = composed.composition.tracks(
            withMediaType: .video
        )
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.cannotAddOutput
        }
        reader.add(videoOutput)

        let audioTracks = composed.composition.tracks(
            withMediaType: .audio
        )
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioOutputSettings
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ExportError.cannotAddOutput
            }
            writer.add(input)
            audioInput = input

            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: nil
            )
            output.audioMix = composed.audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ExportError.cannotAddOutput
            }
            reader.add(output)
            audioOutput = output
        }

        let runState = ExportRunState(reader: reader, writer: writer)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try runState.startWriting()
                try runState.startReading()

                let duration = max(
                    0.001,
                    composed.composition.duration.seconds
                )
                let videoTask = Task.detached(priority: .userInitiated) {
                    try await pumpSamples(
                        output: videoOutput,
                        input: videoInput,
                        runState: runState,
                        duration: duration,
                        progress: progress
                    )
                }
                let audioTask = audioOutput.flatMap { output in
                    audioInput.map { input in
                        Task.detached(priority: .userInitiated) {
                            try await pumpSamples(
                                output: output,
                                input: input,
                                runState: runState,
                                duration: nil,
                                progress: nil
                            )
                        }
                    }
                }
                var tasks = [videoTask]
                if let audioTask {
                    tasks.append(audioTask)
                }
                do {
                    for task in tasks {
                        try await task.value
                    }
                } catch {
                    runState.cancel()
                    for task in tasks {
                        _ = try? await task.value
                    }
                    throw error
                }

                try runState.checkCancellation()
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                await runState.finishWriting()
                try runState.checkCancellation()
                guard writer.status == .completed else {
                    throw writer.error ?? ExportError.failed
                }
                try installExport(
                    temporaryURL: temporaryURL,
                    outputURL: outputURL
                )
                await progress(1)
            } onCancel: {
                runState.cancel()
            }
        } catch {
            runState.abort()
            throw ExportStorage.mapped(error)
        }
    }

    static func makeTranscriptionAudio(
        for project: StudioProject,
        outputURL: URL
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let (composition, _) = try await makeTimelineAudioComposition(
            for: project
        )
        guard composition.duration > .zero else {
            throw ExportError.noAudioForTranscription
        }
        guard
            let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
            )
        else {
            throw ExportError.failed
        }
        try await exporter.export(to: outputURL, as: .m4a)
    }

    /// 按当前时间线裁剪和变速，构建“有效成片音频”合成。优先麦克风轨，
    /// 其次独立系统声音轨，最后是录屏内嵌声音；返回实际使用的来源，
    /// 供精剪扫描提示结果可靠性（路线图 4.1 / 8.2）。
    static func makeTimelineAudioComposition(
        for project: StudioProject
    ) async throws -> (composition: AVMutableComposition, source: SmartCutAudioSource) {
        var candidates: [(url: URL, source: SmartCutAudioSource)] = []
        if let microphoneURL = project.microphoneURL {
            candidates.append((microphoneURL, .microphone))
        }
        if let systemAudioURL = project.systemAudioURL {
            candidates.append((systemAudioURL, .systemAudio))
        }
        candidates.append((project.videoURL, .videoTrack))

        for (url, source) in candidates {
            let asset = AVURLAsset(url: url)
            defer { withExtendedLifetime(asset) {} }
            guard
                let sourceAudio = try await asset
                    .loadTracks(withMediaType: .audio)
                    .first
            else {
                continue
            }
            let audioComposition = AVMutableComposition()
            guard
                try await insertTimelineAudio(
                    sourceAudio,
                    clips: project.timeline.clips,
                    composition: audioComposition,
                    sourceOrigin: try await sourceAudio.load(.timeRange).start
                ) != nil
            else {
                continue
            }
            return (audioComposition, source)
        }
        throw ExportError.noAudioForTranscription
    }

    /// 精剪“保护系统声音”分析用：只含系统声音（独立系统音轨，或屏幕文件
    /// 内嵌音轨）的成片时间合成。没有系统声音轨时返回 nil。
    static func makeSystemSoundComposition(
        for project: StudioProject
    ) async throws -> AVMutableComposition? {
        var sourceAsset = AVURLAsset(
            url: project.systemAudioURL ?? project.videoURL
        )
        defer { withExtendedLifetime(sourceAsset) {} }
        var systemTracks = try await sourceAsset.loadTracks(
            withMediaType: .audio
        )
        if systemTracks.isEmpty, project.systemAudioURL != nil {
            sourceAsset = AVURLAsset(url: project.videoURL)
            systemTracks = try await sourceAsset.loadTracks(
                withMediaType: .audio
            )
        }
        guard let sourceAudio = systemTracks.first else { return nil }
        let composition = AVMutableComposition()
        guard
            try await insertTimelineAudio(
                sourceAudio,
                clips: project.timeline.clips,
                composition: composition,
                sourceOrigin: try await sourceAudio.load(.timeRange).start
            ) != nil
        else {
            return nil
        }
        guard composition.duration > .zero else { return nil }
        return composition
    }

    static func makeComposition(
        for project: StudioProject,
        audioProcessingMode: AudioOptimizer.Mode = .useCache
    ) async throws -> ComposedAsset {
        // 1.2 音频优化：设置开启时优先使用已处理缓存（预览 miss 回落原始
        // 音轨，导出 ensure 模式同步处理）。处理失败不阻断合成，回落原始。
        let audioSources: AudioOptimizer.ResolvedSources
        do {
            audioSources = try await AudioOptimizer.resolve(
                project: project,
                mode: audioProcessingMode
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            audioSources = AudioOptimizer.ResolvedSources()
        }
        let screenAsset = AVURLAsset(url: project.videoURL)
        let videoTracks = try await screenAsset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else {
            throw ExportError.missingVideo
        }
        let sourceVideoRange = try await sourceVideo.load(.timeRange)
        let sourceOrigin = sourceVideoRange.start

        let composition = AVMutableComposition()
        guard let composedVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.missingVideo
        }
        composedVideo.preferredTransform = try await sourceVideo.load(
            .preferredTransform
        )

        let clips = project.timeline.clips
        let sourceWindows = clips.map { clip in
            let start = sourceOrigin + CMTime(
                seconds: clip.sourceStart,
                preferredTimescale: 600
            )
            let end = sourceOrigin + CMTime(
                seconds: clip.sourceEnd,
                preferredTimescale: 600
            )
            return CMTimeRange(
                start: maxCMTime(sourceOrigin, start),
                end: maxCMTime(
                    sourceOrigin,
                    minCMTime(sourceVideoRange.end, end)
                )
            )
        }

        for (clip, range) in zip(clips, sourceWindows) {
            guard range.duration > .zero else { continue }
            try insertScaled(
                range,
                from: sourceVideo,
                into: composedVideo,
                at: compositionCursor(of: composedVideo),
                playbackRate: clip.playbackRate
            )
        }

        var audioParameters: [AVMutableAudioMixInputParameters] = []
        // 系统声音轨：有已处理缓存时改用缓存文件（音量参数照常生效）。
        if let systemAudioURL = audioSources.systemURL ?? project.systemAudioURL {
            let systemAsset = AVURLAsset(url: systemAudioURL)
            let tracks = try await systemAsset.loadTracks(withMediaType: .audio)
            if let sourceAudio = tracks.first {
                if let track = try await insertTimelineAudio(
                    sourceAudio,
                    clips: clips,
                    composition: composition,
                    sourceOrigin: try await sourceAudio.load(.timeRange).start
                ) {
                    audioParameters.append(
                        clipBoundaryAudioParameters(
                            track: track,
                            clips: clips,
                            volume: project.audio.systemVolume
                        )
                    )
                }
            }
        } else {
            // 没有独立系统轨：内嵌声音；有已处理缓存时改用缓存（单轨插入）。
            if let embeddedProcessed = audioSources.embeddedURL {
                let processedAsset = AVURLAsset(url: embeddedProcessed)
                let processedTracks = try await processedAsset.loadTracks(
                    withMediaType: .audio
                )
                if let sourceAudio = processedTracks.first {
                    if let track = try await insertTimelineAudio(
                        sourceAudio,
                        clips: clips,
                        composition: composition,
                        sourceOrigin: sourceOrigin
                    ) {
                        audioParameters.append(
                            clipBoundaryAudioParameters(
                                track: track,
                                clips: clips,
                                volume: project.audio.systemVolume
                            )
                        )
                    }
                }
            } else {
                let systemAudioTracks = try await screenAsset.loadTracks(
                    withMediaType: .audio
                )
                for sourceAudio in systemAudioTracks {
                    if let track = try await insertTimelineAudio(
                        sourceAudio,
                        clips: clips,
                        composition: composition,
                        sourceOrigin: sourceOrigin
                    ) {
                        audioParameters.append(
                            clipBoundaryAudioParameters(
                                track: track,
                                clips: clips,
                                volume: project.audio.systemVolume
                            )
                        )
                    }
                }
            }
        }

        // 麦克风轨：有已处理缓存时改用缓存文件（音量参数照常生效）。
        if let microphoneURL = audioSources.microphoneURL
            ?? project.microphoneURL
        {
            let micAsset = AVURLAsset(url: microphoneURL)
            let micTracks = try await micAsset.loadTracks(withMediaType: .audio)
            if let micTrack = micTracks.first {
                if let track = try await insertTimelineAudio(
                    micTrack,
                    clips: clips,
                    composition: composition,
                    sourceOrigin: try await micTrack.load(.timeRange).start
                ) {
                    audioParameters.append(
                        clipBoundaryAudioParameters(
                            track: track,
                            clips: clips,
                            volume: project.audio.microphoneVolume
                        )
                    )
                }
            }
        }

        var cameraTrackID: CMPersistentTrackID?
        if let cameraURL = project.cameraURL {
            let cameraAsset = AVURLAsset(url: cameraURL)
            let cameraTracks = try await cameraAsset.loadTracks(
                withMediaType: .video
            )
            if let sourceCamera = cameraTracks.first {
                let cameraRange = try await sourceCamera.load(.timeRange)
                if let track = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) {
                    track.preferredTransform = try await sourceCamera.load(
                        .preferredTransform
                    )
                    var outputCursor = 0.0
                    let cameraStartSeconds = cameraRange.start.seconds
                    let cameraEndSeconds = cameraRange.end.seconds
                    for clip in clips {
                        defer {
                            outputCursor += clip.outputDuration
                        }
                        let sourceStart = max(
                            clip.sourceStart,
                            project.cameraOffset
                        )
                        let sourceEnd = min(
                            clip.sourceEnd,
                            project.cameraOffset + cameraRange.duration.seconds
                        )
                        guard sourceEnd > sourceStart else { continue }
                        let cameraStart = cameraStartSeconds
                            + (sourceStart - project.cameraOffset)
                        let cameraEnd = cameraStartSeconds
                            + (sourceEnd - project.cameraOffset)
                        let range = cameraInsertionRange(
                            requestedStart: CMTime(
                                seconds: max(cameraStartSeconds, cameraStart),
                                preferredTimescale: 600
                            ),
                            requestedEnd: CMTime(
                                seconds: min(cameraEndSeconds, cameraEnd),
                                preferredTimescale: 600
                            ),
                            sourceStart: cameraRange.start
                        )
                        guard range.duration > .zero else { continue }
                        let localStart = max(
                            0,
                            (sourceStart - clip.sourceStart)
                                / clip.playbackRate
                        )
                        try insertScaled(
                            range,
                            from: sourceCamera,
                            into: track,
                            at: cameraInsertionTime(
                                CMTime(
                                    seconds: outputCursor + localStart,
                                    preferredTimescale: 600
                                )
                            ),
                            playbackRate: clip.playbackRate
                        )
                    }
                    cameraTrackID = track.trackID
                }
            }
        }

        // F2 视频叠加轨：每个视频叠加片段一条 composition track，从素材
        // 头部起播 min(片段时长, 素材时长)；素材播完的时段该 track 无帧，
        // 合成器跳过该层。图片叠加不占 composition track（合成器直接解码）。
        var overlayTracks: [OverlayTrackRef] = []
        for clip in project.overlayClips where clip.kind == .video {
            guard let mediaURL = project.overlayMediaURL(for: clip) else {
                continue
            }
            let mediaAsset = AVURLAsset(url: mediaURL)
            let mediaVideoTracks = try await mediaAsset.loadTracks(
                withMediaType: .video
            )
            guard let sourceTrack = mediaVideoTracks.first else {
                continue
            }
            let mediaRange = try await sourceTrack.load(.timeRange)
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else {
                continue
            }
            track.preferredTransform = try await sourceTrack.load(
                .preferredTransform
            )
            let wanted = min(
                max(clip.duration, OverlayClip.minimumDuration),
                mediaRange.duration.seconds
            )
            let insertRange = CMTimeRange(
                start: mediaRange.start,
                duration: CMTime(seconds: wanted, preferredTimescale: 600)
            )
            guard insertRange.duration > .zero else { continue }
            try insertScaled(
                insertRange,
                from: sourceTrack,
                into: track,
                at: CMTime(seconds: clip.start, preferredTimescale: 600),
                playbackRate: 1
            )
            overlayTracks.append(
                OverlayTrackRef(clipID: clip.id, trackID: track.trackID)
            )
        }

        let mix: AVAudioMix?
        if audioParameters.isEmpty {
            mix = nil
        } else {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioParameters
            mix = audioMix
        }
        return ComposedAsset(
            composition: composition,
            overlayTracks: overlayTracks,
            audioMix: mix,
            cameraTrackID: cameraTrackID
        )
    }

    static func cameraInsertionRange(
        requestedStart: CMTime,
        requestedEnd: CMTime,
        sourceStart: CMTime
    ) -> CMTimeRange {
        let start: CMTime
        if requestedStart <= sourceStart {
            // AVCaptureMovieFileOutput 的部分摄像头文件以零时长坏样本开头。
            // 从绝对起点插入会让视频合成读取停在 copyNextSampleBuffer()；
            // 跳过最小时间刻度，不重编码，也不改变正常的非零起点。
            start = min(
                requestedEnd,
                sourceStart + CMTime(value: 1, timescale: 600)
            )
        } else {
            start = requestedStart
        }
        return CMTimeRange(start: start, end: requestedEnd)
    }

    static func cameraInsertionTime(_ requested: CMTime) -> CMTime {
        requested > .zero
            ? requested
            : CMTime(value: 1, timescale: 600)
    }

    /// 组装音频轨的混合参数：静音轨保持静音；多片段轨在每个片段边界加
    /// 约 10 ms 音量淡入淡出，避免切点爆音（路线图第 7 节）。预览与导出
    /// 共用同一 audioMix，不改变音频时长和音高。
    private static func clipBoundaryAudioParameters(
        track: AVMutableCompositionTrack,
        clips: [TimelineClip],
        volume: Float
    ) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTimePitchAlgorithm = .timeDomain
        parameters.setVolume(volume, at: .zero)
        guard volume > 0, clips.count > 1 else { return parameters }

        let maximumFade = 0.01
        var cursor = 0.0
        for clip in clips {
            let outputDuration = clip.outputDuration
            let fadeSeconds = min(maximumFade, outputDuration / 3)
            let segmentEnd = cursor + outputDuration
            if fadeSeconds > 1e-6 {
                // 段首淡入：0 → 目标音量。
                parameters.setVolumeRamp(fromStartVolume:
                    0,
                    toEndVolume: volume,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: cursor, preferredTimescale: 600),
                        end: CMTime(
                            seconds: cursor + fadeSeconds,
                            preferredTimescale: 600
                        )
                    )
                )
                // 段尾淡出：目标音量 → 0。
                parameters.setVolumeRamp(fromStartVolume:
                    volume,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(
                        start: CMTime(
                            seconds: segmentEnd - fadeSeconds,
                            preferredTimescale: 600
                        ),
                        end: CMTime(seconds: segmentEnd, preferredTimescale: 600)
                    )
                )
            }
            cursor = segmentEnd
        }
        return parameters
    }

    /// 供 1.2 音频优化把单条源音轨按时间线裁剪/变速装进独立合成
    /// （ducking 的人声活动检测复用同一时间映射）。
    static func insertTimelineAudioTrack(
        _ source: AVAssetTrack,
        clips: [TimelineClip],
        composition: AVMutableComposition,
        sourceOrigin: CMTime
    ) async throws -> AVMutableCompositionTrack? {
        try await insertTimelineAudio(
            source,
            clips: clips,
            composition: composition,
            sourceOrigin: sourceOrigin
        )
    }

    private static func insertTimelineAudio(
        _ source: AVAssetTrack,
        clips: [TimelineClip],
        composition: AVMutableComposition,
        sourceOrigin: CMTime
    ) async throws -> AVMutableCompositionTrack? {
        let sourceRange = try await source.load(.timeRange)
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        var insertedAny = false
        for clip in clips {
            let start = sourceOrigin + CMTime(
                seconds: clip.sourceStart,
                preferredTimescale: 600
            )
            let end = sourceOrigin + CMTime(
                seconds: clip.sourceEnd,
                preferredTimescale: 600
            )
            let rangeStart = maxCMTime(sourceRange.start, start)
            let rangeEnd = minCMTime(sourceRange.end, end)
            // 系统声音通常比录屏先结束；交集为空时会得到无效
            // CMTimeRange，AVFoundation 会以 -12780 拒绝合成。
            guard rangeStart.isValid, rangeEnd.isValid,
                  rangeStart < rangeEnd
            else {
                continue
            }
            let range = CMTimeRange(start: rangeStart, end: rangeEnd)
            guard range.duration > .zero else { continue }
            try insertScaled(
                range,
                from: source,
                into: track,
                at: compositionCursor(of: track),
                playbackRate: clip.playbackRate
            )
            insertedAny = true
        }
        if !insertedAny {
            composition.removeTrack(track)
            return nil
        }
        return track
    }

    private static func insertScaled(
        _ range: CMTimeRange,
        from source: AVAssetTrack,
        into track: AVMutableCompositionTrack,
        at start: CMTime,
        playbackRate: Double
    ) throws {
        try track.insertTimeRange(range, of: source, at: start)
        let scaledDuration = CMTime(
            seconds: range.duration.seconds
                / TimelineClip.clampedRate(playbackRate),
            preferredTimescale: 600
        )
        track.scaleTimeRange(
            CMTimeRange(start: start, duration: range.duration),
            toDuration: scaledDuration
        )
    }

    private static func compositionCursor(
        of track: AVMutableCompositionTrack
    ) -> CMTime {
        let end = track.timeRange.end
        return end.isValid && end.seconds.isFinite && end > .zero
            ? end
            : .zero
    }

    static func makeVideoComposition(
        for composition: AVMutableComposition,
        project: StudioProject,
        cameraTrackID: CMPersistentTrackID?,
        overlayTracks: [OverlayTrackRef] = [],
        outputSize: CGSize? = nil,
        frameRate: Int? = nil,
        burnsCaptions: Bool = true,
        captionBurnMode: CaptionBurnMode? = nil
    ) -> AVMutableVideoComposition {
        let renderSize = outputSize ?? project.canvasOutputSize
        let renderFrameRate = max(1, frameRate ?? project.fps)
        let screenTrackID = composition.tracks(withMediaType: .video)
            .first?
            .trackID ?? kCMPersistentTrackID_Invalid
        let instruction = StudioCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            screenTrackID: screenTrackID,
            cameraTrackID: cameraTrackID,
            overlayTracks: overlayTracks,
            project: project,
            outputSize: renderSize,
            burnsCaptions: burnsCaptions,
            captionBurnMode: captionBurnMode
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioVideoCompositor.self
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(renderFrameRate)
        )
        return videoComposition
    }

    private static var audioOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
    }

    private static func videoOutputSettings(
        configuration: ExportConfiguration
    ) -> [String: Any] {
        let width = Int(configuration.outputSize.width)
        let height = Int(configuration.outputSize.height)
        let frameRate = configuration.frameRate
        let rawBitRate = Double(width * height * frameRate) * 0.1
        let codecScale = configuration.codec == .hevc ? 0.65 : 1.0
        let bitRate = Int(
            min(80_000_000, max(8_000_000, rawBitRate * codecScale))
        )
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            AVVideoAllowFrameReorderingKey: true
        ]
        if configuration.codec == .h264 {
            compression[AVVideoProfileLevelKey] =
                AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: configuration.codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    private static func pumpSamples(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        runState: ExportRunState,
        duration: Double?,
        progress: (@MainActor (Double) -> Void)?
    ) async throws {
        var lastReportedTime = -Double.greatestFiniteMagnitude
        while true {
            try runState.checkCancellation()
            if runState.readerStatus == .failed {
                throw runState.readerError ?? ExportError.failed
            }
            if runState.writerStatus == .failed {
                throw runState.writerError ?? ExportError.failed
            }
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(4))
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else {
                if runState.readerStatus == .failed {
                    throw runState.readerError ?? ExportError.failed
                }
                break
            }
            guard input.append(sample) else {
                throw runState.writerError ?? ExportError.failed
            }
            if
                let duration,
                let progress,
                duration > 0
            {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                if
                    time.isFinite,
                    time - lastReportedTime >= 0.1
                {
                    lastReportedTime = time
                    await progress(min(0.98, max(0, time / duration)))
                }
            }
        }
        input.markAsFinished()
    }

    /// 临时文件 → 输出位置的统一安装：已有目标文件时用 `replaceItemAt`
    /// 原子替换，失败保留旧文件；MP4 与 GIF 导出共用，保证失败不破坏
    /// 已有成片。
    static func installExport(
        temporaryURL: URL,
        outputURL: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(
                outputURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }

    /// 取消 / 失败后的临时产物清理：除主临时文件外，还要清掉
    /// AVAssetWriter（shouldOptimizeForNetworkUse）在旁边生成的
    /// `<临时名>.sb-<随机>` 分片 sidecar，否则取消后会在输出目录
    /// 残留隐藏文件。
    private static func cleanupTemporaryArtifacts(_ temporaryURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: temporaryURL)
        let folder = temporaryURL.deletingLastPathComponent()
        let prefix = temporaryURL.lastPathComponent
        let leftovers = (try? fileManager.contentsOfDirectory(
            atPath: folder.path
        )) ?? []
        for name in leftovers where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

enum ExportError: LocalizedError, Equatable {
    case missingVideo
    case cannotAddOutput
    case cannotStartWriting
    case cannotStartReading
    case diskFull(requiredBytes: Int64?, availableBytes: Int64?)
    case destinationNotWritable
    case destinationUnavailable
    case destinationIsSource
    case noAudioForTranscription
    case cancelled
    case failed

    var errorDescription: String? {
        switch self {
        case .missingVideo:
            return "录制文件里没有可导出的视频。"
        case .cannotAddOutput:
            return "当前编码器不支持所选分辨率或格式。"
        case .cannotStartWriting:
            return "无法创建导出文件，请检查磁盘空间和保存位置。"
        case .cannotStartReading:
            return "无法读取录制素材进行导出。"
        case let .diskFull(requiredBytes, availableBytes):
            if let requiredBytes, let availableBytes {
                return "磁盘可用空间不足：至少需要 \(formatFileSize(requiredBytes))，当前可用 \(formatFileSize(availableBytes))。请清理空间或更换导出位置。"
            }
            return "磁盘可用空间不足，请清理空间或更换导出位置。"
        case .destinationNotWritable:
            return "无法写入所选导出位置，请选择有写入权限的文件夹。"
        case .destinationUnavailable:
            return "所选导出文件夹不存在，请重新选择保存位置。"
        case .destinationIsSource:
            return "导出位置不能覆盖工程原始素材，请选择其他文件名。"
        case .noAudioForTranscription:
            return "这个工程没有可用于本机字幕的麦克风或声音轨道。"
        case .cancelled:
            return "导出已取消。"
        case .failed:
            return "导出失败，请重试。"
        }
    }
}

enum ExportStorage {
    static func validateDestination(
        _ outputURL: URL,
        configuration: ExportConfiguration,
        duration: Double
    ) throws {
        let fileManager = FileManager.default
        let folder = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: folder.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw ExportError.destinationUnavailable
        }
        guard fileManager.isWritableFile(atPath: folder.path) else {
            throw ExportError.destinationNotWritable
        }
        if fileManager.fileExists(atPath: outputURL.path) {
            guard fileManager.isWritableFile(atPath: outputURL.path) else {
                throw ExportError.destinationNotWritable
            }
        }

        let required = estimatedBytes(
            configuration: configuration,
            duration: duration
        )
        let values = try? folder.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
        )
        let available = availableBytes(
            importantUsage: values?.volumeAvailableCapacityForImportantUsage,
            standard: values?.volumeAvailableCapacity
        )
        if
            let available,
            available < required
        {
            throw ExportError.diskFull(
                requiredBytes: required,
                availableBytes: available
            )
        }
    }

    static func availableBytes(
        importantUsage: Int64?,
        standard: Int?
    ) -> Int64? {
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        if let standard, standard > 0 {
            return Int64(standard)
        }
        return nil
    }

    static func estimatedBytes(
        configuration: ExportConfiguration,
        duration: Double
    ) -> Int64 {
        let pixels = max(
            1,
            configuration.outputSize.width
                * configuration.outputSize.height
        )
        let fullHDPixels: CGFloat = 1920 * 1080
        let resolutionFactor = min(
            4,
            max(1, pixels / fullHDPixels)
        )
        let frameRateFactor: CGFloat = configuration.frameRate > 30 ? 1.5 : 1
        let codecFactor: CGFloat = configuration.codec == .hevc ? 0.72 : 1
        let videoMegabits = 8
            * Double(resolutionFactor)
            * Double(frameRateFactor)
            * Double(codecFactor)
        let audioMegabits = 0.192
        let seconds = max(0.1, duration)
        let estimated = (videoMegabits + audioMegabits)
            * 1_000_000
            / 8
            * seconds
            * 1.25
            + 32 * 1_024 * 1_024
        return Int64(estimated.rounded(.up))
    }

    static func mapped(_ error: Error) -> Error {
        if error is CancellationError || error is ExportError {
            return error
        }
        let nsError = error as NSError
        if containsOutOfSpace(nsError) {
            return ExportError.diskFull(
                requiredBytes: nil,
                availableBytes: nil
            )
        }
        if containsPermissionDenied(nsError) {
            return ExportError.destinationNotWritable
        }
        return error
    }

    private static func containsOutOfSpace(_ error: NSError) -> Bool {
        if
            error.domain == NSPOSIXErrorDomain,
            error.code == Int(POSIXErrorCode.ENOSPC.rawValue)
        {
            return true
        }
        if
            error.domain == NSCocoaErrorDomain,
            error.code == NSFileWriteOutOfSpaceError
        {
            return true
        }
        return underlyingErrors(error).contains(where: containsOutOfSpace)
    }

    private static func containsPermissionDenied(_ error: NSError) -> Bool {
        let codes = [
            POSIXErrorCode.EACCES.rawValue,
            POSIXErrorCode.EPERM.rawValue,
            POSIXErrorCode.EROFS.rawValue
        ].map(Int.init)
        if
            error.domain == NSPOSIXErrorDomain,
            codes.contains(error.code)
        {
            return true
        }
        if
            error.domain == NSCocoaErrorDomain,
            error.code == NSFileWriteNoPermissionError
        {
            return true
        }
        return underlyingErrors(error).contains(
            where: containsPermissionDenied
        )
    }

    private static func underlyingErrors(_ error: NSError) -> [NSError] {
        [
            error.userInfo[NSUnderlyingErrorKey],
            (error.userInfo[NSDetailedErrorsKey] as? [NSError])
        ]
        .flatMap { value -> [NSError] in
            if let error = value as? NSError {
                return [error]
            }
            if let errors = value as? [NSError] {
                return errors
            }
            return []
        }
    }
}

private extension URL {
    func conflicts(withSourceFilesOf project: StudioProject) -> Bool {
        let destination = standardizedFileURL.resolvingSymlinksInPath()
        let sources = [
            project.videoURL,
            project.microphoneURL,
            project.systemAudioURL,
            project.cameraURL,
            project.backgroundImageURL
        ].compactMap { $0 }
        return sources.contains { source in
            source.standardizedFileURL.resolvingSymlinksInPath()
                == destination
        }
    }
}

private final class ExportRunState: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    private let lock = NSLock()
    private var cancelled = false
    private var readerStarted = false
    private var finishing = false

    init(reader: AVAssetReader, writer: AVAssetWriter) {
        self.reader = reader
        self.writer = writer
    }

    var readerStatus: AVAssetReader.Status {
        reader.status
    }

    var readerError: Error? {
        reader.error
    }

    var writerStatus: AVAssetWriter.Status {
        writer.status
    }

    var writerError: Error? {
        writer.error
    }

    func startWriting() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            throw CancellationError()
        }
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.cannotStartWriting
        }
        writer.startSession(atSourceTime: .zero)
    }

    func startReading() throws {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            throw CancellationError()
        }
        let started = reader.startReading()
        readerStarted = started
        let error = reader.error
        lock.unlock()
        guard started else {
            throw error ?? ExportError.cannotStartReading
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let cancelReader = readerStarted
        lock.unlock()
        guard cancelReader else {
            return
        }
        // AVAssetWriterInput.append(_:) and cancelWriting() must not race.
        // Stop the reader here so pumpSamples exits, then abort() cancels the
        // writer after both sample pumps have returned.
        reader.cancelReading()
    }

    func abort() {
        lock.lock()
        cancelled = true
        let cancelReader = readerStarted
        let cancelWriter = writer.status == .writing && !finishing
        lock.unlock()
        if cancelReader {
            reader.cancelReading()
        }
        if cancelWriter {
            writer.cancelWriting()
        }
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    func finishWriting() async {
        guard beginFinishing() else { return }
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        markFinishingComplete()
    }

    private func beginFinishing() -> Bool {
        lock.lock()
        finishing = true
        let isCancelled = cancelled
        if isCancelled {
            finishing = false
        }
        lock.unlock()
        return !isCancelled
    }

    private func markFinishingComplete() {
        lock.lock()
        finishing = false
        lock.unlock()
    }
}

private func maxCMTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
    lhs >= rhs ? lhs : rhs
}

private func minCMTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
    lhs <= rhs ? lhs : rhs
}

enum Thumbnailer {
    static func generate(for project: StudioProject) async throws -> String? {
        let asset = AVURLAsset(url: project.videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 400)
        let time = CMTime(
            seconds: min(max(0.5, project.duration * 0.08), 2),
            preferredTimescale: 600
        )
        let image = try await generator.image(at: time).image
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard
            let data = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.82]
            )
        else {
            return nil
        }
        let filename = "thumbnail.jpg"
        try data.write(
            to: project.folderURL.appendingPathComponent(filename),
            options: [.atomic]
        )
        return filename
    }
}
