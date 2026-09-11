import Foundation
import CoreGraphics
import ImageIO

/// CGImage is immutable. This wrapper is the boundary between background
/// decoding and the main-thread image view; it contains no mutable UI state.
public final class ArticleThumbnail: @unchecked Sendable {
    public let image: CGImage
    init(_ image: CGImage) { self.image = image }
    var cost: Int { image.bytesPerRow * image.height }
}

public struct ArticleThumbnailRequest: Hashable, Sendable {
    public let accountID: String
    public let url: URL
    public let pixelSize: Int
    public init(accountID: String, url: URL, pixelSize: Int) {
        self.accountID = accountID
        self.url = url
        self.pixelSize = pixelSize <= 160 ? 160 : (pixelSize <= 640 ? 640 : 1280)
    }
    var cacheKey: String {
        "\(accountID.utf8.count):\(accountID)\(pixelSize):\(url.absoluteString)".stableDigest
    }
}

public enum ArticleThumbnailError: Error, Sendable {
    case unsafeURL, invalidResponse, oversized, undecodable, temporarilyUnavailable
}

private final class ThumbnailMemoryCache: @unchecked Sendable {
    let values = NSCache<NSString, ArticleThumbnail>()
    init(limit: Int) { values.totalCostLimit = limit; values.countLimit = 256 }
}

/// Bounded FIFO gate. Cancelled queued requests are removed, not promoted into
/// downloads later when a user has already left the page.
private actor ThumbnailDownloadGate {
    private let limit: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int) { self.limit = max(1, limit) }
    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiting.isEmpty { active = max(0, active - 1) }
        else { waiting.removeFirst().1.resume() }
    }
}

private actor ThumbnailDiskCache {
    let directory: URL
    let byteLimit: Int
    init(directory: URL, byteLimit: Int) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
    }
    func read(_ key: String) -> Data? {
        let file = directory.appendingPathComponent(key + ".jpg")
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              (values.fileSize ?? Int.max) <= ArticleThumbnailStore.maximumDownloadBytes,
              let modified = values.contentModificationDate,
              Date().timeIntervalSince(modified) < 7 * 24 * 3600 else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }
    func write(_ data: Data, key: String) {
        guard byteLimit > 0, data.count <= byteLimit else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".jpg"), options: .atomic)
            let files = try fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                .filter { $0.pathExtension == "jpg" }
                .compactMap { url -> (URL, Int, Date)? in
                    guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
                }.sorted { $0.2 < $1.2 }
            var bytes = files.reduce(0) { $0 + $1.1 }
            var count = files.count
            for file in files where bytes > byteLimit || count > 1024 {
                if (try? fm.removeItem(at: file.0)) != nil { bytes -= file.1; count -= 1 }
            }
        } catch {
            // Cache storage is optional. A read-only/full disk must not affect
            // the article database or prevent displaying a decoded image.
        }
    }
}

/// Shared, account-isolated byte pipeline. Requests are made only by visible
/// views. No original-sized images or full HTML enter a timeline projection.
public actor ArticleThumbnailStore {
    public typealias Loader = @Sendable (ArticleThumbnailRequest) async throws -> Data
    public static let maximumDownloadBytes = 8 * 1024 * 1024
    private nonisolated let memory: ThumbnailMemoryCache
    private let disk: ThumbnailDiskCache
    private let gate: ThumbnailDownloadGate
    private let loader: Loader
    private struct Flight {
        let id: UUID
        let task: Task<ArticleThumbnail, Error>
        var subscribers: Set<UUID>
    }
    private var flights: [ArticleThumbnailRequest: Flight] = [:]
    private var failures: [ArticleThumbnailRequest: Date] = [:]

    public init(directory: URL? = nil, memoryLimit: Int = 64 * 1024 * 1024,
                diskLimit: Int = 256 * 1024 * 1024, maximumConcurrent: Int = 4,
                loader: Loader? = nil) {
        memory = ThumbnailMemoryCache(limit: max(1, memoryLimit))
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        disk = ThumbnailDiskCache(directory: directory ?? cacheRoot.appendingPathComponent("PaperRss/ArticleThumbnails-v1"), byteLimit: diskLimit)
        gate = ThumbnailDownloadGate(limit: maximumConcurrent)
        self.loader = loader ?? Self.download
    }

    public nonisolated func cachedImage(for request: ArticleThumbnailRequest) -> ArticleThumbnail? {
        memory.values.object(forKey: request.cacheKey as NSString)
    }

    public func image(for request: ArticleThumbnailRequest) async throws -> ArticleThumbnail {
        try Task.checkCancellation()
        guard EntryPreviewImageExtractor.safeURL(request.url.absoluteString) != nil else { throw ArticleThumbnailError.unsafeURL }
        if let cached = cachedImage(for: request) { return cached }
        if let until = failures[request], until > Date() { throw ArticleThumbnailError.temporarilyUnavailable }
        let subscriber = UUID()
        let flight: Flight
        if var current = flights[request] {
            current.subscribers.insert(subscriber)
            flights[request] = current
            flight = current
        } else {
            let gate = self.gate, disk = self.disk, loader = self.loader
            let task = Task.detached(priority: .utility) { () throws -> ArticleThumbnail in
                try await gate.acquire()
                do {
                    try Task.checkCancellation()
                    let result: ArticleThumbnail
                    if let data = await disk.read(request.cacheKey), let decoded = try? Self.decode(data, pixelSize: request.pixelSize) {
                        result = decoded
                    } else {
                        let data = try await loader(request)
                        try Task.checkCancellation()
                        result = try Self.decode(data, pixelSize: request.pixelSize)
                        if let encoded = Self.jpeg(result.image) { await disk.write(encoded, key: request.cacheKey) }
                    }
                    try Task.checkCancellation()
                    await gate.release()
                    return result
                } catch {
                    await gate.release()
                    throw error
                }
            }
            flight = Flight(id: UUID(), task: task, subscribers: [subscriber])
            flights[request] = flight
        }
        return try await withTaskCancellationHandler {
            do {
                let value = try await flight.task.value
                try Task.checkCancellation()
                if flights[request]?.id == flight.id {
                    memory.values.setObject(value, forKey: request.cacheKey as NSString, cost: value.cost)
                    failures.removeValue(forKey: request)
                }
                release(request, flightID: flight.id, subscriber: subscriber)
                return value
            } catch {
                if !Task.isCancelled, !(error is CancellationError),
                   (error as? URLError)?.code != .cancelled, flights[request]?.id == flight.id {
                    failures = failures.filter { $0.value > Date() }
                    if failures.count >= 512 { failures.removeAll(keepingCapacity: true) }
                    failures[request] = Date().addingTimeInterval(error is URLError ? 30 : 3600)
                }
                release(request, flightID: flight.id, subscriber: subscriber)
                throw error
            }
        } onCancel: {
            Task { await self.release(request, flightID: flight.id, subscriber: subscriber) }
        }
    }

    private func release(_ request: ArticleThumbnailRequest, flightID: UUID, subscriber: UUID) {
        guard var current = flights[request], current.id == flightID else { return }
        current.subscribers.remove(subscriber)
        if current.subscribers.isEmpty {
            current.task.cancel()
            flights.removeValue(forKey: request)
        } else { flights[request] = current }
    }

    /// Called when images are explicitly disabled. Cancels queued and active
    /// work; decoded cache entries may be reused on a later explicit enable.
    public func cancelAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    static func decode(_ data: Data, pixelSize: Int) throws -> ArticleThumbnail {
        guard data.count <= maximumDownloadBytes else { throw ArticleThumbnailError.oversized }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 2, height > 2, width <= 40_000, height <= 40_000,
              Int64(width) * Int64(height) <= 80_000_000 else { throw ArticleThumbnailError.undecodable }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: min(1280, max(1, pixelSize)),
                       kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw ArticleThumbnailError.undecodable }
        return ArticleThumbnail(image)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func download(_ image: ArticleThumbnailRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: image.url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("PaperRss/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: ThumbnailRequestDelegate())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.mimeType?.lowercased().hasPrefix("image/") == true else { throw ArticleThumbnailError.invalidResponse }
        guard response.expectedContentLength <= maximumDownloadBytes else { throw ArticleThumbnailError.oversized }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(min(maximumDownloadBytes, max(16_384, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumDownloadBytes else { throw ArticleThumbnailError.oversized }
                data.append(byte)
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return data
        } onCancel: {
            bytes.task.cancel()
        }
    }
}

private final class ThumbnailRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, EntryPreviewImageExtractor.safeURL(url.absoluteString) != nil else {
            completionHandler(nil); return
        }
        var clean = request
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "Referer"] { clean.setValue(nil, forHTTPHeaderField: header) }
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
