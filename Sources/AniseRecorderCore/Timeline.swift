import Foundation

package struct TimelineClip: Codable, Hashable, Identifiable, Sendable {
    package var id: UUID
    package var sourceStart: Double
    package var sourceEnd: Double
    package var playbackRate: Double

    package init(
        id: UUID = UUID(),
        sourceStart: Double,
        sourceEnd: Double,
        playbackRate: Double = 1
    ) {
        self.id = id
        let start = max(0, sourceStart.isFinite ? sourceStart : 0)
        self.sourceStart = start
        self.sourceEnd = max(
            start + Self.minimumSourceDuration,
            sourceEnd.isFinite ? sourceEnd : start + Self.minimumSourceDuration
        )
        self.playbackRate = Self.clampedRate(playbackRate)
    }

    package var sourceDuration: Double {
        max(0, sourceEnd - sourceStart)
    }

    package var outputDuration: Double {
        sourceDuration / playbackRate
    }

    package static let minimumSourceDuration = 0.02
    package static let allowedPlaybackRates = [0.25, 0.5, 1, 1.5, 2, 4]

    package static func clampedRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return min(4, max(0.25, rate))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceStart
        case sourceEnd
        case playbackRate
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            sourceStart: try values.decode(
                Double.self,
                forKey: .sourceStart
            ),
            sourceEnd: try values.decode(
                Double.self,
                forKey: .sourceEnd
            ),
            playbackRate: try values.decodeIfPresent(
                Double.self,
                forKey: .playbackRate
            ) ?? 1
        )
    }
}

package enum TimelineEditError: Error, Equatable, Sendable {
    case noClipAtTime
    case noClipWithID
    case minimumDuration
}

package struct ProjectTimeline: Codable, Hashable, Sendable {
    package var clips: [TimelineClip]

    package init(clips: [TimelineClip] = []) {
        self.clips = clips
    }

    package init(sourceStart: Double, sourceEnd: Double) {
        clips = [
            TimelineClip(
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            )
        ]
    }

    package var duration: Double {
        clips.reduce(0) { $0 + $1.outputDuration }
    }

    package var sourceRange: ClosedRange<Double>? {
        guard
            let first = clips.first,
            let last = clips.last
        else {
            return nil
        }
        return first.sourceStart ... max(first.sourceStart, last.sourceEnd)
    }

    package func outputStart(forClipID id: UUID) -> Double? {
        var cursor = 0.0
        for clip in clips {
            if clip.id == id {
                return cursor
            }
            cursor += clip.outputDuration
        }
        return nil
    }

    package func clipIndex(atOutput time: Double) -> Int? {
        guard time.isFinite, time >= 0, !clips.isEmpty else {
            return nil
        }
        if time >= duration - 0.000_001 {
            return clips.indices.last
        }
        var cursor = 0.0
        for (index, clip) in clips.enumerated() {
            let end = cursor + clip.outputDuration
            if time < end - 0.000_001 {
                return index
            }
            cursor = end
        }
        return clips.indices.last
    }

    package func sourceTime(atOutput time: Double) -> Double? {
        guard time.isFinite, time >= 0, time <= duration else {
            return nil
        }
        var cursor = 0.0
        for clip in clips {
            let end = cursor + clip.outputDuration
            if time < end - 0.000_001 {
                let local = min(clip.outputDuration, max(0, time - cursor))
                return clip.sourceStart + local * clip.playbackRate
            }
            cursor = end
        }
        return clips.last.map {
            $0.sourceStart + $0.sourceDuration
        }
    }

    package func outputTime(forSource time: Double) -> Double? {
        guard time.isFinite else { return nil }
        var cursor = 0.0
        for clip in clips {
            let sourceEnd = clip.sourceStart + clip.sourceDuration
            if time >= clip.sourceStart - 0.000_001,
               time <= sourceEnd + 0.000_001
            {
                let localSource = min(
                    clip.sourceDuration,
                    max(0, time - clip.sourceStart)
                )
                return cursor + localSource / clip.playbackRate
            }
            cursor += clip.outputDuration
        }
        return nil
    }

    /// 成片时间区间 → 被时间线覆盖到的源时间区间（1.2 音频优化用：把
    /// 成片时间的人声活动区间映射到系统声音轨的源时间，供 ducking 包络）。
    /// 变速片段按 `playbackRate` 反推，所以慢速片段映射出更长的源区间。
    package func sourceRanges(
        forOutputRange range: ClosedRange<Double>
    ) -> [ClosedRange<Double>] {
        guard range.upperBound > range.lowerBound else { return [] }
        var result: [ClosedRange<Double>] = []
        var cursor = 0.0
        for clip in clips {
            let clipStart = cursor
            let clipEnd = cursor + clip.outputDuration
            cursor = clipEnd
            let overlapStart = max(range.lowerBound, clipStart)
            let overlapEnd = min(range.upperBound, clipEnd)
            guard overlapEnd > overlapStart + 1e-9 else { continue }
            let sourceStart = clip.sourceStart
                + (overlapStart - clipStart) * clip.playbackRate
            let sourceEnd = clip.sourceStart
                + (overlapEnd - clipStart) * clip.playbackRate
            if sourceEnd > sourceStart {
                result.append(sourceStart...sourceEnd)
            }
        }
        return result
    }

    @discardableResult
    package mutating func split(atOutput time: Double) -> Bool {
        guard
            let index = clipIndex(atOutput: time),
            time.isFinite
        else {
            return false
        }
        let outputStart = outputStart(forClipID: clips[index].id) ?? 0
        let localOutput = time - outputStart
        let clip = clips[index]
        let sourceSplit = clip.sourceStart
            + localOutput * clip.playbackRate
        guard
            sourceSplit - clip.sourceStart >= TimelineClip.minimumSourceDuration,
            clip.sourceEnd - sourceSplit >= TimelineClip.minimumSourceDuration
        else {
            return false
        }
        let first = TimelineClip(
            id: clip.id,
            sourceStart: clip.sourceStart,
            sourceEnd: sourceSplit,
            playbackRate: clip.playbackRate
        )
        let second = TimelineClip(
            sourceStart: sourceSplit,
            sourceEnd: clip.sourceEnd,
            playbackRate: clip.playbackRate
        )
        clips.replaceSubrange(index ... index, with: [first, second])
        return true
    }

    @discardableResult
    package mutating func deleteClip(id: UUID) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            return false
        }
        clips.remove(at: index)
        return true
    }

    @discardableResult
    package mutating func deleteClip(atOutput time: Double) -> Bool {
        guard let index = clipIndex(atOutput: time) else {
            return false
        }
        clips.remove(at: index)
        return true
    }

    @discardableResult
    package mutating func trimClip(
        id: UUID,
        sourceStart: Double,
        sourceEnd: Double
    ) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let old = clips[index]
        let start = min(
            old.sourceEnd - TimelineClip.minimumSourceDuration,
            max(old.sourceStart - 0.000_001, sourceStart)
        )
        let end = max(
            start + TimelineClip.minimumSourceDuration,
            min(old.sourceEnd + 0.000_001, sourceEnd)
        )
        clips[index] = TimelineClip(
            id: old.id,
            sourceStart: start,
            sourceEnd: end,
            playbackRate: old.playbackRate
        )
        return true
    }

    @discardableResult
    package mutating func setPlaybackRate(
        _ rate: Double,
        for clipID: UUID
    ) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else {
            return false
        }
        clips[index].playbackRate = TimelineClip.clampedRate(rate)
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case clips
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clips = try values.decodeIfPresent(
            [TimelineClip].self,
            forKey: .clips
        ) ?? []
    }
}

/// 一次精剪“应用多个剪切”的纯逻辑事务（路线图 4.5）。
///
/// 输入候选的删除窗口（成片时间），输出新时间线以及供摄像头布局段、缩放区
/// 和字幕 cue 做裁剪 / 平移 / 删除判断的时间映射。标记、点击和光标属于源
/// 时间，本类型不提供它们的映射，调用方也不得平移这些数据。
package enum TimelineCutTransaction {
    package struct Outcome: Hashable, Sendable {
        /// 应用全部可执行删除后的时间线。
        package let timeline: ProjectTimeline
        /// 实际删除的成片时间区间，已排序、合并且按帧对齐。
        package let deletions: [ClosedRange<Double>]
        /// 因会产生低于 `TimelineClip.minimumSourceDuration` 的片段而被
        /// 整体跳过的候选，调用方应给出可见说明。
        package let skippedCandidates: [SmartCutCandidate]

        package var removedDuration: Double {
            deletions.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        }

        /// 旧成片时间 → 新成片时间；落在删除区间内（含左端点）时返回 nil。
        package func mappedTime(_ time: Double) -> Double? {
            guard time.isFinite, time >= 0 else { return nil }
            var shifted = time
            for deletion in deletions {
                if time < deletion.lowerBound {
                    break
                }
                if time < deletion.upperBound {
                    return nil
                }
                shifted -= deletion.upperBound - deletion.lowerBound
            }
            return shifted
        }

        /// 旧成片时间 → 新成片时间；落在删除区间内时返回切点之后的新位置，
        /// 供布局段起点这类“不应消失、只需贴到切点后”的边界使用。
        package func mappedTimeSnappingAfterCut(_ time: Double) -> Double? {
            if let mapped = mappedTime(time) {
                return mapped
            }
            for deletion in deletions {
                if time >= deletion.lowerBound, time < deletion.upperBound {
                    return mappedTimeSnappingAfterCut(deletion.upperBound)
                }
            }
            return nil
        }

        /// 区间经删除后的保留部分，返回值已经映射到新成片时间。
        package func keptRanges(in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
            var pieces: [ClosedRange<Double>] = []
            guard range.upperBound > range.lowerBound else { return pieces }
            var cursor = range.lowerBound
            for deletion in deletions {
                guard deletion.upperBound > cursor else { continue }
                guard deletion.lowerBound < range.upperBound else { break }
                if deletion.lowerBound > cursor {
                    appendKeptPiece(
                        cursor...min(range.upperBound, deletion.lowerBound),
                        to: &pieces
                    )
                }
                cursor = max(cursor, deletion.upperBound)
                if cursor >= range.upperBound { break }
            }
            if cursor < range.upperBound {
                appendKeptPiece(cursor...range.upperBound, to: &pieces)
            }
            return pieces
        }

        private func appendKeptPiece(
            _ piece: ClosedRange<Double>,
            to pieces: inout [ClosedRange<Double>]
        ) {
            guard piece.upperBound - piece.lowerBound > 1e-9 else { return }
            // 片段端点不会落在删除区间内部；端点恰好贴着删除边界时，
            // 按“该边界之前发生的删除总量”平移，而不是用 mappedTime
            // （它把删除区间左端点视为已删除）。
            let lower = shiftedTimeBefore(piece.lowerBound)
            let upper = shiftedTimeBefore(piece.upperBound)
            guard upper > lower else { return }
            pieces.append(lower...upper)
        }

        private func shiftedTimeBefore(_ time: Double) -> Double {
            var shifted = time
            for deletion in deletions
            where deletion.upperBound <= time + 1e-9 {
                shifted -= deletion.upperBound - deletion.lowerBound
            }
            return shifted
        }
    }

    /// 把候选的删除窗口应用到时间线。处理顺序与输入顺序无关：删除区间先
    /// 合并，再对每个区间从时间线末尾方向往回切（路线图 2 / 4.5）。
    package static func apply(
        _ candidates: [SmartCutCandidate],
        to timeline: ProjectTimeline,
        frameDuration: Double? = nil
    ) -> Outcome {
        var pending: [PendingDeletion] = []
        for candidate in candidates.sorted(by: { $0.cutStart < $1.cutStart }) {
            let deletion = snappedDeletion(
                cutStart: candidate.cutStart,
                cutEnd: candidate.cutEnd,
                duration: timeline.duration,
                frameDuration: frameDuration
            )
            guard let deletion else { continue }
            if
                let last = pending.last,
                deletion.lowerBound < last.range.upperBound
            {
                let upper = max(last.range.upperBound, deletion.upperBound)
                let sources = last.sources + [candidate]
                pending[pending.count - 1] = PendingDeletion(
                    range: last.range.lowerBound...upper,
                    sources: sources
                )
            } else {
                pending.append(
                    PendingDeletion(range: deletion, sources: [candidate])
                )
            }
        }

        guard !pending.isEmpty else {
            return Outcome(
                timeline: timeline,
                deletions: [],
                skippedCandidates: []
            )
        }

        var executable: [PendingDeletion] = []
        for deletion in pending {
            let trial = executable.map(\.range) + [deletion.range]
            if deletionsLeaveMinimumPieces(trial, in: timeline) {
                executable.append(deletion)
            }
        }
        let skipped = pending
            .filter { !executable.contains($0) }
            .flatMap(\.sources)
        guard !executable.isEmpty else {
            return Outcome(
                timeline: timeline,
                deletions: [],
                skippedCandidates: skipped
            )
        }

        var clips = timeline.clips
        // 从后往前应用，前面的删除不会改变后面的成片时间。
        for deletion in executable.map(\.range).reversed() {
            clips = applyingDeletion(deletion, to: clips)
        }
        return Outcome(
            timeline: ProjectTimeline(clips: clips),
            deletions: executable.map(\.range),
            skippedCandidates: skipped
        )
    }

    // MARK: - 私有辅助

    private struct PendingDeletion: Equatable {
        let range: ClosedRange<Double>
        let sources: [SmartCutCandidate]
    }

    /// 把删除窗口吸附到最近的视频帧网格，避免黑帧和重复帧（路线图 4.4）。
    private static func snappedDeletion(
        cutStart: Double,
        cutEnd: Double,
        duration: Double,
        frameDuration: Double?
    ) -> ClosedRange<Double>? {
        guard cutEnd > cutStart else { return nil }
        var lower = max(0, cutStart)
        var upper = min(duration, cutEnd)
        guard upper - lower > 1e-9 else { return nil }
        if let frameDuration, frameDuration > 0 {
            lower = (lower / frameDuration).rounded() * frameDuration
            upper = (upper / frameDuration).rounded() * frameDuration
        }
        lower = max(0, lower)
        upper = min(duration, upper)
        return upper - lower > 1e-9 ? lower...upper : nil
    }

    /// 删除后任何保留下来的片段都不得低于最小源时长（路线图 4.4）。
    /// 必须把多条删除放在一起校验：各自安全的两刀仍可能留下过短中段。
    private static func deletionsLeaveMinimumPieces(
        _ deletions: [ClosedRange<Double>],
        in timeline: ProjectTimeline
    ) -> Bool {
        let minimum = TimelineClip.minimumSourceDuration
        let ranges = deletions.sorted { $0.lowerBound < $1.lowerBound }
        var cursor = 0.0
        for clip in timeline.clips {
            defer { cursor += clip.outputDuration }
            let clipStart = cursor
            let clipEnd = cursor + clip.outputDuration
            var keptStart = clipStart
            for deletion in ranges {
                guard deletion.upperBound > keptStart else { continue }
                guard deletion.lowerBound < clipEnd else { break }
                let keptEnd = min(clipEnd, deletion.lowerBound)
                if keptEnd > keptStart,
                   (keptEnd - keptStart) * clip.playbackRate
                        < minimum - 1e-9
                {
                    return false
                }
                keptStart = max(keptStart, deletion.upperBound)
                if keptStart >= clipEnd { break }
            }
            if keptStart < clipEnd,
               (clipEnd - keptStart) * clip.playbackRate
                    < minimum - 1e-9
            {
                return false
            }
        }
        return true
    }

    /// 在成片时间区间 [deletion] 内切开并移除中间内容，返回新的片段列表。
    private static func applyingDeletion(
        _ deletion: ClosedRange<Double>,
        to clips: [TimelineClip]
    ) -> [TimelineClip] {
        var result: [TimelineClip] = []
        var cursor = 0.0
        for clip in clips {
            defer { cursor += clip.outputDuration }
            let clipEnd = cursor + clip.outputDuration
            let overlapStart = max(deletion.lowerBound, cursor)
            let overlapEnd = min(deletion.upperBound, clipEnd)
            guard overlapEnd > overlapStart else {
                result.append(clip)
                continue
            }
            let headSourceEnd = clip.sourceStart
                + (overlapStart - cursor) * clip.playbackRate
            let tailSourceStart = clip.sourceStart
                + (overlapEnd - cursor) * clip.playbackRate

            if overlapStart > cursor + 1e-9 {
                result.append(
                    TimelineClip(
                        id: clip.id,
                        sourceStart: clip.sourceStart,
                        sourceEnd: headSourceEnd,
                        playbackRate: clip.playbackRate
                    )
                )
            }
            if overlapEnd < clipEnd - 1e-9 {
                result.append(
                    TimelineClip(
                        sourceStart: tailSourceStart,
                        sourceEnd: clip.sourceEnd,
                        playbackRate: clip.playbackRate
                    )
                )
            }
        }
        return result
    }
}
