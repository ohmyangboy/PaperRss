import XCTest
@testable import PaperRssCore

private actor WorkspaceGate {
    private var started = Set<Int>()
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func enter(_ id: Int) async {
        started.insert(id)
        await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func release(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume()
    }

    func snapshot() -> Set<Int> { started }
}

final class ArticleAIWorkspaceTests: XCTestCase {
    @MainActor
    func testLateSummaryEventsRemainOwnedByTheOriginalArticle() async throws {
        let workspace = ArticleAIWorkspace()
        let articleA = workspace.attach(ReaderAIDocument(entryID: "article-a", text: "A"))
        let stream = AsyncStream.makeStream(of: ReaderAIEvent.self)

        _ = try workspace.submit(.summary(force: false), in: articleA) { emit in
            for await event in stream.stream {
                await emit(event)
            }
        }

        stream.continuation.yield(.summary("A partial"))
        await eventually { workspace.projection.summary?.content == "A partial" }

        let articleB = workspace.attach(ReaderAIDocument(entryID: "article-b", text: "B"))
        XCTAssertEqual(workspace.projection.generation, articleB)
        XCTAssertNil(workspace.projection.summary)

        stream.continuation.yield(.summary("A complete"))
        await Task.yield()
        XCTAssertEqual(workspace.projection.entryID, "article-b")
        XCTAssertNil(workspace.projection.summary)

        _ = workspace.attach(ReaderAIDocument(entryID: "article-a", text: "A"))
        await eventually { workspace.projection.summary?.content == "A complete" }
        stream.continuation.finish()
    }

    @MainActor
    func testRequestedTranslationContinuesAfterNavigationWithoutLeakingIntoAnotherArticle() async throws {
        let workspace = ArticleAIWorkspace()
        let articleA = workspace.attach(ReaderAIDocument(entryID: "article-a", text: "A"))
        let stream = AsyncStream.makeStream(of: ReaderAIEvent.self)

        _ = try workspace.submit(.bilingual(paragraphIDs: ["p0"]), in: articleA) { emit in
            // The deliberately unstructured producer models a provider that
            // can deliver one final callback after URLSession cancellation.
            for await event in stream.stream {
                await emit(event)
            }
        }
        stream.continuation.yield(.bilingual(paragraphID: "p0", text: "A translation"))
        await eventually { workspace.projection.bilingualTranslations["p0"] == "A translation" }

        _ = workspace.attach(ReaderAIDocument(entryID: "article-b", text: "B"))
        stream.continuation.yield(.bilingual(paragraphID: "p0", text: "late A"))
        await eventually { workspace.projection(for: "article-a").bilingualTranslations["p0"] == "late A" }

        XCTAssertEqual(workspace.projection.entryID, "article-b")
        XCTAssertTrue(workspace.projection.bilingualTranslations.isEmpty)
        _ = workspace.attach(ReaderAIDocument(entryID: "article-a", text: "A"))
        XCTAssertEqual(workspace.projection.bilingualTranslations["p0"], "late A")
        stream.continuation.finish()
    }

    @MainActor
    func testBackgroundPoolRunsSixJobsAndStartsSeventhInFIFOOrder() async throws {
        let workspace = ArticleAIWorkspace(maximumBackgroundConcurrency: 6)
        let gate = WorkspaceGate()

        for id in 0..<7 {
            let generation = workspace.attach(ReaderAIDocument(entryID: "article-\(id)", text: "\(id)"))
            _ = try workspace.submit(.summary(force: false), in: generation) { _ in
                await gate.enter(id)
            }
        }

        for _ in 0..<100 where await gate.snapshot().count < 6 { await Task.yield() }
        let firstWave = await gate.snapshot()
        XCTAssertEqual(firstWave, Set(0..<6))
        await gate.release(0)
        for _ in 0..<100 where !(await gate.snapshot().contains(6)) { await Task.yield() }
        let secondWave = await gate.snapshot()
        XCTAssertTrue(secondWave.contains(6))
        for id in 1..<7 { await gate.release(id) }
    }

    @MainActor
    func testSelectionChannelIsNotBlockedBySixBackgroundJobs() async throws {
        let workspace = ArticleAIWorkspace(maximumBackgroundConcurrency: 6)
        let gate = WorkspaceGate()
        for id in 0..<6 {
            let generation = workspace.attach(ReaderAIDocument(entryID: "background-\(id)", text: "\(id)"))
            _ = try workspace.submit(.bilingual(paragraphIDs: ["p0"]), in: generation) { _ in
                await gate.enter(id)
            }
        }
        for _ in 0..<100 where await gate.snapshot().count < 6 { await Task.yield() }

        var selectionStarted = false
        let foreground = workspace.attach(ReaderAIDocument(entryID: "foreground", text: "selection"))
        _ = try workspace.submit(.selection, in: foreground) { _ in
            selectionStarted = true
        }
        await eventually { selectionStarted }
        XCTAssertTrue(selectionStarted)
        for id in 0..<6 { await gate.release(id) }
    }

    @MainActor
    func testSelectionPerformIsCancelledWhenDocumentGenerationChanges() async throws {
        let workspace = ArticleAIWorkspace()
        let generation = workspace.attach(ReaderAIDocument(entryID: "selection-a", text: "A"))
        let started = AsyncStream.makeStream(of: Void.self)
        let task = Task { @MainActor in
            try await workspace.perform(SelectionAIRequest {
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
                return "late"
            }, in: generation)
        }
        for await _ in started.stream.prefix(1) { break }

        _ = workspace.attach(ReaderAIDocument(entryID: "selection-b", text: "B"))

        do {
            _ = try await task.value
            XCTFail("Navigation must cancel the selection request")
        } catch is CancellationError {
            // Expected: cancellation reaches the in-flight network task.
        }
    }

    @MainActor
    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}
