import Foundation

struct WindowDisplayBounds: Equatable {
    let id: UInt32
    let frame: CGRect
}

enum WindowDisplayFilter: Hashable {
    case all
    case display(UInt32)
}

struct WindowDisplayGroup: Identifiable, Equatable {
    let id: String
    let displayID: UInt32?
    let title: String
    let windows: [WindowCaptureInfo]
}

enum WindowPickerLogic {
    static func displayID(
        containing center: CGPoint,
        displays: [WindowDisplayBounds],
        fallback: UInt32
    ) -> UInt32 {
        displays.first(where: { $0.frame.contains(center) })?.id ?? fallback
    }

    static func groups(
        windows: [WindowCaptureInfo],
        displays: [DisplayOption],
        filter: WindowDisplayFilter = .all,
        query: String = "",
        currentDesktopOnly: Bool = false
    ) -> [WindowDisplayGroup] {
        let knownIDs = Set(displays.map(\.id))
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let displayNames = Dictionary(
            uniqueKeysWithValues: displays.map { ($0.id, $0.name) }
        )
        var grouped: [UInt32?: [WindowCaptureInfo]] = [:]

        for window in windows {
            if currentDesktopOnly, !window.isCurrentlyVisible {
                continue
            }
            let displayID = window.displayID.flatMap {
                knownIDs.contains($0) ? $0 : nil
            }
            let displayName = displayID.flatMap { displayNames[$0] }
                ?? "其他显示器"
            guard matchesQuery(
                window,
                displayName: displayName,
                query: trimmedQuery
            ) else {
                continue
            }
            switch filter {
            case .all:
                break
            case let .display(targetID):
                guard displayID == targetID else { continue }
            }
            grouped[displayID, default: []].append(window)
        }

        var result: [WindowDisplayGroup] = displays.compactMap { display in
            guard let windows = grouped[display.id], !windows.isEmpty else {
                return nil
            }
            return WindowDisplayGroup(
                id: "display-\(display.id)",
                displayID: display.id,
                title: display.name,
                windows: sorted(windows)
            )
        }
        if let other = grouped[nil], !other.isEmpty, filter == .all {
            result.append(
                WindowDisplayGroup(
                    id: "display-other",
                    displayID: nil,
                    title: "其他显示器",
                    windows: sorted(other)
                )
            )
        }
        return result
    }

    static func displayCounts(
        windows: [WindowCaptureInfo],
        displays: [DisplayOption],
        currentDesktopOnly: Bool = false
    ) -> [UInt32: Int] {
        let knownIDs = Set(displays.map(\.id))
        var counts: [UInt32: Int] = [:]
        for window in windows {
            if currentDesktopOnly, !window.isCurrentlyVisible {
                continue
            }
            guard
                let displayID = window.displayID,
                knownIDs.contains(displayID)
            else {
                continue
            }
            counts[displayID, default: 0] += 1
        }
        return counts
    }

    private static func matchesQuery(
        _ window: WindowCaptureInfo,
        displayName: String,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        return window.appName.localizedCaseInsensitiveContains(query)
            || window.title.localizedCaseInsensitiveContains(query)
            || displayName.localizedCaseInsensitiveContains(query)
    }

    private static func sorted(
        _ windows: [WindowCaptureInfo]
    ) -> [WindowCaptureInfo] {
        windows.sorted { lhs, rhs in
            if lhs.isCurrentlyVisible != rhs.isCurrentlyVisible {
                return lhs.isCurrentlyVisible
            }
            let appOrder = lhs.appName.localizedCaseInsensitiveCompare(
                rhs.appName
            )
            if appOrder != .orderedSame {
                return appOrder == .orderedAscending
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.windowID < rhs.windowID
        }
    }
}
