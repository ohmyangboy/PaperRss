import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// 深色纸面下正文插图的「深色线稿」判定。
///
/// 正文插图常是透明底或白底的黑色线稿（公式、图表、手绘标注）。深色主题下这类
/// 图片的黑色字形与深色纸面对比度接近 1:1，等同于不可读（issue #41）。本分析器
/// 只做判定、不做任何 IO；命中者由阅读器在深色纸面下反相显示
/// （`invert(1) hue-rotate(180deg)`，保留色相），照片与彩色插图保持原样。
///
/// 任何无法判定的情况（解码失败、格式未知、超限）一律返回 false：宁可保持现状，
/// 也不误伤照片。
public enum ReaderImageInversion {
    /// 缩略图分析尺寸：行内公式图只有约 30×22px，必须同样能命中。
    private static let thumbnailMaxPixelSize = 64
    /// 墨色阈值：相对亮度低于此值的像素视为黑字黑线。
    private static let inkLuminance = 0.15
    /// 四邻域里相对亮度高于此值的像素视为浅色底。
    private static let backgroundLuminance = 0.6
    /// 细笔画判定：墨色像素至少要有这么多个「底」邻居才算文字/线条。
    private static let thinInkBackgroundNeighbors = 2

    /// 判定该图片是否需要在深色纸面下反相。
    public static func shouldInvert(data: Data, contentType: String?) -> Bool {
        if isSVGDocument(data: data, contentType: contentType) {
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return shouldInvertSVG(text)
        }
        return shouldInvertRaster(data)
    }

    /// 装饰性小图（表情、头像）的 URL 特征，与 `imageEmojiScript` 的 `hasEmojiURL`
    /// 同一组 token：它们不参与反相分析，也不占用每篇的图片预算。
    static func isDecorativeURL(_ url: URL) -> Bool {
        let source = url.absoluteString.lowercased()
        return source.contains("/emoji/") || source.contains("twemoji") || source.contains("avatar")
    }

    // MARK: - SVG

    /// SVG 线稿判定（纯文本分析，不做光栅化：AppKit/ImageIO 无公开 SVG 解码）。
    static func shouldInvertSVG(_ text: String) -> Bool {
        // 内嵌位图的 SVG 可能是照片或复杂插图，反转会破坏内容。
        if text.range(of: "<image", options: .caseInsensitive) != nil { return false }
        return paintValues(in: text).contains { paintClass(of: $0) == .dark }
    }

    /// 收集 `fill` / `stroke` / `stop-color` 的漆色值（属性与 CSS 声明两种写法）。
    /// 未加引号的值只在括号内允许空白，保证 `rgb(0, 0, 0)` 完整、`#000 stroke=x` 不串值。
    private static func paintValues(in text: String) -> [String] {
        let pattern = "(?i)(?:fill|stroke|stop-color)\\s*(?:=|:)\\s*(?:\"([^\"]*)\"|'([^']*)'|((?:[^;\"'>\\s(]|\\([^)]*\\))+))"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            for group in 1...3 {
                if let valueRange = Range(match.range(at: group), in: text) {
                    return String(text[valueRange])
                }
            }
            return nil
        }
    }

    private enum PaintClass {
        case dark
        case light
        case ignored
    }

    /// 按 sRGB 相对亮度分类单个漆色值：`< 0.45` 深、`> 0.55` 浅，其余（含无法解析）
    /// 一律忽略。
    private static func paintClass(of raw: String) -> PaintClass {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return .ignored }
        // `<img>` 引用的独立 SVG 文档里没有可继承的 color，currentColor 解析为黑。
        if value == "currentcolor" { return .dark }
        if value == "black" { return .dark }
        if value == "white" { return .light }
        if value == "none" || value == "transparent" || value == "inherit" || value == "initial"
            || value == "unset" || value.hasPrefix("url(") {
            return .ignored
        }
        guard let components = colorComponents(of: value) else { return .ignored }
        let luminance = relativeLuminance(red: components.red, green: components.green, blue: components.blue)
        if luminance < 0.45 { return .dark }
        if luminance > 0.55 { return .light }
        return .ignored
    }

    private static func colorComponents(of value: String) -> (red: Double, green: Double, blue: Double)? {
        if value.hasPrefix("#") { return hexComponents(of: value) }
        if value.hasPrefix("rgb") { return functionalComponents(of: value) }
        return nil
    }

    private static func hexComponents(of value: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = Array(value.dropFirst())
        func component(_ slice: ArraySlice<Character>) -> Double? {
            guard let number = Int(String(slice), radix: 16) else { return nil }
            return Double(number) / Double((1 << (4 * slice.count)) - 1)
        }
        switch digits.count {
        case 3:
            guard let red = component(digits[0...0]), let green = component(digits[1...1]),
                  let blue = component(digits[2...2]) else { return nil }
            return (red, green, blue)
        case 6:
            guard let red = component(digits[0...1]), let green = component(digits[2...3]),
                  let blue = component(digits[4...5]) else { return nil }
            return (red, green, blue)
        default:
            return nil
        }
    }

    /// `rgb()` / `rgba()`：逗号或空白分隔，第四位为 alpha（0 视为未绘制，忽略）。
    private static func functionalComponents(of value: String) -> (red: Double, green: Double, blue: Double)? {
        guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else {
            return nil
        }
        let parts = value[value.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        if parts.count >= 4, parts[3] <= 0 { return nil }
        return (parts[0] / 255, parts[1] / 255, parts[2] / 255)
    }

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return clamped <= 0.03928 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    // MARK: - Raster

    /// 位图线稿判定：只统计缩略图像素，与图片原始尺寸无关。
    static func shouldInvertRaster(_ data: Data) -> Bool {
        #if canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let statistics = statistics(of: image) else { return false }
        return shouldInvert(statistics: statistics)
        #else
        return false
        #endif
    }

    struct Statistics: Equatable {
        var transparentRatio: Double
        var darkRatio: Double
        var lightRatio: Double
        var extremeRatio: Double
        var meanSaturation: Double
        /// 近黑像素（墨色）占可见像素的比例。
        var inkRatio: Double
        /// 墨色像素中「细笔画」的占比：至少两个四邻域是透明底或浅色底。
        var thinInkRatio: Double
    }

    /// 判定阈值即契约：规则 A 覆盖透明底线稿（正文公式最常见的形态），规则 B 覆盖
    /// 白底线稿，规则 C 覆盖「彩色填充 + 黑字黑线」的示意图（issue #41 补充：
    /// 这类图深色区域占比不足 0.35，但黑字黑线同样会淹没在深色纸面里）。
    /// 规则 B 的 `extremeRatio` 是灰阶连续调照片（无极端值）与线稿的分界；
    /// 规则 C 的 `thinInkRatio` 把照片抠图的成片暗部（墨色相连、不细）挡在外面。
    ///
    /// 规则 A 的已知代价：透明底 + 大片暗部的照片抠图也会被反相（外观问题，不影响可读性）。
    /// 实测（colah 技术长文 51 张插图）收紧它的调色板/中性暗部闸门会连带丢掉 14 张
    /// 真实示意图（彩色示意图的暗部同样成片、同样带渐变），故保持现状。
    private static func shouldInvert(statistics: Statistics) -> Bool {
        if statistics.transparentRatio >= 0.15 && statistics.darkRatio >= 0.35 { return true }
        if statistics.lightRatio >= 0.70 && statistics.meanSaturation <= 0.20
            && statistics.extremeRatio >= 0.90 && statistics.darkRatio >= 0.01 {
            return true
        }
        if statistics.transparentRatio >= 0.15 && statistics.inkRatio >= 0.04
            && statistics.thinInkRatio >= 0.5 {
            return true
        }
        return false
    }

    #if canImport(CoreGraphics)
    private static func statistics(of image: CGImage) -> Statistics? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            return nil
        }

        let total = width * height
        var transparent = 0
        var visible = 0
        var opaque = 0
        var dark = 0
        var light = 0
        var extreme = 0
        var ink = 0
        var thinInk = 0
        var saturationSum = 0.0
        // 两遍扫描：细笔画判定要读四邻域，先把 alpha 与亮度映射出来。
        var alphas = [Double](repeating: 0, count: total)
        var luminances = [Double](repeating: 0, count: total)
        for index in 0..<total {
            let offset = index * 4
            let alpha = Double(buffer[offset + 3]) / 255
            alphas[index] = alpha
            guard alpha >= 0.35 else { continue }
            // 预乘存储：先反预乘恢复真实颜色，再按 sRGB 相对亮度统计。
            let red = alpha > 0 ? min(1, Double(buffer[offset]) / 255 / alpha) : 0
            let green = alpha > 0 ? min(1, Double(buffer[offset + 1]) / 255 / alpha) : 0
            let blue = alpha > 0 ? min(1, Double(buffer[offset + 2]) / 255 / alpha) : 0
            luminances[index] = relativeLuminance(red: red, green: green, blue: blue)
        }
        for index in 0..<total {
            let offset = index * 4
            let alpha = alphas[index]
            if alpha < 0.35 {
                transparent += 1
                continue
            }
            visible += 1
            let red = alpha > 0 ? min(1, Double(buffer[offset]) / 255 / alpha) : 0
            let green = alpha > 0 ? min(1, Double(buffer[offset + 1]) / 255 / alpha) : 0
            let blue = alpha > 0 ? min(1, Double(buffer[offset + 2]) / 255 / alpha) : 0
            let luminance = luminances[index]
            if luminance < 0.45 { dark += 1 }
            if luminance < inkLuminance {
                ink += 1
                if backgroundNeighborCount(
                    at: index,
                    width: width,
                    height: height,
                    alphas: alphas,
                    luminances: luminances
                ) >= thinInkBackgroundNeighbors {
                    thinInk += 1
                }
            }
            guard alpha >= 0.9 else { continue }
            opaque += 1
            if luminance > 0.75 { light += 1 }
            if luminance < 0.2 || luminance > 0.85 { extreme += 1 }
            let maximum = max(red, green, blue)
            if maximum > 0 { saturationSum += (maximum - min(red, green, blue)) / maximum }
        }

        return Statistics(
            transparentRatio: Double(transparent) / Double(total),
            darkRatio: visible > 0 ? Double(dark) / Double(visible) : 0,
            lightRatio: opaque > 0 ? Double(light) / Double(opaque) : 0,
            extremeRatio: opaque > 0 ? Double(extreme) / Double(opaque) : 0,
            meanSaturation: opaque > 0 ? saturationSum / Double(opaque) : 0,
            inkRatio: visible > 0 ? Double(ink) / Double(visible) : 0,
            thinInkRatio: ink > 0 ? Double(thinInk) / Double(ink) : 0
        )
    }

    /// 四邻域里「透明底或浅色底」的数量：文字笔画与线条两侧都是底，照片的成片暗部不是。
    private static func backgroundNeighborCount(
        at index: Int,
        width: Int,
        height: Int,
        alphas: [Double],
        luminances: [Double]
    ) -> Int {
        let x = index % width
        let y = index / width
        var count = 0
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let neighborX = x + dx
            let neighborY = y + dy
            guard neighborX >= 0, neighborX < width, neighborY >= 0, neighborY < height else { continue }
            let neighbor = neighborY * width + neighborX
            if alphas[neighbor] < 0.35 || luminances[neighbor] > backgroundLuminance { count += 1 }
        }
        return count
    }
    #endif

    // MARK: - Dispatch

    /// 分派依据：`contentType` 声明，或正文前 1024 字节里出现 `<svg`。
    private static func isSVGDocument(data: Data, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("svg") { return true }
        let head = data.prefix(1024)
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return false
        }
        let trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        return trimmed.lowercased().contains("<svg")
    }
}
