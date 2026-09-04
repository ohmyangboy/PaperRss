import Combine
import Foundation

public struct ReaderAIDocument: Hashable, Sendable {
    public let entryID: String
    public let text: String

    public init(entryID: String, text: String) {
        self.entryID = entryID
        self.text = text
    }
}

public struct AIDocumentGeneration: Hashable, Sendable {
    public let entryID: String
    fileprivate let token: UUID

    fileprivate init(entryID: String, token: UUID = UUID()) {
        self.entryID = entryID
        self.token = token
    }
}

public struct AIRequestID: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ReaderAIIntent: Hashable, Sendable {
    case summary(force: Bool)
    case bilingual(paragraphIDs: [String])
    case selection

    fileprivate var lifecycle: ReaderAIRequestLifecycle {
        switch self {
        case .summary, .bilingual: .background
        case .selection: .document
        }
    }

    fileprivate var artifactKind: AIArtifactKind {
        switch self {
        case .summary: .summary
        case .bilingual: .bilingual
        case .selection: .selectionExplanation
        }
    }
}

private enum ReaderAIRequestLifecycle: Sendable {
    case background
    case document
}

public enum AIJobCancellationScope: Hashable, Sendable {
    case document(AIDocumentGeneration)
    case background(entryID: String, kind: AIArtifactKind)
}

public struct SelectionAIRequest: Sendable {
    fileprivate let operation: @MainActor @Sendable () async throws -> String

    public init(operation: @escaping @MainActor @Sendable () async throws -> String) {
        self.operation = operation
    }
}

public struct SelectionAIResponse: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum ReaderAIEvent: Equatable, Sendable {
    case summary(String)
    case bilingual(paragraphID: String, text: String)
}

public struct ReaderAIStreamProjection: Equatable, Sendable {
    public let requestID: AIRequestID
    public let content: String

    fileprivate init(requestID: AIRequestID, content: String) {
        self.requestID = requestID
        self.content = content
    }
}

public struct ArticleAIProjection: Equatable, Sendable {
    public let entryID: String
    public let generation: AIDocumentGeneration
    public var summary: ReaderAIStreamProjection?
    public var bilingualTranslations: [String: String]

    fileprivate init(
        entryID: String,
        generation: AIDocumentGeneration,
        summary: ReaderAIStreamProjection? = nil,
        bilingualTranslations: [String: String] = [:]
    ) {
        self.entryID = entryID
        self.generation = generation
        self.summary = summary
        self.bilingualTranslations = bilingualTranslations
    }
}

public enum ArticleAIWorkspaceError: Error, Equatable, Sendable {
    case staleDocument
}

/// Owns reader AI request identity and lifecycle independently from SwiftUI's
/// value-type view instances. Summary and already-requested bilingual work use
/// one six-slot FIFO background pool. Only selection work is document-scoped.
@MainActor
public final class ArticleAIWorkspace: ObservableObject {
    public typealias EventSink = @Sendable (ReaderAIEvent) async -> Void
    public typealias Operation = @MainActor @Sendable (@escaping EventSink) async -> Void

    @Published public private(set) var projection: ArticleAIProjection

    private struct RequestMetadata: Sendable {
        let intent: ReaderAIIntent
        let generation: AIDocumentGeneration
    }

    private struct PendingBackgroundRequest {
        let requestID: AIRequestID
        let operation: Operation
    }

    private var requests: [AIRequestID: RequestMetadata] = [:]
    private var tasks: [AIRequestID: Task<Void, Never>] = [:]
    private var selectionTasks: [AIRequestID: Task<String, Error>] = [:]
    private var summaryRequestByEntryID: [String: AIRequestID] = [:]
    private var summaryBufferByEntryID: [String: ReaderAIStreamProjection] = [:]
    private var bilingualRequestByEntryID: [String: AIRequestID] = [:]
    private var bilingualFollowupsByEntryID: [String: [Operation]] = [:]
    private var bilingualBufferByEntryID: [String: [String: String]] = [:]
    private var pendingBackground: [PendingBackgroundRequest] = []
    private var activeBackground = Set<AIRequestID>()
    private let maximumBackgroundConcurrency: Int

    public init(maximumBackgroundConcurrency: Int = 6) {
        self.maximumBackgroundConcurrency = max(1, maximumBackgroundConcurrency)
        let generation = AIDocumentGeneration(entryID: "")
        projection = ArticleAIProjection(entryID: "", generation: generation)
    }

    @discardableResult
    public func attach(_ document: ReaderAIDocument) -> AIDocumentGeneration {
        cancelDocumentWork(in: projection.generation)
        let generation = AIDocumentGeneration(entryID: document.entryID)
        projection = ArticleAIProjection(
            entryID: document.entryID,
            generation: generation,
            summary: summaryBufferByEntryID[document.entryID],
            bilingualTranslations: bilingualBufferByEntryID[document.entryID] ?? [:]
        )
        return generation
    }

    @discardableResult
    public func submit(
        _ intent: ReaderAIIntent,
        in generation: AIDocumentGeneration,
        operation: @escaping Operation
    ) throws -> AIRequestID {
        guard projection.generation == generation else {
            throw ArticleAIWorkspaceError.staleDocument
        }

        if case let .summary(force) = intent,
           let existing = summaryRequestByEntryID[generation.entryID] {
            if !force { return existing }
            cancelRequest(existing)
            summaryBufferByEntryID.removeValue(forKey: generation.entryID)
        }

        if case .bilingual = intent,
           let existing = bilingualRequestByEntryID[generation.entryID] {
            bilingualFollowupsByEntryID[generation.entryID, default: []].append(operation)
            return existing
        }

        if intent.lifecycle == .document {
            for (requestID, metadata) in requests where
                metadata.generation == generation && metadata.intent == intent {
                tasks[requestID]?.cancel()
                tasks.removeValue(forKey: requestID)
                requests.removeValue(forKey: requestID)
            }
        }

        let requestID = AIRequestID()
        requests[requestID] = RequestMetadata(intent: intent, generation: generation)
        if case .summary = intent {
            summaryRequestByEntryID[generation.entryID] = requestID
        } else if case .bilingual = intent {
            bilingualRequestByEntryID[generation.entryID] = requestID
        }

        if intent.lifecycle == .background {
            pendingBackground.append(PendingBackgroundRequest(requestID: requestID, operation: operation))
            startPendingBackgroundWorkIfPossible()
        } else {
            start(requestID: requestID, operation: operation)
        }
        return requestID
    }

    public func cancelDocumentWork(in generation: AIDocumentGeneration) {
        let targets = requests.compactMap { requestID, metadata in
            metadata.generation == generation && metadata.intent.lifecycle == .document
                ? requestID
                : nil
        }
        for requestID in targets {
            cancelRequest(requestID)
        }
    }

    public func cancel(_ scope: AIJobCancellationScope) {
        switch scope {
        case let .document(generation):
            cancelDocumentWork(in: generation)
        case let .background(entryID, kind):
            let targets = requests.compactMap { requestID, metadata in
                metadata.generation.entryID == entryID && metadata.intent.artifactKind == kind
                    ? requestID
                    : nil
            }
            targets.forEach(cancelRequest)
            if kind == .bilingual {
                bilingualFollowupsByEntryID.removeValue(forKey: entryID)
                bilingualBufferByEntryID.removeValue(forKey: entryID)
                if projection.entryID == entryID { projection.bilingualTranslations.removeAll() }
            }
        }
    }

    public func perform(
        _ request: SelectionAIRequest,
        in generation: AIDocumentGeneration
    ) async throws -> SelectionAIResponse {
        guard projection.generation == generation else {
            throw ArticleAIWorkspaceError.staleDocument
        }
        let requestID = AIRequestID()
        requests[requestID] = RequestMetadata(intent: .selection, generation: generation)
        let task = Task { @MainActor in try await request.operation() }
        selectionTasks[requestID] = task
        do {
            let text = try await task.value
            guard requests[requestID]?.generation == generation,
                  projection.generation == generation else {
                finish(requestID: requestID)
                throw ArticleAIWorkspaceError.staleDocument
            }
            finish(requestID: requestID)
            return SelectionAIResponse(text: text)
        } catch {
            finish(requestID: requestID)
            throw error
        }
    }

    public func isCurrent(_ generation: AIDocumentGeneration) -> Bool {
        projection.generation == generation
    }

    public func isWorking(entryID: String, kind: AIArtifactKind) -> Bool {
        requests.values.contains {
            $0.generation.entryID == entryID && $0.intent.artifactKind == kind
        }
    }

    public func projection(for entryID: String) -> ArticleAIProjection {
        let generation = projection.entryID == entryID
            ? projection.generation
            : AIDocumentGeneration(entryID: entryID)
        return ArticleAIProjection(
            entryID: entryID,
            generation: generation,
            summary: summaryBufferByEntryID[entryID],
            bilingualTranslations: bilingualBufferByEntryID[entryID] ?? [:]
        )
    }

    private func startPendingBackgroundWorkIfPossible() {
        while activeBackground.count < maximumBackgroundConcurrency,
              !pendingBackground.isEmpty {
            let next = pendingBackground.removeFirst()
            guard requests[next.requestID] != nil else { continue }
            activeBackground.insert(next.requestID)
            start(requestID: next.requestID, operation: next.operation)
        }
    }

    private func start(requestID: AIRequestID, operation: @escaping Operation) {
        guard let metadata = requests[requestID] else { return }
        let generation = metadata.generation
        tasks[requestID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation { [weak self] event in
                await self?.receive(event, requestID: requestID, generation: generation)
            }
            self.finish(requestID: requestID)
        }
    }

    private func cancelRequest(_ requestID: AIRequestID) {
        if let metadata = requests[requestID], case .bilingual = metadata.intent {
            bilingualFollowupsByEntryID.removeValue(forKey: metadata.generation.entryID)
        }
        tasks[requestID]?.cancel()
        tasks.removeValue(forKey: requestID)
        selectionTasks[requestID]?.cancel()
        selectionTasks.removeValue(forKey: requestID)
        pendingBackground.removeAll { $0.requestID == requestID }
        finish(requestID: requestID)
    }

    private func receive(
        _ event: ReaderAIEvent,
        requestID: AIRequestID,
        generation: AIDocumentGeneration
    ) {
        guard let metadata = requests[requestID], metadata.generation == generation else { return }

        switch event {
        case let .summary(content):
            guard case .summary = metadata.intent,
                  summaryRequestByEntryID[generation.entryID] == requestID else { return }
            let value = ReaderAIStreamProjection(requestID: requestID, content: content)
            summaryBufferByEntryID[generation.entryID] = value
            if projection.entryID == generation.entryID {
                projection.summary = value
            }

        case let .bilingual(paragraphID, text):
            guard case .bilingual = metadata.intent,
                  bilingualRequestByEntryID[generation.entryID] == requestID else { return }
            bilingualBufferByEntryID[generation.entryID, default: [:]][paragraphID] = text
            if projection.entryID == generation.entryID {
                projection.bilingualTranslations[paragraphID] = text
            }
        }
    }

    private func finish(requestID: AIRequestID) {
        guard let metadata = requests[requestID] else { return }
        if case .bilingual = metadata.intent,
           var followups = bilingualFollowupsByEntryID[metadata.generation.entryID],
           !followups.isEmpty,
           !Task.isCancelled {
            let next = followups.removeFirst()
            bilingualFollowupsByEntryID[metadata.generation.entryID] = followups.isEmpty ? nil : followups
            tasks.removeValue(forKey: requestID)
            start(requestID: requestID, operation: next)
            return
        }
        requests.removeValue(forKey: requestID)
        tasks.removeValue(forKey: requestID)
        selectionTasks.removeValue(forKey: requestID)
        let releasedBackgroundSlot = activeBackground.remove(requestID) != nil
        if case .summary = metadata.intent,
           summaryRequestByEntryID[metadata.generation.entryID] == requestID {
            summaryRequestByEntryID.removeValue(forKey: metadata.generation.entryID)
            summaryBufferByEntryID.removeValue(forKey: metadata.generation.entryID)
            if projection.entryID == metadata.generation.entryID,
               projection.summary?.requestID == requestID {
                projection.summary = nil
            }
        }
        if case .bilingual = metadata.intent,
           bilingualRequestByEntryID[metadata.generation.entryID] == requestID {
            bilingualRequestByEntryID.removeValue(forKey: metadata.generation.entryID)
            bilingualFollowupsByEntryID.removeValue(forKey: metadata.generation.entryID)
        }
        if releasedBackgroundSlot { startPendingBackgroundWorkIfPossible() }
    }
}
