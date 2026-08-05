import XCTest
@testable import PaperRssCore

final class PaperRssCoreTests: XCTestCase {
        func testFeedRefreshIntervalOffersExpectedChoices() {
        XCTAssertEqual(FeedRefreshInterval.allCases.map(\.title), [
            "仅手动",
            "每 30 分钟",
            "每小时",
            "每 2 小时",
            "每 4 小时",
            "每 8 小时"
        ])
        XCTAssertNil(FeedRefreshInterval.manual.seconds)
        XCTAssertEqual(FeedRefreshInterval.twoHours.seconds, 7_200)
    }

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
        XCTAssertEqual(index.todayUnreadCount, 1)
        XCTAssertEqual(index.starred.map(\.id), ["newer"])
        XCTAssertEqual(index.byID["newer"]?.title, "Newer")
        XCTAssertEqual(index.listItemsByFeed[technology.id]?.first?.summaryPreview, "One")
        XCTAssertEqual(index.allListItems.first?.sourceTitle, "News")
    }

    func testLibraryIndexExcludesDeletedAndMissingFeedArticles() {
        let activeFeed = Feed(
            id: UUID(),
            title: "Active",
            feedURL: URL(string: "https://example.com/active.xml")!
        )
        let deletedFeed = Feed(
            id: UUID(),
            title: "Deleted",
            feedURL: URL(string: "https://example.com/deleted.xml")!,
            isDeleted: true
        )
        let entries = [
            Entry(id: "active-entry", feedID: activeFeed.id, title: "保留"),
            Entry(id: "deleted-entry", feedID: deletedFeed.id, title: "删除"),
            Entry(id: "missing-entry", feedID: UUID(), title: "孤儿")
        ]

        XCTAssertTrue(deletedFeed.isDeleted)

        let index = EntryLibraryIndex(entries: entries, feeds: [activeFeed, deletedFeed])

        XCTAssertEqual(index.all.map(\.id), ["active-entry"])
        XCTAssertNil(index.byID["deleted-entry"])
        XCTAssertNil(index.byID["missing-entry"])
        XCTAssertNil(index.listItemsByFeed[deletedFeed.id])
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

        // The leading status text is now a real paragraph boundary, so the
        // tweet body and the quoted tweet become independent translation units
        // instead of one undetectable blob.
        XCTAssertEqual(content.text, "Going live today 👀\n\nNohe: @rodydavis @antigravity Heres the link!\nhttps://www.youtube.com/watch?v=LcnBRo11mnk")
        XCTAssertTrue(content.html.contains("Going live today 👀"))
        XCTAssertTrue(content.html.contains("youtube.com/watch?v=LcnBRo11mnk"))
        XCTAssertFalse(content.html.contains("style="))
        XCTAssertFalse(content.html.contains("rsshub-quote"))
    }

    func testSanitizerWrapsTopLevelTweetTextIntoTranslatableParagraphs() {
        let html = """
        We are making our discount permanent! 🎉<br><br>Enjoy building with DeepSeek-V4-Pro!<br><img width="1632" height="900" src="https://pbs.twimg.com/media/HI7xPnWbgAAW4UO?format=jpg&amp;name=orig"><hr><div>DeepSeek: The V4-Pro discount has been extended!<br><img width="1912" height="1012" src="https://pbs.twimg.com/media/HGwt-7VasAAPM7i?format=jpg&amp;name=orig"></div>
        """
        let sanitized = ArticleExtractor.sanitizedHTML(
            html,
            baseURL: URL(string: "https://x.com/deepseek_ai/status/2049312932014813344")!
        )

        // Both the tweet text and the quoted-tweet div are now observable
        // blocks, so the viewport observer can request each one for
        // translation and the first paragraph is no longer skipped.
        XCTAssertEqual(
            // RSSHub inserts an en-space after some labels; normalize it so the
            // assertion is readable while the paragraph boundaries stay exact.
            ArticleExtractor.readerParagraphs(in: sanitized).map(\.original).map { $0.replacingOccurrences(of: "\u{2002}", with: " ") },
            [
                "We are making our discount permanent! 🎉\n\nEnjoy building with DeepSeek-V4-Pro!",
                "DeepSeek: The V4-Pro discount has been extended!"
            ]
        )
        XCTAssertEqual(
            ArticleExtractor.readerParagraphs(in: sanitized).map(\.id),
            ["p0", "p1"]
        )
    }

    func testSanitizerKeepsStandaloneImagesOutsideParagraphs() {
        let html = "<h2>封面图</h2><img src=\"https://example.com/cover.jpg\"><p>图片说明。</p>"
        let sanitized = ArticleExtractor.sanitizedHTML(html)
        XCTAssertTrue(sanitized.contains("<h2>封面图</h2><img src=\"https://example.com/cover.jpg\" loading=\"eager\" decoding=\"async\"><p>图片说明。</p>"))
        XCTAssertFalse(sanitized.contains("<p><img"))
    }

    func testFeedUsesStoredIconForEveryFeedAndFaviconOtherwise() {
        let avatar = URL(string: "https://pbs.twimg.com/profile_images/1717417613775757312/Uk1zNOj4.jpg")
        let twitter = Feed(
            title: "Twitter @DeepSeek",
            feedURL: URL(string: "http://127.0.0.1:1200/twitter/user/deepseek_ai")!,
            storedIconURL: avatar
        )
        XCTAssertEqual(twitter.iconURL, avatar)

        let plain = Feed(
            title: "Site",
            feedURL: URL(string: "https://example.com/rss.xml")!,
            storedIconURL: URL(string: "https://example.com/logo.png")
        )
        XCTAssertEqual(plain.iconURL?.absoluteString, "https://example.com/logo.png")
    }

    func testRSSInfersSiteOriginFromFirstEntryWhenChannelHasNoHomepage() throws {
        let data = Data("""
        <rss version="2.0"><channel><title>Example</title>
        <item><guid>item-1</guid><title>Hello</title><link>https://example.com/blog/hello</link></item>
        </channel></rss>
        """.utf8)

        let feed = try FeedParser.parse(data: data, baseURL: URL(string: "https://feeds.example.net/example.xml")!)

        XCTAssertEqual(feed.siteURL?.absoluteString, "https://example.com")
    }

    func testFeedDecodesLegacyJSONWithoutIconField() throws {
        let data = Data("""
        {"id":"5C0B1B6A-8E6E-4F13-9D1B-3B7F4D2E1A00","title":"Legacy","feedURL":"https://example.com/rss.xml","isDeleted":false}
        """.utf8)
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        XCTAssertEqual(feed.title, "Legacy")
        XCTAssertNil(feed.storedIconURL)
        XCTAssertEqual(feed.iconURL?.absoluteString, "https://www.google.com/s2/favicons?domain=example.com&sz=64")
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

    /// Proves the SSE path delivers the summary one delta at a time (the same
    /// path the summary card uses to render text while it is still being
    /// generated), without touching the network.
    func testSummarySSEStreamsIncrementalDeltas() async throws {
        final class DeltaCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ delta: String) { lock.lock(); items.append(delta); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        }

        final class MockSSEURLProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                // Deliver each SSE event as its own data chunk so the bytes
                // reader yields separate lines and the delta closure fires per
                // chunk rather than once at the end.
                let sse = """
                data: {"choices":[{"delta":{"content":"第一"}}]}

                data: {"choices":[{"delta":{"content":"第二"}}]}

                data: {"choices":[{"delta":{"content":"第三"}}]}

                data: [DONE]

                """
                for chunk in sse.split(separator: "\n\n") {
                    client?.urlProtocol(self, didLoad: Data((String(chunk) + "\n\n").utf8))
                }
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}
        }

        URLProtocol.registerClass(MockSSEURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockSSEURLProtocol.self) }

        let configuration = LLMConfiguration(
            baseURL: "https://example.com/v1",
            model: "test-model",
            temperature: 0.2,
            targetLanguage: "简体中文",
            allowInsecureLocalEndpoint: false
        )
        let collector = DeltaCollector()
        let result = try await LLMService().summary(
            text: "An article body.",
            configuration: configuration,
            apiKey: "test-key"
        ) { delta in
            collector.add(delta)
        }

        XCTAssertEqual(collector.all, ["第一", "第二", "第三"])
        XCTAssertEqual(result, "第一第二第三")
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
        XCTAssertTrue(configuration.showsAISummary)
        XCTAssertFalse(configuration.automaticallyGenerateSummary)
    }

    func testLLMConfigurationCanHideAISummaryModule() throws {
        var configuration = LLMConfiguration.default
        configuration.showsAISummary = false

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(LLMConfiguration.self, from: data)

        XCTAssertFalse(decoded.showsAISummary)
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

    func testUnreadListItemsRetainsReadEntriesInSession() {
        let feedID = UUID()
        let feed = Feed(id: feedID, title: "Test", feedURL: URL(string: "https://example.com")!)
        var entry1 = Entry(id: "item-1", feedID: feedID, title: "Unread 1", isRead: false)
        let entry2 = Entry(id: "item-2", feedID: feedID, title: "Unread 2", isRead: false)

        var index = EntryLibraryIndex(entries: [entry1, entry2], feeds: [feed])
        XCTAssertEqual(index.unreadListItems.count, 2)

        // Simulate marking item1 as read
        entry1.isRead = true
        index = EntryLibraryIndex(entries: [entry1, entry2], feeds: [feed])

        // Without retainingIDs, marked read item vanishes
        XCTAssertEqual(index.unreadListItems.map(\.id), ["item-2"])

        // With retainingIDs set from current session, item1 is retained
        let retained = index.unreadListItems(retainingIDs: ["item-1", "item-2"])
        XCTAssertEqual(retained.map(\.id), ["item-1", "item-2"])
        XCTAssertTrue(retained.first(where: { $0.id == "item-1" })?.isRead == true)
    }

    @MainActor
    func testSummaryForceRegenerationAndMissingKeyError() async throws {
        let store = AppStore()
        var config = store.database.llmConfiguration
        config.baseURL = "https://api.deepseek.com"
        _ = store.saveLLMConfiguration(config, apiKey: "")

        let entry = Entry(id: "test-entry-1", feedID: UUID(), title: "Test Title", summary: "Test Content")
        
        // When DeepSeek API Key is empty, generateSummary reports lastError
        await store.generateSummary(entry: entry, text: "Test Content", force: true)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.lastError?.contains("DeepSeek API Key") == true)
    }
}
