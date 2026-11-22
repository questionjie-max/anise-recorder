import AppKit
import ImageIO
import UniformTypeIdentifiers

struct DesktopWallpaperOption: Identifiable {
    let id: UInt32
    let screenName: String
    let imageURL: URL
    let image: NSImage
}

enum CanvasBackgroundImageError: LocalizedError {
    case unreadableImage
    case missingExtension
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "无法读取这张图片，请换一个图片文件。"
        case .missingExtension:
            return "无法确定图片格式，请换一个图片文件。"
        case let .installFailed(message):
            return "无法保存背景图片：\(message)"
        }
    }
}

enum CanvasBackgroundImageInstaller {
    static func install(
        from sourceURL: URL,
        into folderURL: URL,
        replacing previousFilename: String?
    ) throws -> String {
        let source = sourceURL.resolvingSymlinksInPath()
        let extensionName = try imageExtension(for: source)
        let filename = "background.\(extensionName)"
        let destination = folderURL.appendingPathComponent(filename)
        let fileManager = FileManager.default

        if source.standardizedFileURL == destination.standardizedFileURL {
            guard isReadableImage(source) else {
                throw CanvasBackgroundImageError.unreadableImage
            }
            return filename
        }

        let temporary = folderURL.appendingPathComponent(
            ".background-\(UUID().uuidString).\(extensionName)"
        )
        do {
            try fileManager.copyItem(at: source, to: temporary)
            guard isReadableImage(temporary) else {
                throw CanvasBackgroundImageError.unreadableImage
            }
            if fileExistsOrIsSymbolicLink(destination) {
                let backup = folderURL.appendingPathComponent(
                    ".background-old-\(UUID().uuidString)"
                )
                try fileManager.moveItem(at: destination, to: backup)
                do {
                    try fileManager.moveItem(at: temporary, to: destination)
                } catch {
                    try? fileManager.moveItem(at: backup, to: destination)
                    throw error
                }
                try? fileManager.removeItem(at: backup)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch let error as CanvasBackgroundImageError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CanvasBackgroundImageError.installFailed(
                error.localizedDescription
            )
        }

        if
            let previousFilename,
            previousFilename != filename,
            URL(fileURLWithPath: previousFilename).lastPathComponent
                == previousFilename
        {
            try? fileManager.removeItem(
                at: folderURL.appendingPathComponent(previousFilename)
            )
        }
        return filename
    }

    private static func fileExistsOrIsSymbolicLink(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true
    }

    static func isReadableImage(_ url: URL) -> Bool {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func imageExtension(for url: URL) throws -> String {
        let provided = url.pathExtension.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !provided.isEmpty {
            return provided
        }
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source),
            let extensionName = UTType(type as String)?
                .preferredFilenameExtension
        else {
            throw CanvasBackgroundImageError.missingExtension
        }
        return extensionName
    }
}

/// 壁纸目录两段式（P4 防卡死）：屏幕信息查询走 NSScreen/NSWorkspace
/// 主线程接口（毫秒级）；壁纸解码是重活（5K JPEG/HEIC 100–300ms+/张），
/// 拆成非隔离的 `decodedOptions` 供后台任务执行。
enum DesktopWallpaperCatalog {
    @MainActor
    static func screenEntries() -> [
        (id: UInt32, screenName: String, imageURL: URL)
    ] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard
                let url = NSWorkspace.shared.desktopImageURL(for: screen)
            else {
                return nil
            }
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            return (
                number?.uint32Value ?? UInt32(index + 1),
                screen.localizedName,
                url
            )
        }
    }

    static func decodedOptions(
        from entries: [(id: UInt32, screenName: String, imageURL: URL)]
    ) -> [DesktopWallpaperOption] {
        entries.compactMap { entry in
            guard let image = NSImage(contentsOf: entry.imageURL) else {
                return nil
            }
            return DesktopWallpaperOption(
                id: entry.id,
                screenName: entry.screenName,
                imageURL: entry.imageURL,
                image: image
            )
        }
    }
}

// MARK: F2 素材叠加轨安装器

enum OverlayMediaError: LocalizedError {
    case unsupportedFile
    case unreadableImage
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "只支持图片（PNG/JPEG/HEIC 等）或视频（MOV/MP4）素材。"
        case .unreadableImage:
            return "无法读取这张图片，请换一个图片文件。"
        case let .installFailed(message):
            return "无法保存素材文件：\(message)"
        }
    }
}

/// 素材叠加轨的素材安装：复制进工程目录（文件名 overlay-<uuid>.<ext>，
/// 与背景图同约定——project.json 只存相对文件名）。图片用 CGImageSource
/// 验证可解码；视频仅校验扩展名与可读性，时长/宽高比由调用方经
/// AVURLAsset 异步探测。
enum OverlayMediaInstaller {
    static let supportedVideoExtensions: Set<String> = [
        "mov", "mp4", "m4v",
    ]

    static func kind(for url: URL) -> OverlayClip.Kind? {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) {
            return .video
        }
        if CGImageSourceCreateWithURL(url as CFURL, nil) != nil {
            return .image
        }
        return nil
    }

    static func install(
        from sourceURL: URL,
        into folderURL: URL
    ) throws -> (fileName: String, kind: OverlayClip.Kind) {
        let source = sourceURL.resolvingSymlinksInPath()
        guard fileExists(source) else {
            throw OverlayMediaError.unsupportedFile
        }
        let kind = Self.kind(for: source)
        let ext = source.pathExtension.lowercased()
        guard let kind, !ext.isEmpty else {
            throw OverlayMediaError.unsupportedFile
        }
        if kind == .image {
            guard CanvasBackgroundImageInstaller.isReadableImage(source)
            else {
                throw OverlayMediaError.unreadableImage
            }
        }
        let filename = "overlay-\(UUID().uuidString).\(ext)"
        let destination = folderURL.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw OverlayMediaError.installFailed(error.localizedDescription)
        }
        return (filename, kind)
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
