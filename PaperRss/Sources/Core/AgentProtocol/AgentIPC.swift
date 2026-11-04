#if os(macOS)
import Foundation
import Darwin

public enum AgentIPCPaths {
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: "/tmp/paperrss-agent-\(getuid())", isDirectory: true)
    }
}

private enum IPC {
    static let version = 1
    static let maximumFrame = 1_048_576
    static func failure(_ message: String) -> AgentFailure { AgentFailure("APP_NOT_RUNNING", message) }
    static func secureDirectory(_ directory: URL, create: Bool) throws {
        if create && mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw failure("Cannot create private IPC directory.")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw failure("PaperRss has no local bridge.") }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw AgentFailure("UNAUTHORIZED", "IPC directory must be owned by the current user with mode 0700.")
        }
    }
    static func file(_ url: URL, create: Bool = false) throws -> Int32 {
        let fd = open(url.path, (create ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("App bridge credentials are unavailable.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
            close(fd)
            throw AgentFailure("UNAUTHORIZED", "Unsafe IPC credential or owner file.")
        }
        return fd
    }
    static func writeFile(_ url: URL, _ text: String) throws {
        let fd = try file(url, create: true)
        defer { close(fd) }
        guard ftruncate(fd, 0) == 0 else { throw failure("Cannot update bridge state.") }
        try write(fd, Data(text.utf8))
    }
    static func readFile(_ url: URL) throws -> String {
        let fd = try file(url)
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count < bytes.count, let text = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            throw failure("Invalid bridge state.")
        }
        return text
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw AgentFailure("INVALID_ARGUMENT", "IPC socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func configure(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func peer(_ fd: Int32) throws {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw AgentFailure("UNAUTHORIZED", "IPC peer must belong to the current user.")
        }
    }
    /// The client registers the descriptor before connecting so shutdown can reach
    /// it during the handshake. A nonblocking connect also covers shutdown before
    /// connect begins, when shutdown(2) on an unconnected socket cannot wake it.
    static func connect(_ fd: Int32, to path: String, checkOpen: () throws -> Void) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw failure("Cannot configure local connection.")
        }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        try checkOpen()
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EALREADY || errno == EWOULDBLOCK else {
                throw failure("Open PaperRss with Agent MCP enabled.")
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
            while true {
                try checkOpen()
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw failure("App connection closed or timed out.")
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw failure("Cannot connect to App bridge.") }
                if ready == 0 { continue }
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw failure("Open PaperRss with Agent MCP enabled.")
                }
                break
            }
        }
        try checkOpen()
        try peer(fd)
    }
    static func write(_ fd: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("App connection closed or timed out.") }
                offset += count
            }
        }
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let size = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw failure("App connection closed or timed out.") }
                offset += size
            }
        }
        return bytes
    }
    static func send(_ fd: Int32, _ json: AgentJSON) throws {
        let bytes = try JSONEncoder().encode(json)
        guard bytes.count <= maximumFrame else { throw AgentFailure("INVALID_ARGUMENT", "IPC response exceeds frame limit.") }
        var length = UInt32(bytes.count).bigEndian
        try withUnsafeBytes(of: &length) { try write(fd, Data($0)) }
        try write(fd, bytes)
    }
    static func receive(_ fd: Int32, maximum: Int = maximumFrame) throws -> AgentJSON {
        let header = try read(fd, count: 4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maximum else { throw AgentFailure("INVALID_ARGUMENT", "IPC frame exceeds limit.") }
        let body = try read(fd, count: size)
        do { return try JSONDecoder().decode(AgentJSON.self, from: body) }
        catch { throw AgentFailure("INVALID_ARGUMENT", "Malformed IPC JSON frame.") }
    }
    static func error(_ error: Error) -> AgentJSON {
        let failure = error as? AgentFailure ?? AgentFailure("INTERNAL_ERROR", "App bridge request failed.")
        return .object(["error": .object(["code": .string(failure.code), "message": .string(failure.message)])])
    }
    static func checked(_ response: AgentJSON) throws -> AgentJSON {
        if let error = response["error"], let code = error["code"]?.stringValue {
            throw AgentFailure(code, error["message"]?.stringValue ?? "App bridge rejected the request.")
        }
        return response
    }
    static func disabledOwner(_ directory: URL) -> Bool {
        guard let fd = try? file(directory.appendingPathComponent("owner")) else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) != 0 else { flock(fd, LOCK_UN); return false }
        return (try? readFile(directory.appendingPathComponent("state"))) == "disabled"
    }
}

/// App-owned listener. The owner lock survives disable, permitting an honest NOT_ENABLED
/// response without leaving a data listener open. No library or credential dependency.
public final class AgentIPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String, String, [String: AgentJSON]) async throws -> AgentJSON
    private let directory: URL
    private let handler: Handler
    private let connected: @Sendable (String, String?) async -> Void
    private let disconnected: @Sendable (String) async -> Void
    private let lock = NSRecursiveLock()
    private let acceptQueue = DispatchQueue(label: "PaperRss.AgentIPC.accept")
    private var owner: Int32 = -1
    private var listener: DispatchSourceRead?
    private var clients: Set<Int32> = []
    private var token = ""
    private var instance = ""
    public init(directory: URL = AgentIPCPaths.defaultDirectory, handler: @escaping Handler,
                connected: @escaping @Sendable (String, String?) async -> Void = { _, _ in },
                disconnected: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.directory = directory; self.handler = handler; self.connected = connected; self.disconnected = disconnected
    }
    public func start(enabled: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        if owner >= 0 { try setEnabled(enabled); return }
        try IPC.secureDirectory(directory, create: true)
        let fd = try IPC.file(directory.appendingPathComponent("owner"), create: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw AgentFailure("ALREADY_RUNNING", "Another PaperRss instance owns the bridge.")
        }
        owner = fd
        do {
            try cleanStaleSocket()
            try setEnabled(enabled)
        } catch { stop(); throw error }
    }
    private func cleanStaleSocket() throws {
        let path = directory.appendingPathComponent("bridge.sock").path
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw AgentFailure("UNAUTHORIZED", "Refusing to replace unsafe socket path.")
        }
        // Nonblocking probe: only ECONNREFUSED proves a stale endpoint. A live
        // backlog, pending connection or other error must never justify unlinking.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw IPC.failure("Cannot inspect stale socket.") }
        defer { close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else {
            throw IPC.failure("Cannot inspect socket without blocking.")
        }
        var address = try IPC.address(path)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard result < 0, errno == ECONNREFUSED else { throw AgentFailure("ALREADY_RUNNING", "Socket owner could not be excluded.") }
        guard unlink(path) == 0 else { throw IPC.failure("Cannot remove stale socket.") }
    }
    public func setEnabled(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard owner >= 0 else { throw IPC.failure("Bridge owner is not started.") }
        if !enabled {
            // Revocation must close data access even if the diagnostic marker cannot be written.
            defer { closeListener(); unlink(directory.appendingPathComponent("token").path) }
            try IPC.writeFile(directory.appendingPathComponent("state"), "disabled")
            return
        }
        guard listener == nil else { return }
        try cleanStaleSocket()
        token = UUID().uuidString + UUID().uuidString
        instance = UUID().uuidString
        var succeeded = false, tokenWritten = false, boundSocket = false
        defer {
            if !succeeded {
                if boundSocket { unlink(directory.appendingPathComponent("bridge.sock").path) }
                if tokenWritten { unlink(directory.appendingPathComponent("token").path) }
                token = ""; instance = ""
            }
        }
        try IPC.writeFile(directory.appendingPathComponent("token"), token)
        tokenWritten = true
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPC.failure("Cannot create listener.") }
        defer { if !succeeded { close(fd) } }
        var address = try IPC.address(directory.appendingPathComponent("bridge.sock").path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        boundSocket = bound == 0
        guard bound == 0, chmod(directory.appendingPathComponent("bridge.sock").path, 0o600) == 0,
              listen(fd, 16) == 0 else { throw IPC.failure("Cannot bind private listener.") }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        try IPC.writeFile(directory.appendingPathComponent("state"), "enabled")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        succeeded = true
        source.resume()
    }
    private func acceptConnections(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard listener?.handle == UInt(fd) else { return }
        // Bound lock hold time even if another same-user process floods connections.
        for _ in 0..<64 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard clients.count < 32 else { close(client); continue }
            IPC.configure(client)
            do { try IPC.peer(client) } catch { close(client); continue }
            clients.insert(client)
            let token = token, instance = instance
            Task.detached { [self] in await serve(client, token: token, instance: instance) }
        }
    }
    private func io<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result { try body() }) }
        }
    }
    private func serve(_ fd: Int32, token: String, instance: String) async {
        let session = UUID().uuidString
        do {
            let hello = try await io { try IPC.receive(fd, maximum: 65_536) }
            guard hello["version"]?.intValue == IPC.version else { throw AgentFailure("VERSION_MISMATCH", "IPC protocol version is incompatible.") }
            guard hello["token"]?.stringValue == token else { throw AgentFailure("UNAUTHORIZED", "IPC token does not match this App instance.") }
            // Self-reported diagnostics never participate in authentication or authorization.
            let label = hello["client_label"]?.stringValue
            guard hello["client_label"] == nil || (label.map { !$0.isEmpty && $0.utf8.count <= 128 } == true) else {
                throw AgentFailure("INVALID_ARGUMENT", "Invalid diagnostic client label.")
            }
            await connected(session, label)
            try await io { try IPC.send(fd, .object(["version": .number(Double(IPC.version)), "instance_id": .string(instance)])) }
            while true {
                // Do not expire grants merely because a user is idle. Once a frame begins,
                // SO_RCVTIMEO bounds a stalled sender; shutdown wakes poll on disable.
                let request = try await io {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    var ready: Int32
                    repeat { ready = poll(&descriptor, 1, -1) } while ready < 0 && errno == EINTR
                    guard ready > 0 else { throw IPC.failure("App connection closed.") }
                    return try IPC.receive(fd, maximum: 65_536)
                }
                guard let tool = request["tool"]?.stringValue, let arguments = request["arguments"]?.objectValue else {
                    throw AgentFailure("INVALID_ARGUMENT", "Invalid IPC request.")
                }
                let response: AgentJSON
                do { response = .object(["result": try await handler(session, tool, arguments)]) }
                catch { response = IPC.error(error) }
                try await io { try IPC.send(fd, response) }
            }
        } catch { try? await io { try IPC.send(fd, IPC.error(error)) } }
        removeClient(fd)
        await disconnected(session)
    }
    private func removeClient(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        clients.remove(fd)
        close(fd)
    }
    private func closeListener() {
        guard let source = listener else { return }
        listener = nil
        source.cancel()
        for client in clients { shutdown(client, SHUT_RDWR) }
        unlink(directory.appendingPathComponent("bridge.sock").path)
        unlink(directory.appendingPathComponent("token").path)
        token = ""; instance = ""
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard owner >= 0 else { return }
        closeListener()
        unlink(directory.appendingPathComponent("state").path)
        flock(owner, LOCK_UN); close(owner); owner = -1
    }
    deinit { stop() }
}

/// Each helper owns one serialized authenticated connection; no database is opened.
public final class AgentIPCClientBridge: AgentBridge, @unchecked Sendable {
    private let enabled: Bool
    private let directory: URL
    private let clientLabel: String?
    private let queue = DispatchQueue(label: "PaperRss.AgentIPC.client")
    // Only queue closes sockets. This short lock protects publication, shutdown,
    // and close together so an externally initiated shutdown cannot hit a reused fd.
    private let stateLock = NSLock()
    private var closing = false
    private var fd: Int32 = -1
    public init(enabled: Bool = false, directory: URL = AgentIPCPaths.defaultDirectory, clientLabel: String? = nil) {
        self.enabled = enabled; self.directory = directory; self.clientLabel = clientLabel
    }
    public func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        try checkOpen()
        guard enabled else { throw AgentFailure("NOT_ENABLED", "Set PAPERRSS_AGENT_ENABLED=1 in the helper configuration.") }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    try checkOpen()
                    let response: AgentJSON
                    do {
                        let socket = try connectIfNeeded()
                        try checkOpen()
                        try IPC.send(socket, .object(["tool": .string(tool), "arguments": .object(arguments)]))
                        response = try IPC.receive(socket)
                    } catch {
                        closeConnection()
                        if IPC.disabledOwner(directory) { throw AgentFailure("NOT_ENABLED", "Agent MCP is disabled in the running PaperRss App.") }
                        throw error
                    }
                    // A response may carry an already committed write receipt.
                    // Never turn it into cancellation/closure after receiving it.
                    let checked = try IPC.checked(response)
                    guard let result = checked["result"] else { throw IPC.failure("Invalid App response.") }
                    return result
                })
            }
        }
    }
    private func checkOpen() throws {
        guard stateLock.withLock({ !closing }) else {
            throw AgentFailure("SESSION_CLOSED", "Helper session has shut down.")
        }
    }
    private func connectIfNeeded() throws -> Int32 {
        try checkOpen()
        let existing = stateLock.withLock { fd }
        if existing >= 0 { return existing }
        try IPC.secureDirectory(directory, create: false)
        if IPC.disabledOwner(directory) { throw AgentFailure("NOT_ENABLED", "Agent MCP is disabled in the running PaperRss App.") }
        let token = try IPC.readFile(directory.appendingPathComponent("token"))
        var socketInfo = stat()
        guard lstat(directory.appendingPathComponent("bridge.sock").path, &socketInfo) == 0 else {
            throw IPC.failure("PaperRss has no active listener.")
        }
        guard socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_uid == getuid(),
              socketInfo.st_mode & 0o777 == 0o600 else {
            throw AgentFailure("UNAUTHORIZED", "Unsafe IPC socket permissions or owner.")
        }
        let connected = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connected >= 0 else { throw IPC.failure("Cannot create local socket.") }
        IPC.configure(connected)
        let registered = stateLock.withLock {
            guard !closing else { return false }
            fd = connected
            return true
        }
        guard registered else {
            close(connected)
            try checkOpen()
            throw IPC.failure("Cannot register local connection.")
        }
        do {
            try IPC.connect(connected, to: directory.appendingPathComponent("bridge.sock").path, checkOpen: checkOpen)
            var hello: [String: AgentJSON] = ["version": .number(Double(IPC.version)), "token": .string(token)]
            if let clientLabel { hello["client_label"] = .string(clientLabel) }
            try IPC.send(connected, .object(hello))
            let response = try IPC.checked(IPC.receive(connected))
            guard response["version"]?.intValue == IPC.version, response["instance_id"]?.stringValue?.isEmpty == false else {
                throw AgentFailure("VERSION_MISMATCH", "Invalid App bridge handshake.")
            }
            return connected
        } catch { closeConnection(); throw error }
    }
    private func closeConnection() {
        stateLock.withLock {
            if fd >= 0 {
                Darwin.shutdown(fd, SHUT_RDWR)
                close(fd)
                fd = -1
            }
        }
    }
    /// Temporary disconnect, retained for callers that intentionally reconnect.
    public func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeConnection()
                continuation.resume()
            }
        }
    }
    public func shutdown() async {
        beginShutdown()
        // Shutdown must not be enqueued behind a blocked receive. beginShutdown
        // wakes it first; the queue then finishes queued failures and owns close.
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeConnection()
                continuation.resume()
            }
        }
    }
    private func beginShutdown() {
        stateLock.withLock {
            closing = true
            if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }
    deinit { closeConnection() }
}

#endif
