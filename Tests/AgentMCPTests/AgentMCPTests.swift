import Foundation
import XCTest
import PaperRssAgentProtocol
import PaperRssAgentMCP

@MainActor
final class AgentMCPTests: XCTestCase {
    func testSettingsCatalogCoversVisibleDefinitionsAndAliasesExactlyOnce() throws {
        let entries = AgentMCPToolCatalog.entries
        let catalogNames = entries.flatMap { [$0.name] + $0.aliases }
        let definitionNames = try AgentMCPTools.definitions.map {
            try XCTUnwrap($0["name"]?.stringValue)
        }
        let hiddenName = "paperrss_get_content"
        XCTAssertFalse(catalogNames.contains(hiddenName))
        XCTAssertTrue(definitionNames.contains(hiddenName))
        XCTAssertTrue(AgentToolCatalog.names.contains(hiddenName))
        XCTAssertEqual(Set(catalogNames), Set(definitionNames).subtracting([hiddenName]))
        XCTAssertEqual(catalogNames.count, Set(catalogNames).count, "Duplicate catalog tool or alias")
        XCTAssertEqual(Set(entries.map(\.group)), Set(AgentMCPToolCatalog.Group.allCases))
        for entry in entries {
            XCTAssertFalse(entry.zhSummary.isEmpty, entry.name)
            XCTAssertFalse(entry.enSummary.isEmpty, entry.name)
            XCTAssertTrue(entry.example.hasPrefix(entry.name + "\n{\n"), entry.name)
            XCTAssertTrue(entry.exampleArgs.contains("\n  \""), entry.name)
            let arguments = try JSONDecoder().decode(AgentJSON.self, from: Data(entry.exampleArgs.utf8))
            XCTAssertNotNil(arguments.objectValue, entry.name)
            let definition = try XCTUnwrap(AgentMCPTools.definitions.first { $0["name"]?.stringValue == entry.name })
            for alias in entry.aliases {
                let aliasDefinition = try XCTUnwrap(AgentMCPTools.definitions.first { $0["name"]?.stringValue == alias })
                XCTAssertEqual(aliasDefinition["inputSchema"], definition["inputSchema"], alias)
            }
        }
    }

    private func request(_ method: String, id: Int = 1, params: [String: AgentJSON] = [:]) -> AgentJSON {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
    }

    private func initialize(_ server: AgentMCPServer) async {
        let reply = await server.handle(request("initialize", params: [
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("tests"), "version": .string("1")])
        ]))
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string("2025-11-25"))
    }

    private func call(_ name: String, arguments: [String: AgentJSON] = [:], id: Int = 2) -> AgentJSON {
        request("tools/call", id: id, params: ["name": .string(name), "arguments": .object(arguments)])
    }

    func testExplicitInvocationCatalogsAndPromptTemplates() async throws {
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        let initReply = await server.handle(request("initialize", params: [
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("tests"), "version": .string("1")])]))
        XCTAssertNotNil(initReply?["result"]?["capabilities"]?["prompts"])
        XCTAssertNotNil(initReply?["result"]?["capabilities"]?["resources"])
        let list = await server.handle(request("prompts/list"))
        XCTAssertEqual(list?["result"]?["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["digest", "feeds", "mark_feed_read", "open"])
        for (name, args): (String, [String: AgentJSON]) in [
            ("digest", ["since": .string("today")]), ("digest", ["since": .string("2026-10-28")]),
            ("feeds", ["account_id": .string("a")]), ("mark_feed_read", ["feed": .string("Science")]),
            ("open", ["query": .string("Swift")])
        ] {
            let reply = await server.handle(request("prompts/get", params: ["name": .string(name), "arguments": .object(args)]))
            let text = try XCTUnwrap(reply?["result"]?["messages"]?.arrayValue?.first?["content"]?["text"]?.stringValue)
            XCTAssertTrue(text.contains("paperrss_"))
            XCTAssertTrue(text.contains("untrusted"))
            if name == "mark_feed_read" {
                for required in ["Approve in PaperRss", "paperrss_plan_mark_read", "paperrss_status", "paperrss_apply_plan", "approval_id", "App applies immediately", "optional recovery", "approval_mode", "committed and receipt"] { XCTAssertTrue(text.contains(required)) }
            }
        }
        let count = await bridge.callCount
        XCTAssertEqual(count, 0, "Prompt expansion must never read or mutate the App")
        let resources = await server.handle(request("resources/list"))
        XCTAssertEqual(resources?["result"]?["resources"]?.arrayValue?.count, 3)
        let templates = await server.handle(request("resources/templates/list"))
        XCTAssertEqual(templates?["result"]?["resourceTemplates"]?.arrayValue?.first?["uriTemplate"], .string("paperrss://feed/{feed_id}/unread"))
    }

    func testPromptAndResourceArgumentValidation() async {
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        for params: [String: AgentJSON] in [
            ["name": .string("unknown")], ["name": .string("mark_feed_read")],
            ["name": .string("open"), "arguments": .object(["query": .string(" ")])],
            ["name": .string("digest"), "arguments": .object(["since": .string("tomorrow")])],
            ["name": .string("digest"), "arguments": .object(["since": .string("2026-02-30")])],
            ["name": .string("feeds"), "arguments": .object(["account_id": .number(1)])],
            ["name": .string("feeds"), "arguments": .object(["approval_id": .string("invented")])],
            ["name": .string("open"), "arguments": .object(["query": .string(String(repeating: "x", count: 257))])]
        ] {
            let reply = await server.handle(request("prompts/get", params: params))
            XCTAssertEqual(reply?["error"]?["code"], .number(-32602))
        }
        for uri in ["https://example.org", "paperrss://unknown", "paperrss://feed//unread", "paperrss://feed/a%2Fb/unread", "paperrss://status?token=x"] {
            let reply = await server.handle(request("resources/read", params: ["uri": .string(uri)]))
            XCTAssertEqual(reply?["error"]?["code"], .number(-32602))
        }
        for method in ["prompts/list", "resources/list", "resources/templates/list"] {
            let reply = await server.handle(request(method, params: ["cursor": .string("unknown")]))
            XCTAssertEqual(reply?["error"]?["code"], .number(-32602))
        }
        let count = await bridge.callCount
        XCTAssertEqual(count, 0)
    }

    func testFixtureResourcesAreMetadataOnlyAndUseBridgePolicy() async throws {
        let server = AgentMCPServer(bridge: AgentFixtureBridge(enabled: true))
        await initialize(server)
        for uri in ["paperrss://status", "paperrss://feeds", "paperrss://unread/today", "paperrss://feed/fixture-feed/unread"] {
            let reply = await server.handle(request("resources/read", params: ["uri": .string(uri)]))
            let content = try XCTUnwrap(reply?["result"]?["contents"]?.arrayValue?.first)
            XCTAssertEqual(content["mimeType"], .string("application/json"))
            XCTAssertEqual(content["uri"], .string(uri))
            let text = try XCTUnwrap(content["text"]?.stringValue)
            let payload = try JSONDecoder().decode(AgentJSON.self, from: Data(text.utf8))
            XCTAssertEqual(payload["untrusted"], .bool(true))
            XCTAssertFalse(text.contains("content_html"))
            if uri == "paperrss://feeds" { XCTAssertEqual(payload["data"]?["pages"]?.arrayValue?.first?["data"]?["feeds"]?.arrayValue?.first?["untrusted"], .bool(true)) }
        }
        let disabled = AgentMCPServer(bridge: AgentFixtureBridge())
        await initialize(disabled)
        let denied = await disabled.handle(request("resources/read", params: ["uri": .string("paperrss://feeds")]))
        XCTAssertTrue(denied?["error"]?["message"]?.stringValue?.contains("NOT_ENABLED") == true)
    }

    func testResourcesReadAllAuthorizedAccountsAndPreserveContinuation() async throws {
        let bridge = ResourceBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let reply = await server.handle(request("resources/read", params: ["uri": .string("paperrss://feed/f/unread")]))
        let text = try XCTUnwrap(reply?["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue)
        let payload = try JSONDecoder().decode(AgentJSON.self, from: Data(text.utf8))
        let pages = try XCTUnwrap(payload["data"]?["pages"]?.arrayValue)
        XCTAssertEqual(pages.count, 2)
        for page in pages {
            XCTAssertEqual(page["arguments"]?["scope"], .string("unread"))
            XCTAssertEqual(page["arguments"]?["feed_id"], .string("f"))
            XCTAssertEqual(page["arguments"]?["limit"], .number(20))
            XCTAssertEqual(page["data"]?["next_cursor"], .string("next"))
        }
        let calls = await bridge.calls
        XCTAssertEqual(calls, ["paperrss_status", "paperrss_list_articles", "paperrss_list_articles"])
        let single = await server.handle(request("resources/read", params: ["uri": .string("paperrss://feed/only-a/unread")]))
        let singleText = try XCTUnwrap(single?["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue)
        let singlePayload = try JSONDecoder().decode(AgentJSON.self, from: Data(singleText.utf8))
        XCTAssertEqual(singlePayload["data"]?["pages"]?.arrayValue?.map { $0["account_id"] }, [.string("a")])
        await bridge.setFailure()
        let limited = await server.handle(request("resources/read", params: ["uri": .string("paperrss://feeds")]))
        XCTAssertTrue(limited?["error"]?["message"]?.stringValue?.contains("CONTENT_BUDGET_EXCEEDED") == true)
    }

    func testToolsListPaginationParameters() async throws {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        await initialize(server)
        let baseline = await server.handle(request("tools/list"))
        let tools = try XCTUnwrap(baseline?["result"]?["tools"])
        for params: [String: AgentJSON] in [
            ["cursor": .null], ["cursor": .string("x")],
            ["_meta": .object(["progressToken": .number(1)])]
        ] {
            let reply = await server.handle(request("tools/list", params: params))
            XCTAssertEqual(reply?["result"]?["tools"], tools)
            XCTAssertNil(reply?["result"]?["nextCursor"])
        }
        for params: [String: AgentJSON] in [
            ["bogus": .number(1)], ["cursor": .number(5)], ["_meta": .null]
        ] {
            let reply = await server.handle(request("tools/list", params: params))
            XCTAssertEqual(reply?["error"]?["code"], .number(-32602))
            XCTAssertEqual(reply?["error"]?["message"], .string("Invalid tools/list parameters."))
        }
    }

    func testInitializeEchoes20250326() async {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        let reply = await server.handle(request("initialize", params: [
            "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("tests"), "version": .string("1")])
        ]))
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string("2025-03-26"))
    }

    func testRegistrationHasStrictToolsAndSecurityAnnotations() async throws {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        await initialize(server)
        let reply = await server.handle(request("tools/list"))
        let tools = try XCTUnwrap(reply?["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), Set([
            "paperrss_plan_manage_feeds", "paperrss_status", "paperrss_open", "paperrss_list_feeds", "paperrss_list_articles", "paperrss_get_article",
            "paperrss_get_content", "paperrss_refresh_feeds", "paperrss_plan_state_change", "paperrss_plan_mark_read", "paperrss_apply_plan", "paperrss_apply_state_change",
            "paperrss_add_feed", "paperrss_rename_feed", "paperrss_remove_feed",
            "paperrss_plan_add_feed", "paperrss_plan_rename_feed", "paperrss_plan_remove_feed"
        ]))
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), Set(AgentToolCatalog.names))
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["additionalProperties"], .bool(false))
        }
        let content = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "paperrss_get_content" })
        XCTAssertEqual(content["inputSchema"]?["properties"]?["max_chars"]?["maximum"], .number(20_000))
        XCTAssertEqual(content["annotations"]?["openWorldHint"], .bool(false))
        XCTAssertTrue(content["description"]!.stringValue!.contains("untrusted"))
        let apply = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "paperrss_apply_state_change" })
        XCTAssertEqual(apply["annotations"]?["destructiveHint"], .bool(true))
        XCTAssertEqual(apply["annotations"]?["idempotentHint"], .bool(true))
        let refresh = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "paperrss_refresh_feeds" })
        XCTAssertEqual(refresh["annotations"]?["readOnlyHint"], .bool(false))
        XCTAssertEqual(refresh["annotations"]?["destructiveHint"], .bool(false))
        XCTAssertEqual(refresh["annotations"]?["openWorldHint"], .bool(true))
        XCTAssertEqual(refresh["annotations"]?["idempotentHint"], .bool(false))
    }

    func testBatchFeedSchemaValidatesEachOperationAndBounds() throws {
        let account: AgentJSON = .string("account")
        let valid: [AgentJSON] = [
            .object(["action": .string("add_feed"), "url": .string("https://example.org/rss"), "folder": .string("News")]),
            .object(["action": .string("rename_feed"), "feed_id": .string("id"), "title": .string("New title")]),
            .object(["action": .string("remove_feed"), "feed_id": .string("other")])]
        try AgentMCPTools.validate(name: "paperrss_plan_manage_feeds", arguments: ["account_id": account, "operations": .array(valid)])
        for operations in [[], Array(repeating: valid[0], count: 51),
            [.object(["action": .string("remove_feed"), "feed_id": .string("id"), "title": .string("unexpected")])],
            [.object(["action": .string("rename_feed"), "feed_id": .string("id")])],
            [.object(["action": .string("add_feed"), "url": .string("https://user:secret@example.org/rss")])],
            [.object(["action": .string("remove_feed"), "feed_id": .string("id"), "account_id": .string("other")])]] {
            XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_plan_manage_feeds", arguments: ["account_id": account, "operations": .array(operations)]))
        }
    }

    func testMarkReadScopesAndGenericApplySchema() async throws {
        let definition = try XCTUnwrap(AgentMCPTools.definitions.first { $0["name"] == .string("paperrss_plan_mark_read") })
        XCTAssertEqual(definition["annotations"]?["readOnlyHint"], .bool(false))
        XCTAssertEqual(definition["annotations"]?["destructiveHint"], .bool(false))
        let bridge = RecordingBridge()
        let forwarding = AgentMCPServer(bridge: bridge)
        await initialize(forwarding)
        for scope in ["feed", "folder", "account"] {
            var arguments: [String: AgentJSON] = ["account_id": .string("a"), "scope": .string(scope),
                "before": .string("2026-10-28T00:00:00.000Z")]
            if scope == "feed" { arguments["feed_id"] = .string("f") }
            if scope == "folder" { arguments["folder"] = .string("Science") }
            let reply = await forwarding.handle(call("paperrss_plan_mark_read", arguments: arguments))
            XCTAssertEqual(reply?["result"]?["isError"], .bool(false))
            let recorded = await bridge.lastCall
            XCTAssertEqual(recorded?.1, arguments)
        }
        for extra: [String: AgentJSON] in [
            ["scope": .string("feed")], ["scope": .string("folder")],
            ["scope": .string("account"), "feed_id": .string("f")],
            ["scope": .string("feed"), "feed_id": .string("f"), "folder": .string("x")],
            ["scope": .string("account"), "before": .string("tomorrow")],
            ["scope": .string("account"), "approval_id": .string("self-approved")]
        ] {
            var arguments = extra; arguments["account_id"] = .string("a")
            XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_plan_mark_read", arguments: arguments))
        }
        let apply: [String: AgentJSON] = ["plan_id": .string("p"), "approval_id": .string("a"), "idempotency_key": .string("k")]
        for name in ["paperrss_apply_plan", "paperrss_apply_state_change"] {
            XCTAssertNoThrow(try AgentMCPTools.validate(name: name, arguments: apply))
        }
        XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_approve", arguments: apply))
    }

    func testRefreshSchemaRejectsMismatchedScopesAndExtraFields() throws {
        let definition = try XCTUnwrap(AgentMCPTools.definitions.first { $0["name"] == .string("paperrss_refresh_feeds") })
        XCTAssertEqual(definition["annotations"]?["readOnlyHint"], .bool(false))
        XCTAssertEqual(definition["annotations"]?["destructiveHint"], .bool(false))
        XCTAssertEqual(definition["annotations"]?["openWorldHint"], .bool(true))
        XCTAssertTrue(definition["description"]?.stringValue?.contains("operation_id") == true)
        XCTAssertNoThrow(try AgentMCPTools.validate(name: "paperrss_refresh_feeds", arguments: ["scope": .string("all")]))
        XCTAssertNoThrow(try AgentMCPTools.validate(name: "paperrss_refresh_feeds", arguments: [
            "scope": .string("account"), "account_id": .string("local-default")]))
        XCTAssertNoThrow(try AgentMCPTools.validate(name: "paperrss_refresh_feeds", arguments: [
            "scope": .string("feeds"), "account_id": .string("local-default"),
            "feed_ids": .array([.string("feed-1")])]))
        let tooMany = (0..<51).map { AgentJSON.string("feed-\($0)") }
        for arguments: [String: AgentJSON] in [
            [:],
            ["scope": .string("all"), "account_id": .string("local-default")],
            ["scope": .string("all"), "feed_ids": .array([.string("feed-1")])],
            ["scope": .string("account")],
            ["scope": .string("account"), "account_id": .string("local-default"), "feed_ids": .array([.string("feed-1")])],
            ["scope": .string("feeds"), "account_id": .string("local-default")],
            ["scope": .string("feeds"), "account_id": .string("local-default"), "feed_ids": .array(tooMany)],
            ["scope": .string("feeds"), "account_id": .string("local-default"), "feed_ids": .array([.string("feed-1"), .string("feed-1")])],
            ["scope": .string("all"), "url": .string("https://example.org/feed.xml")]
        ] {
            XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_refresh_feeds", arguments: arguments))
        }
    }

    func testFixtureRefreshCompletesWithoutArticleText() async throws {
        let bridge = AgentFixtureBridge(enabled: true)
        let result = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: ["scope": .string("all")])
        XCTAssertEqual(result["state"], .string("completed"))
        XCTAssertEqual(result["new_unread_count"], .number(0))
        XCTAssertEqual(result["subscriptions_synced"], .bool(false))
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("title"))
        XCTAssertFalse(encoded.contains("http"))
        await expectFixtureFailure(bridge, "NOT_FOUND", ["scope": .string("feeds"), "account_id": .string("fixture-local"), "feed_ids": .array([.string("missing")])])
    }

    private func expectFixtureFailure(_ bridge: AgentFixtureBridge, _ code: String, _ arguments: [String: AgentJSON]) async {
        do {
            _ = try await bridge.call(tool: "paperrss_refresh_feeds", arguments: arguments)
            XCTFail("Expected \(code)")
        } catch let error as AgentFailure {
            XCTAssertEqual(error.code, code)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testOpenHasReadOnlyAnnotationsAndExactlyOneTarget() async throws {
        let definition = try XCTUnwrap(AgentMCPTools.definitions.first { $0["name"] == .string("paperrss_open") })
        XCTAssertEqual(definition["annotations"]?["readOnlyHint"], .bool(true))
        XCTAssertEqual(definition["annotations"]?["idempotentHint"], .bool(true))
        XCTAssertEqual(definition["annotations"]?["openWorldHint"], .bool(false))
        XCTAssertEqual(definition["inputSchema"]?["oneOf"]?.arrayValue?.count, 2)
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        for key in ["article_id", "feed_id"] {
            let arguments: [String: AgentJSON] = ["account_id": .string("allowed"), key: .string("target")]
            let reply = await server.handle(call("paperrss_open", arguments: arguments))
            XCTAssertEqual(reply?["result"]?["isError"], .bool(false))
            let recorded = await bridge.lastCall
            XCTAssertEqual(recorded?.0, "paperrss_open")
            XCTAssertEqual(recorded?.1, arguments)
        }
        for extra: [String: AgentJSON] in [[:], ["article_id": .string("a"), "feed_id": .string("f")],
                                          ["article_id": .null], ["feed_id": .string("")]] {
            var arguments: [String: AgentJSON] = ["account_id": .string("allowed")]
            arguments.merge(extra) { _, new in new }
            let reply = await server.handle(call("paperrss_open", arguments: arguments))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string("INVALID_ARGUMENT"))
        }
    }

    func testRequestMapsExactlyToBridgeAndResultHasBothRepresentations() async throws {
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let arguments: [String: AgentJSON] = ["account_id": .string("allowed"), "scope": .string("unread"),
            "limit": .number(12), "query": .string("Swift"), "since": .string("2026-10-26T08:00:00Z")]
        let reply = await server.handle(call("paperrss_list_articles", arguments: arguments))
        let recorded = await bridge.lastCall
        XCTAssertEqual(recorded?.0, "paperrss_list_articles")
        XCTAssertEqual(recorded?.1, arguments)
        XCTAssertEqual(reply?["result"]?["isError"], .bool(false))
        let structured = try XCTUnwrap(reply?["result"]?["structuredContent"])
        XCTAssertEqual(structured["api_version"], .string("1"))
        let text = try XCTUnwrap(reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(try JSONDecoder().decode(AgentJSON.self, from: Data(text.utf8)), structured)
    }

    func testInvalidParametersNeverReachBridge() async {
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let invalid: [[String: AgentJSON]] = [
            ["account_id": .string("a"), "scope": .string("all")],
            ["account_id": .string("a"), "scope": .string("unread"), "limit": .number(51)],
            ["account_id": .string("a"), "scope": .string("unread"), "limit": .number(1.5)],
            ["account_id": .string("a"), "scope": .string("selection")],
            ["account_id": .string("a"), "scope": .string("unread"), "selection_id": .string("s")],
            ["account_id": .string("a"), "scope": .string("unread"), "fetch": .bool(true)],
            ["account_id": .string("a"), "scope": .string("unread"), "query": .string(String(repeating: "a", count: 201))],
            ["account_id": .string("a"), "scope": .string("unread"), "since": .string("tomorrow")]
        ]
        for arguments in invalid {
            let reply = await server.handle(call("paperrss_list_articles", arguments: arguments))
            XCTAssertEqual(reply?["result"]?["isError"], .bool(true))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string("INVALID_ARGUMENT"))
        }
        let count = await bridge.callCount
        XCTAssertEqual(count, 0)
    }

    func testWriteSchemasRejectDuplicateIDsCredentialsAndUnboundApproval() throws {
        XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_plan_state_change", arguments: [
            "account_id": .string("a"), "article_ids": .array([.string("1"), .string("1")]),
            "field": .string("read"), "value": .bool(true)
        ]))
        for url in ["file:///tmp/feed.xml", "https://user:password@example.org/feed"] {
            XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_add_feed", arguments: [
                "account_id": .string("a"), "url": .string(url)
            ]))
        }
        XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_remove_feed", arguments: [
            "account_id": .string("a"), "feed_id": .string("f"), "approval_id": .string("unbound")
        ]))
        XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_apply_state_change", arguments: [
            "plan_id": .string("p"), "approval_id": .string("a"), "idempotency_key": .string(String(repeating: "x", count: 129))
        ]))
    }

    func testDefaultOffAndEnabledUnavailableAreStructuredFailures() async {
        for (enabled, code) in [(false, "NOT_ENABLED"), (true, "APP_NOT_RUNNING")] {
            let server = AgentMCPServer(bridge: AgentUnavailableBridge(enabled: enabled))
            await initialize(server)
            let reply = await server.handle(call("paperrss_status"))
            XCTAssertEqual(reply?["result"]?["isError"], .bool(true))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["api_version"], .string("1"))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string(code))
        }
    }

    func testProtocolErrorsAreSeparateFromToolErrors() async throws {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        let before = await server.handle(request("tools/list"))
        XCTAssertEqual(before?["error"]?["code"], .number(-32002))
        let rawParse = await server.handle(data: Data("{invalid".utf8))
        let parse = try JSONDecoder().decode(AgentJSON.self, from: XCTUnwrap(rawParse))
        XCTAssertEqual(parse["error"]?["code"], .number(-32700))
        let rawOversized = await server.handle(data: Data(repeating: 32, count: AgentMCPServer.maximumRequestBytes + 1))
        let oversized = try JSONDecoder().decode(AgentJSON.self, from: XCTUnwrap(rawOversized))
        XCTAssertEqual(oversized["error"]?["code"], .number(-32600))
        await initialize(server)
        let unknown = await server.handle(request("unknown/method"))
        XCTAssertEqual(unknown?["error"]?["code"], .number(-32601))
        let notification = await server.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        XCTAssertNil(notification)
    }

    func testCancellationReachesInFlightBridge() async {
        let bridge = WaitingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let pending = Task { await server.handle(call("paperrss_status", id: 42)) }
        await bridge.waitUntilStarted()
        let notification = await server.handle(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(42)])
        ]))
        XCTAssertNil(notification)
        let reply = await pending.value
        XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string("CANCELLED"))
    }

    func testShutdownIsTerminalAndPreservesCommittedReceipt() async throws {
        let bridge = ReceiptOnShutdownBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let pending = Task { await server.handle(call("paperrss_apply_plan", arguments: [
            "plan_id": .string("plan"), "approval_id": .string("approved"), "idempotency_key": .string("once")
        ], id: 42)) }
        await bridge.waitUntilStarted()
        await server.shutdown()
        await server.shutdown()
        let reply = await pending.value
        XCTAssertEqual(reply?["result"]?["isError"], .bool(false))
        XCTAssertEqual(reply?["result"]?["structuredContent"]?["data"]?["committed"], .bool(true))
        let after = await server.handle(call("paperrss_status"))
        XCTAssertNil(after)
        let afterRaw = await server.handle(data: Data("{}".utf8))
        XCTAssertNil(afterRaw)
        let counts = await bridge.counts()
        XCTAssertEqual(counts.calls, 1)
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testFixtureNeverIssuesContentOrWriteApproval() async throws {
        let server = AgentMCPServer(bridge: AgentFixtureBridge(enabled: true))
        await initialize(server)
        let status = await server.handle(call("paperrss_status"))
        XCTAssertEqual(status?["result"]?["structuredContent"]?["data"]?["fixture"], .bool(true))
        XCTAssertEqual(status?["result"]?["structuredContent"]?["data"]?["tools"], .array(AgentToolCatalog.names.map(AgentJSON.string)))
        let open = await server.handle(call("paperrss_open", arguments: [
            "account_id": .string("fixture-local"), "article_id": .string("fixture-article")
        ]))
        XCTAssertEqual(open?["result"]?["structuredContent"]?["error"]?["code"], .string("UNSUPPORTED"))
        let content = await server.handle(call("paperrss_get_content", arguments: [
            "account_id": .string("fixture-local"), "article_id": .string("fixture-article"), "selection_id": .string("invented")
        ]))
        XCTAssertEqual(content?["result"]?["structuredContent"]?["error"]?["code"], .string("UNAUTHORIZED"))
        let apply = await server.handle(call("paperrss_apply_state_change", arguments: [
            "plan_id": .string("invented"), "approval_id": .string("invented"), "idempotency_key": .string("k")
        ]))
        XCTAssertEqual(apply?["result"]?["structuredContent"]?["error"]?["code"], .string("CONFIRMATION_REQUIRED"))
    }

    func testFixtureHonorsTimeFilterAndRejectsUnknownCursor() async throws {
        let server = AgentMCPServer(bridge: AgentFixtureBridge(enabled: true))
        await initialize(server)
        for (since, expectedCount) in [("2026-10-26T00:00:00Z", 1), ("2026-10-28T00:00:00.000Z", 0)] {
            let response = await server.handle(call("paperrss_list_articles", arguments: [
                "account_id": .string("fixture-local"), "scope": .string("unread"), "since": .string(since)
            ]))
            XCTAssertEqual(response?["result"]?["structuredContent"]?["data"]?["articles"]?.arrayValue?.count, expectedCount)
        }
        let cursor = await server.handle(call("paperrss_list_feeds", arguments: [
            "account_id": .string("fixture-local"), "cursor": .string("fabricated")
        ]))
        XCTAssertEqual(cursor?["result"]?["structuredContent"]?["error"]?["code"], .string("INVALID_ARGUMENT"))
    }
}

private actor RecordingBridge: AgentBridge {
    var lastCall: (String, [String: AgentJSON])?
    var callCount = 0
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        callCount += 1
        lastCall = (tool, arguments)
        return .object(["articles": .array([]), "next_cursor": .null])
    }
}

private actor WaitingBridge: AgentBridge {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        started = true
        waiter?.resume()
        waiter = nil
        try await Task.sleep(for: .seconds(30))
        return .null
    }
}

/// Models a write that crossed the App commit boundary before its session closed.
/// The successful receipt must survive the helper's cancellation flag.
private actor ReceiptOnShutdownBridge: AgentBridge {
    private var calls = 0, shutdowns = 0
    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<AgentJSON, Never>?
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        calls += 1
        return await withCheckedContinuation {
            completion = $0
            started?.resume(); started = nil
        }
    }
    func shutdown() async {
        shutdowns += 1
        completion?.resume(returning: .object(["committed": .bool(true)]))
        completion = nil
    }
    func counts() -> (calls: Int, shutdowns: Int) { (calls, shutdowns) }
}

private actor ResourceBridge: AgentBridge {
    var calls: [String] = []
    private var fail = false
    func setFailure() { fail = true }
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        calls.append(tool)
        if tool == "paperrss_status" {
            // "c" is a disabled account: listed by status but outside the session, so resources must skip it.
            return .object(["enabled": .bool(true), "accounts": .array(["a", "b"].map { .object(["account_id": .string($0)]) }
                + [.object(["account_id": .string("c"), "enabled": .bool(false)])])])
        }
        if tool == "paperrss_list_articles", arguments["account_id"] == .string("b"), arguments["feed_id"] == .string("only-a") {
            throw AgentFailure("NOT_FOUND", "Feed not found.")
        }
        if fail { throw AgentFailure("CONTENT_BUDGET_EXCEEDED", "Budget exhausted.") }
        return .object(["articles": .array([]), "next_cursor": .string("next")])
    }
}
