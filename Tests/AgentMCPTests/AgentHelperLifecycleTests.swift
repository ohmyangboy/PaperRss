import XCTest
import Foundation
import Darwin
import PaperRssAgentProtocol

/// These tests launch only synthetic helpers and private socket fixtures. A process
/// must exit by itself before cleanup is allowed to send it a termination signal.
final class AgentHelperLifecycleTests: XCTestCase, @unchecked Sendable {
    func testEOFBeforeInitializeExitsNaturally() throws {
        let helper = try LifecycleHelper()
        defer { helper.cleanup() }
        helper.closeInput()
        guard helper.assertExited() else { return }
        XCTAssertEqual(helper.process.terminationStatus, 0)
    }

    func testEOFAfterInitializeExitsNaturally() throws {
        let helper = try LifecycleHelper()
        defer { helper.cleanup() }
        try helper.initialize()
        helper.closeInput()
        guard helper.assertExited() else { return }
        XCTAssertEqual(helper.process.terminationStatus, 0)
    }

    func testInitializedIdleConnectionRemainsUsableBeyondShutdownDeadline() async throws {
        let helper = try LifecycleHelper()
        defer { helper.cleanup() }
        try helper.initialize()
        try await Task.sleep(nanoseconds: 2_200_000_000)
        guard helper.process.isRunning else {
            XCTFail("A healthy idle connection must not be ended by the shutdown watchdog")
            return
        }
        try helper.send(.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("ping")]))
        XCTAssertNotNil(try helper.readResponse()["result"])
        helper.closeInput()
        helper.assertExited()
    }

    func testInvalidStdinAtStartupExitsWithTransportError() throws {
        // exec preserves the missing fd 0. The helper must validate stdio before
        // allocating its wake pipe, which could otherwise reuse descriptor zero.
        let script = #"""
import os, sys
os.close(0)
os.execv(sys.argv[1], [sys.argv[1], 'serve', '--stdio', '--fixture'])
"""#
        let helper = try LifecycleHelper(launcherScript: script)
        defer { helper.cleanup() }
        guard helper.assertExited(message: "An invalid stdin descriptor did not stop startup") else { return }
        XCTAssertEqual(helper.process.terminationReason, .exit)
        XCTAssertEqual(helper.process.terminationStatus, 1)
    }

    func testEOFClosesRealIPCSession() async throws {
        let directory = privateDirectory()
        let disconnected = expectation(description: "EOF revoked the isolated IPC session")
        let server = AgentIPCServer(directory: directory, handler: { _, _, _ in .object(["fixture": .bool(true)]) },
                                    disconnected: { _ in disconnected.fulfill() })
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start()
        let helper = try LifecycleHelper(directory: directory)
        defer { helper.cleanup() }
        try helper.initialize()
        XCTAssertNotEqual(try helper.status()["result"]?["isError"], .bool(true))
        helper.closeInput()
        helper.assertExited()
        await fulfillment(of: [disconnected], timeout: 3)
    }

    func testEOFDuringBlockedIPCExitsWithinDeadline() async throws {
        let directory = privateDirectory()
        let received = expectation(description: "Isolated App received the request")
        let gate = LifecycleGate()
        let server = AgentIPCServer(directory: directory) { _, _, _ in
            received.fulfill()
            await gate.wait()
            return .object(["completed": .bool(true)])
        }
        defer {
            Task { await gate.open() }
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try server.start()
        let helper = try LifecycleHelper(directory: directory)
        defer { helper.cleanup() }
        try helper.initialize()
        try helper.send(LifecycleHelper.toolRequest(id: 2, name: "paperrss_status"))
        await fulfillment(of: [received], timeout: 3)
        helper.closeInput()
        helper.assertExited()
        await gate.open()
    }

    func testTerminationSignalsExitWhileInputRemainsOpen() throws {
        for signal in [SIGTERM, SIGINT] {
            let helper = try LifecycleHelper()
            defer { helper.cleanup() }
            try helper.initialize()
            XCTAssertEqual(kill(helper.process.processIdentifier, signal), 0)
            if helper.assertExited(message: "Signal \(signal) did not stop the helper") {
                XCTAssertEqual(helper.process.terminationReason, .exit, "Signal must use the unified shutdown path")
                XCTAssertEqual(helper.process.terminationStatus, 128 + signal)
            }
        }
    }

    func testClosedStdoutStopsHelperWithoutSIGPIPE() throws {
        let helper = try LifecycleHelper()
        defer { helper.cleanup() }
        try helper.initialize()
        try helper.output.fileHandleForReading.close()
        try helper.send(.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("ping")]))
        guard helper.assertExited(message: "Closed stdout did not stop the helper while stdin stayed open") else { return }
        XCTAssertEqual(helper.process.terminationReason, .exit, "EPIPE must be handled instead of an accidental SIGPIPE")
        XCTAssertNotEqual(helper.process.terminationStatus, 0)
    }

    func testEOFWithUnreadStdoutDoesNotBlockShutdown() throws {
        let helper = try LifecycleHelper()
        defer { helper.cleanup() }
        try helper.initialize()
        // The catalog is much larger than a ping. These responses exceed pipe
        // capacity while the host deliberately stops consuming stdout.
        for id in 2...97 {
            try helper.send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/list")]))
        }
        XCTAssertTrue(helper.waitForOutput(), "Expected queued responses before testing backpressure")
        Thread.sleep(forTimeInterval: 0.1)
        helper.closeInput()
        helper.assertExited(message: "Unread stdout blocked EOF shutdown")
    }

    func testFullStderrDoesNotBlockStartupOrShutdown() throws {
        let helper = try LifecycleHelper(fillStderr: true)
        defer { helper.cleanup() }
        try helper.initialize()
        helper.closeInput()
        helper.assertExited(message: "A full diagnostic pipe blocked shutdown")
    }

    func testClosingOneHelperKeepsOtherSessionUsable() throws {
        let directory = privateDirectory()
        let server = AgentIPCServer(directory: directory) { session, _, _ in .object(["session": .string(session)]) }
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        try server.start()
        let first = try LifecycleHelper(directory: directory)
        defer { first.cleanup() }
        let second = try LifecycleHelper(directory: directory)
        defer { second.cleanup() }
        try first.initialize(); try second.initialize()
        let firstSession = try first.status()["result"]?["structuredContent"]?["data"]?["session"]
        let secondSession = try second.status()["result"]?["structuredContent"]?["data"]?["session"]
        XCTAssertNotNil(firstSession)
        XCTAssertNotNil(secondSession)
        XCTAssertNotEqual(firstSession, secondSession)
        first.closeInput()
        first.assertExited()
        XCTAssertTrue(second.process.isRunning)
        XCTAssertEqual(try second.status(id: 3)["result"]?["structuredContent"]?["data"]?["session"], secondSession)
        second.closeInput()
        second.assertExited()
    }

    func testParentExitStopsHelperEvenWhenStdinWriterIsRetained() throws {
        // XCTest retains stdin's write end after this launcher dies, so EOF alone
        // cannot terminate the helper. No unrelated application is involved.
        let script = #"""
import json, os, subprocess, sys
child = subprocess.Popen([sys.argv[1], 'serve', '--stdio', '--fixture', '--client', 'lifecycle-parent-test'],
                         stdin=sys.stdin.buffer, stdout=sys.stdout.buffer, stderr=sys.stderr.buffer, env=os.environ)
print(json.dumps({'helper_pid': child.pid}), flush=True)
child.wait()
"""#
        let launcher = try LifecycleHelper(launcherScript: script)
        defer { launcher.cleanup() }
        let header = try launcher.readResponse()
        let helperPID = try XCTUnwrap(header["helper_pid"]?.intValue).asPID()
        var observedExit = false
        defer {
            // This PID belongs to the helper created above, never a user's helper.
            if !observedExit {
                _ = kill(helperPID, SIGTERM)
                Thread.sleep(forTimeInterval: 0.05)
                _ = kill(helperPID, SIGKILL)
            }
        }
        try launcher.initialize()
        let exited = DispatchSemaphore(value: 0)
        let observer = DispatchSource.makeProcessSource(identifier: helperPID, eventMask: .exit, queue: .global(qos: .utility))
        observer.setEventHandler { exited.signal() }
        observer.resume()
        defer { observer.cancel() }
        launcher.process.terminate()
        launcher.assertExited(message: "Test launcher failed to terminate")
        observedExit = exited.wait(timeout: .now() + 3) == .success
        XCTAssertTrue(observedExit, "Helper \(helperPID) survived its parent while stdin remained open")
    }

    private func privateDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/pr-life-\(UUID().uuidString.prefix(12))", isDirectory: true)
    }
}

private actor LifecycleGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

private extension Int {
    func asPID() throws -> pid_t {
        guard let pid = pid_t(exactly: self), pid > 0 else {
            throw AgentFailure("TEST_INVALID_PID", "Launcher returned an invalid helper PID")
        }
        return pid
    }
}

private final class LifecycleHelper {
    let process = Process()
    let input = Pipe(), output = Pipe(), errors = Pipe()
    private var inputClosed = false

    init(directory: URL? = nil, fillStderr: Bool = false, launcherScript: String? = nil) throws {
        let helper = ProcessInfo.processInfo.environment["PAPERRSS_AGENT_TEST_HELPER_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/paperrss-agent")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AgentFailure("TEST_HELPER_MISSING", "Build paperrss-agent before lifecycle tests, or set PAPERRSS_AGENT_TEST_HELPER_PATH")
        }
        if let launcherScript {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "-c", launcherScript, helper.path]
        } else {
            process.executableURL = helper
            process.arguments = ["serve", "--stdio", "--client", "lifecycle-test"] + (directory == nil ? ["--fixture"] : [])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PAPERRSS_AGENT_ENABLED"] = "1"
        environment.removeValue(forKey: "PAPERRSS_AGENT_SOCKET_DIR")
        if let directory { environment["PAPERRSS_AGENT_SOCKET_DIR"] = directory.path }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        if fillStderr { try prefillDiagnosticPipe() }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }

    func initialize() throws {
        try send(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("lifecycle-test"), "version": .string("1")])])]))
        let response = try readResponse()
        XCTAssertNotNil(response["result"], "Helper failed to initialize: \(response)")
    }

    static func toolRequest(id: Int, name: String) -> AgentJSON {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
                 "params": .object(["name": .string(name), "arguments": .object([:])])])
    }

    func status(id: Int = 2) throws -> AgentJSON {
        try send(Self.toolRequest(id: id, name: "paperrss_status"))
        return try readResponse()
    }

    func send(_ request: AgentJSON) throws {
        var frame = try JSONEncoder().encode(request)
        frame.append(10)
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func waitForOutput() -> Bool {
        var state = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        return poll(&state, 1, 3_000) > 0 && state.revents & Int16(POLLIN) != 0
    }

    func readResponse() throws -> AgentJSON {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var frame = Data()
        let fd = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline {
            let milliseconds = Int32(max(1, (deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
            var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&state, 1, milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else {
                throw AgentFailure("TEST_EOF", "Helper stdout closed before a response")
            }
            if byte == 10 { return try JSONDecoder().decode(AgentJSON.self, from: frame) }
            frame.append(byte)
        }
        throw AgentFailure("TEST_TIMEOUT", "Helper response exceeded three seconds")
    }

    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        try? input.fileHandleForWriting.close()
    }

    @discardableResult
    func assertExited(message: String = "Helper did not exit naturally within three seconds",
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(process.isRunning, "\(message) (PID \(process.processIdentifier))", file: file, line: line)
        return !process.isRunning
    }

    func cleanup() {
        closeInput()
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            let killDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertFalse(process.isRunning, "Test helper PID \(process.processIdentifier) survived emergency cleanup")
        }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    private func prefillDiagnosticPipe() throws {
        let fd = errors.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let bytes = [UInt8](repeating: 120, count: 4_096)
        var total = 0
        while total < 1_048_576 {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            guard count > 0 else { throw POSIXError(.EIO) }
            total += count
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(total, 1_048_576, "Test requires a full stderr pipe")
    }
}
