import Foundation

package struct CaptureClock: Equatable, Sendable {
    package struct Pause: Equatable, Sendable {
        package var start: Double
        package var end: Double?
    }

    package private(set) var originHostTime: Double?
    package private(set) var pauses: [Pause] = []

    package init(originHostTime: Double? = nil) {
        self.originHostTime = originHostTime
    }

    package var hasPauses: Bool {
        !pauses.isEmpty
    }

    package mutating func setOrigin(_ hostTime: Double) {
        guard originHostTime == nil, hostTime.isFinite else { return }
        originHostTime = hostTime
    }

    package mutating func pause(at hostTime: Double) {
        guard hostTime.isFinite else { return }
        if let last = pauses.last, last.end == nil {
            return
        }
        let start = max(hostTime, originHostTime ?? hostTime)
        pauses.append(Pause(start: start, end: nil))
    }

    package mutating func resume(at hostTime: Double) {
        guard
            hostTime.isFinite,
            let index = pauses.indices.last,
            pauses[index].end == nil
        else {
            return
        }
        pauses[index].end = max(pauses[index].start, hostTime)
    }

    package func isActive(at hostTime: Double) -> Bool {
        guard
            let originHostTime,
            hostTime.isFinite,
            hostTime >= originHostTime
        else {
            return false
        }
        return !pauses.contains {
            hostTime >= $0.start
                && ($0.end == nil || hostTime < $0.end!)
        }
    }

    package func isPaused(at hostTime: Double) -> Bool {
        guard hostTime.isFinite else { return false }
        return pauses.contains {
            hostTime >= $0.start
                && ($0.end == nil || hostTime < $0.end!)
        }
    }

    package func outputTime(forHostTime hostTime: Double) -> Double? {
        guard isActive(at: hostTime), let originHostTime else {
            return nil
        }
        let pausedDuration = pauses.reduce(0.0) { partial, pause in
            guard let end = pause.end else { return partial }
            let overlapStart = max(originHostTime, pause.start)
            let overlapEnd = min(hostTime, end)
            return partial + max(0, overlapEnd - overlapStart)
        }
        return max(0, hostTime - originHostTime - pausedDuration)
    }

    package func nextActiveHostTime(
        atOrAfter hostTime: Double
    ) -> Double? {
        guard let originHostTime else { return nil }
        var candidate = max(hostTime, originHostTime)
        for pause in pauses {
            guard candidate >= pause.start else { continue }
            guard let end = pause.end else { return nil }
            if candidate < end {
                candidate = end
            }
        }
        return candidate
    }
}
