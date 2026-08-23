import XCTest
import CryptoKit
@testable import PaperRssCore

final class ArticleMathRuntimeTests: XCTestCase {

    func testOfflineMathJaxBundleFilesAndChecksums() throws {
        let fileManager = FileManager.default
        let localDir = URL(fileURLWithPath: "PaperRss/Resources/MathJax")
        let scriptURL = localDir.appendingPathComponent("tex-mml-svg.js")
        let licenseURL = localDir.appendingPathComponent("LICENSE")

        XCTAssertTrue(fileManager.fileExists(atPath: scriptURL.path), "MathJax tex-mml-svg.js 离线文件必须存在于 Resources/MathJax 中")
        XCTAssertTrue(fileManager.fileExists(atPath: licenseURL.path), "MathJax LICENSE 文件必须存在于 Resources/MathJax 中")

        let scriptData = try Data(contentsOf: scriptURL)
        let scriptDigest = SHA256.hash(data: scriptData).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            scriptDigest,
            "01717984f5715d5ab5f3067e78b9f35a7554d9dfc6205106c39fb6a0285a1cb3",
            "MathJax 4.1.2 tex-mml-svg.js SHA-256 必须精确匹配官方包校验和"
        )

        let licenseData = try Data(contentsOf: licenseURL)
        let licenseDigest = SHA256.hash(data: licenseData).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            licenseDigest,
            "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
            "MathJax LICENSE SHA-256 必须精确匹配 Apache 2.0 许可证"
        )
    }

    func testMathDetectionAccuracyAndExclusions() {
        // 正向用例
        XCTAssertTrue(ArticleMathDetector.containsMath(in: "Einstein: \\(E = mc^2\\)"))
        XCTAssertTrue(ArticleMathDetector.containsMath(in: "Integral: \\[\\int_0^1 x^2 dx\\]"))
        XCTAssertTrue(ArticleMathDetector.containsMath(in: "Block: $$\\sum_{i=1}^n i$$"))
        XCTAssertTrue(ArticleMathDetector.containsMath(in: "MathML: <math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi></math>"))
        XCTAssertTrue(ArticleMathDetector.containsMath(in: "Inline with spacing: $x + y = z$"))

        // 反向用例（排除日常价格、邮箱、变量名等）
        XCTAssertFalse(ArticleMathDetector.containsMath(in: "The price is $100 or $200."))
        XCTAssertFalse(ArticleMathDetector.containsMath(in: "Contact me at user@example.com"))
        XCTAssertFalse(ArticleMathDetector.containsMath(in: "Plain sentence without any formula symbols."))
        XCTAssertFalse(ArticleMathDetector.containsMath(in: "The code uses $variable and $other in PHP."))
    }
}
