import XCTest
@testable import PaperRssCore

final class EntryPreviewImageTests: XCTestCase {
    private let base = URL(string: "https://publisher.example/posts/article.html")!

    func testPriorityAndCompletedNoImageAreExplicit() {
        let result = EntryPreviewImageExtractor.extract(
            explicit: [.init("/cover.jpg", source: "media")],
            descriptionHTML: "<img src='/description.jpg'>", contentHTML: "<img src='/body.jpg'>", baseURL: base)
        XCTAssertEqual(result.url?.absoluteString, "https://publisher.example/cover.jpg")
        XCTAssertEqual(result.source, "media")
        let empty = EntryPreviewImageExtractor.extract(contentHTML: "<p>Only text</p>", baseURL: base)
        XCTAssertNil(empty.url)
        XCTAssertNil(empty.source)
        XCTAssertEqual(empty.revision, EntryPreviewImage.currentRevision)
        XCTAssertFalse(empty.inputHash.isEmpty)
        XCTAssertEqual(empty, EntryPreviewImageExtractor.extract(contentHTML: "<p>Only text</p>", baseURL: base))
        XCTAssertNotEqual(empty.inputHash, result.inputHash)
    }

    func testFirstUsableDescriptionImageBeforeFullContent() {
        let result = EntryPreviewImageExtractor.extract(descriptionHTML: """
            <!-- <img src='/comment.jpg'> -->
            <script>const html = "<img src='/script.jpg'>";</script>
            <img src='/tracker.gif' width='1' height='1'>
            <img src='/smile.png' class='emoji'>
            <img src='/hidden.jpg' hidden>
            <img src='/avatar/photo.jpg'>
            <IMG data-original='../photo one.jpg?x=1&amp;y=2' src='data:image/gif;base64,AAAA'>
            <img src='/later.jpg'>
            """, contentHTML: "<img src='/body.jpg'>", baseURL: base)
        XCTAssertEqual(result.url?.absoluteString, "https://publisher.example/photo%20one.jpg?x=1&y=2")
        XCTAssertEqual(result.source, "description")
    }

    func testLazyImagesSrcsetAndProtocolRelativeURLs() {
        for attr in ["data-original", "data-src", "data-lazy-src", "data-actualsrc", "data-full-url", "data-url"] {
            let url = EntryPreviewImageExtractor.firstImage(in: "<img src='blank.gif' \(attr)='//cdn.example/image.jpg'>", baseURL: base)
            XCTAssertEqual(url?.absoluteString, "https://cdn.example/image.jpg", attr)
        }
        let result = EntryPreviewImageExtractor.firstImage(in: "<img srcset='/small.jpg 160w, /large.jpg 640w'>", baseURL: base)
        XCTAssertEqual(result?.path, "/large.jpg")
    }

    func testRejectUnsafeExplicitURLsAndUseContentFallback() {
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:image/png;base64,AA", "ftp://host/image", "https://user:password@example.com/image", "https:///", ""] {
            let result = EntryPreviewImageExtractor.extract(explicit: [.init(bad, source: "media")], contentHTML: "<img src='/safe.jpg'>", baseURL: base)
            XCTAssertEqual(result.url?.path, "/safe.jpg", bad)
            XCTAssertEqual(result.source, "content", bad)
        }
    }

    private func rss(_ body: String) throws -> ParsedFeedEntry {
        let xml = """
        <rss version="2.0" xmlns:m="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel><title>Feed</title><item><guid>one</guid><title>Article</title>
          <link>https://publisher.example/posts/article.html</link>\(body)</item></channel>
        </rss>
        """
        return try XCTUnwrap(FeedParser.parse(data: Data(xml.utf8), baseURL: base).entries.first)
    }

    func testRSSDescriptionImageSurvivesPlainTextSummaryAndEncodedBody() throws {
        let entry = try rss("""
        <description><![CDATA[Summary<img src='/description.jpg'>]]></description>
        <content:encoded><![CDATA[<p>Full body<img src='/body.jpg'></p>]]></content:encoded>
        """)
        XCTAssertEqual(entry.previewImage?.url?.path, "/description.jpg")
        XCTAssertEqual(entry.summary, "Summary")
        XCTAssertTrue(entry.contentHTML?.contains("/body.jpg") == true)
    }

    func testMediaNamespaceAliasDoesNotPolluteArticleBody() throws {
        let entry = try rss("""
        <m:content url="https://cdn.example/video.mp4" type="video/mp4">not the body</m:content>
        <m:thumbnail url="https://cdn.example/cover.jpg" width="640" height="400"/>
        <content:encoded><![CDATA[<p>Actual body</p>]]></content:encoded>
        """)
        XCTAssertEqual(entry.previewImage?.url?.absoluteString, "https://cdn.example/cover.jpg")
        XCTAssertEqual(entry.contentHTML, "<p>Actual body</p>")
        XCTAssertEqual(entry.title, "Article")
    }

    func testEnclosureMustBeAnImage() throws {
        let audio = try rss("<enclosure url='https://cdn.example/podcast.mp3' type='audio/mpeg'/><description><![CDATA[<img src='/fallback.jpg'>]]></description>")
        XCTAssertEqual(audio.previewImage?.url?.path, "/fallback.jpg")
        let image = try rss("<enclosure url='https://cdn.example/photo.png' type='image/png'/><description>Text</description>")
        XCTAssertEqual(image.previewImage?.source, "enclosure")
        XCTAssertEqual(image.previewImage?.url?.path, "/photo.png")
    }

    func testAtomEnclosureDoesNotReplaceAlternateLinkAndResolvesXMLBase() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://publisher.example/news/">
          <title>Feed</title><entry><id>one</id><title>Article</title>
          <link href="post.html" rel="alternate"/>
          <link href="../images/cover.png" rel="enclosure" type="image/png"/>
          <content type="html">&lt;p&gt;Body&lt;/p&gt;</content></entry></feed>
        """
        let entry = try XCTUnwrap(FeedParser.parse(data: Data(xml.utf8), baseURL: base).entries.first)
        XCTAssertEqual(entry.url?.absoluteString, "https://publisher.example/news/post.html")
        XCTAssertEqual(entry.previewImage?.url?.absoluteString, "https://publisher.example/images/cover.png")
        XCTAssertEqual(entry.contentHTML, "<p>Body</p>")
    }

    func testAtomXHTMLImageIsCapturedWithoutWebRequest() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>
        <entry><id>one</id><title>Article</title><summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
        <img src="https://cdn.example/xhtml.jpg"/><p>Summary</p></div></summary></entry></feed>
        """
        let entry = try XCTUnwrap(FeedParser.parse(data: Data(xml.utf8), baseURL: base).entries.first)
        XCTAssertEqual(entry.previewImage?.url?.path, "/xhtml.jpg")
    }

    func testJSONImageBannerAttachmentsAndHTMLFallback() throws {
        let variants: [(String, String)] = [
            (#""image":"https://cdn.example/image.jpg","banner_image":"https://cdn.example/banner.jpg","#,
             "/image.jpg"),
            (#""banner_image":"https://cdn.example/banner.jpg","#, "/banner.jpg"),
            (#""attachments":[{"url":"https://cdn.example/audio.mp3","mime_type":"audio/mpeg"},{"url":"https://cdn.example/attached.png","mime_type":"image/png"}],"#, "/attached.png"),
            ("", "/body.jpg")
        ]
        for (fields, path) in variants {
            let json = """
            {"version":"https://jsonfeed.org/version/1.1","title":"Feed","items":[{
              "id":"one","url":"https://publisher.example/post",\(fields)
              "content_html":"<img src='/body.jpg'>","summary":"<img src='/not-html.jpg'>"}]}
            """
            let entry = try XCTUnwrap(FeedParser.parse(data: Data(json.utf8), baseURL: base).entries.first)
            XCTAssertEqual(entry.previewImage?.url?.path, path)
        }
    }

    func testImagePreferencePreservesExistingListNetworking() {
        XCTAssertFalse(TimelineImagePreference.automatic.showsImages(in: .list))
        XCTAssertTrue(TimelineImagePreference.automatic.showsImages(in: .magazine))
        for style in TimelineViewStyle.allCases {
            XCTAssertFalse(TimelineImagePreference.disabled.showsImages(in: style))
            XCTAssertTrue(TimelineImagePreference.enabled.showsImages(in: style))
        }
        XCTAssertEqual(TimelineViewStyle.allCases.map(\.rawValue), ["list", "magazine", "cards"])
    }
}
