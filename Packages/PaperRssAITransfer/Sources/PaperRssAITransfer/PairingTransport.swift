import Foundation
import Combine
@preconcurrency import Network
import Security
import Darwin

private let maximumFrame = 1_048_576

private func transferHello(sessionID: String, purpose: TransferPurpose) -> Data {
    Data((purpose == .aiConfiguration ? sessionID : "subscriptions:" + sessionID).utf8)
}

private func parameters(secret: Data, identity: String) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    secret.withUnsafeBytes { bytes in
        let key = DispatchData(bytes: bytes)
        Data(identity.utf8).withUnsafeBytes { identityBytes in
            sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, DispatchData(bytes: identityBytes) as __DispatchData)
        }
    }
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    sec_protocol_options_set_tls_resumption_enabled(options, false)
    let result = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    result.includePeerToPeer = false
    result.prohibitedInterfaceTypes = [.cellular]
    return result
}

private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, any Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}

private final class ConnectionIO: @unchecked Sendable {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
    func ready() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(.success(()))
                case .failed, .cancelled: once.finish(.failure(TransferError.connectionFailed))
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
    func send(_ data: Data) async throws {
        guard data.count <= maximumFrame else { throw TransferError.tooLarge }
        var size = UInt32(data.count).bigEndian
        let frame = withUnsafeBytes(of: &size) { Data($0) } + data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: TransferError.connectionFailed) }
                else { continuation.resume() }
            })
        }
    }
    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                guard error == nil, let data, data.count == count else {
                    continuation.resume(throwing: TransferError.connectionFailed); return
                }
                continuation.resume(returning: data)
            }
        }
    }
    func receive() async throws -> Data {
        let prefix = try await read(4)
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumFrame else { throw TransferError.tooLarge }
        return try await read(count)
    }
}

public enum PairingClient {
    public static func receive(offer: PairingOffer) async throws -> TransferSnapshot {
        try await receivePayload(offer: offer, purpose: .aiConfiguration, as: TransferSnapshot.self) { try $0.validate() }
    }

    public static func receiveSubscriptions(offer: PairingOffer) async throws -> SubscriptionSnapshot {
        try await receivePayload(offer: offer, purpose: .subscriptions, as: SubscriptionSnapshot.self) { try $0.validate() }
    }

    private static func receivePayload<Snapshot: Decodable & Sendable>(
        offer: PairingOffer, purpose: TransferPurpose, as type: Snapshot.Type,
        validate: @Sendable (Snapshot) throws -> Void
    ) async throws -> Snapshot {
        try offer.validate()
        // Reject an unrelated QR before even opening the connection: an AI
        // session must not be consumed by the subscription-import entry point.
        guard offer.effectivePurpose == purpose else { throw TransferError.wrongPurpose }
        for host in offer.hosts {
            try Task.checkCancellation()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: offer.port)!,
                                          using: parameters(secret: offer.secret, identity: offer.sessionID))
            let timer = DispatchWorkItem { connection.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timer)
            do {
                let snapshot = try await withTaskCancellationHandler {
                    let io = ConnectionIO(connection)
                    try await io.ready()
                    try await io.send(transferHello(sessionID: offer.sessionID, purpose: purpose))
                    let data = try await io.receive()
                    let snapshot = try JSONDecoder().decode(type, from: data)
                    try validate(snapshot)
                    try Task.checkCancellation()
                    try await io.send(Data("received".utf8))
                    return snapshot
                } onCancel: { connection.cancel() }
                timer.cancel(); connection.cancel()
                return snapshot
            } catch {
                timer.cancel(); connection.cancel()
                if Task.isCancelled { throw CancellationError() }
                if error is DecodingError { throw TransferError.invalidSnapshot }
                if let error = error as? TransferError, error == .invalidSnapshot || error == .unsupportedVersion || error == .tooLarge { throw error }
            }
        }
        throw TransferError.connectionFailed
    }
}

@MainActor
public final class PairingServer: ObservableObject {
    @Published public private(set) var stateDescription = "准备配对"
    public var onConsumed: (() -> Void)?
    public var onInvalidated: (() -> Void)?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var payload: Data?
    private var offer: PairingOffer?
    private var monitor: NWPathMonitor?
    private var expiry: Task<Void, Never>?
    private var transfer: Task<Void, Never>?
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var generation = UUID()
    private var initialHosts: [String] = []

    public init() {}

    public func start(snapshot: TransferSnapshot) async throws -> PairingOffer {
        try Task.checkCancellation()
        stop()
        try snapshot.validate()
        return try await start(payload: JSONEncoder().encode(snapshot), purpose: nil)
    }

    public func start(subscriptions: SubscriptionSnapshot) async throws -> PairingOffer {
        try Task.checkCancellation()
        stop()
        try subscriptions.validate()
        return try await start(payload: JSONEncoder().encode(subscriptions), purpose: .subscriptions)
    }

    private func start(payload: Data, purpose: TransferPurpose?) async throws -> PairingOffer {
        try Task.checkCancellation()
        guard payload.count <= maximumFrame else { throw TransferError.tooLarge }
        let hosts = Self.localHosts()
        guard !hosts.isEmpty else { throw TransferError.noLocalNetwork }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TransferError.connectionFailed }
        let secret = Data(bytes)
        let sessionID = UUID().uuidString
        let instance = generation
        let listener = try NWListener(using: parameters(secret: secret, identity: sessionID))
        self.listener = listener; self.payload = payload; initialHosts = hosts
        stateDescription = "正在准备连接"
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == instance else { connection.cancel(); return }
                self.accept(connection, generation: instance)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.generation == instance else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port?.rawValue else { self.fail(.connectionFailed); return }
                    self.ready?.resume(returning: port); self.ready = nil
                case .failed: self.fail(.connectionFailed)
                case .cancelled:
                    self.ready?.resume(throwing: TransferError.connectionFailed); self.ready = nil
                default: break
                }
            }
        }
        let port: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .global(qos: .userInitiated))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.generation == instance, self.ready != nil else { return }
                    self.fail(.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == instance else { return }
                self.stop()
            }
        }
        try Task.checkCancellation()
        guard generation == instance else { throw TransferError.connectionFailed }
        let offer = PairingOffer(hosts: hosts, port: port, sessionID: sessionID, secret: secret,
                                 expiresAt: Date().addingTimeInterval(120), purpose: purpose)
        self.offer = offer; stateDescription = "等待 iPhone 扫码"
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self, self.generation == instance else { return }
            self.fail(.expired)
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.generation == instance else { return }
                if path.status != .satisfied || Self.localHosts() != self.initialHosts { self.fail(.noLocalNetwork) }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        return offer
    }

    private func accept(_ connection: NWConnection, generation instance: UUID) {
        guard self.connection == nil, let payload, let offer, offer.expiresAt > Date() else { connection.cancel(); return }
        self.connection = connection
        stateDescription = "正在建立安全连接"
        let timer = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        transfer = Task { [weak self] in
            defer { timer.cancel(); connection.cancel() }
            do {
                let io = ConnectionIO(connection)
                try await io.ready()
                guard try await io.receive() == transferHello(sessionID: offer.sessionID, purpose: offer.effectivePurpose) else {
                    throw TransferError.wrongPurpose
                }
                guard offer.expiresAt > Date() else { throw TransferError.expired }
                try Task.checkCancellation()
                guard let self, self.generation == instance else { return }
                self.stateDescription = "正在发送配置"
                // Consume before the first payload byte: interruptions require a new QR.
                self.payload = nil; self.offer = nil; self.listener?.cancel(); self.listener = nil
                try await io.send(payload)
                guard try await io.receive() == Data("received".utf8) else { throw TransferError.connectionFailed }
                guard self.generation == instance else { return }
                self.stop(); self.stateDescription = "已发送到 iPhone"
                self.onConsumed?()
            } catch {
                guard let self, self.generation == instance else { return }
                if self.payload == nil { self.fail(.connectionFailed) }
                else { self.connection = nil; self.stateDescription = "连接未完成，请重新扫码" }
            }
        }
    }

    private func fail(_ error: TransferError) {
        stop(); stateDescription = error.localizedDescription; onInvalidated?()
    }
    public func stop() {
        generation = UUID()
        ready?.resume(throwing: TransferError.connectionFailed); ready = nil
        expiry?.cancel(); expiry = nil
        transfer?.cancel(); transfer = nil
        listener?.cancel(); listener = nil
        connection?.cancel(); connection = nil
        monitor?.cancel(); monitor = nil
        payload = nil; offer = nil; initialHosts = []
    }

    private static func localHosts() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var hosts = Set<String>()
        var cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            let name = String(cString: item.pointee.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  name.hasPrefix("en"), let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if PairingOffer.isPrivateIPv4(host) { hosts.insert(host) }
        }
        return Array(hosts.sorted().prefix(8))
    }
}
