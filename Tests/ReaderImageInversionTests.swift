import Foundation
import XCTest
@testable import PaperRssCore

final class ReaderImageInversionTests: XCTestCase {

    // MARK: - SVG 文本判定

    func testSVGDarkPaintNeedsInversion() {
        XCTAssertTrue(ReaderImageInversion.shouldInvertSVG(
            ##"<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0" stroke="currentColor"/></svg>"##
        ), "独立 SVG 文档里的 currentColor 解析为黑，深色纸面下不可读")
        XCTAssertTrue(ReaderImageInversion.shouldInvertSVG(##"<svg><rect fill="#000"/></svg>"##))
        XCTAssertTrue(ReaderImageInversion.shouldInvertSVG(##"<svg><text style="fill: rgb(0, 0, 0)">x</text></svg>"##))
        XCTAssertTrue(ReaderImageInversion.shouldInvertSVG(##"<svg><rect style="fill: black"/></svg>"##))
    }

    func testSVGLightOrNeutralPaintKeepsOriginal() {
        XCTAssertFalse(ReaderImageInversion.shouldInvertSVG(
            ##"<svg><rect fill="#ffffff"/><path stroke="#eeeeee" d="M0 0"/></svg>"##
        ))
        XCTAssertFalse(ReaderImageInversion.shouldInvertSVG(
            ##"<svg><path fill="none" stroke="url(#gradient)" d="M0 0"/><rect fill="transparent"/></svg>"##
        ))
        XCTAssertFalse(ReaderImageInversion.shouldInvertSVG(
            ##"<svg><rect fill="rgba(0, 0, 0, 0)"/><rect fill="#cccccc"/></svg>"##
        ), "全透明漆色与浅灰都不构成深色线稿")
        XCTAssertFalse(ReaderImageInversion.shouldInvertSVG(""))
    }

    func testSVGDarknessThresholdFollowsRelativeLuminance() {
        // sRGB 相对亮度 0.45 对应 sRGB 灰度约 0.70：更深的灰在深色纸面上同样不可读。
        XCTAssertTrue(ReaderImageInversion.shouldInvertSVG(##"<svg><rect fill="#808080"/></svg>"##))
        XCTAssertFalse(ReaderImageInversion.shouldInvertSVG(##"<svg><rect fill="#b3b3b3"/></svg>"##))
    }

    func testSVGWithEmbeddedRasterKeepsOriginal() {
        XCTAssertFalse(ReaderImageInversion.shouldInvertSVG(
            ##"<svg><image href="photo.png" width="10" height="10"/><path stroke="black" d="M0 0"/></svg>"##
        ), "内嵌位图的 SVG 可能是照片，反转会破坏内容")
    }

    func testDispatchRecognizesSVGByContentTypeAndBySniffing() {
        let markup = Data(##"<svg><rect fill="#000"/></svg>"##.utf8)
        XCTAssertTrue(ReaderImageInversion.shouldInvert(data: markup, contentType: "image/svg+xml"))
        XCTAssertTrue(ReaderImageInversion.shouldInvert(data: markup, contentType: nil), "无 content-type 时按前缀嗅探")
        XCTAssertTrue(ReaderImageInversion.shouldInvert(
            data: Data("\n  \u{FEFF}<svg><rect fill=\"black\"/></svg>".utf8),
            contentType: nil
        ), "嗅探必须跳过 BOM 与空白")
    }

    func testGarbageBytesKeepOriginal() {
        XCTAssertFalse(ReaderImageInversion.shouldInvert(data: Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]), contentType: nil))
        XCTAssertFalse(ReaderImageInversion.shouldInvert(data: Data(), contentType: nil))
    }

    // MARK: - 位图判定

    func testTransparentLineArtNeedsInversion() throws {
        let data = try ReaderImageInversionFixtures.transparentLineArtPNG()
        XCTAssertTrue(ReaderImageInversion.shouldInvertRaster(data))
        XCTAssertTrue(ReaderImageInversion.shouldInvert(data: data, contentType: "image/png"))
        XCTAssertTrue(ReaderImageInversion.shouldInvert(data: data, contentType: nil))
    }

    func testInlineFormulaSizedLineArtNeedsInversion() throws {
        // 行内公式图只有约 30×22px，判定必须与尺寸无关。
        let data = try ReaderImageInversionFixtures.transparentLineArtPNG(width: 30, height: 22)
        XCTAssertTrue(ReaderImageInversion.shouldInvertRaster(data))
    }

    func testWhiteLineArtNeedsInversion() throws {
        let data = try ReaderImageInversionFixtures.whiteLineArtPNG()
        XCTAssertTrue(ReaderImageInversion.shouldInvertRaster(data))
    }

    func testColoredDiagramWithBlackLabelsNeedsInversion() throws {
        // 彩色示意图：深色区域占比低于规则 A 的 0.35，但黑字黑线在深色纸面下同样不可读。
        let data = try ReaderImageInversionFixtures.transparentInkDiagramPNG()
        XCTAssertTrue(ReaderImageInversion.shouldInvertRaster(data))
    }

    func testSolidDarkRegionOnTransparentKeepsOriginal() throws {
        // 规则 C 的细笔画闸门：透明底上的成片暗块（照片抠图暗部的形态）不按线稿反相。
        let data = try ReaderImageInversionFixtures.transparentSolidDarkRegionPNG()
        XCTAssertFalse(ReaderImageInversion.shouldInvertRaster(data))
    }

    func testSaturatedGradientPhotoKeepsOriginal() throws {
        let data = try ReaderImageInversionFixtures.gradientPNG()
        XCTAssertFalse(ReaderImageInversion.shouldInvertRaster(data))
    }

    func testGrayscaleContinuousTonePhotoKeepsOriginal() throws {
        let data = try ReaderImageInversionFixtures.grayscaleNoisePNG()
        XCTAssertFalse(ReaderImageInversion.shouldInvertRaster(data))
    }

    func testFullyTransparentImageKeepsOriginal() throws {
        let data = try ReaderImageInversionFixtures.transparentPNG()
        XCTAssertFalse(ReaderImageInversion.shouldInvertRaster(data))
    }

    // MARK: - 装饰性 URL

    func testDecorativeURLsAreExcludedFromAnalysis() {
        for source in [
            "https://x.com/emoji/a.png",
            "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/1f600.png",
            "https://gravatar.com/avatar/abc",
            "https://cdn-static.example.com/ui/otter_avatar_placeholder_240511.png"
        ] {
            XCTAssertTrue(
                ReaderImageInversion.isDecorativeURL(URL(string: source)!),
                "\(source) 是装饰性小图，不参与反相分析"
            )
        }
        XCTAssertFalse(ReaderImageInversion.isDecorativeURL(
            URL(string: "https://mmbiz.qpic.cn/mmbiz_png/xyz")!
        ))
    }
}
