import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// `ReaderImageInversionTests` 与 `ReaderImageInversionServiceTests` 共用的位图 fixture。
///
/// 所有线稿 fixture 都按整数坐标绘制（无抗锯齿），因此像素统计是确定的：
/// 透明底/白底 + 纯黑线稿、连续调照片（灰阶噪声、高饱和渐变）。
enum ReaderImageInversionFixtures {
    /// 透明底 + 黑描边/黑字块：规则 A 的形态（正文公式图最常见）。
    static func transparentLineArtPNG(width: Int = 64, height: Int = 40) throws -> Data {
        try png(width: width, height: height) { context in
            drawLineArt(in: context, width: width, height: height, opaqueBackground: false)
        }
    }

    /// 白底 + 细黑线 + 黑字块：规则 B 的形态。
    static func whiteLineArtPNG(width: Int = 64, height: Int = 40) throws -> Data {
        try png(width: width, height: height) { context in
            drawLineArt(in: context, width: width, height: height, opaqueBackground: true)
        }
    }

    /// 不透明高饱和双轴渐变：照片类，任何规则都不得命中。
    static func gradientPNG(width: Int = 64, height: Int = 64) throws -> Data {
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),
                CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
            ] as CFArray,
            locations: [0, 1]
        ))
        return try png(width: width, height: height) { context in
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: Double(width), y: Double(height)),
                options: []
            )
        }
    }

    /// 不透明灰阶连续调噪声（0.2–0.8）：没有极端值，规则 B 的 `extremeRatio` 必须挡住它。
    static func grayscaleNoisePNG(width: Int = 64, height: Int = 64) throws -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return try png(width: width, height: height) { context in
            for y in 0..<height {
                for x in 0..<width {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let value = 0.2 + 0.6 * Double((state >> 33) % 1000) / 1000
                    context.setFillColor(CGColor(gray: value, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    /// 全透明 PNG。
    static func transparentPNG(width: Int = 1, height: Int = 1) throws -> Data {
        try png(width: width, height: height) { _ in }
    }

    /// 透明底 + 浅色填充 + 细黑字线（彩色示意图：深色区域占比低，但黑字必须反相）。
    static func transparentInkDiagramPNG(width: Int = 64, height: Int = 40) throws -> Data {
        try png(width: width, height: height) { context in
            drawPaleFills(in: context, width: width, height: height)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1)
            // 边框留在画布内部：两侧都是底色，构成细笔画。
            context.stroke(CGRect(
                x: 8.5,
                y: 8.5,
                width: Double(width) - 17,
                height: Double(height) - 17
            ))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for row in 0..<3 {
                context.fill(CGRect(x: 14, y: CGFloat(12 + row * 12), width: 30, height: 1))
            }
        }
    }

    /// 透明底 + 浅色填充 + 成片暗块（照片抠图暗部的形态：墨色相连、不细）。
    static func transparentSolidDarkRegionPNG(width: Int = 64, height: Int = 40) throws -> Data {
        try png(width: width, height: height) { context in
            drawPaleFills(in: context, width: width, height: height)
            context.setFillColor(CGColor(gray: 0.02, alpha: 1))
            context.fill(CGRect(x: 18, y: 10, width: 25, height: 20))
        }
    }

    /// 浅色填充块：亮度高于 0.6，构成「底色」而不是墨色。
    private static func drawPaleFills(in context: CGContext, width: Int, height: Int) {
        let space = CGColorSpaceCreateDeviceRGB()
        let colors: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [
            (0.75, 0.85, 0.95),
            (0.95, 0.80, 0.85)
        ]
        for (index, color) in colors.enumerated() {
            context.setFillColor(CGColor(colorSpace: space, components: [color.red, color.green, color.blue, 1])!)
            context.fill(CGRect(
                x: 4,
                y: CGFloat(4 + index * 17),
                width: CGFloat(width) - 8,
                height: 15
            ))
        }
    }

    private static func drawLineArt(
        in context: CGContext,
        width: Int,
        height: Int,
        opaqueBackground: Bool
    ) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if opaqueBackground {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        }
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1)
        // 路径落在半像素上：1px 描边正好覆盖最外圈像素，无抗锯齿。
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for row in 0..<3 {
            context.fill(CGRect(
                x: 10,
                y: CGFloat(8 + row * 8),
                width: CGFloat(width) - 20,
                height: 3
            ))
        }
    }

    static func png(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
