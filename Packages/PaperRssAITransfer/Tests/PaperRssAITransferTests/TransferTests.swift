import XCTest
@testable import PaperRssAITransfer

final class TransferTests: XCTestCase {
    private func snapshot() -> TransferSnapshot {
        TransferSnapshot(sourceID: "fixture-mac", sourceName: "Test Mac", settings: .object([
            "schema": .number(5), "providers": .array([.object([
                "id": .string("provider-1"), "name": .string("Test"), "baseURL": .string("https://example.org/v1"),
                "models": .array([.object(["id": .string("model"), "futureMetadata": .object(["effort": .number(7)])])])
            ])]), "featureConfigurations": .array([.string("summary"), .object(["model": .object(["providerID": .string("provider-1"), "modelID": .string("model")])])])
        ]), credentials: ["provider-1": "fixture-secret-never-log"])
    }

    func testSnapshotPreservesUnknownFieldsAndEnumDictionary() throws {
        let original = snapshot()
        let roundtrip = try JSONDecoder().decode(TransferSnapshot.self, from: JSONEncoder().encode(original))
        try roundtrip.validate()
        XCTAssertEqual(roundtrip.settings, original.settings)
        XCTAssertEqual(roundtrip.credentials, original.credentials)
    }
    func testQRCodeContainsOnlyPairingCapabilityAndRoundtrips() throws {
        let offer = PairingOffer(hosts: ["192.168.1.2"], port: 1234, sessionID: UUID().uuidString,
                                 secret: Data(repeating: 7, count: 32), expiresAt: Date().addingTimeInterval(120))
        let encoded = try offer.encodedQRCode()
        XCTAssertFalse(encoded.contains("fixture-secret-never-log"))
        let parsed = try PairingOffer.parseQRCode(encoded)
        XCTAssertEqual(parsed.secret, offer.secret)
        XCTAssertEqual(parsed.sessionID, offer.sessionID)
        XCTAssertEqual(parsed.hosts, offer.hosts)
    }
    func testInvalidExpiredAndPublicDestinationAreRejected() throws {
        XCTAssertThrowsError(try PairingOffer.parseQRCode("https://example.org/feed"))
        for host in ["127.0.0.1", "8.8.8.8", "192.168.01.2", "192.168.1.999", "localhost"] {
            let offer = PairingOffer(hosts: [host], port: 1234, sessionID: UUID().uuidString,
                                     secret: Data(repeating: 3, count: 32), expiresAt: Date().addingTimeInterval(120))
            XCTAssertThrowsError(try offer.validate())
        }
        let expired = PairingOffer(hosts: ["10.0.0.2"], port: 1, sessionID: UUID().uuidString,
                                   secret: Data(repeating: 3, count: 32), expiresAt: Date().addingTimeInterval(-1))
        XCTAssertThrowsError(try expired.validate()) { XCTAssertEqual($0 as? TransferError, .expired) }
    }
    func testCredentialsMustBelongToAProvider() throws {
        let original = snapshot()
        let invalid = TransferSnapshot(sourceID: original.sourceID, sourceName: original.sourceName,
                                       settings: original.settings, credentials: ["unrelated": "fixture"])
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor
    func testEncryptedTransferIsSingleUseAndClosesListener() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let offer: PairingOffer
        do { offer = try await server.start(snapshot: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        let received = try await PairingClient.receive(offer: offer)
        XCTAssertEqual(received.settings, snapshot().settings)
        XCTAssertEqual(received.credentials, snapshot().credentials)
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await PairingClient.receive(offer: offer)
            XCTFail("A consumed session must not send the credentials again")
        } catch { XCTAssertTrue(error is TransferError) }
    }

    @MainActor
    func testWrongPSKCannotReadAndDoesNotConsumeSnapshot() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let offer: PairingOffer
        do { offer = try await server.start(snapshot: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        let invalid = PairingOffer(hosts: offer.hosts, port: offer.port, sessionID: offer.sessionID,
                                   secret: Data(repeating: 0, count: 32), expiresAt: offer.expiresAt)
        do {
            _ = try await PairingClient.receive(offer: invalid)
            XCTFail("Wrong PSK must fail")
        } catch { XCTAssertTrue(error is TransferError) }
        try await Task.sleep(for: .milliseconds(150))
        let received = try await PairingClient.receive(offer: offer)
        XCTAssertEqual(received.credentials, snapshot().credentials)
    }

    @MainActor
    func testStopInvalidatesOldOfferAndFreshSessionCanTransfer() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let original: PairingOffer
        do { original = try await server.start(snapshot: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        server.stop()
        let fresh = try await server.start(snapshot: snapshot())
        XCTAssertNotEqual(original.sessionID, fresh.sessionID)
        XCTAssertFalse(original.secret == fresh.secret, "A new session must rotate its pairing secret")
        do {
            _ = try await PairingClient.receive(offer: original)
            XCTFail("Stopping a session must invalidate the old QR code")
        } catch { XCTAssertTrue(error is TransferError) }
        let received = try await PairingClient.receive(offer: fresh)
        XCTAssertEqual(received.settings, snapshot().settings)
    }

    @MainActor
    func testCancelledReceiveDoesNotConsumeSnapshot() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let offer: PairingOffer
        do { offer = try await server.start(snapshot: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        // A deliberately unauthenticated peer keeps the handshake pending until cancelled.
        let invalid = PairingOffer(hosts: offer.hosts, port: offer.port, sessionID: offer.sessionID,
                                   secret: Data(repeating: 0, count: 32), expiresAt: offer.expiresAt)
        let receive = Task { try await PairingClient.receive(offer: invalid) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelTime = ContinuousClock.now
        receive.cancel()
        do {
            _ = try await receive.value
            XCTFail("Cancelling a receive must not return configuration")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(cancelTime.duration(to: .now), .seconds(2))
        try await Task.sleep(for: .milliseconds(150))
        let received = try await PairingClient.receive(offer: offer)
        XCTAssertEqual(received.settings, snapshot().settings)
    }

    @MainActor
    func testExpiredOfferDoesNotConsumeActiveSession() async throws {
        let server = PairingServer()
        defer { server.stop() }
        let offer: PairingOffer
        do { offer = try await server.start(snapshot: snapshot()) }
        catch TransferError.noLocalNetwork { throw XCTSkip("No local IPv4 interface for transport integration test") }
        let expired = PairingOffer(hosts: offer.hosts, port: offer.port, sessionID: offer.sessionID,
                                   secret: offer.secret, expiresAt: Date().addingTimeInterval(-1))
        do {
            _ = try await PairingClient.receive(offer: expired)
            XCTFail("Expired QR codes must be rejected before connecting")
        } catch { XCTAssertEqual(error as? TransferError, .expired) }
        let received = try await PairingClient.receive(offer: offer)
        XCTAssertEqual(received.settings, snapshot().settings)
    }
}
