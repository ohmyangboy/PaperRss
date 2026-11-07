import XCTest
import Combine
@testable import PaperRssAITransfer

final class SubscriptionTransferTests: XCTestCase {
    private func snapshot() -> SubscriptionSnapshot {
        SubscriptionSnapshot(sourceID: "fixture-mac", sourceName: "Test Mac", accountName: "Local account", feeds: [
            SubscriptionItem(id: "feed-1", title: "HTTPS feed", url: "https://example.org/feed.xml",
                             folder: "技术", folders: ["技术", "稍后读"]),
            SubscriptionItem(id: "feed-2", title: "HTTP feed", url: "http://example.org/legacy.xml", folder: "技术"),
            SubscriptionItem(id: "feed-3", title: "Needs URL correction", url: "not a feed URL")
        ], folders: ["技术", "稍后读", "Empty folder"])
    }

    private func aiSnapshot() -> TransferSnapshot {
        TransferSnapshot(sourceID: "fixture-mac", sourceName: "Test Mac", settings: .object([
            "providers": .array([.object(["id": .string("provider-1"), "name": .string("Fixture"),
                                           "baseURL": .string("https://example.org/v1"), "models": .array([])])])
        ]), credentials: ["provider-1": "fixture-api-key-keep-private"])
    }

    func testSubscriptionSnapshotRoundtripPreservesAllFoldersAndIndividualURLs() throws {
        let original = snapshot()
        try original.validate()
        let encoded = try JSONEncoder().encode(original)
        let received = try JSONDecoder().decode(SubscriptionSnapshot.self, from: encoded)
        try received.validate()
        XCTAssertEqual(received, original)
        XCTAssertEqual(received.feeds[0].folders, ["技术", "稍后读"])
        XCTAssertEqual(received.feeds[1].url, "http://example.org/legacy.xml")
        XCTAssertEqual(received.feeds[2].url, "not a feed URL", "The phone preview must handle each invalid URL independently")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(fields["credentials"])
        XCTAssertNil(fields["settings"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-api-key-keep-private"))
    }

    func testSubscriptionItemDecodesWithoutAdditionalFolderMembership() throws {
        let item = try JSONDecoder().decode(SubscriptionItem.self,
            from: Data("{\"id\":\"feed-1\",\"title\":\"Feed\",\"url\":\"https://example.org/feed\",\"folder\":\"技术\"}".utf8))
        XCTAssertEqual(item.folder, "技术")
        XCTAssertTrue(item.folders.isEmpty)
    }

    func testSubscriptionStructureRejectsDuplicateIDsAndInvalidSource() throws {
        let original = snapshot()
        let duplicate = SubscriptionSnapshot(sourceID: original.sourceID, sourceName: original.sourceName,
                                             accountName: original.accountName, feeds: [original.feeds[0], original.feeds[0]], folders: [])
        XCTAssertThrowsError(try duplicate.validate()) { XCTAssertEqual($0 as? TransferError, .invalidSnapshot) }
        let blankSource = SubscriptionSnapshot(sourceID: " \n ", sourceName: "Mac", accountName: "Local", feeds: [], folders: [])
        XCTAssertThrowsError(try blankSource.validate()) { XCTAssertEqual($0 as? TransferError, .invalidSnapshot) }
        let longSource = SubscriptionSnapshot(sourceID: String(repeating: "a", count: 129), sourceName: "Mac",
                                              accountName: "Local", feeds: [], folders: [])
        XCTAssertThrowsError(try longSource.validate()) { XCTAssertEqual($0 as? TransferError, .invalidSnapshot) }
        let oversizedField = SubscriptionSnapshot(sourceID: "fixture", sourceName: "Mac", accountName: "Local",
                                                  feeds: [SubscriptionItem(id: "a", title: "Feed", url: String(repeating: "a", count: 16_385))], folders: [])
        XCTAssertThrowsError(try oversizedField.validate()) { XCTAssertEqual($0 as? TransferError, .invalidSnapshot) }
    }

    func testSubscriptionVersionAndFrameLimitAreEnforced() throws {
        let future = SubscriptionSnapshot(version: 2, sourceID: "fixture", sourceName: "Mac", accountName: "Local", feeds: [], folders: [])
        XCTAssertThrowsError(try future.validate()) { XCTAssertEqual($0 as? TransferError, .unsupportedVersion) }
        let large = SubscriptionSnapshot(sourceID: "fixture", sourceName: "Mac", accountName: "Local",
                                         feeds: (0..<150).map { SubscriptionItem(id: String($0), title: String(repeating: "x", count: 8000), url: "https://example.org/\($0)") }, folders: [])
        XCTAssertThrowsError(try large.validate()) { XCTAssertEqual($0 as? TransferError, .tooLarge) }
    }

    func testLegacyAIQRCodeRemainsUnchangedAndPurposeDefaultsToAI() throws {
        let offer = PairingOffer(hosts: ["192.168.1.2"], port: 1234, sessionID: UUID().uuidString,
                                 secret: Data(repeating: 8, count: 32), expiresAt: Date().addingTimeInterval(120))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any])
        XCTAssertNil(fields["purpose"], "Legacy AI QR encoding must not gain an envelope or required field")
        let decoded = try PairingOffer.parseQRCode(offer.encodedQRCode())
        XCTAssertNil(decoded.purpose)
        XCTAssertEqual(decoded.effectivePurpose, .aiConfiguration)
        XCTAssertEqual(decoded.secret, offer.secret)
        let aiFields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(aiSnapshot())) as? [String: Any])
        XCTAssertNotNil(aiFields["credentials"])
        XCTAssertNil(aiFields["payload"], "Existing AI payload JSON must remain wire compatible")
    }

    func testSubscriptionQRCodeDeclaresPurposeWithoutIncludingSubscriptions() throws {
        let offer = PairingOffer(hosts: ["10.0.0.2"], port: 1234, sessionID: UUID().uuidString,
                                 secret: Data(repeating: 4, count: 32), expiresAt: Date().addingTimeInterval(120), purpose: .subscriptions)
        let decoded = try PairingOffer.parseQRCode(offer.encodedQRCode())
        XCTAssertEqual(decoded.purpose, .subscriptions)
        XCTAssertEqual(decoded.effectivePurpose, .subscriptions)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any])
        XCTAssertEqual(fields["purpose"] as? String, "subscriptions")
        XCTAssertNil(fields["feeds"])
        XCTAssertNil(fields["credentials"])
    }

    @MainActor
    func testWrongPurposeIsRejectedBeforeConnectingAndSessionRemainsUsable() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let aiOffer: PairingOffer
        do { aiOffer = try await server.start(snapshot: aiSnapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        let start = ContinuousClock.now
        do {
            _ = try await PairingClient.receiveSubscriptions(offer: aiOffer)
            XCTFail("The subscription entry point must reject AI QR codes before opening a connection")
        } catch { XCTAssertEqual(error as? TransferError, .wrongPurpose) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let receivedAI = try await PairingClient.receive(offer: aiOffer)
        XCTAssertEqual(receivedAI.credentials, aiSnapshot().credentials)

        let subscriptionOffer = try await server.start(subscriptions: snapshot())
        do {
            _ = try await PairingClient.receive(offer: subscriptionOffer)
            XCTFail("The AI entry point must reject subscription QR codes")
        } catch { XCTAssertEqual(error as? TransferError, .wrongPurpose) }
        let receivedSubscriptions = try await PairingClient.receiveSubscriptions(offer: subscriptionOffer)
        XCTAssertEqual(receivedSubscriptions, snapshot())
    }

    @MainActor
    func testEncryptedSubscriptionTransferIsSingleUseAndContainsOnlySubscriptions() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let offer: PairingOffer
        do { offer = try await server.start(subscriptions: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        XCTAssertEqual(offer.effectivePurpose, .subscriptions)
        let received = try await PairingClient.receiveSubscriptions(offer: offer)
        XCTAssertEqual(received, snapshot())
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(received)) as? [String: Any])
        XCTAssertNil(fields["credentials"])
        XCTAssertNil(fields["settings"])
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await PairingClient.receiveSubscriptions(offer: offer)
            XCTFail("A consumed subscription session must not send a second payload")
        } catch { XCTAssertTrue(error is TransferError) }
    }

    @MainActor
    func testTamperingQRCodePurposeCannotConsumeAISession() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let offer: PairingOffer
        do { offer = try await server.start(snapshot: aiSnapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        let tampered = PairingOffer(hosts: offer.hosts, port: offer.port, sessionID: offer.sessionID,
                                    secret: offer.secret, expiresAt: offer.expiresAt, purpose: .subscriptions)
        do {
            _ = try await PairingClient.receiveSubscriptions(offer: tampered)
            XCTFail("Changing a QR purpose must not deliver an AI payload to the subscription receiver")
        } catch { XCTAssertTrue(error is TransferError) }
        try await Task.sleep(for: .milliseconds(150))
        let received = try await PairingClient.receive(offer: offer)
        XCTAssertEqual(received.credentials, aiSnapshot().credentials)
    }

    @MainActor
    func testAlreadyCancelledStartDoesNotStopCurrentSubscriptionSession() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let current: PairingOffer
        do { current = try await server.start(subscriptions: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }

        // These tasks are cancelled synchronously before the main actor can run
        // either start entry point, as happens when an old account task is queued.
        let cancelledAI = Task { try await server.start(snapshot: aiSnapshot()) }
        cancelledAI.cancel()
        do {
            _ = try await cancelledAI.value
            XCTFail("An already-cancelled AI task must not start a new session")
        } catch { XCTAssertTrue(error is CancellationError) }
        let cancelledSubscriptions = Task { try await server.start(subscriptions: snapshot()) }
        cancelledSubscriptions.cancel()
        do {
            _ = try await cancelledSubscriptions.value
            XCTFail("An already-cancelled subscription task must not start a new session")
        } catch { XCTAssertTrue(error is CancellationError) }

        let received = try await PairingClient.receiveSubscriptions(offer: current)
        XCTAssertEqual(received, snapshot())
    }

    @MainActor
    func testCancellingPendingStartDoesNotStopReplacementAccountSession() async throws {
        let server = PairingServer()
        defer { server.stop() }
        // Establish local-network availability before awaiting a start notification.
        do { _ = try await server.start(subscriptions: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        server.stop()

        for account in ["Account B", "Account C", "Account D"] {
            let started = AsyncStream<Void>.makeStream()
            let observation = server.$stateDescription.sink { state in
                if state == "正在准备连接" { started.continuation.yield(()) }
            }
            let previous = Task {
                defer { started.continuation.finish() }
                return try await server.start(subscriptions: snapshot())
            }
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()
            observation.cancel()
            previous.cancel()

            let replacementSnapshot = SubscriptionSnapshot(sourceID: "replacement-mac", sourceName: "Mac",
                                                           accountName: account, feeds: snapshot().feeds, folders: snapshot().folders)
            let replacement = try await server.start(subscriptions: replacementSnapshot)
            // Let the old task and its queued main-actor cancellation cleanup run
            // before checking the new listener, matching a rapid account switch.
            _ = try? await previous.value
            await Task.yield()
            let received = try await PairingClient.receiveSubscriptions(offer: replacement)
            XCTAssertEqual(received, replacementSnapshot)
        }
    }
}
