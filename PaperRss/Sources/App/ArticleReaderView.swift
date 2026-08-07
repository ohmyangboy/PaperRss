import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if SWIFT_PACKAGE
import PaperRssCore
#endif

private enum ReaderMode: Hashable {
    case original
    case bilingual
}

private enum ReaderSelectionKind: String, Sendable {
    case explanation
    case translation
}

private struct ReaderSelectionRequest: Sendable {
    let id: String
    let selection: String
    let question: String?
    let localContext: String
    let kind: ReaderSelectionKind
    let anchor: AISelectionAnchor?
}

private struct ReaderSelectionResponse: Sendable {
    let text: String
    let isError: Bool
}

private struct ReaderSelectionAnnotation: Codable, Hashable, Sendable {
    let id: String
    let selection: String
    let explanation: String
    let paragraphID: String
    let startOffset: Int
    let endOffset: Int
}

private struct ReaderHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#if os(macOS)
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }
}

private struct FloatingCapsuleHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = PassthroughHostingView(rootView: content)
        host.layer?.backgroundColor = .clear
        return host
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
}
#endif

struct ArticleReaderView: View {
    @ObservedObject var store: AppStore
    let entry: Entry
    var onSelectNextEntry: () -> Void = {}
    var onFocusListView: () -> Void = {}
    var isZenMode: Bool = false
    var onToggleZenMode: () -> Void = {}
    @State private var text = ""
    @State private var html: String?
    /// Parsing a long document's paragraph structure is deliberately done once
    /// per article. The same stable index drives viewport translation requests
    /// and validation of returned translations.
    @State private var parsedReaderParagraphs: [ReaderParagraph] = []
    @State private var articleBaseURL: URL?
    @State private var isLoading = true
    @State private var activeLoadEntryID: String?
    @State private var isSummaryExpanded = false
    @State private var visibleBilingualParagraphIDs: [String] = []
    @State private var pendingBilingualParagraphIDs: Set<String> = []
    /// Paragraph IDs that failed translation, with the number of failed
    /// attempts. Bounded so a permanently failing paragraph (model refusal,
    /// overlong text, provider outage) stops being re-requested after a few
    /// tries instead of burning paid API calls on every scroll.
    @State private var failedBilingualParagraphIDs: [String: Int] = [:]
    /// Streamed partial translations that have not yet been persisted.
    /// Cleared for failed paragraphs so a truncated result never renders as
    /// a final translation (and never blocks an automatic retry).
    @State private var streamingBilingualTranslations: [String: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var paperTopMargin: CGFloat {
        0
    }

    private var paperLeftMargin: CGFloat {
        0
    }

    private func toggleSummary() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
            isSummaryExpanded.toggle()
        }
    }

    private var artifact: AIArtifact? {
        readerMode == .bilingual ? store.bilingualArtifact(for: entry, text: text) : nil
    }

    private var bilingualSegments: [BilingualSegment] {
        guard readerMode == .bilingual else { return [] }
        let persisted = store.bilingualArtifact(for: entry, text: text)?.segments ?? []
        let persistedIDs = Set(persisted.map(\.id))
        let streamed = readerParagraphs.compactMap { paragraph -> BilingualSegment? in
            guard !persistedIDs.contains(paragraph.id),
                  let translation = streamingBilingualTranslations[paragraph.id],
                  !translation.isEmpty else { return nil }
            return BilingualSegment(id: paragraph.id, original: paragraph.original, translation: translation)
        }
        return persisted + streamed
    }

    private var readerParagraphs: [ReaderParagraph] {
        if !parsedReaderParagraphs.isEmpty {
            return parsedReaderParagraphs
        }
        guard let html, !html.isEmpty else { return [] }
        return ArticleExtractor.readerParagraphs(in: html, title: entry.title)
    }

    private var savedSelectionAnnotations: [ReaderSelectionAnnotation] {
        guard !text.isEmpty else { return [] }
        let articleHash = text.stableDigest
        return store.database.artifacts.compactMap { artifact in
            guard artifact.entryID == entry.id,
                  artifact.kind == .selectionExplanation,
                  artifact.isComplete,
                  !artifact.isDeleted,
                  artifact.selectionArticleHash == articleHash,
                  let selection = artifact.selectionText,
                  let anchor = artifact.selectionAnchor,
                  !artifact.content.isEmpty else { return nil }
            return ReaderSelectionAnnotation(
                id: "saved-\(artifact.id.uuidString)",
                selection: selection,
                explanation: artifact.content,
                paragraphID: anchor.paragraphID,
                startOffset: anchor.startOffset,
                endOffset: anchor.endOffset
            )
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasReaderContent {
                readerBody
                    .zIndex(0)
            }
            if isLoading {
                loadingOverlay
                    .zIndex(2)
            }

            #if os(iOS)
            floatingCapsuleToolbar
                .padding(.top, 14)
                .zIndex(10)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PaperSurface(kind: .page)
                .ignoresSafeArea()
        }
        #if os(iOS)
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: store.activeAIRequest == nil) { _, isIdle in
            // Translation requests are silently skipped while another AI
            // operation (auto summary, selection explanation, selection
            // translation) holds the single request lock. Without this
            // recovery the viewport chain would stay stalled until the user
            // scrolls again — toggling bilingual mode during a summary
            // appeared to do nothing.
            if isIdle {
                requestVisibleTranslationsIfPossible()
            }
        }
        .onChange(of: text) { _, newText in
            if !newText.isEmpty {
                requestVisibleTranslationsIfPossible()
            }
        }
        .onChange(of: readerMode) { _, newMode in
            if newMode == .bilingual {
                requestVisibleTranslationsIfPossible()
            }
        }
        .task(id: entry.id) {
            let requestedEntry = entry
            activeLoadEntryID = requestedEntry.id
            isLoading = true
            isSummaryExpanded = false
            visibleBilingualParagraphIDs = []
            pendingBilingualParagraphIDs = []
            failedBilingualParagraphIDs = [:]
            streamingBilingualTranslations = [:]
            parsedReaderParagraphs = []
            store.markRead(requestedEntry)

            let loadedText: String
            do {
                loadedText = try await store.articleText(for: requestedEntry)
            } catch is CancellationError {
                return
            } catch {
                loadedText = requestedEntry.sourceText
                store.dismissError()
            }
            guard !Task.isCancelled, activeLoadEntryID == requestedEntry.id else { return }

            let loadedHTML = store.articleHTML(for: requestedEntry)
            let parsedParagraphs: [ReaderParagraph] = await Task.detached(priority: .userInitiated) { () -> [ReaderParagraph] in
                guard let loadedHTML, !loadedHTML.isEmpty else { return [] }
                return ArticleExtractor.readerParagraphs(in: loadedHTML, title: requestedEntry.title)
            }.value
            guard !Task.isCancelled, activeLoadEntryID == requestedEntry.id else { return }

            text = loadedText
            html = loadedHTML
            parsedReaderParagraphs = parsedParagraphs
            articleBaseURL = store.articleSourceURL(for: requestedEntry)
            isLoading = false
            requestVisibleTranslationsIfPossible()
            if store.database.llmConfiguration.automaticallyGenerateSummary,
               store.artifact(for: requestedEntry, kind: .summary) == nil,
               !text.isEmpty {
                isSummaryExpanded = true
                await store.generateSummary(entry: requestedEntry, text: text)
            }
        }
    }

    private var hasReaderContent: Bool {
        !(html?.isEmpty ?? true) || !text.isEmpty
    }

    private var loadingOverlay: some View {
        ZStack {
            PaperSurface(kind: .page)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("正在准备正文…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var readerBody: some View {
        #if os(macOS)
        if usesNativeHTMLScroller, let html {
            ArticleHTMLView(
                entry: entry,
                feedTitle: store.feed(for: entry)?.title,
                html: html,
                baseURL: articleBaseURL,
                contentTopInset: 84,
                readerParagraphs: readerParagraphs,
                inlineTranslations: bilingualSegments,
                pendingTranslationIDs: pendingBilingualParagraphIDs,
                selectionAnnotations: savedSelectionAnnotations,
                isBilingualMode: readerMode == .bilingual,
                fontSize: store.articleFontSize,
                summaryArtifact: store.summaryArtifact(for: entry),
                isSummaryExpanded: isSummaryExpanded,
                isGeneratingSummary: activeAIStatus(for: .summary) != nil,
                aiStatusMessage: activeAIStatus(for: .summary)?.phase.message,
                errorMessage: store.lastError,
                onVisibleParagraphIDsChange: handleVisibleParagraphIDs,
                onScrollOffsetChange: { _ in },
                onSelectionRequest: performSelectionRequest,
                onGenerateSummary: { force in generateSummary(force: force) },
                onToggleSummary: toggleSummary,
                onSelectNextEntry: onSelectNextEntry,
                onFocusListView: onFocusListView,
                onAdjustFontSize: { action in
                    switch action {
                    case "increase": store.increaseArticleFontSize()
                    case "decrease": store.decreaseArticleFontSize()
                    case "reset": store.resetArticleFontSize()
                    default: break
                    }
                }
            )
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, paperLeftMargin)
        } else {
            ScrollView {
                readerContents
                    .padding(.top, 84)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, paperLeftMargin)
        }
        #else
        if usesNativeHTMLScroller, let html {
            ArticleHTMLView(
                entry: entry,
                feedTitle: store.feed(for: entry)?.title,
                html: html,
                baseURL: articleBaseURL,
                contentTopInset: 64,
                readerParagraphs: readerParagraphs,
                inlineTranslations: bilingualSegments,
                pendingTranslationIDs: pendingBilingualParagraphIDs,
                selectionAnnotations: savedSelectionAnnotations,
                isBilingualMode: readerMode == .bilingual,
                fontSize: store.articleFontSize,
                summaryArtifact: store.summaryArtifact(for: entry),
                isSummaryExpanded: isSummaryExpanded,
                isGeneratingSummary: activeAIStatus(for: .summary) != nil,
                aiStatusMessage: activeAIStatus(for: .summary)?.phase.message,
                errorMessage: store.lastError,
                onVisibleParagraphIDsChange: handleVisibleParagraphIDs,
                onScrollOffsetChange: { _ in },
                onSelectionRequest: performSelectionRequest,
                onGenerateSummary: { force in generateSummary(force: force) },
                onToggleSummary: toggleSummary,
                onSelectNextEntry: onSelectNextEntry,
                onFocusListView: onFocusListView,
                onAdjustFontSize: { action in
                    switch action {
                    case "increase": store.increaseArticleFontSize()
                    case "decrease": store.decreaseArticleFontSize()
                    case "reset": store.resetArticleFontSize()
                    default: break
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, paperLeftMargin)
        } else {
            ScrollView {
                readerContents
                    .padding(.top, 64)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, paperLeftMargin)
        }
        #endif
    }

    private var readerContents: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summaryCard
            content
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 84)
        .padding(.bottom, 32)
    }

    private var usesNativeHTMLScroller: Bool {
        !(html?.isEmpty ?? true)
    }

    @ViewBuilder private var content: some View {
        switch readerMode {
        case .original:
            if let html, !html.isEmpty {
                #if os(macOS) || os(iOS)
                // The native web scroller is presented by readerBody. This branch
                // remains for SwiftUI's type-safe view construction only.
                EmptyView()
                #else
                Text(text).font(.system(size: CGFloat(store.articleFontSize))).lineSpacing(7).textSelection(.enabled)
                #endif
            } else {
                Text(text).font(.system(size: CGFloat(store.articleFontSize))).lineSpacing(7).textSelection(.enabled)
            }
        case .bilingual:
            if let artifact, !artifact.segments.isEmpty {
                #if os(macOS) || os(iOS)
                // The document itself hosts each Chinese paragraph.  Keeping
                // this empty prevents a second, replacement-style transcript
                // below the native reader on Mac.
                EmptyView()
                #else
                BilingualContent(
                    segments: artifact.segments,
                    isLoadingNextBatch: activeAIStatus(for: .bilingual) != nil,
                    hasMore: !artifact.isComplete,
                    loadNextBatch: generateBilingualTranslation
                )
                #endif
            } else if let status = activeAIStatus(for: .bilingual) {
                aiProgress(status)
            } else {
                unavailable("尚未生成全文上下对照", actionTitle: "生成对照翻译", action: generateBilingualTranslation)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = entry.url {
                Link(destination: url) {
                    Text(entry.title)
                        .font(.system(.title, design: .serif).weight(.bold))
                        .tracking(0.25)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("在默认浏览器打开原网页")
                .help("打开原网页")
            } else {
                Text(entry.title)
                    .font(.system(.title, design: .serif).weight(.bold))
                    .tracking(0.25)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let feed = store.feed(for: entry) { Text(feed.title) }
                if let author = entry.author, !author.isEmpty { Text(author) }
                if let date = entry.publishedAt { Text(date, format: .dateTime.year().month().day().hour().minute()) }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("AI 摘要", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PaperTheme.accent)
                Spacer()
                if store.summaryArtifact(for: entry) != nil {
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
                            isSummaryExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isSummaryExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PaperTheme.accent)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(PaperTheme.accent.opacity(0.09), in: Circle())
                    .accessibilityLabel(isSummaryExpanded ? "收起 AI 摘要" : "展开 AI 摘要")
                    .accessibilityHint(isSummaryExpanded ? "隐藏完整摘要" : "显示完整摘要")
                }
            }

            if let summary = store.summaryArtifact(for: entry), !summary.content.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.content)
                        .font(.body)
                        .lineSpacing(4)
                        .lineLimit(isSummaryExpanded ? nil : 3)
                        .textSelection(.enabled)
                        .contentTransition(.opacity)
                    if !summary.isComplete {
                        if activeAIStatus(for: .summary) != nil {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("AI 正在生成摘要…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        } else {
                            // A partially generated summary survived an app
                            // relaunch or cancellation. Offer a visible retry
                            // instead of leaving an eternal spinner.
                            HStack(spacing: 8) {
                                Text("上次生成未完成")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("重新生成") { generateSummary(force: true) }
                                    .buttonStyle(.borderless)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            } else if let status = activeAIStatus(for: .summary) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status.phase.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = store.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 8) {
                        Text("尚未生成；仅在你点按后发送正文。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("生成摘要") { generateSummary(force: false) }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.semibold))
                            .disabled(effectiveArticleText.isEmpty)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PaperTheme.noteBackground(scheme: colorScheme),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PaperTheme.noteBorder(scheme: colorScheme), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if store.summaryArtifact(for: entry) != nil {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
                    isSummaryExpanded.toggle()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var currentEntry: Entry {
        store.entry(id: entry.id) ?? entry
    }

    private var floatingCapsuleToolbar: some View {
        HStack(spacing: 4) {
            Button(action: toggleBilingualTranslation) {
                toolbarSymbol(
                    readerMode == .bilingual ? "character.bubble.fill" : "character.bubble",
                    isActive: readerMode == .bilingual
                )
            }
            .buttonStyle(.borderless)
            .disabled(text.isEmpty || store.activeAIRequest != nil)
            .accessibilityLabel(readerMode == .bilingual ? "关闭逐段翻译" : "开启逐段翻译")
            .help(readerMode == .bilingual ? "关闭逐段翻译" : "开启逐段翻译")

            Button {
                store.markRead(currentEntry, read: !currentEntry.isRead)
            } label: {
                toolbarSymbol(currentEntry.isRead ? "envelope.open" : "envelope", isActive: false)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(currentEntry.isRead ? "标为未读" : "标为已读")
            .help(currentEntry.isRead ? "标为未读" : "标为已读")

            Button {
                store.toggleStar(currentEntry)
            } label: {
                toolbarSymbol(currentEntry.isStarred ? "star.fill" : "star", isActive: currentEntry.isStarred)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(currentEntry.isStarred ? "取消收藏" : "收藏")
            .help(currentEntry.isStarred ? "取消收藏" : "收藏")

            Button {
                onToggleZenMode()
            } label: {
                toolbarSymbol(
                    isZenMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    isActive: isZenMode
                )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isZenMode ? "退出禅模式" : "禅模式全屏阅读")
            .help(isZenMode ? "退出禅模式" : "禅模式全屏阅读")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 140, height: 32)
        .background(
            Capsule()
                .fill(
                    colorScheme == .dark
                        ? AnyShapeStyle(Color.white.opacity(0.08))
                        : AnyShapeStyle(Color.black.opacity(0.04))
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 6,
                    x: 0,
                    y: 2
                )
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private func toolbarSymbol(_ name: String, isActive: Bool) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? AnyShapeStyle(PaperTheme.accent) : AnyShapeStyle(.primary))
            .frame(width: 29, height: 29)
            .background(isActive ? AnyShapeStyle(PaperTheme.accent.opacity(0.18)) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Circle())
    }

    private var readerMode: ReaderMode {
        store.isBilingualActive(for: entry.id) ? .bilingual : .original
    }

    private func toggleBilingualTranslation() {
        failedBilingualParagraphIDs.removeAll()
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            store.toggleBilingualMode(for: entry.id)
        }
        requestVisibleTranslationsIfPossible()
    }

    private var effectiveArticleText: String {
        if !text.isEmpty {
            return text
        }
        if let html, !html.isEmpty {
            let stripped = ArticleExtractor.content(from: html, baseURL: nil).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        if !entry.summary.isEmpty {
            let stripped = ArticleExtractor.content(from: entry.summary, baseURL: nil).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return entry.sourceText
    }

    private func generateSummary(force: Bool = false) {
        let targetText = effectiveArticleText
        guard !targetText.isEmpty else {
            store.reportError("文章暂无正文内容，无法生成摘要。")
            return
        }
        if store.activeAIRequest != nil {
            store.reportError("已有 AI 任务正在进行，请等待它完成后再试。")
            return
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
            isSummaryExpanded = true
        }
        Task { await store.generateSummary(entry: entry, text: targetText, force: force) }
    }

    private func generateBilingualTranslation() {
        guard !text.isEmpty else { return }
        failedBilingualParagraphIDs.removeAll()
        if !store.isBilingualActive(for: entry.id) {
            store.toggleBilingualMode(for: entry.id)
        }
        requestVisibleTranslationsIfPossible()
    }

    private func performSelectionRequest(
        _ request: ReaderSelectionRequest,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async -> ReaderSelectionResponse {
        do {
            let result: String
            switch request.kind {
            case .explanation:
                if let question = request.question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result = try await store.askSelection(
                        entry: entry,
                        selection: request.selection,
                        question: question,
                        localContext: request.localContext,
                        articleText: text,
                        selectionAnchor: request.anchor,
                        onDelta: onDelta
                    )
                } else {
                    result = try await store.explainSelection(
                        entry: entry,
                        selection: request.selection,
                        localContext: request.localContext,
                        articleText: text,
                        selectionAnchor: request.anchor,
                        onDelta: onDelta
                    )
                }
            case .translation:
                result = try await store.translateSelection(
                    entry: entry,
                    selection: request.selection,
                    onDelta: onDelta
                )
            }
            return ReaderSelectionResponse(text: result, isError: false)
        } catch {
            return ReaderSelectionResponse(
                text: error.localizedDescription,
                isError: true
            )
        }
    }

    private func handleVisibleParagraphIDs(_ ids: [String]) {
        let validIDs = Set(readerParagraphs.map(\.id))
        var seen = Set<String>()
        let normalized = ids.filter { validIDs.contains($0) && seen.insert($0).inserted }
        if normalized != visibleBilingualParagraphIDs {
            // Failure counters intentionally survive scrolling: clearing them
            // here made a permanently failing paragraph re-enter a paid batch
            // on every scroll. They reset per article in .task(id:).
            visibleBilingualParagraphIDs = normalized
        }
        requestVisibleTranslationsIfPossible()
    }

    /// Whether another AI operation (summary, selection explanation, etc.)
    /// is currently holding the store's single request lock.
    private var isAIRequestInFlight: Bool {
        store.activeAIRequest != nil
    }

    private func requestVisibleTranslationsIfPossible() {
        guard readerMode == .bilingual,
              !text.isEmpty,
              !isAIRequestInFlight else { return }

        let translatedIDs = Set(bilingualSegments.map(\.id))
        let batch = Array(
            visibleBilingualParagraphIDs
                .filter {
                    !translatedIDs.contains($0)
                        && !pendingBilingualParagraphIDs.contains($0)
                        && (failedBilingualParagraphIDs[$0] ?? 0) < Self.maximumTranslationFailures
                }
                .prefix(4)
        )
        guard !batch.isEmpty else { return }

        pendingBilingualParagraphIDs.formUnion(batch)
        let paragraphs = readerParagraphs
        Task {
            await store.translateBilingualParagraphs(
                entry: entry,
                text: text,
                paragraphs: paragraphs,
                paragraphIDs: batch,
                onDelta: { id, delta in
                    await MainActor.run {
                        streamingBilingualTranslations[id, default: ""] += delta
                    }
                }
            )

            let completedIDs = Set(
                store.bilingualArtifact(for: entry, text: text)?.segments.map(\.id) ?? []
            )
            let unsuccessfulIDs = Set(batch).subtracting(completedIDs)
            pendingBilingualParagraphIDs.subtract(batch)
            for id in batch where completedIDs.contains(id) {
                streamingBilingualTranslations.removeValue(forKey: id)
                failedBilingualParagraphIDs.removeValue(forKey: id)
            }
            for id in unsuccessfulIDs {
                // Never leave a truncated streamed text behind: it would
                // render as a final translation and block automatic retries.
                streamingBilingualTranslations.removeValue(forKey: id)
                failedBilingualParagraphIDs[id, default: 0] += 1
            }
            requestVisibleTranslationsIfPossible()
        }
    }

    private static let maximumTranslationFailures = 2

    private func activeAIStatus(for kind: AIArtifactKind) -> AIRequestStatus? {
        guard store.isGeneratingAI(for: entry, kind: kind) else { return nil }
        return store.activeAIRequest
    }

    private func aiProgress(_ status: AIRequestStatus) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("正在生成 \(status.kind.title)")
                .font(.headline)
            Text(status.phase.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("你可以继续阅读；结果完成后会自动出现。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }

    private func unavailable(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "sparkles")
        } description: {
            Text("仅在你点按生成后，正文才会发送给模型。")
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.activeAIRequest != nil)
            }
        }
            .frame(maxWidth: .infinity, minHeight: 280)
    }
}

private enum PaperReaderHeaderBuilder {
    static func headerHTML(
        entry: Entry,
        feedTitle: String?,
        summaryArtifact: AIArtifact?,
        isSummaryExpanded: Bool,
        isGeneratingSummary: Bool,
        aiStatusMessage: String?,
        isBilingualMode: Bool = false,
        titleSegment: BilingualSegment? = nil,
        isTitlePending: Bool = false
    ) -> String {
        let titleText = entry.title.htmlEscaped
        let titleHTML: String
        if let url = entry.url {
            titleHTML = "<a href=\"\(url.absoluteString.htmlEscaped)\">\(titleText)</a>"
        } else {
            titleHTML = titleText
        }

        let titleTranslationHTML: String
        if isBilingualMode {
            if let titleSegment {
                titleTranslationHTML = ArticleExtractor.translationMarkup(for: titleSegment.translation, id: "title")
            } else if isTitlePending {
                titleTranslationHTML = ArticleExtractor.pendingTranslationMarkup(for: "title")
            } else {
                titleTranslationHTML = ""
            }
        } else {
            titleTranslationHTML = ""
        }

        var metaParts: [String] = []
        if let feedTitle, !feedTitle.isEmpty {
            metaParts.append("<span>\(feedTitle.htmlEscaped)</span>")
        }
        if let author = entry.author, !author.isEmpty {
            metaParts.append("<span>\(author.htmlEscaped)</span>")
        }
        if let date = entry.publishedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            metaParts.append("<span>\(formatter.string(from: date))</span>")
        }
        let metaHTML = metaParts.joined(separator: " &bull; ")

        let summaryHTML = summaryCardHTML(
            summaryArtifact: summaryArtifact,
            isSummaryExpanded: isSummaryExpanded,
            isGeneratingSummary: isGeneratingSummary,
            aiStatusMessage: aiStatusMessage
        )

        let titleAttr = " data-paper-rss-id=\"title\""

        return """
        <header class="paper-header-container">
          <h1 class="paper-header-title"\(titleAttr)>\(titleHTML)</h1>
          \(titleTranslationHTML)
          <div class="paper-header-meta">\(metaHTML)</div>
          <div class="paper-summary-card" id="paper-summary-card">\(summaryHTML)</div>
          <hr class="paper-header-divider">
        </header>
        """
    }

    static func summaryCardHTML(
        summaryArtifact: AIArtifact?,
        isSummaryExpanded: Bool,
        isGeneratingSummary: Bool,
        aiStatusMessage: String?,
        errorMessage: String? = nil
    ) -> String {
        let sparklesSVG = """
        <svg class="paper-summary-icon" viewBox="0 0 24 24" fill="currentColor">
          <path d="M12 3l1.4 4.2L17.5 9l-4.1 1.8L12 15l-1.4-4.2L6.5 9l4.1-1.8L12 3z"/>
        </svg>
        """

        let chevronUpSVG = """
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="18 15 12 9 6 15"></polyline>
        </svg>
        """

        let chevronDownSVG = """
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="6 9 12 15 18 9"></polyline>
        </svg>
        """

        if let summary = summaryArtifact, !summary.content.isEmpty {
            let formattedContent = summary.content.htmlEscaped.replacingOccurrences(of: "\n", with: "<br>")
            let toggleIcon = isSummaryExpanded ? chevronUpSVG : chevronDownSVG
            let bodyClass = isSummaryExpanded ? "expanded" : "collapsed"
            
            var statusFooter = ""
            if !summary.isComplete {
                if isGeneratingSummary {
                    statusFooter = """
                    <div class="paper-summary-status">
                      <span class="paper-spinner"></span>
                      <span>AI 正在生成摘要…</span>
                    </div>
                    """
                } else {
                    let errStr = errorMessage.map { "<span class=\"paper-summary-error\">\($0.htmlEscaped)</span> " } ?? "<span>上次生成未完成</span> "
                    statusFooter = """
                    <div class="paper-summary-status">
                      \(errStr)<button class="paper-summary-action-btn" data-paper-action="generateSummary" data-paper-force="true">重新生成</button>
                    </div>
                    """
                }
            }

            return """
            <div class="paper-summary-header">
              <span class="paper-summary-title">\(sparklesSVG) AI 摘要</span>
              <button class="paper-summary-toggle-btn" data-paper-action="toggleSummary">
                \(toggleIcon)
              </button>
            </div>
            <div class="paper-summary-body \(bodyClass)">
              <p>\(formattedContent)</p>
              \(statusFooter)
            </div>
            """
        } else if isGeneratingSummary {
            let msg = aiStatusMessage ?? "AI 正在准备摘要…"
            return """
            <div class="paper-summary-header">
              <span class="paper-summary-title">\(sparklesSVG) AI 摘要</span>
            </div>
            <div class="paper-summary-status">
              <span class="paper-spinner"></span>
              <span>\(msg.htmlEscaped)</span>
            </div>
            """
        } else {
            let errNotice = errorMessage.map {
                """
                <div class="paper-summary-error" style="color: #c93b3b; font-size: 0.85em; margin-bottom: 6px;">
                  ⚠️ \($0.htmlEscaped)
                </div>
                """
            } ?? ""
            return """
            <div class="paper-summary-header">
              <span class="paper-summary-title">\(sparklesSVG) AI 摘要</span>
            </div>
            \(errNotice)
            <div class="paper-summary-placeholder">
              <span>尚未生成；仅在你点按后发送正文。</span>
              <button class="paper-summary-action-btn" data-paper-action="generateSummary" data-paper-force="false">生成摘要</button>
            </div>
            """
        }
    }
}

private extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private let paperArticleStyle = """
:root {
  color-scheme: light dark;
  --paper-ink: #302d27;
  --paper-muted: #6f695e;
  --paper-accent: #5f7355;
  --paper-warm: #9f5843;
  --paper-rule: rgba(72, 65, 52, .22);
  --paper-wash: rgba(95, 115, 85, .10);
  --paper-code: rgba(100, 88, 65, .09);
  --paper-card: rgba(250, 248, 240, .97);
}
@media (prefers-color-scheme: dark) {
  :root {
    --paper-ink: #e4ded1;
    --paper-muted: #aaa397;
    --paper-accent: #9eaf91;
    --paper-warm: #d18b73;
    --paper-rule: rgba(225, 215, 197, .18);
    --paper-wash: rgba(158, 175, 145, .10);
    --paper-code: rgba(224, 211, 185, .08);
    --paper-card: rgba(48, 45, 40, .97);
  }
}
html { background: transparent; }
body {
  max-width: 820px;
  margin: 0 auto 42px auto;
  padding-left: 32px;
  padding-right: 32px;
  padding-top: var(--paper-reader-top-inset, 84px);
  box-sizing: border-box;
  color: var(--paper-ink);
  background: transparent;
  font-size: var(--paper-font-size, 17px);
  font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
  font-weight: 400;
  line-height: 1.72;
  letter-spacing: .006em;
  overflow-wrap: anywhere;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
}
::selection { background: rgba(116, 137, 100, .24); }

.paper-header-container {
  margin: 0 0 24px 0;
  padding: 0;
}
.paper-header-title {
  font-family: "New York", "Iowan Old Style", "Songti SC", "STSong", Georgia, serif;
  font-size: 1.85em;
  font-weight: 700;
  line-height: 1.28;
  letter-spacing: .012em;
  color: var(--paper-ink);
  margin: 0 0 10px 0;
}
.paper-header-title a {
  color: var(--paper-ink);
  text-decoration: none;
}
.paper-header-title a:hover {
  color: var(--paper-accent);
}
.paper-header-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px 10px;
  font-size: 0.88em;
  color: var(--paper-muted);
  margin: 0 0 16px 0;
}
.paper-summary-card {
  background: var(--paper-card);
  border: 1px solid var(--paper-rule);
  border-radius: 10px;
  padding: 14px;
  margin: 0 0 20px 0;
  font-size: 0.95em;
  cursor: pointer;
}
.paper-summary-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 8px;
  font-weight: 600;
  color: var(--paper-accent);
}
.paper-summary-title {
  display: flex;
  align-items: center;
  gap: 6px;
}
.paper-summary-icon {
  width: 16px;
  height: 16px;
}
.paper-summary-toggle-btn {
  background: rgba(95, 115, 85, 0.1);
  border: none;
  border-radius: 50%;
  width: 24px;
  height: 24px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  color: var(--paper-accent);
  padding: 0;
}
.paper-summary-body {
  line-height: 1.6;
  color: var(--paper-ink);
}
.paper-summary-body.collapsed {
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.paper-summary-placeholder, .paper-summary-status {
  display: flex;
  align-items: center;
  gap: 8px;
  color: var(--paper-muted);
  font-size: 0.9em;
  margin-top: 4px;
}
.paper-summary-action-btn {
  background: transparent;
  border: none;
  color: var(--paper-accent);
  font-weight: 600;
  cursor: pointer;
  padding: 2px 6px;
  border-radius: 4px;
  font-size: 0.9em;
}
.paper-summary-action-btn:hover {
  background: var(--paper-wash);
}
.paper-spinner {
  display: inline-block;
  width: 13px;
  height: 13px;
  border: 2px solid var(--paper-wash);
  border-top-color: var(--paper-accent);
  border-radius: 50%;
  animation: paper-spin 0.8s linear infinite;
}
@keyframes paper-spin {
  to { transform: rotate(360deg); }
}
.paper-header-divider {
  border: none;
  height: 1px;
  background: linear-gradient(to right, rgba(72, 65, 52, 0.05), var(--paper-rule), rgba(72, 65, 52, 0.05));
  margin: 18px 0 24px 0;
}
p, ul, ol, dl, blockquote, pre, table, figure { margin: 0 0 1.2em; }
h1, h2, h3, h4, h5, h6 {
  margin: 1.6em 0 .58em;
  color: var(--paper-ink);
  font-family: "New York", "Iowan Old Style", "Songti SC", "STSong", Georgia, serif;
  font-weight: 700;
  line-height: 1.28;
  letter-spacing: .012em;
}
h1 { font-size: 1.72em; }
h2 { font-size: 1.42em; }
h3 { font-size: 1.20em; }
strong, b { font-weight: 680; color: var(--paper-ink); }
img, video {
  display: block;
  box-sizing: border-box;
  max-width: 100%;
  height: auto;
  margin: 1.2em auto;
  border: .5px solid var(--paper-rule);
  border-radius: 6px;
  cursor: pointer;
}
figure {
  margin: 1.2em auto;
  text-align: center;
}
figure img, figure video {
  margin-left: auto;
  margin-right: auto;
}
:fullscreen, :-webkit-full-screen {
  background-color: #000000 !important;
}
video:fullscreen, video:-webkit-full-screen,
*:fullscreen video, *:-webkit-full-screen video {
  width: 100% !important;
  height: 100% !important;
  max-width: 100% !important;
  max-height: 100% !important;
  margin: 0 !important;
  border: none !important;
  border-radius: 0 !important;
  object-fit: contain !important;
  background-color: #000000 !important;
}
figure img { margin-bottom: .48em; }
figcaption {
  color: var(--paper-muted);
  font-size: .88em;
  line-height: 1.55;
  letter-spacing: .015em;
  text-align: center;
}
.paper-rss-lightbox {
  position: fixed;
  top: 0;
  left: 0;
  width: 100vw;
  height: 100vh;
  z-index: 999999;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.22s ease-out;
}
.paper-rss-lightbox.is-active {
  opacity: 1;
  pointer-events: auto;
}
.paper-rss-lightbox-backdrop {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  background: rgba(0, 0, 0, 0.82);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
}
.paper-rss-lightbox-content {
  position: relative;
  max-width: 92vw;
  max-height: 92vh;
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 2;
}
.paper-rss-lightbox-img {
  max-width: 92vw;
  max-height: 92vh;
  object-fit: contain;
  border-radius: 8px;
  box-shadow: 0 16px 40px rgba(0, 0, 0, 0.45);
  cursor: zoom-out;
}
.paper-rss-lightbox-close {
  position: absolute;
  top: -44px;
  right: -8px;
  background: rgba(255, 255, 255, 0.22);
  border: none;
  color: #ffffff;
  width: 32px;
  height: 32px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  backdrop-filter: blur(8px);
  -webkit-backdrop-filter: blur(8px);
  transition: background 0.15s ease;
}
.paper-rss-lightbox-close:hover {
  background: rgba(255, 255, 255, 0.38);
}
a {
  color: var(--paper-accent);
  text-decoration-color: color-mix(in srgb, var(--paper-accent) 48%, transparent);
  text-decoration-thickness: .07em;
  text-underline-offset: .18em;
}
a:hover { color: var(--paper-warm); }
a:focus-visible {
  outline: 2px solid var(--paper-accent);
  outline-offset: 3px;
  border-radius: 3px;
}
blockquote {
  border-left: 2px solid var(--paper-warm);
  padding: .08em 0 .08em 1em;
  color: var(--paper-muted);
  font-family: "New York", "Iowan Old Style", "Songti SC", "STSong", Georgia, serif;
}
pre {
  white-space: pre-wrap;
  padding: .9em 1em;
  background: var(--paper-code);
  border: .5px solid var(--paper-rule);
  border-radius: 6px;
}
code { font-size: .92em; }
hr {
  height: 1px;
  border: 0;
  background: var(--paper-rule);
  margin: 2em 0;
}
table {
  display: block;
  max-width: 100%;
  overflow-x: auto;
  border-collapse: collapse;
}
th, td {
  border: 1px solid var(--paper-rule);
  padding: .48em .68em;
  text-align: left;
  vertical-align: top;
}
.paper-rss-translation {
  margin: -.64em 0 1.32em;
  padding: .72em .95em .76em;
  border-left: 2px solid var(--paper-accent);
  border-radius: 0 6px 6px 0;
  background: var(--paper-wash);
  color: var(--paper-muted);
}
.paper-rss-translation-label {
  position: relative;
  display: inline-flex;
  vertical-align: -.22em;
  width: 24px;
  height: 20px;
  margin: 0 .42em 0 0;
  color: var(--paper-accent);
}
.paper-rss-language-chip {
  position: absolute;
  display: grid;
  place-items: center;
  box-sizing: border-box;
  width: 16px;
  height: 14px;
  border: 1px solid currentColor;
  border-radius: 4px;
  background: var(--paper-card);
  font-size: 8px;
  font-weight: 700;
  line-height: 1;
}
.paper-rss-language-chip:first-child {
  top: 0;
  left: 0;
}
.paper-rss-language-chip:last-child {
  right: 0;
  bottom: 0;
}
.paper-rss-translation p { margin: 0; }
.paper-rss-translation-text { white-space: pre-wrap; }
.paper-rss-translation.is-loading {
  color: var(--paper-muted);
  opacity: .72;
}
.paper-rss-selection-actions {
  position: fixed;
  z-index: 2147483645;
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 6px;
  border: 1px solid var(--paper-rule);
  border-radius: 20px;
  color: var(--paper-ink);
  background: var(--paper-card);
  box-shadow: 0 8px 24px rgba(35, 31, 25, .16), 0 2px 6px rgba(35, 31, 25, .08);
  backdrop-filter: blur(20px) saturate(1.2);
  -webkit-backdrop-filter: blur(20px) saturate(1.2);
  animation: paper-rss-materialize .18s ease-out both;
}
.paper-rss-selection-action {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  padding: 0;
  border: 0;
  border-radius: 50%;
  color: inherit;
  background: transparent;
  cursor: pointer;
  -webkit-appearance: none;
  transition: background-color .15s ease, color .15s ease, transform .12s ease;
}
.paper-rss-selection-action .paper-rss-icon,
.paper-rss-explanation-header .paper-rss-icon {
  width: 16px;
  height: 16px;
  flex: 0 0 auto;
}
.paper-rss-selection-action:hover {
  color: var(--paper-accent);
  background: color-mix(in srgb, var(--paper-accent) 14%, transparent);
}
.paper-rss-selection-action:active { transform: scale(.94); }
.paper-rss-explained.is-pending,
.paper-rss-explained.is-complete {
  background: transparent;
  box-shadow: none;
}
.paper-rss-explained.is-pending {
  cursor: progress;
}
.paper-rss-explained.is-complete {
  cursor: pointer;
}
.paper-rss-annotation-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  width: 18px;
  height: 18px;
  margin: 0 .18em;
  vertical-align: -.18em;
  color: var(--paper-accent);
  opacity: .92;
  pointer-events: auto;
  cursor: pointer;
  transition: opacity .15s ease, transform .15s ease;
}
.paper-rss-annotation-icon:hover {
  opacity: 1;
  transform: translateY(-1px);
}
.paper-rss-annotation-icon.is-pending {
  opacity: .60;
  animation: paper-rss-pulse 1.2s ease-in-out infinite;
}
.paper-rss-annotation-icon .paper-rss-icon {
  width: 15px;
  height: 15px;
  flex: 0 0 auto;
}
.paper-rss-explanation {
  position: absolute;
  z-index: 2147483647;
  box-sizing: border-box;
  width: min(350px, calc(100vw - 40px));
  max-height: min(320px, calc(100vh - 40px));
  overflow: auto;
  padding: 14px 16px 16px;
  border: .5px solid var(--paper-rule);
  border-radius: 14px;
  color: var(--paper-ink);
  background: var(--paper-card);
  box-shadow: 0 8px 24px rgba(35, 31, 25, .12);
  -webkit-backdrop-filter: blur(20px) saturate(1.2);
  backdrop-filter: blur(20px) saturate(1.2);
  font: 14px/1.58 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
  animation: paper-rss-materialize .20s ease-out both;
  transform-origin: top center;
}
.paper-rss-selection-anchor {
  display: inline;
  width: 0;
  height: 0;
  margin: 0;
  padding: 0;
  font-size: 0;
  line-height: 0;
}
.paper-rss-explanation-header {
  display: flex;
  align-items: center;
  gap: 7px;
  margin-bottom: 9px;
  color: var(--paper-accent);
  font-weight: 680;
}
.paper-rss-explanation-body {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.paper-rss-explanation.is-loading .paper-rss-explanation-body {
  color: var(--paper-muted);
}
.paper-rss-explanation.is-translation .paper-rss-explanation-header {
  color: var(--paper-warm);
}
.paper-rss-explanation.is-error .paper-rss-explanation-header {
  color: var(--paper-warm);
}
@keyframes paper-rss-pulse {
  50% { opacity: .28; }
}
@keyframes paper-rss-materialize {
  from { opacity: 0; transform: translateY(4px) scale(.98); }
  to { opacity: 1; transform: translateY(0) scale(1); }
}
@media (prefers-reduced-motion: reduce) {
.paper-rss-selection-action,
  .paper-rss-explanation,
  .paper-rss-annotation-icon {
    animation: none;
  }
}
"""

@MainActor
enum PaperReaderBridge {
    static let scrollMessageName = "paperRssReaderScroll"
    static let visibleParagraphsMessageName = "paperRssVisibleParagraphs"
    static let explainSelectionMessageName = "paperRssExplainSelection"
    static let askSelectionMessageName = "paperRssAskSelection"
    static let observerScript = WKUserScript(
        source: """
        (() => {
          var lastOffset = -1;
          var lastParagraphPayload = "";
          let observedParagraphs = new Map();
          let allParagraphs = Array.from(document.querySelectorAll("[data-paper-rss-id]"));
          let scheduled = { scroll: false, paragraphs: false };

          const publishScroll = () => {
            scheduled.scroll = false;
            const offset = Math.max(
              0,
              window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0
            );
            // The header only changes state near its top/collapse thresholds.
            // Sending every sub-pixel offset over the WebKit bridge is needless
            // work on a 120 Hz trackpad scroll.
            if (Math.abs(offset - lastOffset) >= 4) {
              lastOffset = offset;
              window.webkit.messageHandlers.paperRssReaderScroll.postMessage(offset);
            }
          };

          const publishParagraphs = () => {
            scheduled.paragraphs = false;
            const viewportHeight = Math.max(window.innerHeight || 0, 1);
            const paragraphIDs = Array.from(observedParagraphs.values())
              .map(node => ({ id: node.dataset.paperRssId, rect: node.getBoundingClientRect() }))
              .filter(item =>
                item.id &&
                item.rect.bottom > 0 &&
                item.rect.top < viewportHeight * 1.75
              )
              .sort((lhs, rhs) => {
                const lhsVisible = lhs.rect.top < viewportHeight && lhs.rect.bottom > 0 ? 0 : 1;
                const rhsVisible = rhs.rect.top < viewportHeight && rhs.rect.bottom > 0 ? 0 : 1;
                return lhsVisible - rhsVisible || lhs.rect.top - rhs.rect.top;
              })
              .slice(0, 6)
              .map(item => item.id);
            const payload = JSON.stringify(paragraphIDs);
            if (payload !== lastParagraphPayload) {
              lastParagraphPayload = payload;
              window.webkit.messageHandlers.paperRssVisibleParagraphs.postMessage(paragraphIDs);
            }
          };

          const scheduleScroll = () => {
            if (scheduled.scroll) return;
            scheduled.scroll = true;
            requestAnimationFrame(publishScroll);
          };

          const scheduleParagraphs = () => {
            if (scheduled.paragraphs) return;
            scheduled.paragraphs = true;
            requestAnimationFrame(publishParagraphs);
          };

          // IntersectionObserver keeps the lazy-translation priority queue to
          // the small visible/nearby set. The previous approach forced layout
          // for every paragraph once per scroll frame on long essays.
          const observer = new IntersectionObserver(entries => {
            entries.forEach(entry => {
              const id = entry.target.dataset.paperRssId;
              if (!id) return;
              if (entry.isIntersecting) observedParagraphs.set(id, entry.target);
              else observedParagraphs.delete(id);
            });
            scheduleParagraphs();
          }, {
            root: null,
            rootMargin: "0px 0px 75% 0px",
            threshold: 0
          });
          allParagraphs.forEach(node => observer.observe(node));

          document.addEventListener("scroll", scheduleScroll, { passive: true, capture: true });
          window.addEventListener("resize", () => {
            scheduleScroll();
            scheduleParagraphs();
          }, { passive: true });
          document.addEventListener("click", event => {
            const btn = event.target ? event.target.closest("[data-paper-action]") : null;
            if (btn) {
              const action = btn.dataset.paperAction;
              if (action === "generateSummary") {
                event.preventDefault();
                event.stopPropagation();
                const force = btn.dataset.paperForce === "true";
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.paperRssGenerateSummary) {
                  window.webkit.messageHandlers.paperRssGenerateSummary.postMessage({ force: force });
                }
                return;
              } else if (action === "toggleSummary") {
                event.preventDefault();
                event.stopPropagation();
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.paperRssToggleSummary) {
                  window.webkit.messageHandlers.paperRssToggleSummary.postMessage({});
                }
                return;
              }
            }

            const summaryCard = event.target ? event.target.closest(".paper-summary-card") : null;
            if (summaryCard) {
              const sel = window.getSelection();
              if (sel && sel.toString() && sel.toString().trim().length > 0) {
                return;
              }
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.paperRssToggleSummary) {
                window.webkit.messageHandlers.paperRssToggleSummary.postMessage({});
              }
            }
          }, true);
          scheduleScroll();
          scheduleParagraphs();
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static let selectionScript = WKUserScript(
        source: """
        (() => {
          if (window.paperRssSelectionAssistant) return;

          let actionBar = null;
          let activeRange = null;
          let activeSelection = null;
          let activePopover = null;
          let activeAnchorRect = null;
          let activeAnchorElement = null;
          let selectionTimer = null;

          let isAsking = false;

          const removeAction = () => {
            isAsking = false;
            actionBar?.remove();
            actionBar = null;
            activeRange = null;
            activeSelection = null;
          };

          const dismissPopover = () => {
            activePopover?.remove();
            if (activeAnchorElement?.classList.contains("paper-rss-selection-anchor")) {
              activeAnchorElement.remove();
            }
            activePopover = null;
            activeAnchorRect = null;
            activeAnchorElement = null;
          };

          const positionNear = (element, rect, documentSpace = false) => {
            if (!element || !rect) return;
            const gap = 9;
            const margin = 12;
            const topInset = parseInt(getComputedStyle(document.body).getPropertyValue('--paper-reader-top-inset')) || 0;
            const minTop = Math.max(margin, topInset + 8);
            const bounds = element.getBoundingClientRect();
            const candidates = [
              { left: rect.left + rect.width / 2 - bounds.width / 2, top: rect.bottom + gap },
              { left: rect.left + rect.width / 2 - bounds.width / 2, top: rect.top - bounds.height - gap },
              { left: rect.right + gap, top: rect.top + rect.height / 2 - bounds.height / 2 },
              { left: rect.left - bounds.width - gap, top: rect.top + rect.height / 2 - bounds.height / 2 }
            ];
            const fits = candidate => candidate.left >= margin &&
              candidate.left + bounds.width <= window.innerWidth - margin &&
              candidate.top >= minTop &&
              candidate.top + bounds.height <= window.innerHeight - margin;
            const chosen = candidates.find(fits) || {
              left: Math.min(window.innerWidth - bounds.width - margin, Math.max(margin, candidates[0].left)),
              top: Math.min(window.innerHeight - bounds.height - margin, Math.max(minTop, candidates[0].top))
            };
            // Popovers live in document coordinates so they stay glued to the
            // explained sentence while the page scrolls. The action bar keeps
            // viewport coordinates because it is a fixed transient menu.
            const scrollX = documentSpace ? window.scrollX : 0;
            const scrollY = documentSpace ? window.scrollY : 0;
            element.style.left = (chosen.left + scrollX) + "px";
            element.style.top = (Math.max(margin, chosen.top) + scrollY) + "px";
          };

          const focusRectForSelection = (selection, range) => {
            try {
              if (selection?.focusNode) {
                const focusRange = document.createRange();
                focusRange.setStart(selection.focusNode, selection.focusOffset);
                focusRange.collapse(true);
                const rect = focusRange.getBoundingClientRect();
                if (rect && (rect.width || rect.height)) return rect;
              }
            } catch (_) {}
            const rects = Array.from(range.getClientRects());
            return rects[rects.length - 1] || range.getBoundingClientRect();
          };

          const svgIcon = (kind) => {
            const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
            svg.setAttribute("viewBox", "0 0 24 24");
            svg.setAttribute("aria-hidden", "true");
            svg.setAttribute("focusable", "false");
            svg.classList.add("paper-rss-icon");
            const paths = kind === "translation"
              ? ["m5 8 6 6", "m4 14 6-6 2-3", "M2 5h12", "M7 2v3", "M22 22l-5-10-5 10", "M14 18h6"]
              : kind === "ask"
                ? ["M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"]
                : kind === "note"
                  ? ["M12 3l1.4 4.2L17.5 9l-4.1 1.8L12 15l-1.4-4.2L6.5 9l4.1-1.8L12 3z", "M19 14l.7 2.3L22 17l-2.3.7L19 20l-.7-2.3L16 17l2.3-.7L19 14z"]
                  : ["M12 3l1.4 4.2L17.5 9l-4.1 1.8L12 15l-1.4-4.2L6.5 9l4.1-1.8L12 3z", "M5 14l.6 1.6 1.4.6-1.4.6L5 18.4l-.6-1.6-1.4-.6 1.4-.6L5 14z"];
            paths.forEach(d => {
              const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
              path.setAttribute("d", d);
              path.setAttribute("fill", "none");
              path.setAttribute("stroke", "currentColor");
              path.setAttribute("stroke-width", "1.8");
              path.setAttribute("stroke-linecap", "round");
              path.setAttribute("stroke-linejoin", "round");
              svg.append(path);
            });
            return svg;
          };

          // The selection bar's translation action uses the same compact
          // "A文" badge as the side-by-side translation labels, so both
          // translation entry points share one visual language.
          const translationBadge = () => {
            const badge = document.createElement("span");
            badge.className = "paper-rss-translation-label";
            badge.setAttribute("aria-hidden", "true");
            ["A", "文"].forEach(value => {
              const chip = document.createElement("span");
              chip.className = "paper-rss-language-chip";
              chip.textContent = value;
              badge.append(chip);
            });
            return badge;
          };

          const textNodesForRange = range => {
            const nodes = [];
            const root = range.commonAncestorContainer;
            const consider = node => {
              if (!node || node.nodeType !== Node.TEXT_NODE || !node.textContent) return;
              try { if (!range.intersectsNode(node)) return; } catch (_) { return; }
              const start = node === range.startContainer ? range.startOffset : 0;
              const end = node === range.endContainer ? range.endOffset : node.textContent.length;
              if (start < end) nodes.push({ node, start, end });
            };
            if (root.nodeType === Node.TEXT_NODE) consider(root);
            else {
              const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
              while (walker.nextNode()) consider(walker.currentNode);
            }
            return nodes;
          };

          const markRange = (range, id, selectionText) => {
            const marks = [];
            textNodesForRange(range).reverse().forEach(item => {
              const piece = document.createRange();
              piece.setStart(item.node, item.start);
              piece.setEnd(item.node, item.end);
              const mark = document.createElement("span");
              mark.className = "paper-rss-explained is-pending";
              mark.dataset.explanationId = id;
              mark.dataset.selection = selectionText || piece.toString().trim();
              try { piece.surroundContents(mark); marks.push(mark); } catch (_) {}
            });
            const createAnnotationButton = (expId) => {
              const btn = document.createElement("span");
              btn.className = "paper-rss-annotation-icon is-pending";
              btn.dataset.explanationId = expId;
              btn.setAttribute("role", "button");
              btn.setAttribute("tabindex", "0");
              btn.setAttribute("aria-label", "AI 解释");
              // A compact sparkle marks the explained sentence; it is
              // visually distinct from the bilingual "A文" translation badge.
              btn.append(svgIcon("note"));
              return btn;
            };

            const last = marks[0];
            let container = last ? (last.closest('[data-paper-rss-id]') || last.parentElement) : null;
            if (!container && range) {
              let node = range.commonAncestorContainer;
              container = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
              if (container) container = container.closest('[data-paper-rss-id]') || container;
            }
            if (container) {
              const existingIcons = container.querySelectorAll('.paper-rss-annotation-icon');
              existingIcons.forEach(icon => icon.remove());
            }

            if (last) {
              const icon = createAnnotationButton(id);
              last.append(icon);
            } else {
              const icon = createAnnotationButton(id);
              const end = range.cloneRange();
              end.collapse(false);
              end.insertNode(icon);
            }
            return marks;
          };

          const rangeForAnchor = anchor => {
            if (!anchor?.paragraphID) return null;
            const block = document.querySelector('[data-paper-rss-id="' + CSS.escape(anchor.paragraphID) + '"]');
            if (!block) return null;
            const textNodes = [];
            const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              if (walker.currentNode.textContent) textNodes.push(walker.currentNode);
            }
            const pointAt = offset => {
              let remaining = Math.max(0, Number(offset) || 0);
              for (const node of textNodes) {
                const length = node.textContent.length;
                if (remaining <= length) return { node, offset: remaining };
                remaining -= length;
              }
              const last = textNodes[textNodes.length - 1];
              return last ? { node: last, offset: last.textContent.length } : null;
            };
            const start = pointAt(anchor.startOffset);
            const end = pointAt(anchor.endOffset);
            if (!start || !end) return null;
            try {
              const range = document.createRange();
              range.setStart(start.node, start.offset);
              range.setEnd(end.node, end.offset);
              const normalize = value => (value || "").replace(/\\s+/g, " ").trim();
              if (normalize(range.toString()) !== normalize(anchor.selection)) return null;
              return range;
            } catch (_) {
              return null;
            }
          };

          const localContextForRange = range => {
            const origin = range.startContainer.nodeType === Node.TEXT_NODE ? range.startContainer.parentElement : range.startContainer;
            const block = origin?.closest?.("[data-paper-rss-id]");
            if (!block) return origin?.textContent?.trim() || "";
            const blocks = Array.from(document.querySelectorAll("[data-paper-rss-id]"));
            const index = blocks.indexOf(block);
            return blocks.slice(Math.max(0, index - 1), Math.min(blocks.length, index + 2)).map(item => item.textContent.trim()).filter(Boolean).join("\\n\\n");
          };

          const selectionAnchorForRange = range => {
            const startOrigin = range.startContainer.nodeType === Node.TEXT_NODE ? range.startContainer.parentElement : range.startContainer;
            const endOrigin = range.endContainer.nodeType === Node.TEXT_NODE ? range.endContainer.parentElement : range.endContainer;
            const startBlock = startOrigin?.closest?.("[data-paper-rss-id]");
            const endBlock = endOrigin?.closest?.("[data-paper-rss-id]");
            if (!startBlock || startBlock !== endBlock) return null;
            try {
              const startProbe = document.createRange();
              startProbe.selectNodeContents(startBlock);
              startProbe.setEnd(range.startContainer, range.startOffset);
              const endProbe = document.createRange();
              endProbe.selectNodeContents(startBlock);
              endProbe.setEnd(range.endContainer, range.endOffset);
              return {
                paragraphID: startBlock.dataset.paperRssId,
                startOffset: startProbe.toString().length,
                endOffset: endProbe.toString().length
              };
            } catch (_) {
              return null;
            }
          };

          const showPopover = (id, rect, text, state, kind, anchorElement = null, question = null) => {
            dismissPopover();
            activeAnchorRect = rect;
            activeAnchorElement = anchorElement;
            const popover = document.createElement("aside");
            popover.className = "paper-rss-explanation " + (state || "") + (kind === "translation" ? " is-translation" : "");
            popover.dataset.explanationId = id;
            popover.dataset.kind = kind;
            popover.setAttribute("role", "status");
            const header = document.createElement("div");
            header.className = "paper-rss-explanation-header";
            header.append(svgIcon(kind === "translation" ? "translation" : "note"));
            const title = document.createElement("span");
            title.textContent = kind === "translation" ? "翻译" : (question ? "问 AI 答疑" : "AI 解释");
            header.append(title);
            popover.append(header);
            if (question) {
              const qBox = document.createElement("div");
              qBox.className = "paper-rss-question-tag";
              qBox.style.cssText = "font-size:12px;opacity:0.8;margin:4px 0 8px;font-weight:600;";
              qBox.textContent = "问：" + question;
              popover.append(qBox);
            }
            const body = document.createElement("div");
            body.className = "paper-rss-explanation-body";
            body.textContent = text || (kind === "translation" ? "正在翻译…" : "正在生成解答…");
            popover.append(body);
            document.body.append(popover);
            activePopover = popover;
            positionNear(popover, rect, true);
          };

          const updatePopover = (id, text, state, kind) => {
            if (!activePopover || activePopover.dataset.explanationId !== id) return;
            activePopover.className = "paper-rss-explanation " + (state || "") + (kind === "translation" ? " is-translation" : "");
            const body = activePopover.querySelector(".paper-rss-explanation-body");
            if (body) body.textContent = text || (state === "is-error" ? "暂时无法完成，请稍后重试。" : "正在生成…");
            const rect = activeAnchorElement?.isConnected ? activeAnchorElement.getBoundingClientRect() : activeAnchorRect;
            positionNear(activePopover, rect, true);
          };

          const postRequest = (kind, range, selectedText, question = null) => {
            const requestID = "selection-" + Date.now() + "-" + Math.random().toString(36).slice(2);
            const rect = focusRectForSelection(window.getSelection(), range);
            const isExplanation = kind === "explanation" || kind === "note";
            const anchor = isExplanation ? selectionAnchorForRange(range) : null;
            const markers = isExplanation ? markRange(range, requestID, selectedText) : [];
            let marker = markers[0]?.querySelector?.(".paper-rss-annotation-icon") || markers[0] || null;
            if (!marker && kind === "translation") {
              const anchorSpan = document.createElement("span");
              anchorSpan.className = "paper-rss-selection-anchor";
              anchorSpan.setAttribute("aria-hidden", "true");
              const endRange = range.cloneRange();
              endRange.collapse(false);
              endRange.insertNode(anchorSpan);
              marker = anchorSpan;
            }
            showPopover(requestID, marker?.getBoundingClientRect?.() || rect, "", "is-loading", kind, marker, question);
            removeAction();
            window.getSelection()?.removeAllRanges();
            const handler = question ? window.webkit.messageHandlers.paperRssAskSelection : window.webkit.messageHandlers.paperRssExplainSelection;
            handler?.postMessage({
              id: requestID,
              kind,
              selection: selectedText.slice(0, 4000),
              question: question ? question.slice(0, 1000) : null,
              localContext: kind === "explanation" || kind === "note" ? localContextForRange(range).slice(0, 8000) : "",
              anchor
            });
          };

          const presentQuestionInput = (bar, focusRect, range, selectedText) => {
            isAsking = true;
            bar.innerHTML = "";
            bar.className = "paper-rss-selection-actions is-asking";
            const form = document.createElement("form");
            form.className = "paper-rss-ask-form";
            form.style.cssText = "display:flex;align-items:center;gap:4px;padding:2px 6px;";

            const input = document.createElement("input");
            input.type = "text";
            input.className = "paper-rss-ask-input";
            input.placeholder = "针对划选文字提问...";
            input.style.cssText = "border:none;background:transparent;outline:none;font-size:13px;color:var(--paper-ink);width:150px;";

            const sendBtn = document.createElement("button");
            sendBtn.type = "submit";
            sendBtn.className = "paper-rss-selection-action";
            sendBtn.append(svgIcon("ask"));
            sendBtn.setAttribute("title", "发送提问");

            form.append(input, sendBtn);
            bar.append(form);

            form.addEventListener("submit", event => {
              event.preventDefault();
              const question = input.value.trim();
              if (!question) return;
              postRequest("note", range, selectedText, question);
            });

            setTimeout(() => input.focus(), 50);
            positionNear(bar, { left: focusRect.left - 40, top: focusRect.top, width: 80, height: Math.max(1, focusRect.height), bottom: focusRect.bottom });
          };

          const presentActionForSelection = () => {
            if (isAsking) return;
            removeAction();
            const selection = window.getSelection();
            const selectedText = selection?.toString().trim() || "";
            if (!selection || selection.rangeCount === 0 || selectedText.length < 2) return;
            const range = selection.getRangeAt(0).cloneRange();
            const origin = range.commonAncestorContainer.nodeType === Node.TEXT_NODE ? range.commonAncestorContainer.parentElement : range.commonAncestorContainer;
            if (origin?.closest?.(".paper-rss-selection-actions")) return;
            const focusRect = focusRectForSelection(selection, range);
            if (!focusRect || (!focusRect.width && !focusRect.height)) return;
            activeRange = range;
            activeSelection = selectedText;
            const bar = document.createElement("div");
            bar.className = "paper-rss-selection-actions";
            const makeButton = (kind, label) => {
              const button = document.createElement("button");
              button.type = "button";
              button.className = "paper-rss-selection-action";
              button.append(svgIcon(kind));
              button.setAttribute("aria-label", label);
              button.setAttribute("title", label);
              button.addEventListener("pointerdown", event => event.preventDefault());
              button.addEventListener("click", () => {
                if (!activeRange || !activeSelection) return;
                if (kind === "ask") {
                  presentQuestionInput(bar, focusRect, activeRange.cloneRange(), activeSelection);
                } else {
                  postRequest(kind, activeRange.cloneRange(), activeSelection);
                }
              });
              return button;
            };
            bar.append(makeButton("note", "解释所选文字"), makeButton("ask", "问 AI 所选文字"), makeButton("translation", "翻译所选文字"));
            actionBar = bar;
            document.body.append(bar);
            positionNear(bar, { left: focusRect.left - 36, top: focusRect.top, width: 72, height: Math.max(1, focusRect.height), bottom: focusRect.bottom });
          };

          const scheduleSelectionAction = () => {
            if (isAsking) return;
            clearTimeout(selectionTimer);
            selectionTimer = setTimeout(presentActionForSelection, 90);
          };

          document.addEventListener("selectionchange", scheduleSelectionAction);
          document.addEventListener("pointerup", scheduleSelectionAction);
          document.addEventListener("keyup", scheduleSelectionAction);
          document.addEventListener("pointerdown", event => {
            if (isAsking && event.target.closest?.(".paper-rss-selection-actions")) return;
            if (!event.target.closest?.(".paper-rss-selection-actions") && !event.target.closest?.(".paper-rss-explanation")) removeAction();
          }, true);
          document.addEventListener("click", event => {
            if (isAsking && event.target.closest?.(".paper-rss-selection-actions")) return;
            const icon = event.target.closest?.(".paper-rss-annotation-icon");
            if (icon) {
              event.preventDefault();
              const target = icon;
              const loading = target.classList.contains("is-pending");
              const rect = icon.getBoundingClientRect();
              showPopover(target.dataset.explanationId, rect, loading ? "" : (target.dataset.explanation || "解释暂不可用。"), loading ? "is-loading" : "", "explanation", icon);
              return;
            }
            if (!event.target.closest?.(".paper-rss-explanation") && !event.target.closest?.(".paper-rss-selection-actions")) dismissPopover();
          });
          document.addEventListener("scroll", () => {
            if (!isAsking) removeAction();
          }, { passive: true, capture: true });
          window.addEventListener("resize", () => {
            if (!activePopover) return;
            const rect = activeAnchorElement?.isConnected ? activeAnchorElement.getBoundingClientRect() : activeAnchorRect;
            positionNear(activePopover, rect, true);
          }, { passive: true });

          window.paperRssSelectionAssistant = {
            updateInlineTranslation(id, text) {
              const el = document.getElementById("paper-rss-translation-" + id);
              if (!el) return;
              el.classList.remove("is-loading");
              const span = el.querySelector(".paper-rss-translation-text");
              if (span) span.textContent = text;
            },
            append(id, text, kind) {
              if (!text) return;
              const body = activePopover?.dataset.explanationId === id ? activePopover.querySelector(".paper-rss-explanation-body") : null;
              if (body) body.textContent = (body.textContent === "正在结合全文理解这段文字…" || body.textContent === "正在翻译…") ? text : body.textContent + text;
            },
            resolve(id, text, isError, kind) {
              const marks = Array.from(document.querySelectorAll('.paper-rss-explained[data-explanation-id="' + CSS.escape(id) + '"]'));
              const standaloneIcons = Array.from(document.querySelectorAll('.paper-rss-annotation-icon[data-explanation-id="' + CSS.escape(id) + '"]'));
              if (kind === "translation") {
                updatePopover(id, text, isError ? "is-error" : "", kind);
                return;
              }
              if (isError) {
                marks.forEach(mark => { const parent = mark.parentNode; mark.replaceWith(...mark.childNodes); parent?.normalize(); });
                standaloneIcons.forEach(icon => icon.remove());
                updatePopover(id, text, "is-error", kind);
              } else {
                marks.forEach(mark => {
                  mark.classList.remove("is-pending");
                  mark.classList.add("is-complete");
                  mark.dataset.explanation = text;
                  const btn = mark.querySelector(".paper-rss-annotation-icon");
                  if (btn) {
                    btn.classList.remove("is-pending");
                    btn.setAttribute("title", "点击重新查看 AI 解释");
                  }
                });
                standaloneIcons.forEach(icon => {
                  icon.classList.remove("is-pending");
                  icon.dataset.explanation = text;
                  icon.setAttribute("aria-label", "已完成解释，点击重新查看");
                  icon.setAttribute("title", "点击重新查看 AI 解释");
                });
                updatePopover(id, text, "", kind);
              }
            },
            restoreAnnotations(items) {
              (items || []).forEach(item => {
                if (!item?.id || !item?.explanation || document.querySelector('[data-explanation-id="' + CSS.escape(item.id) + '"]')) return;
                const range = rangeForAnchor({
                  paragraphID: item.paragraphID,
                  startOffset: item.startOffset,
                  endOffset: item.endOffset,
                  selection: item.selection
                });
                if (!range) return;
                markRange(range, item.id, item.selection);
                window.paperRssSelectionAssistant.resolve(item.id, item.explanation, false, "explanation");
              });
            }
          };
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    /// Remote article images occasionally fail when WebKit cancels subresource
    /// loads during rapid article changes. Retry only failed images, with a
    /// bounded backoff and a cache-busting query, while normal images remain
    /// handled by WebKit's HTTP cache and native lazy loading.
    static let imageRecoveryScript = WKUserScript(
        source: """
        (() => {
          const attachRecovery = image => {
            if (!image || image.dataset.paperRssRecoveryAttached === "1") return;
            image.dataset.paperRssRecoveryAttached = "1";
            image.addEventListener("error", () => {
              const retry = Number(image.dataset.paperRssRetry || "0");
              const original = image.dataset.paperRssOriginalSource || image.currentSrc || image.src;
              if (!original || retry >= 2) return;
              image.dataset.paperRssOriginalSource = original;
              image.dataset.paperRssRetry = String(retry + 1);
              window.setTimeout(() => {
                try {
                  const url = new URL(original, document.baseURI);
                  url.searchParams.set("_paper_rss_retry", String(retry + 1));
                  image.src = url.href;
                } catch (_) {
                  image.src = original;
                }
              }, retry === 0 ? 350 : 1200);
            }, { passive: true });
          };
          document.querySelectorAll("img").forEach(attachRecovery);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static let nextArticleMessageName = "paperRssNextArticle"
    static let focusListMessageName = "paperRssFocusList"

    static let spacebarScript = WKUserScript(
        source: """
        (() => {
          window.addEventListener("keydown", event => {
            if (event.key === " " || event.keyCode === 32) {
              const active = document.activeElement;
              if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)) {
                return;
              }
              if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) {
                return;
              }
              event.preventDefault();

              const scrollHeight = Math.max(
                document.documentElement.scrollHeight,
                document.body.scrollHeight
              );
              const clientHeight = window.innerHeight;
              const scrollTop = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
              const isAtBottom = (scrollTop + clientHeight) >= (scrollHeight - 6);

              if (isAtBottom) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(nextArticleMessageName)) {
                  window.webkit.messageHandlers.\(nextArticleMessageName).postMessage({});
                }
              } else {
                const pageDistance = Math.max(120, clientHeight * 0.382);
                window.scrollBy({
                  top: pageDistance,
                  behavior: "smooth"
                });
              }
            } else if (event.key === "ArrowLeft" || event.keyCode === 37) {
              const active = document.activeElement;
              if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)) {
                return;
              }
              if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) {
                return;
              }
              if (window.getSelection() && window.getSelection().toString().length > 0) {
                return;
              }
              event.preventDefault();
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(focusListMessageName)) {
                window.webkit.messageHandlers.\(focusListMessageName).postMessage({});
              }
            }
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static let mediaFullscreenScript = WKUserScript(
        source: """
        (() => {
          let scale = 1;
          let translateX = 0;
          let translateY = 0;
          let initialDistance = 0;
          let initialScale = 1;
          let isDragging = false;
          let startX = 0;
          let startY = 0;
          let initialTx = 0;
          let initialTy = 0;
          let lastTapTime = 0;

          const resetZoom = img => {
            scale = 1;
            translateX = 0;
            translateY = 0;
            if (img) {
              img.style.transition = "transform 0.2s cubic-bezier(0.2, 0, 0.2, 1)";
              img.style.transform = "translate(0px, 0px) scale(1)";
            }
          };

          const updateTransform = (img, animate = false) => {
            if (!img) return;
            img.style.transition = animate ? "transform 0.2s cubic-bezier(0.2, 0, 0.2, 1)" : "none";
            img.style.transform = `translate(${translateX}px, ${translateY}px) scale(${scale})`;
          };

          const closeLightbox = () => {
            const overlay = document.getElementById("paper-rss-lightbox-overlay");
            if (overlay && overlay.classList.contains("is-active")) {
              const lightboxImg = overlay.querySelector(".paper-rss-lightbox-img");
              resetZoom(lightboxImg);
              overlay.classList.remove("is-active");
              document.body.style.overflow = "";
            }
          };

          const openLightbox = img => {
            let overlay = document.getElementById("paper-rss-lightbox-overlay");
            if (!overlay) {
              overlay = document.createElement("div");
              overlay.id = "paper-rss-lightbox-overlay";
              overlay.className = "paper-rss-lightbox";
              overlay.innerHTML = `
                <div class="paper-rss-lightbox-backdrop"></div>
                <div class="paper-rss-lightbox-content">
                  <img class="paper-rss-lightbox-img" src="" alt="" />
                  <button class="paper-rss-lightbox-close" title="关闭 (Esc)">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                  </button>
                </div>
              `;
              document.body.appendChild(overlay);

              const lightboxImg = overlay.querySelector(".paper-rss-lightbox-img");

              overlay.addEventListener("click", e => {
                if (e.target === overlay || e.target.classList.contains("paper-rss-lightbox-backdrop") || e.target.closest(".paper-rss-lightbox-close")) {
                  closeLightbox();
                }
              });

              // macOS 触控板 Pinch 手势与滚轮事件
              overlay.addEventListener("wheel", e => {
                if (e.ctrlKey) {
                  e.preventDefault();
                  const zoomFactor = Math.exp(-e.deltaY * 0.01);
                  scale = Math.min(Math.max(1, scale * zoomFactor), 5);
                  if (scale === 1) {
                    translateX = 0;
                    translateY = 0;
                  }
                  updateTransform(lightboxImg, false);
                } else if (scale > 1) {
                  e.preventDefault();
                  translateX -= e.deltaX;
                  translateY -= e.deltaY;
                  updateTransform(lightboxImg, false);
                }
              }, { passive: false });

              // WebKit 原生手势
              overlay.addEventListener("gesturestart", e => {
                e.preventDefault();
                initialScale = scale;
              }, { passive: false });

              overlay.addEventListener("gesturechange", e => {
                e.preventDefault();
                scale = Math.min(Math.max(1, initialScale * e.scale), 5);
                if (scale === 1) {
                  translateX = 0;
                  translateY = 0;
                }
                updateTransform(lightboxImg, false);
              }, { passive: false });

              // 触控屏 Pinch 捏合
              overlay.addEventListener("touchstart", e => {
                if (e.touches.length === 2) {
                  e.preventDefault();
                  initialDistance = Math.hypot(
                    e.touches[0].clientX - e.touches[1].clientX,
                    e.touches[0].clientY - e.touches[1].clientY
                  );
                  initialScale = scale;
                } else if (e.touches.length === 1 && scale > 1) {
                  isDragging = true;
                  startX = e.touches[0].clientX;
                  startY = e.touches[0].clientY;
                  initialTx = translateX;
                  initialTy = translateY;
                }
              }, { passive: false });

              overlay.addEventListener("touchmove", e => {
                if (e.touches.length === 2 && initialDistance > 0) {
                  e.preventDefault();
                  const currentDistance = Math.hypot(
                    e.touches[0].clientX - e.touches[1].clientX,
                    e.touches[0].clientY - e.touches[1].clientY
                  );
                  scale = Math.min(Math.max(1, initialScale * (currentDistance / initialDistance)), 5);
                  if (scale === 1) {
                    translateX = 0;
                    translateY = 0;
                  }
                  updateTransform(lightboxImg, false);
                } else if (e.touches.length === 1 && isDragging && scale > 1) {
                  e.preventDefault();
                  translateX = initialTx + (e.touches[0].clientX - startX);
                  translateY = initialTy + (e.touches[0].clientY - startY);
                  updateTransform(lightboxImg, false);
                }
              }, { passive: false });

              overlay.addEventListener("touchend", () => {
                isDragging = false;
                if (scale < 1) resetZoom(lightboxImg);
              }, { passive: false });

              // 鼠标拖拽 (Scale > 1)
              lightboxImg.addEventListener("mousedown", e => {
                if (scale > 1) {
                  e.preventDefault();
                  isDragging = true;
                  startX = e.clientX;
                  startY = e.clientY;
                  initialTx = translateX;
                  initialTy = translateY;
                }
              });

              window.addEventListener("mousemove", e => {
                if (isDragging && scale > 1) {
                  translateX = initialTx + (e.clientX - startX);
                  translateY = initialTy + (e.clientY - startY);
                  updateTransform(lightboxImg, false);
                }
              });

              window.addEventListener("mouseup", () => {
                isDragging = false;
              });

              // 双击快速放大 / 重置
              lightboxImg.addEventListener("click", e => {
                e.stopPropagation();
                const now = Date.now();
                if (now - lastTapTime < 300) {
                  if (scale > 1.2) {
                    resetZoom(lightboxImg);
                  } else {
                    scale = 2.5;
                    translateX = 0;
                    translateY = 0;
                    updateTransform(lightboxImg, true);
                  }
                }
                lastTapTime = now;
              });
            }

            const lightboxImg = overlay.querySelector(".paper-rss-lightbox-img");
            if (lightboxImg) {
              resetZoom(lightboxImg);
              lightboxImg.src = img.currentSrc || img.src;
              lightboxImg.alt = img.alt || "";
            }

            overlay.classList.add("is-active");
            document.body.style.overflow = "hidden";
          };

          document.addEventListener("click", event => {
            const target = event.target.closest("img, video");
            if (!target) return;
            if (target.classList.contains("paper-summary-icon") || target.classList.contains("paper-rss-annotation-icon") || target.closest(".paper-rss-explanation")) {
              return;
            }

            if (target.tagName === "VIDEO") {
              if (document.fullscreenElement || document.webkitFullscreenElement) {
                const exit = document.exitFullscreen || document.webkitExitFullscreen;
                if (exit) exit.call(document);
              } else {
                const req = target.requestFullscreen || target.webkitRequestFullscreen;
                if (req) req.call(target);
              }
            } else if (target.tagName === "IMG") {
              if (target.classList.contains("paper-rss-lightbox-img")) {
                return;
              }
              event.preventDefault();
              event.stopPropagation();
              openLightbox(target);
            }
          }, true);

          window.addEventListener("keydown", event => {
            if (event.key === "Escape" || event.keyCode === 27) {
              closeLightbox();
            }
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static let fontSizeMessageName = "paperRssFontSize"

    static let fontSizeScript = WKUserScript(
        source: """
        (() => {
          window.addEventListener("keydown", event => {
            if (event.metaKey || event.ctrlKey) {
              const isIncrease = (event.key === "=" || event.key === "+" || event.keyCode === 187 || event.keyCode === 61 || event.keyCode === 107);
              const isDecrease = (event.key === "-" || event.key === "_" || event.keyCode === 189 || event.keyCode === 173 || event.keyCode === 109);
              const isReset = (event.key === "0" || event.keyCode === 48 || event.keyCode === 96);
              if (isIncrease || isDecrease || isReset) {
                event.preventDefault();
                event.stopPropagation();
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(fontSizeMessageName)) {
                  const action = isIncrease ? "increase" : (isDecrease ? "decrease" : "reset");
                  window.webkit.messageHandlers.\(fontSizeMessageName).postMessage({ action: action });
                }
              }
            }
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )
}

#if os(macOS)
private final class ArticleWebViewContainer: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if webView.superview === self {
            webView.frame = bounds
        }
    }
}

private struct ArticleHTMLView: NSViewRepresentable {
    let entry: Entry
    let feedTitle: String?
    let html: String
    let baseURL: URL?
    let contentTopInset: CGFloat
    let readerParagraphs: [ReaderParagraph]
    let inlineTranslations: [BilingualSegment]
    let pendingTranslationIDs: Set<String>
    let selectionAnnotations: [ReaderSelectionAnnotation]
    let isBilingualMode: Bool
    let fontSize: Int
    let summaryArtifact: AIArtifact?
    let isSummaryExpanded: Bool
    let isGeneratingSummary: Bool
    let aiStatusMessage: String?
    let errorMessage: String?
    let onVisibleParagraphIDsChange: ([String]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void
    let onSelectionRequest: (
        ReaderSelectionRequest,
        @escaping @Sendable (String) async -> Void
    ) async -> ReaderSelectionResponse
    let onGenerateSummary: (Bool) -> Void
    let onToggleSummary: () -> Void
    var onSelectNextEntry: () -> Void = {}
    var onFocusListView: () -> Void = {}
    var onAdjustFontSize: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ArticleWebViewContainer {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // HTML5 <video> fullscreen (and the Fullscreen API in general) is
        // disabled by default in WKWebView. Without this, the video element's
        // fullscreen control does nothing on macOS.
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.scrollMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.visibleParagraphsMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.explainSelectionMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.askSelectionMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.nextArticleMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.focusListMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.fontSizeMessageName
        )
        // 摘要卡片按钮使用 observerScript (.defaultClient 特权世界) 的全局点击
        // 捕获代理发布 postMessage,在 CSP script-src 'none' 下完美安全触发。
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: "paperRssGenerateSummary"
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: "paperRssToggleSummary"
        )
        configuration.userContentController.addUserScript(PaperReaderBridge.observerScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.selectionScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.imageRecoveryScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.spacebarScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.mediaFullscreenScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.fontSizeScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.wantsLayer = true
        webView.layer?.masksToBounds = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.setAccessibilityLabel(isBilingualMode ? "原文与中文逐段翻译" : "原文内容")
        webView.enclosingScrollView?.hasVerticalScroller = true
        webView.enclosingScrollView?.autohidesScrollers = true
        webView.enclosingScrollView?.verticalScrollElasticity = .automatic
        webView.enclosingScrollView?.horizontalScrollElasticity = .none
        webView.enclosingScrollView?.drawsBackground = false
        context.coordinator.webView = webView
        context.coordinator.loadIfNeeded(into: webView)
        return ArticleWebViewContainer(webView: webView)
    }

    func updateNSView(_ container: ArticleWebViewContainer, context: Context) {
        let webView = container.webView
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(into: webView)
        context.coordinator.synchronizeSummaryCard(in: webView)
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--paper-font-size', '\(fontSize)px')")
        for segment in inlineTranslations {
            context.coordinator.updateInlineTranslationInWebView(id: segment.id, translation: segment.translation)
        }
    }

    static func dismantleNSView(_ container: ArticleWebViewContainer, coordinator: Coordinator) {
        let webView = container.webView
        webView.isHidden = true
        webView.removeFromSuperview()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.scrollMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.visibleParagraphsMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.explainSelectionMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.askSelectionMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.nextArticleMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "paperRssGenerateSummary",
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "paperRssToggleSummary",
            contentWorld: .defaultClient
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: ArticleHTMLView
        private var loadedArticleKey: String?
        private var renderedTranslations: [String: String] = [:]
        private var renderedPendingTranslationIDs = Set<String>()
        private var selectionExplanationTask: Task<Void, Never>?
        private var activeSelectionExplanationID: String?
        private var pendingSelectionExplanationRequests: [ReaderSelectionRequest] = []
        weak var webView: WKWebView?

        init(parent: ArticleHTMLView) {
            self.parent = parent
        }

        func updateInlineTranslationInWebView(id: String, translation: String) {
            guard renderedTranslations[id] != translation else { return }
            renderedTranslations[id] = translation
            let escaped = (try? String(data: JSONEncoder().encode(translation), encoding: .utf8)) ?? "\"\""
            webView?.evaluateJavaScript("window.paperRssSelectionAssistant?.updateInlineTranslation('\(id)', \(escaped))")
        }

        func synchronizeSummaryCard(in webView: WKWebView) {
            let summaryHTML = PaperReaderHeaderBuilder.summaryCardHTML(
                summaryArtifact: parent.summaryArtifact,
                isSummaryExpanded: parent.isSummaryExpanded,
                isGeneratingSummary: parent.isGeneratingSummary,
                aiStatusMessage: parent.aiStatusMessage,
                errorMessage: parent.errorMessage
            )
            guard let data = try? JSONEncoder().encode(summaryHTML),
                  let jsonEncoded = String(data: data, encoding: .utf8) else { return }
            let script = """
            (() => {
              const card = document.getElementById('paper-summary-card');
              if (card) {
                card.innerHTML = \(jsonEncoded);
              }
            })();
            """
            webView.evaluateJavaScript(script)
        }

        private func readerScrollView(in webView: WKWebView) -> NSScrollView? {
            var candidates = descendantScrollViews(in: webView)
            if let enclosingScrollView = webView.enclosingScrollView,
               !candidates.contains(where: { $0 === enclosingScrollView }) {
                candidates.append(enclosingScrollView)
            }

            // WKWebView can contain more than one AppKit scroll view. The main
            // article scroller is the candidate whose document extends furthest
            // beyond its viewport after WebKit has laid out the page.
            return candidates.max { lhs, rhs in
                scrollableExtent(of: lhs) < scrollableExtent(of: rhs)
            }
        }

        private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
            var result = (view as? NSScrollView).map { [$0] } ?? []
            for subview in view.subviews {
                result.append(contentsOf: descendantScrollViews(in: subview))
            }
            return result
        }

        private func scrollableExtent(of scrollView: NSScrollView) -> CGFloat {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let viewportHeight = scrollView.contentView.bounds.height
            return max(0, documentHeight - viewportHeight)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case PaperReaderBridge.scrollMessageName:
                guard let offset = message.body as? Double else { return }
                parent.onScrollOffsetChange(CGFloat(max(0, offset)))
            case PaperReaderBridge.visibleParagraphsMessageName:
                guard let paragraphIDs = message.body as? [String] else { return }
                parent.onVisibleParagraphIDsChange(paragraphIDs)
            case PaperReaderBridge.explainSelectionMessageName, PaperReaderBridge.askSelectionMessageName:
                guard let payload = message.body as? [String: Any],
                      let id = payload["id"] as? String,
                      let selection = payload["selection"] as? String,
                      let localContext = payload["localContext"] as? String,
                      !selection.isEmpty else { return }
                let question = payload["question"] as? String
                let anchorPayload = payload["anchor"] as? [String: Any]
                let anchor = anchorPayload.flatMap { payload -> AISelectionAnchor? in
                    guard let paragraphID = payload["paragraphID"] as? String,
                          let startOffset = (payload["startOffset"] as? NSNumber)?.intValue,
                          let endOffset = (payload["endOffset"] as? NSNumber)?.intValue else { return nil }
                    return AISelectionAnchor(paragraphID: paragraphID, startOffset: startOffset, endOffset: endOffset)
                }
                let request = ReaderSelectionRequest(
                    id: id,
                    selection: selection,
                    question: question,
                    localContext: localContext,
                    kind: ReaderSelectionKind(rawValue: payload["kind"] as? String ?? "explanation") ?? .explanation,
                    anchor: anchor
                )
                pendingSelectionExplanationRequests.append(request)
                startNextSelectionExplanationIfNeeded()
            case PaperReaderBridge.nextArticleMessageName:
                parent.onSelectNextEntry()
            case PaperReaderBridge.focusListMessageName:
                parent.onFocusListView()
            case PaperReaderBridge.fontSizeMessageName:
                guard let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }
                parent.onAdjustFontSize?(action)
            case "paperRssGenerateSummary":
                let force = (message.body as? [String: Any])?["force"] as? Bool ?? false
                parent.onGenerateSummary(force)
            case "paperRssToggleSummary":
                parent.onToggleSummary()
            default:
                break
            }
        }

        /// Closing a popover is purely presentational. Requests run to
        /// completion so an already-sent request can populate the cached
        /// explanation/translation even if the reader moves on.
        private func startNextSelectionExplanationIfNeeded() {
            guard selectionExplanationTask == nil,
                  !pendingSelectionExplanationRequests.isEmpty else { return }
            let request = pendingSelectionExplanationRequests.removeFirst()
            activeSelectionExplanationID = request.id
            selectionExplanationTask = Task { @MainActor [weak self] in
                guard let self, let webView = self.webView else { return }
                let response = await self.parent.onSelectionRequest(request) { [weak self] delta in
                    guard let self else { return }
                    await self.sendSelectionDelta(delta, for: request)
                }
                guard self.activeSelectionExplanationID == request.id else { return }
                _ = try? await webView.callAsyncJavaScript(
                    "window.paperRssSelectionAssistant?.resolve(id, text, isError, kind)",
                    arguments: [
                        "id": request.id,
                        "text": response.text,
                        "isError": response.isError,
                        "kind": request.kind.rawValue
                    ],
                    in: nil,
                    contentWorld: .defaultClient
                )
                self.selectionExplanationTask = nil
                self.activeSelectionExplanationID = nil
                self.startNextSelectionExplanationIfNeeded()
            }
        }

        @MainActor
        private func sendSelectionDelta(_ delta: String, for request: ReaderSelectionRequest) async {
            guard let webView else { return }
            _ = try? await webView.callAsyncJavaScript(
                "window.paperRssSelectionAssistant?.append(id, text, kind)",
                arguments: ["id": request.id, "text": delta, "kind": request.kind.rawValue],
                in: nil,
                contentWorld: .defaultClient
            )
        }

        func loadIfNeeded(into webView: WKWebView) {
            let secureBaseURL = parent.baseURL.flatMap { url -> URL? in
                guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return nil }
                return url
            }
            let articleKey = "\(parent.entry.id)|\(secureBaseURL?.absoluteString ?? "")"
            guard loadedArticleKey != articleKey else {
                synchronizeContentTopInset(in: webView)
                synchronizeTranslations(in: webView)
                synchronizeSummaryCard(in: webView)
                return
            }
            let initialTranslationState = translationState()
            let readerHTML = ArticleExtractor.insertingInlineTranslations(
                into: parent.html,
                segments: parent.inlineTranslations,
                pendingIDs: parent.isBilingualMode ? parent.pendingTranslationIDs : []
            )
            let headerHTML = PaperReaderHeaderBuilder.headerHTML(
                entry: parent.entry,
                feedTitle: parent.feedTitle,
                summaryArtifact: parent.summaryArtifact,
                isSummaryExpanded: parent.isSummaryExpanded,
                isGeneratingSummary: parent.isGeneratingSummary,
                aiStatusMessage: parent.aiStatusMessage,
                isBilingualMode: parent.isBilingualMode,
                titleSegment: parent.inlineTranslations.first(where: { $0.id == "title" }),
                isTitlePending: parent.pendingTranslationIDs.contains("title")
            )
            let document = Self.documentHTML(
                body: readerHTML,
                topInset: parent.contentTopInset,
                fontSize: parent.fontSize,
                headerHTML: headerHTML
            )
            loadedArticleKey = articleKey
            renderedTranslations = initialTranslationState.translations
            renderedPendingTranslationIDs = initialTranslationState.pendingIDs
            pendingScrollOffset = readerScrollView(in: webView)?.contentView.bounds.origin.y
            webView.loadHTMLString(document, baseURL: secureBaseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                if let offset = self.pendingScrollOffset,
                   let scrollView = self.readerScrollView(in: webView) {
                    self.pendingScrollOffset = nil
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    self.parent.onScrollOffsetChange(max(0, offset))
                }
                self.synchronizeContentTopInset(in: webView)
                self.synchronizeTranslations(in: webView)
                self.synchronizeSummaryCard(in: webView)
                self.restoreSelectionAnnotations(in: webView)
            }
        }

        private func restoreSelectionAnnotations(in webView: WKWebView) {
            guard !parent.selectionAnnotations.isEmpty else { return }
            let items: [[String: Any]] = parent.selectionAnnotations.map {
                [
                    "id": $0.id,
                    "selection": $0.selection,
                    "explanation": $0.explanation,
                    "paragraphID": $0.paragraphID,
                    "startOffset": $0.startOffset,
                    "endOffset": $0.endOffset
                ]
            }
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "window.paperRssSelectionAssistant?.restoreAnnotations(items)",
                    arguments: ["items": items],
                    in: nil,
                    contentWorld: .defaultClient
                )
            }
        }

        private func synchronizeContentTopInset(in webView: WKWebView) {
            let inset = max(0, parent.contentTopInset)
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "document.documentElement.style.setProperty('--paper-reader-top-inset', inset + 'px')",
                    arguments: ["inset": inset],
                    in: nil,
                    contentWorld: .defaultClient
                )
            }
        }

        private func synchronizeTranslations(in webView: WKWebView) {
            let desired = translationState()
            let currentIDs = Set(renderedTranslations.keys).union(renderedPendingTranslationIDs)
            let desiredIDs = Set(desired.translations.keys).union(desired.pendingIDs)
            let removals = Array(currentIDs.subtracting(desiredIDs)).sorted()

            var updates: [[String: Any]] = []
            for id in desired.translations.keys.sorted() {
                guard let translation = desired.translations[id],
                      renderedTranslations[id] != translation || renderedPendingTranslationIDs.contains(id) else { continue }
                updates.append(["id": id, "text": translation, "isLoading": false])
            }
            for id in desired.pendingIDs.sorted() where !renderedPendingTranslationIDs.contains(id) || renderedTranslations[id] != nil {
                updates.append(["id": id, "text": "正在翻译…", "isLoading": true])
            }

            guard !updates.isEmpty || !removals.isEmpty else { return }
            renderedTranslations = desired.translations
            renderedPendingTranslationIDs = desired.pendingIDs
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    Self.translationSynchronizationScript,
                    arguments: ["updates": updates, "removals": removals],
                    in: nil,
                    contentWorld: .defaultClient
                )
            }
        }

        private func translationState() -> (translations: [String: String], pendingIDs: Set<String>) {
            guard parent.isBilingualMode else { return ([:], []) }
            let sourceByID = Dictionary(uniqueKeysWithValues: parent.readerParagraphs.map { ($0.id, $0) })
            let translations = parent.inlineTranslations.reduce(into: [String: String]()) { result, segment in
                guard let source = sourceByID[segment.id],
                      source.original.isSameReaderParagraph(as: segment.original) else { return }
                result[segment.id] = segment.translation
            }
            let pendingIDs = parent.pendingTranslationIDs.subtracting(translations.keys)
            return (translations, pendingIDs)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            // The initial, locally supplied document is the only navigation allowed
            // inside this unprivileged view. Links always leave through NSWorkspace.
            decisionHandler(navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }

        private var pendingScrollOffset: CGFloat?

        private static let translationSynchronizationScript = """
        const visibleNodes = Array.from(document.querySelectorAll("[data-paper-rss-id]"))
          .filter(node => {
            const rect = node.getBoundingClientRect();
            return rect.bottom > 0 && rect.top < window.innerHeight;
          });
        const anchor = visibleNodes[0] || null;
        const anchorTop = anchor ? anchor.getBoundingClientRect().top : null;

        const translationNodeID = id => "paper-rss-translation-" + id;
        const makeTranslation = update => {
          const aside = document.createElement("aside");
          aside.id = translationNodeID(update.id);
          aside.dataset.paperRssTranslationFor = update.id;

          const label = document.createElement("span");
          label.className = "paper-rss-translation-label";
          label.setAttribute("aria-label", "译文");
          ["A", "文"].forEach(value => {
            const chip = document.createElement("span");
            chip.className = "paper-rss-language-chip";
            chip.textContent = value;
            chip.setAttribute("aria-hidden", "true");
            label.appendChild(chip);
          });
          const paragraph = document.createElement("p");
          const text = document.createElement("span");
          text.className = "paper-rss-translation-text";
          paragraph.append(label, text);
          aside.append(paragraph);
          return aside;
        };

        const applyUpdate = update => {
          if (!update || !update.id) return;
          const source = document.querySelector(
            '[data-paper-rss-id="' + CSS.escape(update.id) + '"]'
          );
          if (!source) return;
          let aside = document.getElementById(translationNodeID(update.id));
          if (!aside) {
            aside = makeTranslation(update);
            source.insertAdjacentElement("afterend", aside);
          }
          aside.classList.toggle("is-loading", Boolean(update.isLoading));
          aside.setAttribute("aria-label", update.isLoading ? "正在生成中文翻译" : "中文翻译");
          if (update.isLoading) aside.setAttribute("aria-live", "polite");
          else aside.removeAttribute("aria-live");
          const paragraph = aside.querySelector(".paper-rss-translation-text");
          if (paragraph) paragraph.textContent = update.text || "";
        };

        removals.forEach(id => document.getElementById(translationNodeID(id))?.remove());
        updates.forEach(applyUpdate);

        if (anchor && anchorTop !== null) {
          const delta = anchor.getBoundingClientRect().top - anchorTop;
          if (Math.abs(delta) > 0.5) window.scrollBy(0, delta);
        }
        """

        private static func documentHTML(body: String, topInset: CGFloat, fontSize: Int, headerHTML: String) -> String {
            return """
            <!doctype html>
            <html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https: data: blob:; style-src 'unsafe-inline'; font-src 'none'; media-src http: https: data: blob:; object-src 'none'; frame-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'">
            <style>:root { --paper-reader-top-inset: \(max(0, topInset))px; --paper-font-size: \(fontSize)px; }\(paperArticleStyle)</style>
            </head><body>\(headerHTML)\(body)</body></html>
            """
        }
    }
}
#endif

#if os(iOS)
private struct ArticleHTMLView: UIViewRepresentable {
    let entry: Entry
    let feedTitle: String?
    let html: String
    let baseURL: URL?
    let contentTopInset: CGFloat
    let readerParagraphs: [ReaderParagraph]
    let inlineTranslations: [BilingualSegment]
    let pendingTranslationIDs: Set<String>
    let selectionAnnotations: [ReaderSelectionAnnotation]
    let isBilingualMode: Bool
    let fontSize: Int
    let summaryArtifact: AIArtifact?
    let isSummaryExpanded: Bool
    let isGeneratingSummary: Bool
    let aiStatusMessage: String?
    let errorMessage: String?
    let onVisibleParagraphIDsChange: ([String]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void
    let onSelectionRequest: (
        ReaderSelectionRequest,
        @escaping @Sendable (String) async -> Void
    ) async -> ReaderSelectionResponse
    let onGenerateSummary: (Bool) -> Void
    let onToggleSummary: () -> Void
    var onSelectNextEntry: () -> Void = {}
    var onFocusListView: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // iOS 15.4+ exposes the same Fullscreen API preference; enable it so
        // article videos can use the native fullscreen controller.
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.scrollMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.visibleParagraphsMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.explainSelectionMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.askSelectionMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.nextArticleMessageName
        )
        // 摘要卡片按钮使用 observerScript (.defaultClient 特权世界) 的全局点击
        // 捕获代理发布 postMessage,在 CSP script-src 'none' 下完美安全触发。
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: "paperRssGenerateSummary"
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: "paperRssToggleSummary"
        )
        configuration.userContentController.addUserScript(PaperReaderBridge.observerScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.selectionScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.imageRecoveryScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.spacebarScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.mediaFullscreenScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.alwaysBounceVertical = true
        webView.accessibilityLabel = isBilingualMode ? "原文与中文逐段翻译" : "原文内容"
        context.coordinator.webView = webView
        context.coordinator.loadIfNeeded(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(into: webView)
        context.coordinator.synchronizeSummaryCard(in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.scrollMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.visibleParagraphsMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.explainSelectionMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.askSelectionMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: PaperReaderBridge.nextArticleMessageName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "paperRssGenerateSummary",
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "paperRssToggleSummary",
            contentWorld: .defaultClient
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: ArticleHTMLView
        private var loadedArticleKey: String?
        private var pendingContentOffset: CGPoint?
        private var renderedTranslations: [String: String] = [:]
        private var renderedPendingTranslationIDs = Set<String>()
        private var selectionExplanationTask: Task<Void, Never>?
        private var activeSelectionExplanationID: String?
        private var pendingSelectionExplanationRequests: [ReaderSelectionRequest] = []
        weak var webView: WKWebView?

        init(parent: ArticleHTMLView) {
            self.parent = parent
        }

        func synchronizeSummaryCard(in webView: WKWebView) {
            let summaryHTML = PaperReaderHeaderBuilder.summaryCardHTML(
                summaryArtifact: parent.summaryArtifact,
                isSummaryExpanded: parent.isSummaryExpanded,
                isGeneratingSummary: parent.isGeneratingSummary,
                aiStatusMessage: parent.aiStatusMessage,
                errorMessage: parent.errorMessage
            )
            guard let data = try? JSONEncoder().encode(summaryHTML),
                  let jsonEncoded = String(data: data, encoding: .utf8) else { return }
            let script = """
            (() => {
              const card = document.getElementById('paper-summary-card');
              if (card) {
                card.innerHTML = \(jsonEncoded);
              }
            })();
            """
            webView.evaluateJavaScript(script)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case PaperReaderBridge.scrollMessageName:
                guard let offset = message.body as? Double else { return }
                parent.onScrollOffsetChange(CGFloat(max(0, offset)))
            case PaperReaderBridge.visibleParagraphsMessageName:
                guard let paragraphIDs = message.body as? [String] else { return }
                parent.onVisibleParagraphIDsChange(paragraphIDs)
            case PaperReaderBridge.explainSelectionMessageName, PaperReaderBridge.askSelectionMessageName:
                guard let payload = message.body as? [String: Any],
                      let id = payload["id"] as? String,
                      let selection = payload["selection"] as? String,
                      let localContext = payload["localContext"] as? String,
                      !selection.isEmpty else { return }
                let question = payload["question"] as? String
                let anchorPayload = payload["anchor"] as? [String: Any]
                let anchor = anchorPayload.flatMap { payload -> AISelectionAnchor? in
                    guard let paragraphID = payload["paragraphID"] as? String,
                          let startOffset = (payload["startOffset"] as? NSNumber)?.intValue,
                          let endOffset = (payload["endOffset"] as? NSNumber)?.intValue else { return nil }
                    return AISelectionAnchor(paragraphID: paragraphID, startOffset: startOffset, endOffset: endOffset)
                }
                let request = ReaderSelectionRequest(
                    id: id,
                    selection: selection,
                    question: question,
                    localContext: localContext,
                    kind: ReaderSelectionKind(rawValue: payload["kind"] as? String ?? "explanation") ?? .explanation,
                    anchor: anchor
                )
                pendingSelectionExplanationRequests.append(request)
                startNextSelectionExplanationIfNeeded()
            case PaperReaderBridge.nextArticleMessageName:
                parent.onSelectNextEntry()
            case "paperRssGenerateSummary":
                let force = (message.body as? [String: Any])?["force"] as? Bool ?? false
                parent.onGenerateSummary(force)
            case "paperRssToggleSummary":
                parent.onToggleSummary()
            default:
                break
            }
        }

        private func startNextSelectionExplanationIfNeeded() {
            guard selectionExplanationTask == nil,
                  !pendingSelectionExplanationRequests.isEmpty else { return }
            let request = pendingSelectionExplanationRequests.removeFirst()
            activeSelectionExplanationID = request.id
            selectionExplanationTask = Task { @MainActor [weak self] in
                guard let self, let webView = self.webView else { return }
                let response = await self.parent.onSelectionRequest(request) { [weak self] delta in
                    guard let self else { return }
                    await self.sendSelectionDelta(delta, for: request)
                }
                guard self.activeSelectionExplanationID == request.id else { return }
                _ = try? await webView.callAsyncJavaScript(
                    "window.paperRssSelectionAssistant?.resolve(id, text, isError, kind)",
                    arguments: [
                        "id": request.id,
                        "text": response.text,
                        "isError": response.isError,
                        "kind": request.kind.rawValue
                    ],
                    in: nil,
                    contentWorld: .defaultClient
                )
                self.selectionExplanationTask = nil
                self.activeSelectionExplanationID = nil
                self.startNextSelectionExplanationIfNeeded()
            }
        }

        @MainActor
        private func sendSelectionDelta(_ delta: String, for request: ReaderSelectionRequest) async {
            guard let webView else { return }
            _ = try? await webView.callAsyncJavaScript(
                "window.paperRssSelectionAssistant?.append(id, text, kind)",
                arguments: ["id": request.id, "text": delta, "kind": request.kind.rawValue],
                in: nil,
                contentWorld: .defaultClient
            )
        }

        func loadIfNeeded(into webView: WKWebView) {
            let secureBaseURL = parent.baseURL.flatMap { url -> URL? in
                guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return nil }
                return url
            }
            let articleKey = "\(parent.entry.id)|\(secureBaseURL?.absoluteString ?? "")"
            guard loadedArticleKey != articleKey else {
                synchronizeContentTopInset(in: webView)
                synchronizeTranslations(in: webView)
                synchronizeSummaryCard(in: webView)
                return
            }
            let initialTranslationState = translationState()
            let readerHTML = ArticleExtractor.insertingInlineTranslations(
                into: parent.html,
                segments: parent.inlineTranslations,
                pendingIDs: parent.isBilingualMode ? parent.pendingTranslationIDs : []
            )
            let headerHTML = PaperReaderHeaderBuilder.headerHTML(
                entry: parent.entry,
                feedTitle: parent.feedTitle,
                summaryArtifact: parent.summaryArtifact,
                isSummaryExpanded: parent.isSummaryExpanded,
                isGeneratingSummary: parent.isGeneratingSummary,
                aiStatusMessage: parent.aiStatusMessage,
                isBilingualMode: parent.isBilingualMode,
                titleSegment: parent.inlineTranslations.first(where: { $0.id == "title" }),
                isTitlePending: parent.pendingTranslationIDs.contains("title")
            )
            let document = Self.documentHTML(
                body: readerHTML,
                topInset: parent.contentTopInset,
                fontSize: parent.fontSize,
                headerHTML: headerHTML
            )
            loadedArticleKey = articleKey
            renderedTranslations = initialTranslationState.translations
            renderedPendingTranslationIDs = initialTranslationState.pendingIDs
            pendingContentOffset = webView.scrollView.contentOffset
            webView.loadHTMLString(document, baseURL: secureBaseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let offset = pendingContentOffset
            pendingContentOffset = nil
            DispatchQueue.main.async {
                if let offset {
                    webView.scrollView.setContentOffset(offset, animated: false)
                    self.parent.onScrollOffsetChange(
                        max(0, offset.y + webView.scrollView.adjustedContentInset.top)
                    )
                }
                self.synchronizeContentTopInset(in: webView)
                self.synchronizeTranslations(in: webView)
                self.synchronizeSummaryCard(in: webView)
                self.restoreSelectionAnnotations(in: webView)
            }
        }

        private func restoreSelectionAnnotations(in webView: WKWebView) {
            guard !parent.selectionAnnotations.isEmpty else { return }
            let items: [[String: Any]] = parent.selectionAnnotations.map {
                [
                    "id": $0.id,
                    "selection": $0.selection,
                    "explanation": $0.explanation,
                    "paragraphID": $0.paragraphID,
                    "startOffset": $0.startOffset,
                    "endOffset": $0.endOffset
                ]
            }
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "window.paperRssSelectionAssistant?.restoreAnnotations(items)",
                    arguments: ["items": items],
                    in: nil,
                    contentWorld: .defaultClient
                )
            }
        }

        private func synchronizeContentTopInset(in webView: WKWebView) {
            let inset = max(0, parent.contentTopInset)
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "document.documentElement.style.setProperty('--paper-reader-top-inset', inset + 'px')",
                    arguments: ["inset": inset],
                    in: nil,
                    contentWorld: .defaultClient
                )
            }
        }

        private func synchronizeTranslations(in webView: WKWebView) {
            let desired = translationState()
            let currentIDs = Set(renderedTranslations.keys).union(renderedPendingTranslationIDs)
            let desiredIDs = Set(desired.translations.keys).union(desired.pendingIDs)
            let removals = Array(currentIDs.subtracting(desiredIDs)).sorted()

            var updates: [[String: Any]] = []
            for id in desired.translations.keys.sorted() {
                guard let translation = desired.translations[id],
                      renderedTranslations[id] != translation || renderedPendingTranslationIDs.contains(id) else { continue }
                updates.append(["id": id, "text": translation, "isLoading": false])
            }
            for id in desired.pendingIDs.sorted() where !renderedPendingTranslationIDs.contains(id) || renderedTranslations[id] != nil {
                updates.append(["id": id, "text": "正在翻译…", "isLoading": true])
            }

            guard !updates.isEmpty || !removals.isEmpty else { return }
            renderedTranslations = desired.translations
            renderedPendingTranslationIDs = desired.pendingIDs
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    Self.translationSynchronizationScript,
                    arguments: ["updates": updates, "removals": removals],
                    in: nil,
                    contentWorld: .defaultClient
                )
            }
        }

        private func translationState() -> (translations: [String: String], pendingIDs: Set<String>) {
            guard parent.isBilingualMode else { return ([:], []) }
            let sourceByID = Dictionary(uniqueKeysWithValues: parent.readerParagraphs.map { ($0.id, $0) })
            let translations = parent.inlineTranslations.reduce(into: [String: String]()) { result, segment in
                guard let source = sourceByID[segment.id],
                      source.original.isSameReaderParagraph(as: segment.original) else { return }
                result[segment.id] = segment.translation
            }
            let pendingIDs = parent.pendingTranslationIDs.subtracting(translations.keys)
            return (translations, pendingIDs)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }

        private static let translationSynchronizationScript = """
        const visibleNodes = Array.from(document.querySelectorAll("[data-paper-rss-id]"))
          .filter(node => {
            const rect = node.getBoundingClientRect();
            return rect.bottom > 0 && rect.top < window.innerHeight;
          });
        const anchor = visibleNodes[0] || null;
        const anchorTop = anchor ? anchor.getBoundingClientRect().top : null;

        const translationNodeID = id => "paper-rss-translation-" + id;
        const makeTranslation = update => {
          const aside = document.createElement("aside");
          aside.id = translationNodeID(update.id);
          aside.dataset.paperRssTranslationFor = update.id;

          const label = document.createElement("span");
          label.className = "paper-rss-translation-label";
          label.setAttribute("aria-label", "译文");
          ["A", "文"].forEach(value => {
            const chip = document.createElement("span");
            chip.className = "paper-rss-language-chip";
            chip.textContent = value;
            chip.setAttribute("aria-hidden", "true");
            label.appendChild(chip);
          });
          const paragraph = document.createElement("p");
          const text = document.createElement("span");
          text.className = "paper-rss-translation-text";
          paragraph.append(label, text);
          aside.append(paragraph);
          return aside;
        };

        const applyUpdate = update => {
          if (!update || !update.id) return;
          const source = document.querySelector(
            '[data-paper-rss-id="' + CSS.escape(update.id) + '"]'
          );
          if (!source) return;
          let aside = document.getElementById(translationNodeID(update.id));
          if (!aside) {
            aside = makeTranslation(update);
            source.insertAdjacentElement("afterend", aside);
          }
          aside.classList.toggle("is-loading", Boolean(update.isLoading));
          aside.setAttribute("aria-label", update.isLoading ? "正在生成中文翻译" : "中文翻译");
          if (update.isLoading) aside.setAttribute("aria-live", "polite");
          else aside.removeAttribute("aria-live");
          const paragraph = aside.querySelector(".paper-rss-translation-text");
          if (paragraph) paragraph.textContent = update.text || "";
        };

        removals.forEach(id => document.getElementById(translationNodeID(id))?.remove());
        updates.forEach(applyUpdate);

        if (anchor && anchorTop !== null) {
          const delta = anchor.getBoundingClientRect().top - anchorTop;
          if (Math.abs(delta) > 0.5) window.scrollBy(0, delta);
        }
        """

        private static func documentHTML(body: String, topInset: CGFloat, fontSize: Int, headerHTML: String) -> String {
            return """
            <!doctype html>
            <html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https: data: blob:; style-src 'unsafe-inline'; font-src 'none'; media-src http: https: data: blob:; object-src 'none'; frame-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'">
            <style>:root { --paper-reader-top-inset: \(max(0, topInset))px; --paper-font-size: \(fontSize)px; }\(paperArticleStyle)</style>
            </head><body>\(headerHTML)\(body)</body></html>
            """
        }
    }
}
#endif

private struct BilingualContent: View {
    let segments: [BilingualSegment]
    let isLoadingNextBatch: Bool
    let hasMore: Bool
    let loadNextBatch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(segments) { segment in
                VStack(alignment: .leading, spacing: 10) {
                    Text(segment.original).foregroundStyle(.primary).textSelection(.enabled)
                    Text(segment.translation).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.body).lineSpacing(4)
                Divider()
            }

            if hasMore {
                HStack(spacing: 8) {
                    if isLoadingNextBatch {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在翻译接下来的段落…")
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text("继续向下阅读以翻译下一段")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .id("bilingual-next-\(segments.count)-\(isLoadingNextBatch)")
                .onAppear {
                    guard !isLoadingNextBatch else { return }
                    loadNextBatch()
                }
            } else {
                Label("全文翻译完成", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - 阅读胶囊工具栏控件

struct ReaderCapsuleToolbar: View {
    let isBilingualActive: Bool
    let isRead: Bool
    let isStarred: Bool
    var isZenMode: Bool = false
    let disabled: Bool
    let onToggleBilingual: () -> Void
    let onToggleRead: () -> Void
    let onToggleStar: () -> Void
    var onToggleZenMode: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleBilingual) {
                toolbarSymbol(
                    isBilingualActive ? "character.bubble.fill" : "character.bubble",
                    isActive: isBilingualActive
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(isBilingualActive ? "关闭逐段翻译" : "开启逐段翻译")
            .help(isBilingualActive ? "关闭逐段翻译" : "开启逐段翻译")

            Button(action: onToggleRead) {
                toolbarSymbol(isRead ? "envelope.open" : "envelope", isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRead ? "标为未读" : "标为已读")
            .help(isRead ? "标为未读" : "标为已读")

            Button(action: onToggleStar) {
                toolbarSymbol(isStarred ? "star.fill" : "star", isActive: isStarred)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isStarred ? "取消收藏" : "收藏")
            .help(isStarred ? "取消收藏" : "收藏")

            Button(action: onToggleZenMode) {
                toolbarSymbol(
                    isZenMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    isActive: isZenMode
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isZenMode ? "退出禅模式" : "禅模式全屏阅读")
            .help(isZenMode ? "退出禅模式" : "禅模式全屏阅读")
        }
        .padding(.horizontal, 8)
        .frame(width: 140, height: 28)
    }

    private func toolbarSymbol(_ name: String, isActive: Bool) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? AnyShapeStyle(PaperTheme.accent) : AnyShapeStyle(.primary))
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 26)
            .background(isActive ? AnyShapeStyle(PaperTheme.accent.opacity(0.18)) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Circle())
    }
}
