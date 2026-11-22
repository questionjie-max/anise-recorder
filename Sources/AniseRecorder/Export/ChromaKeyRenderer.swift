import CoreGraphics
import CoreImage
import Foundation
import Vision

/// C2 绿幕抠像优化后的键控渲染器。
///
/// 与 1.3 现行版（`applyLegacyCube`，单一关键色 + 色相距离 LUT）的差异：
/// 1. 度量升级为对亮度不敏感的色度距离（YCbCr 的 Cb/Cr 距离，亮度只在
///    近黑/近白两端作噪声权重）——阴影里的绿色（色相不变、只是变暗）
///    同样识别为背景；
/// 2. 自动取色估计 12×7 低分辨率背景色场（帧降采样 60×35、每格 5px；
///    边框多点采样 + IDW 内插 + 两轮盒糊重模糊），
///    逐像素用所在位置的背景色作键控参照，处理幕布明暗渐变与局部阴影；
///    手动取色保留单点模式（nil 色场 = 均匀单色场）；
/// 3. 边缘三件套：alpha 线性渐变带（tolerance/softness 沿用原滑杆语义）、
///    哑光内收（形态学腐蚀）+ alpha 小半径高斯柔化、去溢色权重为
///    (1-alpha)×spill（只作用于未完全保留区，不做全图 desaturate）。
///
/// 全部用标准 CIFilter 组合实现（无自定义 kernel），预览 / MP4 / GIF
/// 经同一 `CanvasRenderer` 共用，逐像素确定、无时域状态，预览与导出
/// 天然一致。现行 LUT 路径保留为 `applyLegacyCube` 仅供 A/B 对照测试。
enum ChromaKeyRenderer {
    static let cubeDimension = 32

    private static let cubeCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 8
        return cache
    }()

    private static let fieldCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 4
        return cache
    }()

    /// 测试用：释放跨用例持有的 LUT / 背景色场 / Vision CIContext 缓存。
    /// 整套测试连续运行时，1080p 色场与 mask 缓存会把进程推到
    /// AVFoundation 解码的资源边界，导致后续导出用例偶发 SIGSEGV。
    static func clearCachesForTesting() {
        cubeCache.removeAllObjects()
        fieldCache.removeAllObjects()
        maskContext.clearCaches()
    }

    // MARK: - 入口

    /// 抠像合成入口。三态：enabled=false 关闭；enabled &&
    /// personSegmentation=false 绿幕；enabled && personSegmentation
    /// 自动分割。分割模式把人像 mask 作为 alpha 输入接进与绿幕
    /// 共用的后段（哑光收缩 / alpha 羽化 / 合成），不另起渲染链；
    /// maskProvider 可注入（测试用），生产走 Vision accurate。
    static func apply(
        _ image: CIImage,
        settings: CameraChromaKeySettings,
        maskProvider: PersonMaskProvider? = nil
    ) -> CIImage {
        applyWithMatte(image, settings: settings, maskProvider: maskProvider).image
    }

    /// 抠像合成 + 交出 matte（不透明灰色图，亮度 = 保留度）。
    /// light wrap 需要与提词画面同变换的 matte 来定位边缘环带；
    /// compositor 用同一个 fill / fit 变换两者，保证对齐。
    static func applyWithMatte(
        _ image: CIImage,
        settings: CameraChromaKeySettings,
        maskProvider: PersonMaskProvider? = nil
    ) -> (image: CIImage, matte: CIImage) {
        guard
            settings.enabled,
            image.extent.width > 1,
            image.extent.height > 1
        else {
            return (image, CIImage.empty())
        }
        if settings.personSegmentation {
            return personSegmented(
                image,
                settings: settings,
                maskProvider: maskProvider ?? visionPersonMask
            )
        }
        return keyed(image, settings: settings)
    }

    /// C3 分割模式合成：mask → 收缩 → 羽化 → 与背景（透明或自身重
    /// 模糊）合成。与绿幕共用收缩 / 羽化 / 合成段。返回（合成图，
    /// 不透明灰色 matte）。
    private static func personSegmented(
        _ image: CIImage,
        settings: CameraChromaKeySettings,
        maskProvider: PersonMaskProvider
    ) -> (image: CIImage, matte: CIImage) {
        let extent = image.extent
        guard
            let rawMask = try? maskProvider(image),
            rawMask.extent.width > 1
        else {
            // 无可用 mask（检测失败 / 异常）：整帧保留原样，绝不静默
            // 把画面抠成全透明。matte 为全不透明（无环带 → light
            // wrap 自然不生效）。
            return (image, white(in: extent))
        }
        let shrink = min(3, max(0, settings.edgeShrinkPixels))
        let feather = min(4, max(0, settings.edgeFeatherPixels))
        var alpha = clamp01(
            matrix(
                rawMask.cropped(to: extent),
                rVector: (1, 0, 0, 0),
                gVector: (1, 0, 0, 0),
                bVector: (1, 0, 0, 0)
            )
        )
        if shrink > 0.05 {
            alpha = alpha.applyingFilter(
                "CIMorphologyMinimum",
                parameters: ["inputRadius": shrink]
            ).cropped(to: extent)
        }
        if feather > 0.05 {
            alpha = alpha.applyingFilter(
                "CIGaussianBlur",
                parameters: ["inputRadius": feather]
            ).cropped(to: extent)
        }
        alpha = clamp01(alpha)
        let mask = matrix(
            alpha,
            rVector: (1, 0, 0, 0),
            gVector: (1, 0, 0, 0),
            bVector: (1, 0, 0, 0)
        )
        let background: CIImage
        if settings.segmentationBackgroundBlurred {
            background = image.applyingFilter(
                "CIGaussianBlur",
                parameters: ["inputRadius": min(40, extent.width / 30)]
            ).cropped(to: extent)
        } else {
            background = CIImage.empty()
        }
        let composited = image.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask
            ]
        ).cropped(to: extent)
        return (composited, mask)
    }

    /// 人像 mask 提供器：输入摄像头帧，输出 alpha mask（亮度即人像
    /// 置信度）。生产实现 = Vision accurate。
    typealias PersonMaskProvider = (CIImage) throws -> CIImage

    /// 生产 mask：VNGeneratePersonSegmentationRequest（accurate，全
    /// 离线）。单通道 mask 缓冲按亮度处理。帧策略 = 逐帧（见历史实测记录
    /// 的性能实测与取舍）。
    ///
    /// 性能快修：① CIContext 改为缓存单例（原每帧新建）；
    /// ② 送 Vision 前降采样到长边 512（模型固定 512 预测分辨率，
    /// 全分辨率回读是纯浪费），mask 再放大回原空间对齐。
    static func visionPersonMask(_ image: CIImage) throws -> CIImage {
        guard let (cgImage, _) = downscaledForSegmentation(image) else {
            throw NSError(
                domain: "ChromaKeyRenderer",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "人像分割帧转换失败"]
            )
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            options: [:]
        )
        try handler.perform([request])
        guard
            let buffer = request.results?.first?.pixelBuffer
        else {
            throw NSError(
                domain: "ChromaKeyRenderer",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "人像分割无结果"]
            )
        }
        let mask = CIImage(cvPixelBuffer: buffer)
        // 对齐回输入空间：Vision mask 的原生分辨率与输入无关（实测
        // 480×270 输入 → 2016×1512 mask），必须按比例缩放，不能裁剪
        // （旧实现 cropped(to: extent) 只取左下角，mask 长期错位——
        // 自动分割检出率差的根源之一，本次修复）。
        let maskExtent = mask.extent
        let needsFit =
            abs(maskExtent.width - image.extent.width) > 1
            || abs(maskExtent.height - image.extent.height) > 1
        guard needsFit else { return mask }
        let scaleX = image.extent.width / maskExtent.width
        let scaleY = image.extent.height / maskExtent.height
        let scaled = mask.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )
        // 物化一次：CIImage 惰性求值，缩放后的 mask 会被后续每个消费者
        // （矩阵 / 形态学 / 合成）重复重采样，实测 +18ms/帧；经
        // CIContext 落成 CGImage 后全链共享同一份位图。
        if let materialized = maskContext.createCGImage(scaled, from: image.extent) {
            return CIImage(cgImage: materialized)
        }
        return scaled.cropped(to: image.extent)
    }

    /// 缓存的 CIContext（CIContext 线程安全，可跨帧复用；原实现每帧
    /// 新建，是分割模式的主要开销之一）。
    private static let maskContext: CIContext = {
        CIContext(options: [.workingColorSpace: NSNull()])
    }()

    /// 送 Vision 前的降采样：长边 > 512 时按比例缩小（VNGenerate
    /// PersonSegmentationRequest 的预测分辨率固定 512，喂全分辨率
    /// 不回任何质量）。返回（CGImage, 缩放比）。
    static func downscaledForSegmentation(_ image: CIImage)
        -> (cgImage: CGImage, scale: CGFloat)?
    {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        let scale: CGFloat = longest > 512 ? 512 / longest : 1
        let scaled = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let target = CGRect(
            x: scaled.extent.origin.x.rounded(),
            y: scaled.extent.origin.y.rounded(),
            width: scaled.extent.width.rounded(),
            height: scaled.extent.height.rounded()
        )
        guard let cgImage = maskContext.createCGImage(scaled, from: target)
        else {
            return nil
        }
        return (cgImage, scale)
    }

    // MARK: - 边缘光包裹（light wrap）

    /// Light wrap：把画布背景光沿 alpha 边缘环带叠回前景，消除人物
    /// 「贴」在背景上的贴纸感。`keyed`、`matte`、`backdrop` 必须同
    /// extent（compositor 在摄像头 rect 空间调用：提词画面与 matte
    /// 经同一个 fill / fit 变换、backdrop 为画布同区域裁剪，无需逆
    /// 变换；环带半径随 rect 宽度缩放，输出分辨率下视觉一致）。
    /// 强度 0 时逐像素恒等（预览 / 导出一致性不受影响）。
    ///
    /// matte 为灰色图（亮度 = 保留度）但 alpha 通道不可靠（键控链
    /// 混合副产物）；CIBlendWithMask 按 mask 亮度语义（实测：1 →
    /// input），故用「白 / 黑 + CIBlendWithMask」把它转成不透明灰度，
    /// 保证后续形态学（按 alpha 定目标域）行为确定。
    static func applyLightWrap(
        _ keyed: CIImage,
        matte: CIImage,
        settings: CameraChromaKeySettings,
        backdrop: CIImage
    ) -> CIImage {
        let extent = keyed.extent
        let strength = min(1, max(0, settings.lightWrap))
        guard
            strength > 0.001,
            extent.width > 1,
            extent.height > 1,
            abs(backdrop.extent.width - extent.width) < 1,
            abs(backdrop.extent.height - extent.height) < 1,
            abs(matte.extent.width - extent.width) < 1,
            abs(matte.extent.height - extent.height) < 1
        else {
            return keyed
        }
        // 环带半径：约 rect 宽度的 0.5%，钳制 1...4px（rect 空间）。
        let ringRadius = min(4, max(1, extent.width / 200))
        let black = CIImage(color: CIColor.black).cropped(to: extent)
        let white = CIImage(color: CIColor.white).cropped(to: extent)
        // 不透明 matte：白×(matte 亮度) + 黑×(1 − 亮度)。
        let opaqueMatte = white.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: black,
                kCIInputMaskImageKey: matte
            ]
        ).cropped(to: extent)
        // ring = matte − 腐蚀(matte)（不透明域；CIDifferenceBlendMode
        // 取绝对值，腐蚀只降值故等价于差）。
        let eroded = opaqueMatte.applyingFilter(
            "CIMorphologyMinimum",
            parameters: ["inputRadius": ringRadius]
        ).cropped(to: extent)
        let ringRaw = blend("CIDifferenceBlendMode", opaqueMatte, eroded)
            .cropped(to: extent)
        // ring 同样转不透明（亮度语义）。
        let ring = white.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: black,
                kCIInputMaskImageKey: ringRaw
            ]
        ).cropped(to: extent)
        // 背景光扩散 + 环带加权 + 颜色相加。
        // 预乘语义（本机实测）：alpha=0 的附加项预乘颜色恒 0，直接加法
        // 无效；乘法混合的 alpha 按 source-over 公式，权重 0 处输出背景
        // 本身。正确构造：CIBlendWithMask(input=模糊背景, background=
        // 透明, mask=权重灰) → 预乘 color = 背景×w、alpha = w；再用
        // Porter-Duff plus（CIAdditionCompositing）加到 keyed 上，
        // CIColorClamp 压回 alpha（plus 的 alpha 累加不钳制，已知怪癖）。
        let blurred = backdrop.applyingFilter(
            "CIGaussianBlur",
            parameters: ["inputRadius": ringRadius * 2]
        ).cropped(to: extent)
        let weight = matrix(
            ring,
            rVector: (strength, 0, 0, 0),
            gVector: (strength, 0, 0, 0),
            bVector: (strength, 0, 0, 0)
        )
        let wrapAddend = blurred.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: weight
            ]
        ).cropped(to: extent)
        let summed = blend("CIAdditionCompositing", wrapAddend, keyed)
            .cropped(to: extent)
        // 环带内 color = keyed + 模糊背景×w；带外 w=0，逐像素等于 keyed。
        return clamp01(summed)
    }

    // MARK: - 纯逻辑色度度量（估计器与测试共用）

    /// JFIF 全范围 YCbCr：cb/cr ∈ -0.5...0.5（亮度无关），y ∈ 0...1。
    static func chromaComponents(
        red: Double,
        green: Double,
        blue: Double
    ) -> (cb: Double, cr: Double, y: Double) {
        let y = 0.299 * red + 0.587 * green + 0.114 * blue
        let cb = (blue - y) * 0.565
        let cr = (red - y) * 0.713
        return (cb, cr, y)
    }

    /// 对亮度不敏感的色度距离：√(dCb² + dCr²) × 2，亮度 y 不参与距离。
    /// 「对亮度不敏感」由两条机制共同实现：(1) 度量本身只取 Cb/Cr，
    /// 同一幕布色叠加等量光（y 变、cb/cr 不变）时距离为 0；(2) 渐进
    /// 明暗（阴影 / 亮斑）由低分辨率背景色场逐像素提供同亮度水平的
    /// 局部参照吸收（纯除以 y 的归一化会放大暗部噪声：0.04/0.12≈0.33，
    /// 实测放弃，见历史实测记录）。亮度只在近黑端作噪声权重（yWeight，只压低
    /// 键出量、绝不打折保留量，否则暗前景会被透成半透明）。
    static func chromaDistance(
        _ lhs: (red: Double, green: Double, blue: Double),
        _ rhs: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let a = chromaComponents(
            red: lhs.red,
            green: lhs.green,
            blue: lhs.blue
        )
        let b = chromaComponents(
            red: rhs.red,
            green: rhs.green,
            blue: rhs.blue
        )
        let dcb = a.cb - b.cb
        let dcr = a.cr - b.cr
        return (dcb * dcb + dcr * dcr).squareRoot() * 2
    }

    // MARK: - 背景色场估计（多点取色）

    /// 从边框多点估计背景色场：帧先降采样到 60×35，按 12×7 网格取均值
    /// （每格 5×5 px）；
    /// 判定为幕布色（绿系）的边框格作为已知点，其余边框格与内部格按
    /// Laplacian 迭代内插填充，再做两轮 3×3 盒式模糊（网格尺度的重模糊，
    /// 上采样后即平滑色场）。返回色场与幕布色中位数（供 UI 显示与单点
    /// 回退）。边框绿系格不足时返回 nil（与旧取色一致的“无幕布”提示）。
    static func sampleBackgroundField(
        from image: CGImage
    ) -> (field: ChromaKeyField, keyColorHex: String)? {
        let columns = ChromaKeyField.columns
        let rows = ChromaKeyField.rows
        let sampleWidth = columns * 5
        let sampleHeight = rows * 5
        var pixels = [UInt8](
            repeating: 0,
            count: sampleWidth * sampleHeight * 4
        )
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &pixels,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: sampleWidth,
                height: sampleHeight
            )
        )

        // 网格均值。CGBitmapContext 缓冲行 0 是绘制区的视觉顶部
        // （实测确认），网格行 0 = 画面顶部，直接对应。
        var cells = [RGB]()
        cells.reserveCapacity(rows * columns)
        for gridRow in 0 ..< rows {
            let bufferRow = gridRow
            for column in 0 ..< columns {
                var red = 0.0
                var green = 0.0
                var blue = 0.0
                for dy in 0 ..< 5 {
                    let y = bufferRow * 5 + dy
                    for dx in 0 ..< 5 {
                        let offset = (y * sampleWidth + column * 5 + dx) * 4
                        red += Double(pixels[offset]) / 255
                        green += Double(pixels[offset + 1]) / 255
                        blue += Double(pixels[offset + 2]) / 255
                    }
                }
                let count = 25.0
                cells.append(
                    RGB(
                        red: red / count,
                        green: green / count,
                        blue: blue / count
                    )
                )
            }
        }

        // 边框格中判定幕布色（宽松绿优门：镜面亮斑饱和度塌陷但仍以绿
        // 为主，也要收进色场；总体数量守卫防止整帧无幕布）。
        let borderIndices = borderCellIndices(columns: columns, rows: rows)
        let screenIndices = borderIndices.filter { isLooseScreenColor(cells[$0]) }
        guard screenIndices.count >= max(6, borderIndices.count / 3) else {
            return nil
        }
        var known = [Bool](repeating: false, count: rows * columns)
        for index in screenIndices {
            known[index] = true
        }
        // 内部与未知格：距离反比加权（IDW）一步填充自全部已知格——
        // 网格小、直接全局加权，避免迭代填充收敛不足残留前景初值。
        var filled = cells
        for index in 0 ..< (rows * columns) where !known[index] {
            let row = index / columns
            let column = index % columns
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var weightSum = 0.0
            for knownIndex in screenIndices {
                let knownRow = knownIndex / columns
                let knownColumn = knownIndex % columns
                let dr = Double(row - knownRow)
                let dc = Double(column - knownColumn)
                let distanceSquared = dr * dr + dc * dc
                let weight = 1 / (distanceSquared + 1)
                let cell = cells[knownIndex]
                red += cell.red * weight
                green += cell.green * weight
                blue += cell.blue * weight
                weightSum += weight
            }
            guard weightSum > 0 else { continue }
            filled[index] = RGB(
                red: red / weightSum,
                green: green / weightSum,
                blue: blue / weightSum
            )
        }

        // 网格尺度重模糊：两轮 3×3 盒式模糊（上采样后即平滑色场），
        // 模糊后复置已知格原值，保持边框实测梯度不失真。
        var smoothed = boxSmooth(
            boxSmooth(filled, columns: columns, rows: rows),
            columns: columns,
            rows: rows
        )
        for index in screenIndices {
            smoothed[index] = cells[index]
        }
        let field = ChromaKeyField(
            cells: smoothed.map {
                ChromaRGB(red: $0.red, green: $0.green, blue: $0.blue)
            }
        )

        // 幕布色取边框幕布格的中位数（供 UI 显示与单点回退）。
        let medians = screenIndices.map { cells[$0] }
        let key = RGB(
            red: median(medians.map(\.red)),
            green: median(medians.map(\.green)),
            blue: median(medians.map(\.blue))
        )
        return (field, key.hexString)
    }

    private static func borderCellIndices(
        columns: Int,
        rows: Int
    ) -> [Int] {
        var indices: [Int] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                guard
                    row == 0 || row == rows - 1
                        || column == 0 || column == columns - 1
                else { continue }
                indices.append(row * columns + column)
            }
        }
        return indices
    }

    /// 宽松幕布色判定（边框格收进色场用）：绿占优且不至全黑即可，
    /// 不设饱和度下限——镜面亮斑饱和度塌陷但仍属幕布。
    private static func isLooseScreenColor(_ color: RGB) -> Bool {
        color.green > 0.05
            && color.green > color.red
            && color.green > color.blue
    }

    private static func boxSmooth(
        _ cells: [RGB],
        columns: Int,
        rows: Int
    ) -> [RGB] {
        cells.enumerated().map { index, cell -> RGB in
            let row = index / columns
            let column = index % columns
            var red = cell.red
            var green = cell.green
            var blue = cell.blue
            var count = 1.0
            for dr in -1 ... 1 {
                for dc in -1 ... 1 {
                    guard dr != 0 || dc != 0 else { continue }
                    let r = row + dr
                    let c = column + dc
                    guard r >= 0, r < rows, c >= 0, c < columns else {
                        continue
                    }
                    let neighbor = cells[r * columns + c]
                    red += neighbor.red
                    green += neighbor.green
                    blue += neighbor.blue
                    count += 1
                }
            }
            return RGB(
                red: red / count,
                green: green / count,
                blue: blue / count
            )
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    // MARK: - 新键控链（标准 CIFilter 组合）

    private static func keyed(
        _ image: CIImage,
        settings: CameraChromaKeySettings
    ) -> (image: CIImage, matte: CIImage) {
        let extent = image.extent
        let tolerance = min(0.5, max(0.02, settings.tolerance))
        let band = max(0.004, min(0.3, settings.softness))
        let spill = min(1, max(0, settings.spillSuppression))
        let shrink = min(3, max(0, settings.edgeShrinkPixels))
        let feather = min(4, max(0, settings.edgeFeatherPixels))

        let field = backgroundFieldImage(for: settings, in: extent)
        let camChroma = chromaImage(image, in: extent)
        let fieldChroma = chromaImage(field, in: extent)
        // 逐像素色度差 → 平方 → 归一化距离平方 D² = 4(dCb²+dCr²)。
        let diff = blend(
            "CIDifferenceBlendMode",
            camChroma,
            fieldChroma
        ).cropped(to: extent)
        let diffSquared = blend("CIMultiplyBlendMode", diff, diff)
            .cropped(to: extent)
        let distanceSquared = matrix(
            diffSquared,
            rVector: (4, 4, 0, 0),
            gVector: (0, 0, 0, 0),
            bVector: (0, 0, 0, 0)
        )

        // 键出量渐变带（保留量的补集）：D ≤ tolerance → 1（全键出），
        // D ≥ tolerance+band → 0（全保留），中间线性过渡。把偏移一起折进
        // CIColorMatrix 后钳制到 0...1（输入 alpha=1）。
        let core = tolerance * tolerance
        let outer = (tolerance + band) * (tolerance + band)
        let rampScale = 1 / (outer - core)
        let keyedRamp = clamp01(
            matrix(
                distanceSquared,
                rVector: (-rampScale, -rampScale, 0, 1 + core * rampScale),
                gVector: (0, 0, 0, 0),
                bVector: (0, 0, 0, 0)
            )
        )

        // 亮度只作键出量的权重：近黑（传感器噪声）不参与键控，避免暗部
        // 闪点。必须乘在键出量上而不是保留量上——色度远离幕布的暗前景
        // （黑发、深色衣物）键出量为 0，要完整保留；若乘在保留量上，暗
        // 前景会按亮度被打折成半透明，合成时把背后的亮画面透上来，黑发
        // 直接变白（用户反馈的抠像把人物也影响了）。
        // 绿幕优化把硬门从 y<0.03 放宽到 y<0.005：旧门会把 y≈0.04 的
        // 阴影黑发 / 黑衣打穿（发片 alpha 仅 0.13）；绝对色度距离下暗部
        // 噪声本就低于容差，无需重门禁。
        let luminance = matrix(
            image,
            rVector: (0.299, 0.587, 0.114, 0),
            gVector: (0, 0, 0, 0),
            bVector: (0, 0, 0, 0)
        )
        let luminanceWeight = clamp01(
            matrix(
                luminance,
                rVector: (1 / 0.015, 0, 0, -0.005 / 0.015),
                gVector: (0, 0, 0, 0),
                bVector: (0, 0, 0, 0)
            )
        )
        let keyed = blend("CIMultiplyBlendMode", keyedRamp, luminanceWeight)
            .cropped(to: extent)
        // alpha = 1 − 键出量。
        var alpha = blend("CIDifferenceBlendMode", white(in: extent), keyed)
            .cropped(to: extent)

        // 哑光内收（形态学腐蚀 1-2px 去绿边）+ 小半径高斯柔化。
        // 注（实测）：腐蚀是现行 despill 设计控溢色环的主力
        // （shrink=0 时溢色环 19→122），且细于结构元的发丝（≤3px）
        // 腐蚀后信息已毁、后处理无法恢复——发丝保留属结构性课题
        // （形态学重构 / matting 模型），留待后续优化，不做假修复。
        if shrink > 0.05 {
            alpha = alpha.applyingFilter(
                "CIMorphologyMinimum",
                parameters: ["inputRadius": shrink]
            ).cropped(to: extent)
        }
        if feather > 0.05 {
            alpha = alpha.applyingFilter(
                "CIGaussianBlur",
                parameters: ["inputRadius": feather]
            ).cropped(to: extent)
        }
        alpha = clamp01(alpha)
        let mask = matrix(
            alpha,
            rVector: (1, 0, 0, 0),
            gVector: (1, 0, 0, 0),
            bVector: (1, 0, 0, 0)
        )

        // 边缘去溢色：作用区 = 半透明带（1−alpha）+ 哑光边缘内侧约 2px
        // 的环（alpha − 腐蚀(alpha)）——真实传感器的绿溢色集中在贴边
        // 1-2px，即使 alpha 已到 1 也要拉回前景估计，绝不全图 desaturate。
        // 溢色量用均值型估计 g − (r+b)/2（纯 CIColorMatrix，无需混合
        // 原语——本机实测 CIMaximum/Minimum BlendMode 返回错误结果，
        // 见历史实测记录）。
        var keyedOutput = image
        if spill > 0.001 {
            let inverseAlpha = blend("CIDifferenceBlendMode", white(in: extent), mask)
            let translucentTerm = matrix(
                inverseAlpha,
                rVector: (0, 0, 0, 0),
                gVector: (0, spill, 0, 0),
                bVector: (0, 0, 0, 0)
            )
            let eroded = alpha.applyingFilter(
                "CIMorphologyMinimum",
                parameters: ["inputRadius": min(shrink + 1.5, 3)]
            ).cropped(to: extent)
            // CISubtractBlendMode = background − input（实测确认）：
            // input 传腐蚀后的哑光、background 传原 alpha → alpha−eroded。
            let ringRaw = blend("CISubtractBlendMode", eroded, alpha)
                .cropped(to: extent)
            // 哑光环内拉满强度（像素以前景为主，直接拉回前景估计）；
            // 半透明带按 spill 强度。
            let ringTerm = clamp01(
                matrix(
                    ringRaw,
                    rVector: (0, 0, 0, 0),
                    gVector: (0, 1, 0, 0),
                    bVector: (0, 0, 0, 0)
                )
            )
            // 两个带权项相加（plus 会把 alpha 累加到 2，合成回不透明黑
            // 恢复 alpha=1，颜色分量不变——本机实测确认）。
            let spillZoneRaw = blend("CIAdditionCompositing", translucentTerm, ringTerm)
            let spillZone = spillZoneRaw
                .composited(
                    over: CIImage(
                        color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                    ).cropped(to: extent)
                )
                .cropped(to: extent)
            // 溢色量用均值型估计 g − (r+b)/2（纯 CIColorMatrix，无需
            // 混合原语——本机实测 CIMaximum/Minimum BlendMode 返回
            // 错误结果，见历史实测记录）。绿幕优化曾 A/B double-red
            // average g−(2r+b)/3（肤色保护说）：合成肤色溢色环上
            // 0.3032 vs 0.3056，double-red 反略差，按门禁否决切换，
            // 维持均值型；证据见 ChromaKeyQualityTests 的
            // testDespillAlgorithmABOnSkinEdges。
            let excessGreen = clamp01(
                matrix(
                    image,
                    rVector: (0, 0, 0, 0),
                    gVector: (-0.5, 1, -0.5, 0),
                    bVector: (0, 0, 0, 0)
                )
            )
            let weightedExcess = blend("CIMultiplyBlendMode", excessGreen, spillZone)
                .cropped(to: extent)
            // CISubtractBlendMode 结果 = background − input（实测确认），
            // 因此 input 传溢色量、background 传原图，得 image − 溢色。
            keyedOutput = blend("CISubtractBlendMode", weightedExcess, image)
                .cropped(to: extent)
            keyedOutput = matrix(
                keyedOutput,
                rVector: (1, 0, 0, 0),
                gVector: (0, 1, 0, 0),
                bVector: (0, 0, 1, 0)
            )
        }

        let composited = keyedOutput.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ]
        ).cropped(to: extent)
        return (composited, mask)
    }

    /// 背景色场图：有估计色场时上采样到画面尺寸（网格内插 + 估计期重
    /// 模糊已保证平滑），否则退回单点均匀色场（手动取色 / 旧工程）。
    private static func backgroundFieldImage(
        for settings: CameraChromaKeySettings,
        in extent: CGRect
    ) -> CIImage {
        if let data = settings.backgroundFieldData {
            let key = "\(data)|\(Int(extent.width))x\(Int(extent.height))" as NSString
            if let cached = fieldCache.object(forKey: key) {
                return cached
            }
            if let image = ChromaKeyField(data: data)?.ciImage(in: extent) {
                fieldCache.setObject(image, forKey: key)
                return image
            }
        }
        let key = RGB(hex: settings.keyColorHex) ?? RGB(
            red: 0,
            green: 0.69,
            blue: 0.25
        )
        let color = CIColor(
            red: key.red,
            green: key.green,
            blue: key.blue,
            alpha: 1
        )
        return CIImage(color: color).cropped(to: extent)
    }

    /// (cb + 0.5, cr + 0.5, 0.5) 色度图：整体 +0.5 抬进 0...1（差分时
    /// 抵消），避免负分量参与混合。CIAdditionCompositing 是 Porter-Duff
    /// plus，alpha 会累加到 2；合成到不透明黑上可恢复 alpha=1
    /// （αo = αs + αb(1−αs) = 1）且颜色分量不变（本机实测确认）。
    private static func chromaImage(
        _ image: CIImage,
        in extent: CGRect
    ) -> CIImage {
        let chroma = matrix(
            image,
            rVector: (-0.168_935, -0.331_655, 0.500_59, 0),
            gVector: (0.499_813, -0.418_531, -0.081_282, 0),
            bVector: (0, 0, 0, 0)
        )
        let half = CIImage(
            color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ).cropped(to: extent)
        let shifted = blend("CIAdditionCompositing", chroma, half)
        return shifted
            .composited(
                over: CIImage(
                    color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                ).cropped(to: extent)
            )
            .cropped(to: extent)
    }

    private static func white(in extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: extent)
    }

    private static func blend(
        _ name: String,
        _ input: CIImage,
        _ background: CIImage
    ) -> CIImage {
        input.applyingFilter(
            name,
            parameters: [kCIInputBackgroundImageKey: background]
        )
    }

    /// CIColorMatrix：r/g/b/a 四个 4 元向量（分量乘 r,g,b,a）。
    private static func matrix(
        _ image: CIImage,
        rVector: (Double, Double, Double, Double),
        gVector: (Double, Double, Double, Double),
        bVector: (Double, Double, Double, Double),
        aVector: (Double, Double, Double, Double) = (0, 0, 0, 1)
    ) -> CIImage {
        image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(
                    x: rVector.0,
                    y: rVector.1,
                    z: rVector.2,
                    w: rVector.3
                ),
                "inputGVector": CIVector(
                    x: gVector.0,
                    y: gVector.1,
                    z: gVector.2,
                    w: gVector.3
                ),
                "inputBVector": CIVector(
                    x: bVector.0,
                    y: bVector.1,
                    z: bVector.2,
                    w: bVector.3
                ),
                "inputAVector": CIVector(
                    x: aVector.0,
                    y: aVector.1,
                    z: aVector.2,
                    w: aVector.3
                )
            ]
        )
    }

    private static func clamp01(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorClamp", parameters: [:])
    }

    // MARK: - 现行版（1.3）LUT 路径：保留作 A/B 对照测试

    static func applyLegacyCube(
        _ image: CIImage,
        settings: CameraChromaKeySettings
    ) -> CIImage {
        guard settings.enabled else { return image }
        return image.applyingFilter(
            "CIColorCube",
            parameters: [
                "inputCubeDimension": cubeDimension,
                "inputCubeData": cubeData(for: settings)
            ]
        )
    }

    /// Samples the dominant green from the outer band of a frame. The center
    /// is intentionally ignored so a presenter cannot become the key color.
    static func sampleKeyColor(from image: CGImage) -> String? {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        let border = max(4, width / 6)
        var candidates: [RGB] = []
        candidates.reserveCapacity(width * height / 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                guard
                    x < border
                        || x >= width - border
                        || y < border
                        || y >= height - border
                else {
                    continue
                }
                let offset = (y * width + x) * 4
                let red = Double(pixels[offset]) / 255
                let green = Double(pixels[offset + 1]) / 255
                let blue = Double(pixels[offset + 2]) / 255
                let hsv = hsv(RGB(red: red, green: green, blue: blue))
                guard
                    hsv.saturation > 0.18,
                    hsv.value > 0.08,
                    green > red + 0.06,
                    green > blue + 0.06
                else {
                    continue
                }
                candidates.append(
                    RGB(red: red, green: green, blue: blue)
                )
            }
        }
        guard candidates.count >= 8 else { return nil }
        let sample = RGB(
            red: median(candidates.map(\.red)),
            green: median(candidates.map(\.green)),
            blue: median(candidates.map(\.blue))
        )
        return sample.hexString
    }

    private static func cubeData(
        for settings: CameraChromaKeySettings
    ) -> Data {
        let key = cacheKey(settings)
        if let cached = cubeCache.object(forKey: key as NSString) {
            return cached as Data
        }
        let data = makeCubeData(settings)
        cubeCache.setObject(data as NSData, forKey: key as NSString)
        return data
    }

    private static func cacheKey(
        _ settings: CameraChromaKeySettings
    ) -> String {
        let tolerance = Int((settings.tolerance * 1000).rounded())
        let softness = Int((settings.softness * 1000).rounded())
        let spill = Int((settings.spillSuppression * 1000).rounded())
        return "\(settings.keyColorHex)-\(tolerance)-\(softness)-\(spill)"
    }

    private static func makeCubeData(
        _ settings: CameraChromaKeySettings
    ) -> Data {
        let key = RGB(hex: settings.keyColorHex) ?? RGB(
            red: 0,
            green: 0.69,
            blue: 0.25
        )
        let keyHSV = hsv(key)
        let tolerance = min(0.5, max(0.01, settings.tolerance))
        let softness = min(0.3, max(0.001, settings.softness))
        let spill = min(1, max(0, settings.spillSuppression))
        let dimension = cubeDimension
        var values = [Float](
            repeating: 0,
            count: dimension * dimension * dimension * 4
        )
        var index = 0
        for blueIndex in 0 ..< dimension {
            for greenIndex in 0 ..< dimension {
                for redIndex in 0 ..< dimension {
                    let red = Double(redIndex) / Double(dimension - 1)
                    let green = Double(greenIndex) / Double(dimension - 1)
                    let blue = Double(blueIndex) / Double(dimension - 1)
                    let source = RGB(red: red, green: green, blue: blue)
                    let pixelHSV = hsv(source)
                    let hueDistance = circularDistance(
                        pixelHSV.hue,
                        keyHSV.hue
                    )
                    let saturationWeight = smoothstep(
                        0.06,
                        0.22,
                        pixelHSV.saturation
                    )
                    let keyWeight = (
                        1 - smoothstep(
                            tolerance,
                            tolerance + softness,
                            hueDistance
                        )
                    ) * saturationWeight
                    let alpha = 1 - keyWeight
                    let spillWeight = (
                        1 - smoothstep(
                            tolerance,
                            min(
                                0.5,
                                tolerance + softness + 0.12
                            ),
                            hueDistance
                        )
                    ) * saturationWeight * spill
                    var correctedGreen = green
                    let ceiling = max(red, blue)
                    if correctedGreen > ceiling {
                        correctedGreen += (
                            ceiling - correctedGreen
                        ) * spillWeight
                    }
                    values[index] = Float(red * alpha)
                    values[index + 1] = Float(correctedGreen * alpha)
                    values[index + 2] = Float(blue * alpha)
                    values[index + 3] = Float(alpha)
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private static func circularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }

    private static func smoothstep(
        _ edge0: Double,
        _ edge1: Double,
        _ value: Double
    ) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let normalized = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return normalized * normalized * (3 - 2 * normalized)
    }

    private static func hsv(_ color: RGB) -> HSV {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        let saturation = maximum > 0.000_001 ? delta / maximum : 0
        var hue = 0.0
        if delta > 0.000_001 {
            if maximum == color.red {
                hue = ((color.green - color.blue) / delta)
                    .truncatingRemainder(dividingBy: 6)
                hue /= 6
            } else if maximum == color.green {
                hue = ((color.blue - color.red) / delta + 2) / 6
            } else {
                hue = ((color.red - color.green) / delta + 4) / 6
            }
            if hue < 0 { hue += 1 }
        }
        return HSV(hue: hue, saturation: saturation, value: maximum)
    }
}

/// C2 低分辨率背景色场：12×7 网格 RGB（自上而下、自左而右），base64
/// 存储（每格 3 字节，共 252 字节 → 336 字符）。
struct ChromaKeyField {
    static let columns = 12
    static let rows = 7

    /// 行主序（row 0 = 画面顶部），rows×columns 个 RGB。
    let cells: [ChromaRGB]

    init?(data: String) {
        guard
            let bytes = Data(base64Encoded: data),
            bytes.count == Self.rows * Self.columns * 3
        else {
            return nil
        }
        var parsed: [ChromaRGB] = []
        parsed.reserveCapacity(Self.rows * Self.columns)
        for index in 0 ..< (Self.rows * Self.columns) {
            parsed.append(
                ChromaRGB(
                    red: Double(bytes[index * 3]) / 255,
                    green: Double(bytes[index * 3 + 1]) / 255,
                    blue: Double(bytes[index * 3 + 2]) / 255
                )
            )
        }
        cells = parsed
    }

    init(cells: [ChromaRGB]) {
        self.cells = cells
    }

    var data: String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(cells.count * 3)
        for cell in cells {
            bytes.append(UInt8((cell.red * 255).rounded()))
            bytes.append(UInt8((cell.green * 255).rounded()))
            bytes.append(UInt8((cell.blue * 255).rounded()))
        }
        return Data(bytes).base64EncodedString()
    }

    /// 色场预览小图（加深队列）：把网格渲染成固定宽度的 CGImage，让
    /// 用户看得见机器估的背景对不对。逐格近似放大 + 顶行在顶部。
    func previewCGImage(width: CGFloat = 90) -> CGImage? {
        guard cells.count == Self.rows * Self.columns else { return nil }
        var bytes = [UInt8](repeating: 255, count: cells.count * 4)
        for (index, cell) in cells.enumerated() {
            bytes[index * 4] = UInt8((cell.red * 255).rounded())
            bytes[index * 4 + 1] = UInt8((cell.green * 255).rounded())
            bytes[index * 4 + 2] = UInt8((cell.blue * 255).rounded())
            bytes[index * 4 + 3] = 255
        }
        let cellSize = max(1, Int(width / CGFloat(Self.columns)))
        let scaledWidth = cellSize * Self.columns
        let scaledHeight = cellSize * Self.rows
        var scaled = [UInt8](
            repeating: 0,
            count: scaledWidth * scaledHeight * 4
        )
        for y in 0 ..< scaledHeight {
            let gridRow = min(Self.rows - 1, y / cellSize)
            for x in 0 ..< scaledWidth {
                let gridColumn = min(Self.columns - 1, x / cellSize)
                let source = (gridRow * Self.columns + gridColumn) * 4
                let target = (y * scaledWidth + x) * 4
                scaled[target] = bytes[source]
                scaled[target + 1] = bytes[source + 1]
                scaled[target + 2] = bytes[source + 2]
                scaled[target + 3] = 255
            }
        }
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return scaled.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: scaledWidth,
                    height: scaledHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: scaledWidth * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            return context.makeImage()
        }
    }

    /// 网格 → CIImage：双线性上采样到目标尺寸（网格在估计期已重模糊，
    /// 上采样后即平滑色场）。
    func ciImage(in extent: CGRect) -> CIImage? {
        guard cells.count == Self.rows * Self.columns else { return nil }
        var bytes = [UInt8](repeating: 255, count: cells.count * 4)
        for (index, cell) in cells.enumerated() {
            bytes[index * 4] = UInt8((cell.red * 255).rounded())
            bytes[index * 4 + 1] = UInt8((cell.green * 255).rounded())
            bytes[index * 4 + 2] = UInt8((cell.blue * 255).rounded())
            bytes[index * 4 + 3] = 255
        }
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &bytes,
                width: Self.columns,
                height: Self.rows,
                bitsPerComponent: 8,
                bytesPerRow: Self.columns * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let cgImage = context.makeImage()
        else {
            return nil
        }
        return CIImage(cgImage: cgImage)
            .transformed(
                by: CGAffineTransform(
                    scaleX: extent.width / CGFloat(Self.columns),
                    y: extent.height / CGFloat(Self.rows)
                )
            )
            .cropped(to: extent)
    }
}

struct ChromaRGB {
    let red: Double
    let green: Double
    let blue: Double
}

private struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    init?(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard
            cleaned.count == 6,
            let value = UInt32(cleaned, radix: 16)
        else {
            return nil
        }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    var hexString: String {
        let redValue = Int((red * 255).rounded())
        let greenValue = Int((green * 255).rounded())
        let blueValue = Int((blue * 255).rounded())
        return String(
            format: "#%02X%02X%02X",
            redValue,
            greenValue,
            blueValue
        )
    }
}

private struct HSV {
    let hue: Double
    let saturation: Double
    let value: Double
}
