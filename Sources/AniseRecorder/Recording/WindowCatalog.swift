import AppKit
import Foundation
import ScreenCaptureKit

enum WindowCatalog {
    /// 窗口选择器可列出条件：桌面层（layer 0）、最小尺寸、有归属应用、
    /// 且不是本 App 的窗口——本 App 的窗口（含提词面板、悬浮窗、HUD）
    /// 永远不会成为可选的录制来源。
    static func isListableWindow(
        windowLayer: Int,
        width: CGFloat,
        height: CGFloat,
        owningBundleIdentifier: String?,
        appName: String,
        ownBundleID: String
    ) -> Bool {
        guard
            windowLayer == 0,
            width >= 160,
            height >= 100,
            let owningBundleIdentifier,
            owningBundleIdentifier != ownBundleID
        else {
            return false
        }
        return !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func loadWindows() async -> [WindowCaptureInfo] {
        do {
            // onScreenWindowsOnly: false 才会返回其他 macOS 桌面（Space）
            // 和最小化的窗口；是否可见记录在 isOnScreen 上，由选择器
            // 标注并提供“仅当前桌面”过滤。
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let ownBundleID = Bundle.main.bundleIdentifier ?? ""
            let displayBounds = activeDisplayBounds()
            let windows = content.windows.compactMap { window -> WindowCaptureInfo? in
                let appName = (window.owningApplication?.applicationName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    isListableWindow(
                        windowLayer: window.windowLayer,
                        width: window.frame.width,
                        height: window.frame.height,
                        owningBundleIdentifier: window.owningApplication?
                            .bundleIdentifier,
                        appName: appName,
                        ownBundleID: ownBundleID
                    )
                else {
                    return nil
                }
                let title = (window.title ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let center = CGPoint(
                    x: window.frame.midX,
                    y: window.frame.midY
                )
                let displayID = WindowPickerLogic.displayID(
                    containing: center,
                    displays: displayBounds,
                    fallback: CGMainDisplayID()
                )
                return WindowCaptureInfo(
                    windowID: window.windowID,
                    displayID: displayID,
                    appName: appName,
                    title: title,
                    width: Int(window.frame.width.rounded()),
                    height: Int(window.frame.height.rounded()),
                    bundleIdentifier: window.owningApplication?
                        .bundleIdentifier ?? "",
                    screenFrame: appKitFrame(for: window.frame),
                    isOnScreen: window.isOnScreen
                )
            }
            return windows.sorted {
                if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.appName.localizedCaseInsensitiveCompare($1.appName)
                    == .orderedAscending
            }
        } catch {
            return []
        }
    }

    @MainActor
    static func captureDisplayPreview(
        displayID: UInt32,
        maximumSize: CGSize = CGSize(width: 1280, height: 800)
    ) async throws -> NSImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw SourcePreviewError.screenRecordingUnavailable(
                error.localizedDescription
            )
        }
        guard
            let display = content.displays.first(where: {
                $0.displayID == displayID
            })
        else {
            throw SourcePreviewError.displayUnavailable
        }
        let filter = SCContentFilter(
            display: display,
            excludingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let fit = min(
            1,
            maximumSize.width / max(1, CGFloat(display.width)),
            maximumSize.height / max(1, CGFloat(display.height))
        )
        configuration.width = max(
            2,
            Int((CGFloat(display.width) * fit).rounded())
        )
        configuration.height = max(
            2,
            Int((CGFloat(display.height) * fit).rounded())
        )
        configuration.showsCursor = false
        configuration.scalesToFit = true

        do {
            let image: CGImage = try await withCheckedThrowingContinuation {
                continuation in
                SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                ) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(
                            throwing: error
                                ?? SourcePreviewError.captureFailed
                        )
                    }
                }
            }
            return NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        } catch {
            throw SourcePreviewError.screenRecordingUnavailable(
                error.localizedDescription
            )
        }
    }

    @MainActor
    static func capturePreview(
        for info: WindowCaptureInfo,
        maximumSize: CGSize = CGSize(width: 720, height: 450)
    ) async -> NSImage? {
        guard let window = await resolveWindow(windowID: info.windowID) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = max(1, filter.pointPixelScale)
        let contentRect = filter.contentRect
        let fit = min(
            1,
            maximumSize.width / max(1, contentRect.width * CGFloat(scale)),
            maximumSize.height / max(1, contentRect.height * CGFloat(scale))
        )
        configuration.width = max(
            2,
            Int((contentRect.width * CGFloat(scale) * fit).rounded())
        )
        configuration.height = max(
            2,
            Int((contentRect.height * CGFloat(scale) * fit).rounded())
        )
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true

        do {
            let image: CGImage = try await withCheckedThrowingContinuation {
                continuation in
                SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                ) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(
                            throwing: error ?? WindowCatalogError.captureFailed
                        )
                    }
                }
            }
            return NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        } catch {
            return nil
        }
    }

    static func resolveWindow(windowID: UInt32) async -> SCWindow? {
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        else {
            return nil
        }
        return content.windows.first { $0.windowID == windowID }
    }

    static func screenFrame(for windowID: UInt32) async -> CGRect? {
        guard let window = await resolveWindow(windowID: windowID) else {
            return nil
        }
        return appKitFrame(for: window.frame)
    }

    private static func activeDisplayBounds() -> [WindowDisplayBounds] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return [
                WindowDisplayBounds(
                    id: CGMainDisplayID(),
                    frame: CGDisplayBounds(CGMainDisplayID())
                )
            ]
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return [
                WindowDisplayBounds(
                    id: CGMainDisplayID(),
                    frame: CGDisplayBounds(CGMainDisplayID())
                )
            ]
        }
        return ids.prefix(Int(count)).map {
            WindowDisplayBounds(id: $0, frame: CGDisplayBounds($0))
        }
    }

    private static func appKitFrame(for cgFrame: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens
            .first(where: { screen in
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
                return number?.uint32Value == CGMainDisplayID()
            })?
            .frame.maxY ?? 0
        return CGRect(
            x: cgFrame.minX,
            y: mainHeight - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }
}

enum WindowCatalogError: LocalizedError {
    case captureFailed

    var errorDescription: String? {
        "无法读取窗口画面，请重新选择窗口。"
    }
}

enum SourcePreviewError: LocalizedError {
    case displayUnavailable
    case screenRecordingUnavailable(String)
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "当前显示器已断开，请刷新来源后重新选择。"
        case .screenRecordingUnavailable:
            return "无法读取屏幕预览。请在系统设置中允许“八角录屏”使用屏幕录制，然后刷新来源。"
        case .captureFailed:
            return "无法读取当前画面，请刷新来源后重试。"
        }
    }
}
