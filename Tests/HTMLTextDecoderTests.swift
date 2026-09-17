import XCTest
@testable import PaperRssCore

final class HTMLTextDecoderTests: XCTestCase {

    func testDecodesNumericEntities() {
        XCTAssertEqual(HTMLTextDecoder.decoded("a &#8212; b"), "a — b")
        XCTAssertEqual(HTMLTextDecoder.decoded("&#29233;&#20570;&#3903;"), "爱做༿")
        XCTAssertEqual(HTMLTextDecoder.decoded("hex &#x2014; end"), "hex — end")
        XCTAssertEqual(HTMLTextDecoder.decoded("emoji &#x1F600;"), "emoji 😀")
    }

    func testDecodesCommonNamedEntities() {
        XCTAssertEqual(HTMLTextDecoder.decoded("rock &amp; roll"), "rock & roll")
        XCTAssertEqual(HTMLTextDecoder.decoded("a &mdash; b &hellip;"), "a — b …")
        XCTAssertEqual(HTMLTextDecoder.decoded("x&nbsp;y"), "x y")
        XCTAssertEqual(HTMLTextDecoder.decoded("&laquo;quote&raquo;"), "«quote»")
        XCTAssertEqual(HTMLTextDecoder.decoded("it&rsquo;s"), "it’s")
    }

    func testDecodesDoubleEscapedEntities() {
        XCTAssertEqual(HTMLTextDecoder.decoded("&amp;#8212;"), "—")
        XCTAssertEqual(HTMLTextDecoder.decoded("&amp;mdash;"), "—")
        XCTAssertEqual(HTMLTextDecoder.decoded("&amp;amp;"), "&")
    }

    func testLeavesUnknownEntitiesAndPlainTextUntouched() {
        XCTAssertEqual(HTMLTextDecoder.decoded("&unknown; stays"), "&unknown; stays")
        XCTAssertEqual(HTMLTextDecoder.decoded("AT&T 与 100% 纯文本"), "AT&T 与 100% 纯文本")
        XCTAssertEqual(HTMLTextDecoder.decoded(""), "")
        XCTAssertEqual(HTMLTextDecoder.decoded("没有实体"), "没有实体")
    }

    func testDecodingIsIdempotent() {
        let once = HTMLTextDecoder.decoded("AI &#8212; &amp;amp; &#x4E50;")
        XCTAssertEqual(HTMLTextDecoder.decoded(once), once)
    }
}
