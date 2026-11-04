import XCTest
import Foundation
import Darwin
import PaperRssAgentProtocol

final class AgentIPCTests: XCTestCase, @unchecked Sendable {
    private func directory() -> URL {
        // Keep below sockaddr_un's 104-byte limit, including on long CI TMPDIRs.
        URL(fileURLWithPath: "/tmp/pr-ipc-\(UUID().uuidString.prefix(12))", isDirectory: true)
    }
    private func expect(_ code: String, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)") }
        catch let error as AgentFailure { XCTAssertEqual(error.code, code) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testDisabledHelperAndMissingApp() async {
        let dir = directory()
        await expect("NOT_ENABLED") { _ = try await AgentIPCClientBridge(directory: dir).call(tool: "paperrss_status", arguments: [:]) }
        await expect("APP_NOT_RUNNING") { _ = try await AgentIPCClientBridge(enabled: true, directory: dir).call(tool: "paperrss_status", arguments: [:]) }
    }
    func testDisabledOwnerAndStopAreDistinct() async throws {
        let dir = directory()
        let server = AgentIPCServer(directory: dir) { _, _, _ in XCTFail("Disabled server must not dispatch"); return .null }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start(enabled: false)
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        await expect("NOT_ENABLED") { _ = try await client.call(tool: "paperrss_status", arguments: [:]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bridge.sock").path))
        server.stop()
        await expect("APP_NOT_RUNNING") { _ = try await client.call(tool: "paperrss_status", arguments: [:]) }
    }
    func testRoundtripIsolationDisableAndReconnect() async throws {
        let dir = directory()
        let disconnected = XCTestExpectation(description: "Client session revoked")
        disconnected.expectedFulfillmentCount = 3
        let server = AgentIPCServer(directory: dir, handler: { session, tool, arguments in
            .object(["session": .string(session), "tool": .string(tool), "arguments": .object(arguments)])
        }, disconnected: { _ in disconnected.fulfill() })
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let first = AgentIPCClientBridge(enabled: true, directory: dir)
        let second = AgentIPCClientBridge(enabled: true, directory: dir)
        let status = try await first.call(tool: "paperrss_status", arguments: [:])
        for name in ["paperrss_list_feeds", "paperrss_list_articles", "paperrss_get_article"] {
            let result = try await first.call(tool: name, arguments: ["account_id": .string("test-local")])
            XCTAssertEqual(result["session"], status["session"])
            XCTAssertEqual(result["tool"], .string(name))
            XCTAssertEqual(result["arguments"]?["account_id"], .string("test-local"))
        }
        let other = try await second.call(tool: "paperrss_status", arguments: [:])
        XCTAssertNotEqual(other["session"], status["session"])
        try server.setEnabled(false)
        await expect("NOT_ENABLED") { _ = try await first.call(tool: "paperrss_status", arguments: [:]) }
        await second.disconnect()
        try server.setEnabled(true)
        let renewed = try await first.call(tool: "paperrss_status", arguments: [:])
        XCTAssertNotEqual(renewed["session"], status["session"])
        await first.disconnect()
        await fulfillment(of: [disconnected], timeout: 5)
    }
    func testDiagnosticClientLabelIsHandshakeMetadataOnly() async throws {
        let dir = directory()
        let labels = DiagnosticLabels()
        let server = AgentIPCServer(directory: dir, handler: { session, _, arguments in
            .object(["label": await labels.value(session).map(AgentJSON.string) ?? .null,
                     "arguments": .object(arguments)])
        }, connected: { session, label in await labels.set(session, label) })
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let named = AgentIPCClientBridge(enabled: true, directory: dir, clientLabel: "helper <untrusted>")
        let anonymous = AgentIPCClientBridge(enabled: true, directory: dir)
        let response = try await named.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(response["label"], .string("helper <untrusted>"))
        XCTAssertEqual(response["arguments"], .object([:]))
        let missing = try await anonymous.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(missing["label"], .null)
        let oversized = AgentIPCClientBridge(enabled: true, directory: dir, clientLabel: String(repeating: "x", count: 129))
        await expect("INVALID_ARGUMENT") { _ = try await oversized.call(tool: "paperrss_status", arguments: [:]) }
        await named.disconnect(); await anonymous.disconnect()
    }
    func testPrivatePermissionsAndUnsafeDirectoryRejected() throws {
        let dir = directory()
        let server = AgentIPCServer(directory: dir) { _, _, _ in .null }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        for (name, mode) in [("", 0o700), ("bridge.sock", 0o600), ("token", 0o600), ("owner", 0o600)] {
            let path = name.isEmpty ? dir.path : dir.appendingPathComponent(name).path
            var info = stat()
            XCTAssertEqual(lstat(path, &info), 0)
            XCTAssertEqual(Int(info.st_mode & 0o777), mode)
            XCTAssertEqual(info.st_uid, getuid())
        }
        server.stop()
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual(($0 as? AgentFailure)?.code, "UNAUTHORIZED") }
    }
    func testBadTokenAndVersionFailBeforeDispatch() async throws {
        let dir = directory()
        let server = AgentIPCServer(directory: dir) { _, _, _ in XCTFail("Unauthenticated request dispatched"); return .null }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let token = try String(contentsOf: dir.appendingPathComponent("token"), encoding: .utf8)
        let badToken = try rawHandshake(dir: dir, version: 1, token: "wrong-token")
        XCTAssertEqual(badToken["error"]?["code"], .string("UNAUTHORIZED"))
        let badVersion = try rawHandshake(dir: dir, version: 999, token: token)
        XCTAssertEqual(badVersion["error"]?["code"], .string("VERSION_MISMATCH"))
    }
    func testOversizedAndMalformedFramesNeverDispatch() throws {
        let dir = directory()
        let server = AgentIPCServer(directory: dir) { _, _, _ in XCTFail("Invalid frame dispatched"); return .null }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let oversized = try rawHandshake(dir: dir, version: 1, token: "unused", declaredLength: 65_537)
        XCTAssertEqual(oversized["error"]?["code"], .string("INVALID_ARGUMENT"))
        let malformed = try rawHandshake(dir: dir, version: 1, token: "unused", bodyOverride: Data("{broken".utf8))
        XCTAssertEqual(malformed["error"]?["code"], .string("INVALID_ARGUMENT"))
    }
    func testLiveOwnerCannotBeReplaced() async throws {
        let dir = directory()
        let first = AgentIPCServer(directory: dir) { _, _, _ in .string("original") }
        let second = AgentIPCServer(directory: dir) { _, _, _ in .string("replacement") }
        defer { first.stop(); second.stop(); try? FileManager.default.removeItem(at: dir) }
        try first.start()
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual(($0 as? AgentFailure)?.code, "ALREADY_RUNNING") }
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        let response = try await client.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(response, .string("original"))
        await client.disconnect()
    }
    func testStaleSocketReclaimed() async throws {
        let dir = directory()
        XCTAssertEqual(mkdir(dir.path, 0o700), 0)
        let stale = try boundSocket(dir)
        close(stale)
        let server = AgentIPCServer(directory: dir) { _, _, _ in .bool(true) }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        let result = try await client.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(result, .bool(true))
        await client.disconnect()
    }
    func testLiveSocketWithoutOwnerLockIsPreserved() throws {
        let dir = directory()
        XCTAssertEqual(mkdir(dir.path, 0o700), 0)
        let live = try boundSocket(dir)
        XCTAssertEqual(listen(live, 4), 0)
        let server = AgentIPCServer(directory: dir) { _, _, _ in .null }
        defer { close(live); server.stop(); try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual(($0 as? AgentFailure)?.code, "ALREADY_RUNNING") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bridge.sock").path))
    }
    func testToolFailureKeepsSessionUsable() async throws {
        let dir = directory()
        let server = AgentIPCServer(directory: dir) { session, tool, _ in
            if tool == "bad" { throw AgentFailure("UNAUTHORIZED", "Denied") }
            return .string(session)
        }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        let before = try await client.call(tool: "paperrss_status", arguments: [:])
        await expect("UNAUTHORIZED") { _ = try await client.call(tool: "bad", arguments: [:]) }
        let result = try await client.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(result, before)
        await client.disconnect()
    }
    func testDisconnectCanReconnectButShutdownIsPermanent() async throws {
        let dir = directory()
        let server = AgentIPCServer(directory: dir) { session, _, _ in .string(session) }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        let first = try await client.call(tool: "paperrss_status", arguments: [:])
        await client.disconnect()
        let second = try await client.call(tool: "paperrss_status", arguments: [:])
        XCTAssertNotEqual(first, second)
        async let firstShutdown: Void = client.shutdown()
        async let repeatedShutdown: Void = client.shutdown()
        _ = await (firstShutdown, repeatedShutdown)
        await client.disconnect()
        await expect("SESSION_CLOSED") { _ = try await client.call(tool: "paperrss_status", arguments: [:]) }
    }
    func testShutdownInterruptsHandshake() async throws {
        let dir = directory()
        XCTAssertEqual(mkdir(dir.path, 0o700), 0)
        let listener = try boundSocket(dir)
        defer { close(listener); try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(chmod(dir.appendingPathComponent("bridge.sock").path, 0o600), 0)
        XCTAssertEqual(listen(listener, 4), 0)
        let token = dir.appendingPathComponent("token")
        try Data("isolated-test-token".utf8).write(to: token)
        XCTAssertEqual(chmod(token.path, 0o600), 0)
        let accepted = XCTestExpectation(description: "Raw peer received handshake")
        let release = DispatchSemaphore(value: 0)
        let peerDone = XCTestExpectation(description: "Raw peer finished")
        DispatchQueue.global(qos: .utility).async {
            defer { peerDone.fulfill() }
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 3_000) > 0 else { return }
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer { close(peer) }
            var dataReady = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&dataReady, 1, 3_000) > 0 else { return }
            accepted.fulfill()
            // Deliberately never send the handshake reply. The client must wake
            // itself rather than waiting for the peer or its 15-second timeout.
            _ = release.wait(timeout: .now() + 5)
        }
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        let call = Task { try await client.call(tool: "paperrss_status", arguments: [:]) }
        await fulfillment(of: [accepted], timeout: 3)
        let stopped = XCTestExpectation(description: "Handshake shutdown completed")
        let start = ContinuousClock.now
        let shutdown = Task { await client.shutdown(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        release.signal()
        await shutdown.value
        do { _ = try await call.value; XCTFail("A stalled handshake cannot succeed") }
        catch { /* A closed handshake has no business operation to complete. */ }
        await expect("SESSION_CLOSED") { _ = try await client.call(tool: "paperrss_status", arguments: [:]) }
        await fulfillment(of: [peerDone], timeout: 3)
    }
    func testShutdownInterruptsResponseAndDoesNotDispatchQueuedCalls() async throws {
        let dir = directory()
        let gate = IPCRequestGate()
        let started = XCTestExpectation(description: "First request reached App")
        let server = AgentIPCServer(directory: dir) { _, _, _ in
            await gate.recordCall()
            started.fulfill()
            await gate.wait()
            return .object(["receipt": .string("already-owned-by-app")])
        }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        let first = Task { try await client.call(tool: "paperrss_status", arguments: [:]) }
        await fulfillment(of: [started], timeout: 3)
        let queued = Task { try await client.call(tool: "paperrss_status", arguments: [:]) }
        let stopped = XCTestExpectation(description: "Blocked response shutdown completed")
        let start = ContinuousClock.now
        let shutdown = Task { await client.shutdown(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        await gate.release()
        await shutdown.value
        do { _ = try await first.value; XCTFail("Closed response pipe must fail") }
        catch { /* Transport closure does not claim the App operation rolled back. */ }
        do { _ = try await queued.value; XCTFail("Queued request must not dispatch after shutdown") }
        catch { }
        let count = await gate.count
        XCTAssertEqual(count, 1)
        await expect("SESSION_CLOSED") { _ = try await client.call(tool: "paperrss_status", arguments: [:]) }
    }
    func testIndividualCancellationPreservesReceiptAndSession() async throws {
        let dir = directory()
        let gate = IPCRequestGate()
        let committing = XCTestExpectation(description: "App owns the in-flight operation")
        let server = AgentIPCServer(directory: dir) { session, tool, _ in
            if tool == "commit_fixture" {
                committing.fulfill()
                await gate.wait()
                return .object(["session": .string(session), "receipt": .string("committed")])
            }
            return .object(["session": .string(session)])
        }
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let client = AgentIPCClientBridge(enabled: true, directory: dir)
        let call = Task { try await client.call(tool: "commit_fixture", arguments: [:]) }
        await fulfillment(of: [committing], timeout: 3)
        call.cancel()
        await gate.release()
        let receipt = try await call.value
        XCTAssertEqual(receipt["receipt"], .string("committed"))
        let next = try await client.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(next["session"], receipt["session"])
        await client.shutdown()
    }
    func testHelperProductWithoutFixture() async throws {
        let helper = ProcessInfo.processInfo.environment["PAPERRSS_AGENT_TEST_HELPER_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/paperrss-agent")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AgentFailure("TEST_HELPER_MISSING", "Build paperrss-agent before product smoke, or set PAPERRSS_AGENT_TEST_HELPER_PATH")
        }
        let dir = directory()
        let labels = DiagnosticLabels()
        let server = AgentIPCServer(directory: dir, handler: { session, tool, _ in
            if tool == "paperrss_status" {
                return .object(["real_ipc": .bool(true), "fixture": .bool(false),
                                "client_label": await labels.value(session).map(AgentJSON.string) ?? .null])
            }
            if tool == "paperrss_list_feeds" { return .object(["feeds": .array([])]) }
            return .object(["articles": .array([])])
        }, connected: { session, label in await labels.set(session, label) })
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        try server.start()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = helper
        process.arguments = ["serve", "--stdio", "--client", "ipc-product-test"]
        var environment = ProcessInfo.processInfo.environment
        environment["PAPERRSS_AGENT_ENABLED"] = "1"
        environment["PAPERRSS_AGENT_SOCKET_DIR"] = dir.path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        defer { assertProductHelperExitAndCleanup(process, input: input.fileHandleForWriting) }
        func exchange(_ json: AgentJSON) throws -> AgentJSON {
            var bytes = try JSONEncoder().encode(json); bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
            var result = Data()
            let descriptor = output.fileHandleForReading.fileDescriptor
            while true {
                var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&state, 1, 5_000) > 0 else { throw AgentFailure("TEST_TIMEOUT", "Helper stdout timeout") }
                var byte: UInt8 = 0
                guard Darwin.read(descriptor, &byte, 1) == 1 else { throw AgentFailure("TEST_EOF", "Helper stopped") }
                if byte == 10 { break }
                result.append(byte)
            }
            return try JSONDecoder().decode(AgentJSON.self, from: result)
        }
        let initialized = try exchange(.object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-11-25"),
                "capabilities": .object([:]), "clientInfo": .object(["name": .string("ipc-test"), "version": .string("1")])])]))
        XCTAssertNotNil(initialized["result"])
        for (index, tool) in ["paperrss_status", "paperrss_list_feeds", "paperrss_list_articles"].enumerated() {
            var arguments: [String: AgentJSON] = tool == "paperrss_status" ? [:] : ["account_id": .string("test-local")]
            if tool == "paperrss_list_articles" { arguments["scope"] = .string("unread") }
            let result = try exchange(.object(["jsonrpc": .string("2.0"), "id": .number(Double(index + 2)),
                "method": .string("tools/call"), "params": .object(["name": .string(tool), "arguments": .object(arguments)])]))
            XCTAssertNotEqual(result["result"]?["isError"], .bool(true), "\(result)")
            XCTAssertNotNil(result["result"])
            if tool == "paperrss_status" {
                XCTAssertEqual(result["result"]?["structuredContent"]?["data"]?["real_ipc"], .bool(true))
                XCTAssertEqual(result["result"]?["structuredContent"]?["data"]?["client_label"], .string("ipc-product-test"))
            }
        }
    }
    private func assertProductHelperExitAndCleanup(_ process: Process, input: FileHandle,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        try? input.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(process.isRunning, "Helper PID \(process.processIdentifier) failed to exit naturally after EOF", file: file, line: line)
        if process.isRunning {
            process.terminate()
            let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            let killDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertFalse(process.isRunning, "Product helper PID \(process.processIdentifier) survived emergency cleanup", file: file, line: line)
        }
    }
    private func address(_ dir: URL) -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(dir.appendingPathComponent("bridge.sock").path.utf8) + [0]
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        return value
    }
    private func boundSocket(_ dir: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var value = address(dir)
        let result = withUnsafePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard result == 0 else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        return fd
    }
    private func rawHandshake(dir: URL, version: Int, token: String, declaredLength: Int? = nil, bodyOverride: Data? = nil) throws -> AgentJSON {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var value = address(dir)
        let result = withUnsafePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        let body = try bodyOverride ?? JSONEncoder().encode(AgentJSON.object(["version": .number(Double(version)), "token": .string(token)]))
        var size = UInt32(declaredLength ?? body.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(body)
        try frame.withUnsafeBytes { bytes in
            guard Darwin.write(fd, bytes.baseAddress!, bytes.count) == bytes.count else { throw POSIXError(.EIO) }
        }
        func readExactly(_ count: Int) throws -> Data {
            var bytes = Data(count: count)
            try bytes.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < count {
                    let got = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                    guard got > 0 else { throw POSIXError(.EIO) }
                    offset += got
                }
            }
            return bytes
        }
        let count = try readExactly(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count < 65_536 else { throw POSIXError(.EIO) }
        return try JSONDecoder().decode(AgentJSON.self, from: readExactly(count))
    }
}

private actor DiagnosticLabels {
    private var labels: [String: String] = [:]
    func set(_ session: String, _ label: String?) { labels[session] = label }
    func value(_ session: String) -> String? { labels[session] }
}

private actor IPCRequestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    func recordCall() { count += 1 }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
