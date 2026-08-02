import XCTest
@testable import PaperRssCore

final class PaperRssCoreTests: XCTestCase {
    func testParsesRSSAndUsesGuid() throws {
        let data = Data("""
        <rss version="2.0"><channel><title>Example</title><link>https://example.com</link>
        <item><guid>item-1</guid><title>Hello</title><link>https://example.com/hello</link><description><![CDATA[<p>Short summary</p>]]></description><pubDate>Tue, 28 Jul 2026 10:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let feed = try FeedParser.parse(data: data, baseURL: URL(string: "https://example.com/feed.xml")!)
        XCTAssertEqual(feed.title, "Example")
        XCTAssertEqual(feed.entries.count, 1)
        XCTAssertEqual(feed.entries[0].id, "item-1")
        XCTAssertEqual(feed.entries[0].summary, "Short summary")
    }

    func testLibraryIndexSortsAndGroupsWithoutRepeatedQueries() throws {
        let technology = Feed(
            id: UUID(),
            title: "Technology",
            feedURL: URL(string: "https://example.com/technology.xml")!,
            folder: "Reading"
        )
        let news = Feed(
            id: UUID(),
            title: "News",
            feedURL: URL(string: "https://example.com/news.xml")!
        )
        let morning = Date(timeIntervalSince1970: 1_785_430_800)
        let evening = morning.addingTimeInterval(3_600)
        let entries = [
            Entry(id: "older", feedID: technology.id, title: "Older", publishedAt: morning, summary: "One", isRead: false),
            Entry(id: "newer", feedID: news.id, title: "Newer", publishedAt: evening, summary: "Two", isRead: true, isStarred: true)
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let index = EntryLibraryIndex(entries: entries, feeds: [technology, news], now: evening, calendar: calendar)

        XCTAssertEqual(index.all.map(\.id), ["newer", "older"])
        XCTAssertEqual(index.byFeed[technology.id]?.map(\.id), ["older"])
        XCTAssertEqual(index.byFolder["Reading"]?.map(\.id), ["older"])
        XCTAssertEqual(index.unreadByFeed[technology.id], 1)
        XCTAssertEqual(index.unreadByFolder["Reading"], 1)
        XCTAssertEqual(index.starred.map(\.id), ["newer"])
        XCTAssertEqual(index.byID["newer"]?.title, "Newer")
        XCTAssertEqual(index.listItemsByFeed[technology.id]?.first?.summaryPreview, "One")
        XCTAssertEqual(index.allListItems.first?.sourceTitle, "News")
    }

    func testEntryListItemDoesNotCarryFullArticleContent() {
        let feedID = UUID()
        let longSummary = String(repeating: "摘要", count: 4_000)
        let entry = Entry(
            id: "full-content",
            feedID: feedID,
            title: "Full article feed",
            summary: longSummary,
            contentHTML: String(repeating: "<p>正文</p>", count: 4_000)
        )

        let item = EntryListItem(entry: entry, sourceTitle: "Feed")

        XCTAssertEqual(item.summaryPreview.count, 240)
        XCTAssertFalse(Mirror(reflecting: item).children.contains { $0.label == "contentHTML" })
    }

    func testParsesAtomAndJSONFeed() throws {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title><entry><id>42</id><title>Entry</title><link href="https://example.com/entry"/><updated>2026-07-28T12:00:00Z</updated><content type="html"><![CDATA[<p>Body</p>]]></content></entry></feed>
        """.utf8)
        let atomFeed = try FeedParser.parse(data: atom, baseURL: URL(string: "https://example.com/feed")!)
        XCTAssertEqual(atomFeed.entries.first?.url?.absoluteString, "https://example.com/entry")
        XCTAssertEqual(atomFeed.entries.first?.contentHTML, "<p>Body</p>")

        let json = Data("""
        {"version":"https://jsonfeed.org/version/1.1","title":"JSON","items":[{"id":"a","url":"https://example.com/a","title":"A","content_text":"Text"}]}
        """.utf8)
        let jsonFeed = try FeedParser.parse(data: json, baseURL: URL(string: "https://example.com/feed")!)
        XCTAssertEqual(jsonFeed.title, "JSON")
        XCTAssertEqual(jsonFeed.entries.first?.summary, "Text")
    }

    func testOPMLRoundTripAndDeduplicatesURLs() {
        let feed = Feed(title: "Example", feedURL: URL(string: "https://example.com/rss")!)
        let data = OPMLService.export(feeds: [feed])
        let urls = OPMLService.importURLs(data: data)
        XCTAssertEqual(urls, [feed.feedURL])
    }

    func testSanitizerRemovesExecutableContent() {
        let html = "<article><h1>Title</h1><script>alert(1)</script><p>Hello <strong>world</strong>.</p><form>Bad</form></article>"
        let text = ArticleExtractor.mainText(from: html)
        XCTAssertEqual(text, "Title\n\nHello world.")
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("Bad"))
    }

    func testArticleImageExtractionKeepsRelativeAndSecureURLs() {
        let html = """
        <article><img src="/cover.jpg"><p>Enough text for an article.</p><img data-src="https://cdn.example.com/photo.png"><img src="javascript:alert(1)"></article>
        """
        let urls = ArticleExtractor.imageURLs(from: html, baseURL: URL(string: "https://example.com/posts/one")!)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/cover.jpg", "https://cdn.example.com/photo.png"])
    }

    func testHTMLReaderSanitizerPreservesDocumentOrderWithoutExecutableContent() {
        let html = """
        <article><h2>封面图</h2><img src="/cover.jpg" onerror="alert(1)"><p>图片说明。</p><script>alert(2)</script><a href="javascript:alert(3)">坏链接</a><p>后续正文。</p></article>
        """
        let output = ArticleExtractor.sanitizedHTML(html, baseURL: URL(string: "https://example.com/post")!)
        XCTAssertTrue(output.contains("<h2>封面图</h2><img src=\"https://example.com/cover.jpg\" loading=\"eager\" decoding=\"async\"><p>图片说明。</p>"))
        XCTAssertTrue(output.contains("<p>后续正文。</p>"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("script"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("onerror"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("javascript:"))
    }

    func testSanitizerEagerLoadsOnlyInitialImages() {
        let html = "<p>Lead</p><img src=\"https://example.com/one.jpg\"><img src=\"https://example.com/two.jpg\"><img src=\"https://example.com/three.jpg\">"
        let output = ArticleExtractor.sanitizedHTML(html)

        XCTAssertEqual(output.components(separatedBy: "loading=\"eager\"").count - 1, 2)
        XCTAssertEqual(output.components(separatedBy: "loading=\"lazy\"").count - 1, 1)
    }

    func testSanitizerNormalizesNestedAmpersandsInImageQueryItems() {
        let html = #"<article><p>Enough text for an image.</p><img src="https://pbs.twimg.com/media/HI7xPnWbgAAW4UO?format=webp&amp;amp;name=medium"></article>"#
        let output = ArticleExtractor.sanitizedHTML(html)

        XCTAssertTrue(output.contains("format=jpg&amp;name=medium"))
        XCTAssertFalse(output.contains("amp;amp"))
        XCTAssertEqual(
            ArticleExtractor.imageURLs(from: output, baseURL: nil).map(\.absoluteString),
            ["https://pbs.twimg.com/media/HI7xPnWbgAAW4UO?format=jpg&name=medium"]
        )
    }

    func testRSSHubTwitterFeedBodyStaysCompactAndKeepsTextOrder() {
        let html = """
        Going live today 👀<hr style="border:0"><div class="rsshub-quote">Nohe: @rodydavis @antigravity Heres the link!<br>https://www.youtube.com/watch?v=LcnBRo11mnk<br></div>
        """
        let content = ArticleExtractor.content(
            from: html,
            baseURL: URL(string: "https://x.com/antigravity/status/2082908715200675889")
        )

        XCTAssertEqual(content.text, "Going live today 👀 Nohe: @rodydavis @antigravity Heres the link!\nhttps://www.youtube.com/watch?v=LcnBRo11mnk")
        XCTAssertTrue(content.html.contains("Going live today 👀"))
        XCTAssertTrue(content.html.contains("youtube.com/watch?v=LcnBRo11mnk"))
        XCTAssertFalse(content.html.contains("style="))
        XCTAssertFalse(content.html.contains("rsshub-quote"))
    }

    func testLegacyArticleCacheRequiresOneTimeSanitization() throws {
        let data = Data("""
        {
          "entryID": "legacy",
          "text": "Body",
          "html": "<p>Body</p>",
          "imageURLs": [],
          "fetchedAt": 0
        }
        """.utf8)

        let cache = try JSONDecoder().decode(ArticleCache.self, from: data)

        XCTAssertFalse(cache.isSanitized)
    }

    func testChunkerPreservesParagraphOrder() {
        let text = "First paragraph.\n\nSecond paragraph."
        XCTAssertEqual(ArticleChunker.paragraphs(text), ["First paragraph.", "Second paragraph."])
    }

    func testTranslationSegmentsKeepParagraphBoundaries() {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        XCTAssertEqual(
            ArticleChunker.translationSegments(text),
            ["First paragraph.", "Second paragraph.", "Third paragraph."]
        )
    }

    func testBatchTranslationDecoderOnlyAcceptsOrderedJSON() throws {
        XCTAssertEqual(
            try LLMService.decodeBatchTranslations("[\"第一段\", \"第二段\"]"),
            ["第一段", "第二段"]
        )
        XCTAssertEqual(
            try LLMService.decodeBatchTranslations("```json\n{\"translations\":[\"A\",\"B\"]}\n```"),
            ["A", "B"]
        )
        XCTAssertThrowsError(try LLMService.decodeBatchTranslations("翻译：第一段；第二段"))
    }

    func testReaderParagraphsHaveStableDocumentOrderIDs() {
        let html = "<h2>Heading</h2><img src=\"https://example.com/photo.jpg\"><p>First paragraph.</p><p>Second paragraph.</p>"
        XCTAssertEqual(
            ArticleExtractor.readerParagraphs(in: html),
            [
                ReaderParagraph(id: "p0", original: "Heading"),
                ReaderParagraph(id: "p1", original: "First paragraph."),
                ReaderParagraph(id: "p2", original: "Second paragraph.")
            ]
        )
    }

    func testInlineTranslationsKeepOriginalHTMLAndSupportOutOfOrderViewportResults() {
        let html = "<p>First <a href=\"https://example.com\">paragraph</a>.</p><img src=\"https://example.com/photo.jpg\"><p>Second paragraph.</p>"
        let output = ArticleExtractor.insertingInlineTranslations(
            into: html,
            segments: [
                BilingualSegment(id: "p1", original: "Second paragraph.", translation: "第二段。")
            ],
            pendingIDs: ["p0"]
        )

        XCTAssertTrue(output.contains("<a href=\"https://example.com\">paragraph</a>"))
        XCTAssertTrue(output.contains("<img src=\"https://example.com/photo.jpg\">"))
        XCTAssertTrue(output.contains("data-paper-rss-id=\"p0\""))
        XCTAssertTrue(output.contains("data-paper-rss-id=\"p1\""))
        XCTAssertTrue(output.contains("id=\"paper-rss-translation-p0\""))
        XCTAssertTrue(output.contains("data-paper-rss-translation-for=\"p1\""))
        XCTAssertTrue(output.contains("正在翻译…"))
        XCTAssertTrue(output.contains("paper-rss-language-chip"))
        XCTAssertFalse(output.contains(">中文</span>"))
        XCTAssertLessThan(
            try! XCTUnwrap(output.range(of: "Second paragraph.")).lowerBound,
            try! XCTUnwrap(output.range(of: "第二段。")).lowerBound
        )
        XCTAssertFalse(output.contains("paperrss://translate-next"))
    }

    func testLegacyLLMConfigurationMigratesToProviderDefaults() throws {
        let data = Data("""
        {"baseURL":"https://example.com/v1","model":"local-model","temperature":0.4,"targetLanguage":"简体中文","allowInsecureLocalEndpoint":false}
        """.utf8)
        let configuration = try JSONDecoder().decode(LLMConfiguration.self, from: data)
        XCTAssertEqual(configuration.providerName, "OpenAI 兼容接口")
        XCTAssertEqual(configuration.providerDescription, "用于翻译、总结和解读文章")
        XCTAssertEqual(configuration.reasoningMode, "自动")
        XCTAssertEqual(configuration.model, "local-model")
        XCTAssertFalse(configuration.automaticallyGenerateSummary)
    }

    func testDeepSeekPresetUsesOfficialAPIHost() {
        let configuration = LLMConfiguration.deepSeek
        XCTAssertEqual(configuration.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(configuration.model, "deepseek-v4-flash")
        XCTAssertTrue(configuration.usesDeepSeekAPI)
        XCTAssertFalse(LLMConfiguration.default.usesDeepSeekAPI)
    }

    func testDeepSeekRequestMatchesOfficialOpenAICompatibleContract() throws {
        var configuration = LLMConfiguration.deepSeek
        configuration.reasoningMode = "高"
        let request = try LLMService().makeRequest(
            prompt: "Hello",
            system: "You are a helpful assistant.",
            configuration: configuration,
            apiKey: "test-key",
            stream: false
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(json["reasoning_effort"] as? String, "high")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"], "Hello")
    }

    func testTranslationRequestsDisableDeepSeekThinking() throws {
        var configuration = LLMConfiguration.deepSeek
        configuration.reasoningMode = "高"
        let request = try LLMService().makeRequest(
            prompt: "Translate this.",
            system: "You are a translator.",
            configuration: configuration,
            apiKey: "test-key",
            stream: false,
            forceDisableReasoning: true
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(json["reasoning_effort"])
    }

    func testSelectionExplanationRequestsDisableDeepSeekThinking() throws {
        var configuration = LLMConfiguration.deepSeek
        configuration.reasoningMode = "高"
        let request = try LLMService().makeRequest(
            prompt: "Explain this passage.",
            system: "You explain selected passages.",
            configuration: configuration,
            apiKey: "test-key",
            stream: true,
            forceDisableReasoning: true
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(json["reasoning_effort"])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testContextMemoSourceKeepsArticleShapeWithoutRepeatingWholeLongArticle() {
        let opening = String(repeating: "O", count: 9_000)
        let middle = String(repeating: "M", count: 50_000)
        let ending = String(repeating: "E", count: 9_000)
        let article = opening + middle + ending

        let context = ArticleChunker.contextualArticle(
            article,
            around: "",
            maximumCharacters: 30_000
        )

        XCTAssertTrue(context.contains("[Article opening]"))
        XCTAssertTrue(context.contains("[Selection neighborhood]"))
        XCTAssertTrue(context.contains("[Article ending]"))
        XCTAssertTrue(context.contains(String(repeating: "O", count: 100)))
        XCTAssertTrue(context.contains(String(repeating: "M", count: 100)))
        XCTAssertTrue(context.contains(String(repeating: "E", count: 100)))
        XCTAssertLessThan(context.count, article.count)
    }

    func testNewerArtifactTombstoneWinsCloudMerge() throws {
        let id = UUID()
        let entryID = "feed-entry"
        let remoteResult = AIArtifact(
            id: id,
            entryID: entryID,
            kind: .summary,
            contentHash: "hash",
            model: "model",
            targetLanguage: "简体中文",
            content: "旧摘要",
            isComplete: true,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let localTombstone = AIArtifact(
            id: id,
            entryID: entryID,
            kind: .summary,
            contentHash: "hash",
            model: "model",
            targetLanguage: "简体中文",
            isDeleted: true,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let merged = CloudLibrary.merged(
            local: CloudLibrary(feeds: [], readingStates: [:], artifacts: [localTombstone]),
            remote: CloudLibrary(feeds: [], readingStates: [:], artifacts: [remoteResult])
        )
        let artifact = try XCTUnwrap(merged.artifacts.first)
        XCTAssertTrue(artifact.isDeleted)
        XCTAssertTrue(artifact.content.isEmpty)
    }
}
