import Foundation

/// 提词器滚动状态。offset 为文稿坐标系内已滚过的距离（点），
/// elapsedActiveTime 只累计未暂停的推进时间，保证暂停后不跳位。
public struct TeleprompterScrollState: Equatable, Sendable {
    public var offset: Double
    public var isPaused: Bool
    public var elapsedActiveTime: TimeInterval

    public init(
        offset: Double = 0,
        isPaused: Bool = false,
        elapsedActiveTime: TimeInterval = 0
    ) {
        self.offset = offset
        self.isPaused = isPaused
        self.elapsedActiveTime = elapsedActiveTime
    }

    public static let initial = TeleprompterScrollState()
}

/// 提词器自动滚动的纯逻辑引擎。只接受视图层测量好的内容高度与视口高度，
/// 不做文本排版；速度以「档位 1...10」表达，映射为线性点 / 秒。
public struct TeleprompterScrollEngine: Equatable, Sendable {
    /// 用户可调速度档位范围。
    public static let speedRange = 1.0 ... 10.0
    /// 每档位对应的滚动速度（点 / 秒）：档位 × 24 → 24...240。
    private static let pointsPerSecondPerLevel = 24.0

    /// 段尾减速参数：接近下一段边界时线性降速到 floor，越过边界后恢复。
    public struct Deceleration: Equatable, Sendable {
        /// 即将到达的内容坐标（已由调用方按阅读线位置折算）。
        public let boundaryOffset: Double
        /// 开始减速的距离（点）。
        public let zone: Double
        /// 减速下限比例（0...1）。
        public let floor: Double

        public init(boundaryOffset: Double, zone: Double, floor: Double) {
            self.boundaryOffset = boundaryOffset
            self.zone = zone
            self.floor = floor
        }
    }

    /// 线性减速系数：剩余距离在减速区内按比例降到 floor，区外 / 越过边界 /
    /// 非法区间为 1（全速）。
    public static func decelerationMultiplier(
        remainingToBoundary: Double,
        zone: Double,
        floor: Double
    ) -> Double {
        guard zone > 0, remainingToBoundary > 0, remainingToBoundary < zone
        else { return 1 }
        return max(floor, remainingToBoundary / zone)
    }

    public let contentHeight: Double
    public let viewportHeight: Double
    public let speed: Double

    public init(contentHeight: Double, viewportHeight: Double, speed: Double) {
        self.contentHeight = max(0, contentHeight)
        self.viewportHeight = max(0, viewportHeight)
        self.speed = Self.clampedSpeed(speed)
    }

    public var pointsPerSecond: Double {
        Self.pointsPerSecond(forSpeed: speed)
    }

    public var maxOffset: Double {
        max(0, contentHeight - viewportHeight)
    }

    public func isAtEnd(in state: TeleprompterScrollState) -> Bool {
        state.offset >= maxOffset
    }

    /// 把当前状态推进 interval 秒。暂停时不前进也不累计时间；
    /// 到达尾部后停在 maxOffset。
    public func advanced(
        from state: TeleprompterScrollState,
        by interval: TimeInterval
    ) -> TeleprompterScrollState {
        advanced(from: state, by: interval, deceleration: nil)
    }

    /// 带段尾减速的推进。deceleration 为 nil 时与普通推进一致。
    public func advanced(
        from state: TeleprompterScrollState,
        by interval: TimeInterval,
        deceleration: Deceleration?
    ) -> TeleprompterScrollState {
        var next = state
        guard !state.isPaused, interval > 0 else { return next }
        next.elapsedActiveTime += interval
        let multiplier: Double
        if let deceleration {
            multiplier = Self.decelerationMultiplier(
                remainingToBoundary: deceleration.boundaryOffset - state.offset,
                zone: deceleration.zone,
                floor: deceleration.floor
            )
        } else {
            multiplier = 1
        }
        next.offset = min(
            state.offset + pointsPerSecond * interval * multiplier,
            maxOffset
        )
        return next
    }

    public func paused(
        _ state: TeleprompterScrollState
    ) -> TeleprompterScrollState {
        var next = state
        next.isPaused = true
        return next
    }

    public func resumed(
        _ state: TeleprompterScrollState
    ) -> TeleprompterScrollState {
        var next = state
        next.isPaused = false
        return next
    }

    /// 拖动进度条回退 / 前进，钳制在有效范围。
    public func seek(
        to offset: Double,
        in state: TeleprompterScrollState
    ) -> TeleprompterScrollState {
        var next = state
        next.offset = min(max(offset, 0), maxOffset)
        return next
    }

    public func reset() -> TeleprompterScrollState {
        TeleprompterScrollState()
    }

    public static func clampedSpeed(_ speed: Double) -> Double {
        min(max(speed, speedRange.lowerBound), speedRange.upperBound)
    }

    public static func pointsPerSecond(forSpeed speed: Double) -> Double {
        clampedSpeed(speed) * pointsPerSecondPerLevel
    }
}

/// 文稿分段：按空行拆段，用于面板显示当前段 / 下一段预告与段尾减速。
/// 段内保留原始换行；\r\n 归一化为 \n。
public struct TeleprompterDocument: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// 段落在归一化文稿中的起始字符偏移。
        public let startOffset: Int
        public let text: String

        public init(startOffset: Int, text: String) {
            self.startOffset = startOffset
            self.text = text
        }
    }

    public let normalizedText: String
    public let segments: [Segment]

    public init(text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        self.normalizedText = normalized
        self.segments = Self.split(normalized)
    }

    private static func split(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var currentStart: Int?
        var currentLines: [String] = []
        var lineStart = 0
        var offset = 0
        var line = ""

        func finishLine() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // 空行结束当前段
                if let start = currentStart, !currentLines.isEmpty {
                    segments.append(
                        Segment(
                            startOffset: start,
                            text: currentLines.joined(separator: "\n")
                        )
                    )
                }
                currentStart = nil
                currentLines = []
            } else {
                if currentStart == nil {
                    currentStart = lineStart
                }
                currentLines.append(line)
            }
            line = ""
        }

        for character in text {
            if character == "\n" {
                finishLine()
                offset += 1
                lineStart = offset
            } else {
                line.append(character)
                offset += 1
            }
        }
        // 无结尾换行的最后一行
        if !line.isEmpty {
            finishLine()
        }
        if let start = currentStart, !currentLines.isEmpty {
            segments.append(
                Segment(
                    startOffset: start,
                    text: currentLines.joined(separator: "\n")
                )
            )
        }
        return segments
    }
}
