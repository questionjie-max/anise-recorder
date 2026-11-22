import Foundation

/// 按标记分段导出「按标记分段」模式的分段规划。
///
/// 纯函数：输入标记列表（sourceTime）+ 剪辑事务后的成片时间映射 +
/// 成片时长，输出每段 [起点, 终点]（成片时间）与落在已剪除区间 /
/// 片尾的「跳过」清单。分段从每个标记开始，到下一标记或片尾结束；
/// 首个标记之前的内容不包含在分段内（用户可在 0 处补一个标记包含它）。
struct MarkerSegmentPlan: Equatable {
    struct Segment: Equatable, Identifiable {
        var id: UUID { markerID }
        let markerID: UUID
        let markerName: String
        /// 成片时间起点。
        let start: Double
        /// 成片时间终点（不含），最后一段为成片时长。
        let end: Double
        /// 基名-标记名.mp4（已回退 / 去重）。
        let fileName: String
    }

    struct SkippedMarker: Equatable, Identifiable {
        var id: UUID { markerID }
        let markerID: UUID
        let markerName: String
        let reason: String
    }

    let segments: [Segment]
    let skipped: [SkippedMarker]
}

enum MarkerSegmentPlanner {
    /// 相邻标记（或标记与片尾）间隔低于该值时并入前段 / 跳过，
    /// 保证不产生空段与不可用的碎段。
    static let minimumSegmentDuration: Double = 0.1

    /// 分段规划（纯函数）。`outputTime` 传工程的 source→成片映射
    /// （`StudioProject.outputTime(forSourceTime:)`）；被剪除区间的
    /// sourceTime 映射为 nil。
    static func plan(
        markers: [RecordingMarker],
        excludedIDs: Set<UUID>,
        baseName: String,
        trimDuration: Double,
        outputTime: (Double) -> Double?
    ) -> MarkerSegmentPlan {
        guard trimDuration > minimumSegmentDuration else {
            return MarkerSegmentPlan(segments: [], skipped: [])
        }
        let sorted = markers
            .filter { !excludedIDs.contains($0.id) }
            .sorted {
                if abs($0.sourceTime - $1.sourceTime) > 0.000_001 {
                    return $0.sourceTime < $1.sourceTime
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        var skipped: [MarkerSegmentPlan.SkippedMarker] = []
        var anchors: [(marker: RecordingMarker, time: Double)] = []
        for marker in sorted {
            let name = marker.name
            guard let mapped = outputTime(marker.sourceTime) else {
                skipped.append(
                    MarkerSegmentPlan.SkippedMarker(
                        markerID: marker.id,
                        markerName: name,
                        reason: "标记位于已剪除区间"
                    )
                )
                continue
            }
            let time = min(max(0, mapped), trimDuration)
            if let last = anchors.last,
               time - last.time < minimumSegmentDuration
            {
                skipped.append(
                    MarkerSegmentPlan.SkippedMarker(
                        markerID: marker.id,
                        markerName: name,
                        reason: "与上一标记同一时间或间隔过小，已并入前段"
                    )
                )
                continue
            }
            anchors.append((marker, time))
        }
        // 片尾的标记不成段（否则会产生空段），从最后一个锚点开始弹出。
        while let last = anchors.last,
              trimDuration - last.time < minimumSegmentDuration
        {
            anchors.removeLast()
            skipped.append(
                MarkerSegmentPlan.SkippedMarker(
                    markerID: last.marker.id,
                    markerName: last.marker.name,
                    reason: "位于片尾，不足以成段"
                )
            )
        }
        guard !anchors.isEmpty else {
            return MarkerSegmentPlan(segments: [], skipped: skipped)
        }

        let base = sanitizeFilenameComponent(baseName, fallback: "八角录屏")
        var segments: [MarkerSegmentPlan.Segment] = []
        var usedFileNames: Set<String> = []
        for (index, anchor) in anchors.enumerated() {
            let end = index + 1 < anchors.count
                ? anchors[index + 1].time
                : trimDuration
            let displayName = sanitizeFilenameComponent(
                anchor.marker.name,
                fallback: "段 \(index + 1)"
            )
            var fileName = "\(base)-\(displayName).mp4"
            var sequence = 2
            while usedFileNames.contains(fileName) {
                fileName = "\(base)-\(displayName)-\(sequence).mp4"
                sequence += 1
            }
            usedFileNames.insert(fileName)
            segments.append(
                MarkerSegmentPlan.Segment(
                    markerID: anchor.marker.id,
                    markerName: anchor.marker.name,
                    start: anchor.time,
                    end: end,
                    fileName: fileName
                )
            )
        }
        return MarkerSegmentPlan(segments: segments, skipped: skipped)
    }

    /// 与导出文件名规则一致：非法路径字符替换为连字符，空名回退。
    static func sanitizeFilenameComponent(
        _ value: String,
        fallback: String
    ) -> String {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[/\\:*?"<>|]+"#,
                with: "-",
                options: .regularExpression
            )
        return cleaned.isEmpty ? fallback : cleaned
    }
}
