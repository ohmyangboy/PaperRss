import XCTest
@testable import PaperRssCore

final class LegacyDTOCompatibilityTests: XCTestCase {
    func testLegacyAppDatabaseDecodesEquivalentlyToAppDatabase() throws {
        let feedID1 = UUID()
        let feedID2 = UUID()
        let artID1 = UUID()
        let artID2 = UUID()

        let jsonString = """
        {
            "feeds": [
                {
                    "id": "\(feedID1.uuidString)",
                    "title": "Swift News",
                    "siteURL": "https://swift.org",
                    "feedURL": "https://swift.org/atom.xml",
                    "folder": "Tech",
                    "etag": "\\"123\\"",
                    "lastModified": "Wed, 21 Oct 2025 07:28:00 GMT",
                    "lastRefreshedAt": 1700000000.0,
                    "isDeleted": false,
                    "updatedAt": 1700000000.0,
                    "storedIconURL": "https://swift.org/icon.png"
                },
                {
                    "id": "\(feedID2.uuidString)",
                    "title": "Deleted Feed",
                    "feedURL": "https://del.org/rss",
                    "isDeleted": true,
                    "updatedAt": 1700000000.0
                }
            ],
            "entries": [
                {
                    "id": "entry_1",
                    "feedID": "\(feedID1.uuidString)",
                    "title": "Swift 6.0 Released",
                    "author": "Apple",
                    "url": "https://swift.org/blog/swift-6",
                    "publishedAt": 1699999000.0,
                    "summary": "Swift 6 features complete concurrency.",
                    "contentHTML": "<p>Swift 6 features complete concurrency.</p>",
                    "isRead": false,
                    "isStarred": true,
                    "updatedAt": 1700000000.0
                }
            ],
            "articleCaches": {
                "entry_1": {
                    "entryID": "entry_1",
                    "text": "Clean plain text",
                    "html": "<div>HTML</div>",
                    "imageURLs": ["https://img.com/a.png", "https://img.com/b.png"],
                    "fetchedAt": 1700000050.0,
                    "sourceURL": "https://swift.org/blog/swift-6",
                    "isSanitized": true
                }
            },
            "readingStates": {
                "entry_1": {
                    "entryID": "entry_1",
                    "isRead": true,
                    "isStarred": true,
                    "updatedAt": 1700000100.0
                }
            },
            "artifacts": [
                {
                    "id": "\(artID1.uuidString)",
                    "entryID": "entry_1",
                    "kind": "summary",
                    "contentHash": "hash1",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 1,
                    "content": "摘要内容",
                    "segments": [
                        {"id": "s1", "original": "Swift 6", "translation": "Swift 6 语言"}
                    ],
                    "selectionAnchor": {
                        "paragraphID": "p1",
                        "startOffset": 0,
                        "endOffset": 5
                    },
                    "isComplete": true,
                    "isDeleted": false,
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                },
                {
                    "id": "\(artID2.uuidString)",
                    "entryID": "translation-memory-v2:digest_abc",
                    "kind": "translation",
                    "contentHash": "hash2",
                    "model": "deepseek-chat",
                    "targetLanguage": "zh-Hans",
                    "promptVersion": 2,
                    "content": "全局翻译记忆",
                    "isComplete": true,
                    "isDeleted": false,
                    "createdAt": 1700000000.0,
                    "updatedAt": 1700000000.0
                }
            ],
            "llmConfiguration": {
                "providerName": "DeepSeek",
                "providerDescription": "API",
                "baseURL": "https://api.deepseek.com",
                "model": "deepseek-v4-flash",
                "reasoningMode": "自动",
                "temperature": 0.2,
                "targetLanguage": "简体中文",
                "allowInsecureLocalEndpoint": false,
                "showsAISummary": true,
                "automaticallyGenerateSummary": false,
                "showsSelectionExplanation": true,
                "showsSelectionAsk": true,
                "showsSelectionTranslation": true,
                "customPrompt": "自定义 Prompt"
            },
            "customFolders": ["Tech", "News"]
        }
        """

        let data = Data(jsonString.utf8)
        let decoder = JSONDecoder()

        let currentDB = try decoder.decode(AppDatabase.self, from: data)
        let legacyDB = try decoder.decode(LegacyAppDatabase.self, from: data)

        // 1. Feeds 等价性
        XCTAssertEqual(currentDB.feeds.count, legacyDB.feeds.count)
        for (cFeed, lFeed) in zip(currentDB.feeds, legacyDB.feeds) {
            XCTAssertEqual(cFeed.id, lFeed.id)
            XCTAssertEqual(cFeed.title, lFeed.title)
            XCTAssertEqual(cFeed.siteURL, lFeed.siteURL)
            XCTAssertEqual(cFeed.feedURL, lFeed.feedURL)
            XCTAssertEqual(cFeed.folder, lFeed.folder)
            XCTAssertEqual(cFeed.etag, lFeed.etag)
            XCTAssertEqual(cFeed.lastModified, lFeed.lastModified)
            XCTAssertEqual(cFeed.isDeleted, lFeed.isDeleted)
            XCTAssertEqual(cFeed.storedIconURL, lFeed.storedIconURL)
        }

        // 2. Entries 等价性
        XCTAssertEqual(currentDB.entries.count, legacyDB.entries.count)
        for (cEntry, lEntry) in zip(currentDB.entries, legacyDB.entries) {
            XCTAssertEqual(cEntry.id, lEntry.id)
            XCTAssertEqual(cEntry.feedID, lEntry.feedID)
            XCTAssertEqual(cEntry.title, lEntry.title)
            XCTAssertEqual(cEntry.author, lEntry.author)
            XCTAssertEqual(cEntry.url, lEntry.url)
            XCTAssertEqual(cEntry.summary, lEntry.summary)
            XCTAssertEqual(cEntry.contentHTML, lEntry.contentHTML)
            XCTAssertEqual(cEntry.isRead, lEntry.isRead)
            XCTAssertEqual(cEntry.isStarred, lEntry.isStarred)
        }

        // 3. ArticleCaches 等价性
        XCTAssertEqual(currentDB.articleCaches.count, legacyDB.articleCaches.count)
        for (key, cCache) in currentDB.articleCaches {
            guard let lCache = legacyDB.articleCaches[key] else {
                XCTFail("Missing cache key in legacy: \(key)")
                continue
            }
            XCTAssertEqual(cCache.entryID, lCache.entryID)
            XCTAssertEqual(cCache.text, lCache.text)
            XCTAssertEqual(cCache.html, lCache.html)
            XCTAssertEqual(cCache.imageURLs, lCache.imageURLs)
            XCTAssertEqual(cCache.sourceURL, lCache.sourceURL)
            XCTAssertEqual(cCache.isSanitized, lCache.isSanitized)
        }

        // 4. ReadingStates 等价性
        XCTAssertEqual(currentDB.readingStates.count, legacyDB.readingStates.count)
        for (key, cState) in currentDB.readingStates {
            guard let lState = legacyDB.readingStates[key] else {
                XCTFail("Missing state key in legacy: \(key)")
                continue
            }
            XCTAssertEqual(cState.entryID, lState.entryID)
            XCTAssertEqual(cState.isRead, lState.isRead)
            XCTAssertEqual(cState.isStarred, lState.isStarred)
        }

        // 5. Artifacts 等价性
        XCTAssertEqual(currentDB.artifacts.count, legacyDB.artifacts.count)
        for (cArt, lArt) in zip(currentDB.artifacts, legacyDB.artifacts) {
            XCTAssertEqual(cArt.id, lArt.id)
            XCTAssertEqual(cArt.entryID, lArt.entryID)
            XCTAssertEqual(cArt.kind.rawValue, lArt.kind.rawValue)
            XCTAssertEqual(cArt.contentHash, lArt.contentHash)
            XCTAssertEqual(cArt.model, lArt.model)
            XCTAssertEqual(cArt.targetLanguage, lArt.targetLanguage)
            XCTAssertEqual(cArt.promptVersion, lArt.promptVersion)
            XCTAssertEqual(cArt.content, lArt.content)
            XCTAssertEqual(cArt.segments.count, lArt.segments.count)
            XCTAssertEqual(cArt.selectionAnchor?.paragraphID, lArt.selectionAnchor?.paragraphID)
        }

        // 6. LLMConfiguration & Folders 等价性
        XCTAssertEqual(currentDB.llmConfiguration.baseURL, legacyDB.llmConfiguration.baseURL)
        XCTAssertEqual(currentDB.llmConfiguration.model, legacyDB.llmConfiguration.model)
        XCTAssertEqual(currentDB.llmConfiguration.customPrompt, legacyDB.llmConfiguration.customPrompt)
        XCTAssertEqual(currentDB.customFolders, legacyDB.customFolders)
    }
}
