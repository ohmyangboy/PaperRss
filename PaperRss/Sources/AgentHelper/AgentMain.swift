import Foundation
import Darwin
#if !PAPERRSS_AGENT_NATIVE
import PaperRssAgentProtocol
#endif
#if !PAPERRSS_AGENT_NATIVE
import PaperRssAgentMCP
#endif

@main
enum PaperRssAgentMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--version"] {
            print("paperrss-agent 0.1.0-spike")
            return
        }
        guard args.starts(with: ["serve", "--stdio"]), validOptions(Array(args.dropFirst(2))) else {
            diagnostic("Usage: paperrss-agent serve --stdio [--client LABEL] [--fixture]\n")
            exit(2)
        }
        let enabled = ProcessInfo.processInfo.environment["PAPERRSS_AGENT_ENABLED"] == "1"
        let directory = ProcessInfo.processInfo.environment["PAPERRSS_AGENT_SOCKET_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AgentIPCPaths.defaultDirectory
        let clientLabel = args.firstIndex(of: "--client").map { args[$0 + 1] }
        let bridge: any AgentBridge = args.contains("--fixture")
            ? AgentFixtureBridge(enabled: enabled) : AgentIPCClientBridge(enabled: enabled, directory: directory, clientLabel: clientLabel)
        // --client is a diagnostic label only, never an authentication identity.
        let server = AgentMCPServer(bridge: bridge)
        do {
            let transport = try StdioTransport(server: server)
            let reason = await transport.run()
            await server.shutdown()
            // Do not wait for unrelated Swift tasks or attempt a blocking stdio flush.
            // The peer has disconnected; the OS releases the helper's descriptors.
            _exit(reason.exitCode)
        } catch {
            diagnostic("paperrss-agent pid=\(getpid()) ppid=\(getppid()) event=stop reason=stdio_setup_error\n")
            _exit(1)
        }
    }

    private static func validOptions(_ args: [String]) -> Bool {
        var index = 0, fixture = false, client = false
        while index < args.count {
            switch args[index] {
            case "--fixture" where !fixture:
                fixture = true
                index += 1
            case "--client" where !client:
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--"),
                      !args[index + 1].isEmpty, args[index + 1].utf8.count <= 128 else { return false }
                client = true
                index += 2
            default: return false
            }
        }
        return true
    }

    private static func diagnostic(_ text: String) {
        StdioTransport.diagnostic(text)
    }
}

/// A single bounded stdio connection. A native EOF filter remains active even
/// when request slots are occupied or the peer has stopped consuming responses.
/// Only this pump writes stdout; all termination sources use the private wake pipe.
private final class StdioTransport: @unchecked Sendable {
    enum StopReason: String, Sendable {
        case eof = "stdin_eof", parent = "parent_exit", terminate = "sigterm", interrupt = "sigint"
        case input = "stdin_error", output = "stdout_error"
        var exitCode: Int32 {
            switch self {
            case .eof, .parent: 0
            case .terminate: 128 + SIGTERM
            case .interrupt: 128 + SIGINT
            case .input, .output: 1
            }
        }
    }

    private let server: AgentMCPServer
    private let parentPID = getppid()
    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "PaperRss.Agent.lifecycle", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "PaperRss.Agent.stdio", qos: .utility)
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let inputEvents: Int32
    private var parentSource: DispatchSourceProcess?
    private var signalSources: [DispatchSourceSignal] = []
    // Protected by lock; completed responses retain a request slot until written.
    private var reason: StopReason?
    private var outstanding = 0
    private var responses: [Data] = []

    init(server: AgentMCPServer) throws {
        self.server = server
        // Validate before pipe() can reuse an invalid stdin/stdout descriptor.
        for fd in [STDIN_FILENO, STDOUT_FILENO] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        wakeRead = descriptors[0]; wakeWrite = descriptors[1]
        var info = stat()
        let stream = fstat(STDIN_FILENO, &info) == 0 &&
            (info.st_mode & S_IFMT == S_IFIFO || info.st_mode & S_IFMT == S_IFSOCK)
        inputEvents = stream ? kqueue() : -1
        do {
            if stream {
                guard inputEvents >= 0 else { throw POSIXError(.EIO) }
                _ = fcntl(inputEvents, F_SETFD, FD_CLOEXEC)
                var event = kevent(ident: UInt(STDIN_FILENO), filter: Int16(EVFILT_READ),
                    flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR), fflags: 0, data: 0, udata: nil)
                guard kevent(inputEvents, &event, 1, nil, 0, nil) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            for fd in [wakeRead, wakeWrite] {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            _ = fcntl(wakeRead, F_SETFD, FD_CLOEXEC)
            _ = fcntl(wakeWrite, F_SETFD, FD_CLOEXEC)
        } catch {
            close(wakeRead); close(wakeWrite)
            if inputEvents >= 0 { close(inputEvents) }
            throw error
        }
    }

    func run() async -> StopReason {
        // Convert broken stdout into an ordinary write error, not an unexpected signal death.
        signal(SIGPIPE, SIG_IGN)
        for (number, stopReason) in [(SIGTERM, StopReason.terminate), (SIGINT, .interrupt)] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: controlQueue)
            source.setEventHandler { [weak self] in self?.stop(stopReason) }
            signalSources.append(source)
            source.resume()
        }
        let parent = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: controlQueue)
        parent.setEventHandler { [weak self] in self?.stop(.parent) }
        parentSource = parent
        parent.resume()
        Self.diagnostic("paperrss-agent pid=\(getpid()) ppid=\(parentPID) event=start\n")
        // Close the race where the parent exited before the dispatch source was installed.
        if parentPID <= 1 || getppid() != parentPID { stop(.parent) }
        return await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: self.pump()) }
        }
    }

    private func stop(_ stopReason: StopReason) {
        lock.lock()
        guard reason == nil else { lock.unlock(); return }
        reason = stopReason
        lock.unlock()
        // Schedule before actor cleanup or diagnostics. Neither blocked tasks nor a full
        // stderr pipe may prevent this deadline from being armed or extend it later.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {
            _exit(stopReason.exitCode)
        }
        wake()
        Self.diagnostic("paperrss-agent pid=\(getpid()) ppid=\(parentPID) event=stop reason=\(stopReason.rawValue)\n")
        Task { await server.shutdown() }
    }

    private var stopReason: StopReason? { lock.withLock { reason } }
    private var hasCapacity: Bool { lock.withLock { reason == nil && outstanding < 32 } }

    private func submit(_ request: Data) {
        lock.lock()
        guard reason == nil else { lock.unlock(); return }
        outstanding += 1
        lock.unlock()
        Task {
            let response = await server.handle(data: request)
            lock.withLock {
                if reason == nil, var response {
                    response.append(10)
                    responses.append(response)
                } else { outstanding -= 1 }
            }
            wake()
        }
    }

    private func wake() {
        var byte: UInt8 = 1
        // EAGAIN means a wake is already pending. The pipe is never closed during run.
        while Darwin.write(wakeWrite, &byte, 1) < 0 && errno == EINTR {}
    }

    private func observeInputEOF() {
        var event = kevent(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            let count = kevent(inputEvents, nil, 0, &event, 1, &timeout)
            if count < 0 && errno == EINTR { continue }
            if count < 0 || (count > 0 && event.flags & UInt16(EV_ERROR) != 0) { stop(.input); return }
            guard count > 0 else { return }
            if event.flags & UInt16(EV_EOF) != 0 { stop(.eof); return }
        }
    }

    private func pump() -> StopReason {
        var line = Data(), buffered = [UInt8](), position = 0, droppingOversize = false
        var readBuffer = [UInt8](repeating: 0, count: 4_096)
        var output: Data?, outputOffset = 0
        while stopReason == nil {
            while position < buffered.count && hasCapacity {
                let byte = buffered[position]
                position += 1
                if byte == 10 {
                    if droppingOversize {
                        submit(Data(repeating: 32, count: AgentMCPServer.maximumRequestBytes + 1))
                    } else if !line.isEmpty { submit(line) }
                    line.removeAll(keepingCapacity: true)
                    droppingOversize = false
                } else if !droppingOversize {
                    if line.count >= AgentMCPServer.maximumRequestBytes {
                        droppingOversize = true
                        line.removeAll(keepingCapacity: true)
                    } else { line.append(byte) }
                }
            }
            if position == buffered.count { buffered.removeAll(keepingCapacity: true); position = 0 }
            if output == nil {
                output = lock.withLock { responses.isEmpty ? nil : responses.removeFirst() }
                outputOffset = 0
            }
            // Darwin poll may hide pipe HUP while unread bytes remain. The separate
            // EV_EOF filter sees the last writer close without draining those bytes.
            let readEnabled = buffered.isEmpty && hasCapacity
            var descriptors = [
                pollfd(fd: STDIN_FILENO, events: readEnabled ? Int16(POLLIN) : 0, revents: 0),
                pollfd(fd: STDOUT_FILENO, events: output == nil ? 0 : Int16(POLLOUT), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputEvents, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&descriptors, nfds_t(descriptors.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                stop(.input); break
            }
            if descriptors[2].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 256)
                while Darwin.read(wakeRead, &bytes, bytes.count) > 0 {}
            }
            if descriptors[3].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { stop(.input) }
            else if descriptors[3].revents & Int16(POLLIN) != 0 { observeInputEOF() }
            guard stopReason == nil else { break }
            let inputEvents = descriptors[0].revents, outputEvents = descriptors[1].revents
            if inputEvents & Int16(POLLNVAL | POLLERR) != 0 { stop(.input); break }
            if outputEvents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 { stop(.output); break }
            if inputEvents & Int16(POLLHUP) != 0 { stop(.eof); break }
            if inputEvents & Int16(POLLIN) != 0 && readEnabled {
                let count = Darwin.read(STDIN_FILENO, &readBuffer, readBuffer.count)
                if count == 0 { stop(.eof); break }
                if count > 0 { buffered = Array(readBuffer.prefix(count)) }
                else if errno != EINTR && errno != EAGAIN { stop(.input); break }
            }
            if outputEvents & Int16(POLLOUT) != 0, let frame = output {
                let count = frame.withUnsafeBytes { raw in
                    Darwin.write(STDOUT_FILENO, raw.baseAddress!.advanced(by: outputOffset), min(65_536, raw.count - outputOffset))
                }
                if count > 0 {
                    outputOffset += count
                    if outputOffset == frame.count {
                        output = nil
                        lock.withLock { outstanding -= 1 }
                    }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) { stop(.output); break }
            }
        }
        parentSource?.cancel()
        for source in signalSources { source.cancel() }
        return stopReason ?? .input
    }

    static func diagnostic(_ text: String) {
        let flags = fcntl(STDERR_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        let data = Data(text.utf8)
        data.withUnsafeBytes { raw in _ = Darwin.write(STDERR_FILENO, raw.baseAddress, raw.count) }
    }

    deinit {
        close(wakeRead)
        close(wakeWrite)
        if inputEvents >= 0 { close(inputEvents) }
    }
}
