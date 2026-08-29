import Foundation
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

/// 旧版 AppKit toolbar 会把真正的 material 放在 NSToolbarItem 容器层。
/// 这样 NSVisualEffectView 才能以 withinWindow 采样下方的阅读内容，SwiftUI
/// 只保留按钮布局，避免它在 NSHostingView 内把 material 扁平化为实色。
private struct ReaderCapsuleMaterialHostedByAppKitKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var readerCapsuleMaterialHostedByAppKit: Bool {
        get { self[ReaderCapsuleMaterialHostedByAppKitKey.self] }
        set { self[ReaderCapsuleMaterialHostedByAppKitKey.self] = newValue }
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
    var appearanceMode: ReaderAppearanceMode?
    var shortcutInvocation: ReaderShortcutInvocation?
    var onReaderShortcut: (ReaderShortcutAction) -> Void = { _ in }
    var onShortcutFeedback: (String) -> Void = { _ in }
    var onSelectNextEntry: () -> Void = {}
    var onFocusListView: () -> Void = {}
    var isZenMode: Bool = false
    var onToggleZenMode: () -> Void = {}
    @State private var preparedArticle: PreparedArticle?
    @State private var displayedEntry: Entry?
    /// Parsing a long document's paragraph structure is deliberately done once
    /// per article. The same stable index drives viewport translation requests
    /// and validation of returned translations.
    @State private var parsedReaderParagraphs: [ReaderParagraph] = []
    @State private var parsedReaderEntryID: String?
    @State private var isLoading = true
    @State private var showsLoadingIndicator = false
    /// 本次加载命中内存缓存：旧文档由 WebKit 保持绘制到新文档 commit，
    /// 期间不得显示不透明 loading 遮罩（否则产生“内容→纸面→内容”的屏闪）。
    /// isLoading 语义保持不变，供 onDocumentReady 握手使用。
    @State private var displaysMemoizedArticle = false
    @State private var documentLoadFailed = false
    @State private var activeLoadEntryID: String?
    @State private var articleLoadSession = 0
    @State private var articleReloadToken = 0
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
    @State private var streamingSummary: String?
    @State private var activeTranslationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var text: String { preparedArticle?.text ?? "" }
    private var html: String? { preparedArticle?.html }
    private var isDisplayedDocumentInteractive: Bool {
        !isLoading && !documentLoadFailed && activeLoadEntryID == entry.id && displayedEntry?.id == entry.id
    }
    private var canNavigateDisplayedDocument: Bool {
        isDisplayedDocumentInteractive ||
            (documentLoadFailed && activeLoadEntryID == entry.id && displayedEntry?.id == entry.id)
    }

    private var effectiveSummaryArtifact: AIArtifact? {
        if let streaming = streamingSummary {
            var art = store.summaryArtifact(for: entry) ?? AIArtifact(
                id: UUID(),
                entryID: entry.id,
                kind: .summary,
                contentHash: text.stableDigest,
                model: store.llmConfiguration.model,
                targetLanguage: store.llmConfiguration.targetLanguage,
                content: streaming,
                isComplete: false
            )
            art.content = streaming
            art.isComplete = false
            return art
        }
        return store.summaryArtifact(for: entry)
    }

    private func cancelBilingualTranslationLocal() {
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        pendingBilingualParagraphIDs.removeAll()
        store.cancelBilingualTranslation()
    }

    private var paperTopMargin: CGFloat {
        0
    }

    private var paperLeftMargin: CGFloat {
        0
    }

    private var readerAppearanceMode: ReaderAppearanceMode {
        appearanceMode ?? ReaderAppearanceMode(colorScheme)
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
        if parsedReaderEntryID == displayedEntry?.id {
            return parsedReaderParagraphs
        }
        guard let html, !html.isEmpty else { return [] }
        return ArticleExtractor.readerParagraphs(in: html, title: entry.title)
    }

    private var savedSelectionAnnotations: [ReaderSelectionAnnotation] {
        guard !text.isEmpty else { return [] }
        let articleHash = text.stableDigest
        return store.selectionArtifacts(for: entry, articleHash: articleHash).compactMap { artifact in
            guard let selection = artifact.selectionText,
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
            if isLoading && !displaysMemoizedArticle {
                loadingOverlay
                    .zIndex(2)
            } else if documentLoadFailed {
                documentLoadFailureOverlay
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
            AppearanceSurface(
                role: .reader,
                appearance: store.readerAppearance,
                mode: readerAppearanceMode
            )
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
            } else {
                cancelBilingualTranslationLocal()
                onShortcutFeedback(I18N.shared.localized("已取消双语翻译"))
            }
        }
        .onChange(of: shortcutInvocation) { _, invocation in
            guard let invocation else { return }
            handleReaderShortcut(invocation.action)
        }
        .onChange(of: store.articleRefreshSignal) { _, signal in
            guard let signal, signal.entryID == entry.id else { return }
            articleReloadToken += 1
        }
        .task(id: "\(entry.id)-\(articleReloadToken)") {
            cancelBilingualTranslationLocal()
            store.dismissError()
            let requestedEntry = entry
            articleLoadSession += 1
            let requestedLoadSession = articleLoadSession
            activeLoadEntryID = requestedEntry.id
            // 内存命中：跳过 loading 遮罩直接换页（WebKit 保持旧页直到新文档 commit）；
            // 未命中：维持既有 loading 行为，150ms 后才显示文案。
            let memoizedPrepared = store.memoizedPreparedArticle(for: requestedEntry)
            displaysMemoizedArticle = (memoizedPrepared != nil)
            isLoading = true
            showsLoadingIndicator = false
            documentLoadFailed = false
            isSummaryExpanded = false
            visibleBilingualParagraphIDs = []
            pendingBilingualParagraphIDs = []
            failedBilingualParagraphIDs = [:]
            streamingBilingualTranslations = [:]
            streamingSummary = nil
            // markRead 含同步 DB 写 + 侧栏聚合 + objectWillChange，
            // 推迟到过渡帧之后执行，避免切换瞬间叠加额外渲染压力。
            Task { @MainActor in
                store.markRead(requestedEntry)
            }

            if memoizedPrepared == nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard articleLoadSession == requestedLoadSession,
                          activeLoadEntryID == requestedEntry.id,
                          isLoading else { return }
                    showsLoadingIndicator = true
                }
            }

            let prepared: PreparedArticle
            if let memoizedPrepared {
                prepared = memoizedPrepared
            } else {
                prepared = await store.prepareArticle(for: requestedEntry)
            }
            guard !Task.isCancelled, activeLoadEntryID == requestedEntry.id else { return }

            let loadedText = prepared.text.isEmpty ? requestedEntry.sourceText : prepared.text
            let sourceHTML: String
            if prepared.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !loadedText.isEmpty {
                sourceHTML = "<p>\(loadedText.htmlEscaped.replacingOccurrences(of: "\n", with: "<br>"))</p>"
            } else {
                sourceHTML = prepared.html
            }
            let loadedHTML = ArticleExtractor.removingDuplicateLeadingHeading(from: sourceHTML, articleTitle: requestedEntry.title) ?? ""
            let parsedParagraphs: [ReaderParagraph] = await Task.detached(priority: .userInitiated) { () -> [ReaderParagraph] in
                guard !loadedHTML.isEmpty else { return [] }
                return ArticleExtractor.readerParagraphs(in: loadedHTML, title: requestedEntry.title)
            }.value
            guard !Task.isCancelled, activeLoadEntryID == requestedEntry.id else { return }

            displayedEntry = requestedEntry
            preparedArticle = PreparedArticle(
                text: loadedText,
                html: loadedHTML,
                imageURLs: prepared.imageURLs,
                baseURL: prepared.baseURL,
                source: prepared.source,
                features: prepared.features
            )
            parsedReaderParagraphs = parsedParagraphs
            parsedReaderEntryID = requestedEntry.id
            if store.llmConfiguration.showsAISummary,
               store.llmConfiguration.automaticallyGenerateSummary,
               store.artifact(for: requestedEntry, kind: .summary) == nil,
               !text.isEmpty {
                isSummaryExpanded = true
                await store.generateSummary(entry: requestedEntry, text: text) { partial in
                    await MainActor.run {
                        guard self.activeLoadEntryID == requestedEntry.id else { return }
                        self.streamingSummary = partial
                    }
                }
                self.streamingSummary = nil
            }
        }
    }

    private var hasReaderContent: Bool { preparedArticle != nil }

    private var loadingOverlay: some View {
        ZStack {
            AppearanceSurface(role: .reader, appearance: store.readerAppearance, mode: readerAppearanceMode)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
            if showsLoadingIndicator {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(I18N.localized("正在准备正文…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var documentLoadFailureOverlay: some View {
        ZStack {
            AppearanceSurface(role: .reader, appearance: store.readerAppearance, mode: readerAppearanceMode)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
            Text(I18N.localized("正文显示失败，请切换文章后重试。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var readerBody: some View {
        #if os(macOS)
        if usesNativeHTMLScroller, let preparedArticle, let displayedEntry {
            ArticleHTMLView(
                entry: displayedEntry,
                feedTitle: store.feed(for: displayedEntry)?.title,
                article: preparedArticle,
                loadSession: articleLoadSession,
                contentTopInset: 84,
                readerParagraphs: readerParagraphs,
                inlineTranslations: bilingualSegments,
                pendingTranslationIDs: pendingBilingualParagraphIDs,
                selectionAnnotations: savedSelectionAnnotations,
                isBilingualMode: readerMode == .bilingual,
                fontSize: store.articleFontSize,
                readerAppearance: store.readerAppearance,
                readerAppearanceMode: readerAppearanceMode,
                isInteractive: isDisplayedDocumentInteractive,
                allowsNavigationWhenInactive: documentLoadFailed,
                onDocumentReady: { loadedEntryID in
                    guard isLoading, activeLoadEntryID == loadedEntryID else { return false }
                    isLoading = false
                    showsLoadingIndicator = false
                    displaysMemoizedArticle = false
                    requestVisibleTranslationsIfPossible()
                    return true
                },
                onDocumentLoadFailed: { loadedEntryID in
                    guard activeLoadEntryID == loadedEntryID else { return }
                    isLoading = false
                    showsLoadingIndicator = false
                    displaysMemoizedArticle = false
                    documentLoadFailed = true
                },
                summaryArtifact: effectiveSummaryArtifact,
                isSummaryExpanded: isSummaryExpanded,
                isGeneratingSummary: activeAIStatus(for: .summary) != nil,
                aiStatusMessage: activeAIStatus(for: .summary)?.phase.message,
                errorMessage: store.lastError,
                showsAISummary: store.llmConfiguration.showsAISummary,
                showsSelectionExplanation: store.llmConfiguration.showsSelectionExplanation,
                showsSelectionAsk: store.llmConfiguration.showsSelectionAsk,
                showsSelectionTranslation: store.llmConfiguration.showsSelectionTranslation,
                onVisibleParagraphIDsChange: handleVisibleParagraphIDs,
                onScrollOffsetChange: { _ in },
                onSelectionRequest: performSelectionRequest,
                onGenerateSummary: { force in generateSummary(force: force) },
                onToggleSummary: toggleSummary,
                onReaderShortcut: { action in
                    guard canNavigateDisplayedDocument else { return }
                    onReaderShortcut(action)
                },
                onSelectNextEntry: {
                    guard canNavigateDisplayedDocument else { return }
                    onSelectNextEntry()
                },
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
        if usesNativeHTMLScroller, let preparedArticle, let displayedEntry {
            ArticleHTMLView(
                entry: displayedEntry,
                feedTitle: store.feed(for: displayedEntry)?.title,
                article: preparedArticle,
                loadSession: articleLoadSession,
                contentTopInset: 64,
                readerParagraphs: readerParagraphs,
                inlineTranslations: bilingualSegments,
                pendingTranslationIDs: pendingBilingualParagraphIDs,
                selectionAnnotations: savedSelectionAnnotations,
                isBilingualMode: readerMode == .bilingual,
                fontSize: store.articleFontSize,
                readerAppearance: store.readerAppearance,
                readerAppearanceMode: readerAppearanceMode,
                isInteractive: isDisplayedDocumentInteractive,
                allowsNavigationWhenInactive: documentLoadFailed,
                onDocumentReady: { loadedEntryID in
                    guard isLoading, activeLoadEntryID == loadedEntryID else { return false }
                    isLoading = false
                    showsLoadingIndicator = false
                    displaysMemoizedArticle = false
                    requestVisibleTranslationsIfPossible()
                    return true
                },
                onDocumentLoadFailed: { loadedEntryID in
                    guard activeLoadEntryID == loadedEntryID else { return }
                    isLoading = false
                    showsLoadingIndicator = false
                    displaysMemoizedArticle = false
                    documentLoadFailed = true
                },
                summaryArtifact: effectiveSummaryArtifact,
                isSummaryExpanded: isSummaryExpanded,
                isGeneratingSummary: activeAIStatus(for: .summary) != nil,
                aiStatusMessage: activeAIStatus(for: .summary)?.phase.message,
                errorMessage: store.lastError,
                showsAISummary: store.llmConfiguration.showsAISummary,
                showsSelectionExplanation: store.llmConfiguration.showsSelectionExplanation,
                showsSelectionAsk: store.llmConfiguration.showsSelectionAsk,
                showsSelectionTranslation: store.llmConfiguration.showsSelectionTranslation,
                onVisibleParagraphIDsChange: handleVisibleParagraphIDs,
                onScrollOffsetChange: { _ in },
                onSelectionRequest: performSelectionRequest,
                onGenerateSummary: { force in generateSummary(force: force) },
                onToggleSummary: toggleSummary,
                onSelectNextEntry: {
                    guard canNavigateDisplayedDocument else { return }
                    onSelectNextEntry()
                },
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
        preparedArticle != nil
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
                .accessibilityHint(I18N.localized("在默认浏览器打开原网页"))
                .help(I18N.localized("打开原网页"))
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

    @ViewBuilder
    private var summaryCard: some View {
        if store.llmConfiguration.showsAISummary {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label(I18N.localized("AI 摘要"), systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    if store.summaryArtifact(for: entry) != nil {
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
                                isSummaryExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isSummaryExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.accentColor.opacity(0.09), in: Circle())
            .accessibilityLabel(I18N.shared.localized(isSummaryExpanded ? "收起 AI 摘要" : "展开 AI 摘要"))
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
                        if activeAIStatus(for: .summary) != nil {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(I18N.localized("AI 正在生成摘要…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        } else {
                            HStack(spacing: 8) {
                                if !summary.isComplete {
                                    Text(I18N.localized("上次生成未完成"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button(I18N.localized("重新生成")) { generateSummary(force: true) }
                                    .buttonStyle(.borderless)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.top, 2)
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
                            Text(I18N.localized("尚未生成；仅在你点按后发送正文。"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button(I18N.localized("生成摘要")) { generateSummary(force: false) }
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
    }

    private var currentEntry: Entry {
        store.entry(id: entry.id) ?? entry
    }

    private var floatingCapsuleToolbar: some View {
        HStack(spacing: 6) {
            Button(action: toggleBilingualTranslation) {
                translationToolbarIcon(isActive: readerMode == .bilingual)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .accessibilityLabel("\(I18N.shared.localized(readerMode == .bilingual ? "关闭逐段翻译" : "开启逐段翻译")) (C)")
            .help("\(I18N.shared.localized(readerMode == .bilingual ? "关闭逐段翻译" : "开启逐段翻译")) (C)")

            Button {
                store.markRead(currentEntry, read: !currentEntry.isRead)
            } label: {
                toolbarSymbol(currentEntry.isRead ? "envelope.open" : "envelope", isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18N.shared.localized(currentEntry.isRead ? "标为未读" : "标为已读"))
            .help(I18N.shared.localized(currentEntry.isRead ? "标为未读" : "标为已读"))

            Button {
                store.toggleStar(currentEntry)
            } label: {
                toolbarSymbol(currentEntry.isStarred ? "star.fill" : "star", isActive: currentEntry.isStarred)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18N.shared.localized(currentEntry.isStarred ? "取消收藏" : "收藏文章"))
            .help(I18N.shared.localized(currentEntry.isStarred ? "取消收藏" : "收藏文章"))
            
            Button {
                onToggleZenMode()
            } label: {
                toolbarSymbol(
                    isZenMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    isActive: isZenMode
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18N.shared.localized(isZenMode ? "退出禅模式" : "禅模式全屏阅读"))
            .help(I18N.shared.localized(isZenMode ? "退出禅模式" : "禅模式全屏阅读"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background { readerToolbarCapsuleBackground }
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
    }

    @ViewBuilder
    private var readerToolbarCapsuleBackground: some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            Capsule().fill(.ultraThinMaterial)
        } else {
            Capsule().fill(PaperTheme.surface(.page, scheme: colorScheme).opacity(0.96))
        }
        #else
        Capsule().fill(.ultraThinMaterial)
        #endif
    }

    private func translationToolbarIcon(isActive: Bool) -> some View {
        ZStack {
            Image(systemName: isActive ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 16.5, weight: .regular))
            
            Text(I18N.shared.isEnglish ? "A" : "文")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .offset(x: 0.2, y: -1.6)
        }
        .offset(y: 0.8)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .frame(width: 28, height: 28)
        .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear), in: Circle())
        .contentShape(Circle())
    }

    private func toolbarSymbol(_ name: String, isActive: Bool) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .frame(width: 28, height: 28)
            .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Circle())
    }

    private var readerMode: ReaderMode {
        store.isBilingualActive(for: entry.id) ? .bilingual : .original
    }

    private func toggleBilingualTranslation() {
        guard isDisplayedDocumentInteractive else { return }
        failedBilingualParagraphIDs.removeAll()
        pendingBilingualParagraphIDs.removeAll()
        let isActivating = !store.isBilingualActive(for: entry.id)
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            store.toggleBilingualMode(for: entry.id)
        }
        if isActivating {
            requestVisibleTranslationsIfPossible()
        } else {
            cancelBilingualTranslationLocal()
            onShortcutFeedback(I18N.shared.localized("已取消双语翻译"))
        }
    }

    private func handleReaderShortcut(_ action: ReaderShortcutAction) {
        if action == .previousArticle || action == .nextArticle || action == .toggleFullScreen {
            guard canNavigateDisplayedDocument else { return }
            onReaderShortcut(action)
            return
        }
        guard isDisplayedDocumentInteractive else { return }
        switch action {
        case .toggleBilingual:
            toggleBilingualTranslation()
        case .showSummary:
            switch ReaderShortcutPolicy.summaryDecision(
                showsAISummary: store.llmConfiguration.showsAISummary,
                hasCachedSummary: store.summaryArtifact(for: entry) != nil,
                isAIRequestActive: store.activeSummaryRequest != nil
            ) {
            case .promptToEnable:
                onShortcutFeedback(I18N.shared.localized("请先在设置中开启 AI 摘要模块。"))
            case .revealCached:
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
                    isSummaryExpanded.toggle()
                }
            case .generate:
                guard !effectiveArticleText.isEmpty else {
                    onShortcutFeedback(I18N.shared.localized("文章暂无正文内容，无法生成摘要。"))
                    return
                }
                generateSummary(force: false)
            case .rejectBusy:
                onShortcutFeedback(I18N.shared.localized("已有 AI 摘要任务正在进行，请稍后再试。"))
            }
        case .toggleStar:
            store.toggleStar(currentEntry)
        case .previousArticle, .nextArticle, .toggleFullScreen:
            break
        }
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
        guard isDisplayedDocumentInteractive else { return }
        let targetText = effectiveArticleText
        guard !targetText.isEmpty else {
            onShortcutFeedback(I18N.shared.localized("文章暂无正文内容，无法生成摘要。"))
            return
        }
        if store.activeSummaryRequest != nil {
            onShortcutFeedback(I18N.shared.localized("已有 AI 摘要任务正在进行，请稍后再试。"))
            return
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
            isSummaryExpanded = true
        }
        let requestedEntry = entry
        Task {
            await store.generateSummary(entry: requestedEntry, text: targetText, force: force) { partial in
                await MainActor.run {
                    guard self.entry.id == requestedEntry.id else { return }
                    self.streamingSummary = partial
                }
            }
            await MainActor.run {
                if self.entry.id == requestedEntry.id {
                    self.streamingSummary = nil
                }
            }
        }
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
        guard isDisplayedDocumentInteractive else {
            return ReaderSelectionResponse(text: "", isError: true)
        }
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
        guard isDisplayedDocumentInteractive,
              readerMode == .bilingual,
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
                .prefix(6)
        )
        guard !batch.isEmpty else { return }

        pendingBilingualParagraphIDs.formUnion(batch)
        let paragraphs = readerParagraphs
        activeTranslationTask = Task {
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

            guard !Task.isCancelled else { return }
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
            Text(I18N.shared.localizedFormat("正在生成 %@", status.kind.title))
                .font(.headline)
            Text(status.phase.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(I18N.localized("你可以继续阅读；结果完成后会自动出现。"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }

    private func unavailable(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        ContentUnavailableView {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: "sparkles")
            }
        } description: {
            Text(I18N.localized("仅在你点按生成后，正文才会发送给模型。"))
        } actions: {
            if let actionTitle, let action {
                Button(I18N.shared.localized(actionTitle), action: action)
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
        showsAISummary: Bool = true,
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

        let summaryCardHTMLString: String
        if showsAISummary {
            summaryCardHTMLString = summaryCardHTML(
                summaryArtifact: summaryArtifact,
                isSummaryExpanded: isSummaryExpanded,
                isGeneratingSummary: isGeneratingSummary,
                aiStatusMessage: aiStatusMessage,
                errorMessage: nil
            )
        } else {
            summaryCardHTMLString = ""
        }

        let titleAttr = " data-paper-rss-id=\"title\""

        return """
        <header class="paper-header-container">
          <h1 class="paper-header-title"\(titleAttr)>\(titleHTML)</h1>
          \(titleTranslationHTML)
          <div class="paper-header-meta">\(metaHTML)</div>
          \(summaryCardHTMLString)
          <hr class="paper-header-divider">
        </header>
        """
    }

    static func formatSimpleMarkdown(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var formattedLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            
            var current = trimmed.htmlEscaped
            
            // 处理 # / ## / ### 标题，转为 <strong> 加粗，字号保持一致
            if current.hasPrefix("#") {
                let stripped = current.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                current = "<strong>\(stripped)</strong>"
            } else if current.hasPrefix("- ") || current.hasPrefix("* ") {
                let content = current.dropFirst(2).trimmingCharacters(in: .whitespaces)
                current = "&bull;&nbsp;\(content)"
            }
            
            // 处理 **粗体** 匹配
            while let rangeStart = current.range(of: "**") {
                let afterStart = current[rangeStart.upperBound...]
                if let rangeEnd = afterStart.range(of: "**") {
                    let boldText = afterStart[..<rangeEnd.lowerBound]
                    let fullRange = rangeStart.lowerBound..<rangeEnd.upperBound
                    current.replaceSubrange(fullRange, with: "<strong>\(boldText)</strong>")
                } else {
                    break
                }
            }
            
            formattedLines.append(current)
        }
        
        return formattedLines.joined(separator: "<br>")
    }

    static func summaryCardHTML(
        summaryArtifact: AIArtifact?,
        isSummaryExpanded: Bool,
        isGeneratingSummary: Bool,
        aiStatusMessage: String?,
        errorMessage: String? = nil
    ) -> String {
        let chevronRightSVG = """
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="9 18 15 12 9 6"></polyline>
        </svg>
        """

        let chevronDownSVG = """
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="6 9 12 15 18 9"></polyline>
        </svg>
        """

        let titleText = I18N.localized("AI 摘要").htmlEscaped

        if let summary = summaryArtifact, !summary.content.isEmpty {
            let formattedContent = formatSimpleMarkdown(summary.content)
            let bodyClass = isSummaryExpanded ? "expanded" : "collapsed"
            
            var statusFooter = ""
            if isGeneratingSummary {
                statusFooter = """
                <div class="paper-summary-status">
                  <span class="paper-spinner"></span>
                  <span>\(I18N.localized("AI 正在生成摘要…").htmlEscaped)</span>
                </div>
                """
            } else {
                let noticeHTML: String
                if let errorMessage {
                    noticeHTML = "<span class=\"paper-summary-error\">\(errorMessage.htmlEscaped)</span> "
                } else if !summary.isComplete {
                    noticeHTML = "<span>\(I18N.localized("上次生成未完成").htmlEscaped)</span> "
                } else {
                    noticeHTML = ""
                }
                statusFooter = """
                <div class="paper-summary-status">
                  \(noticeHTML)<button class="paper-summary-action-btn" data-paper-action="generateSummary" data-paper-force="true">\(I18N.localized("重新生成").htmlEscaped)</button>
                </div>
                """
            }

            // 提取摘要第一句作为折叠预览（去除 # 和 ** 等标识符）
            let rawContent = summary.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = rawContent.components(separatedBy: CharacterSet(charactersIn: "\n。")).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.trimmingCharacters(in: .whitespaces) ?? rawContent
            let cleanFirstLine = firstLine
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            let previewText = cleanFirstLine.isEmpty ? "" : (cleanFirstLine + (cleanFirstLine.count < rawContent.count ? "..." : ""))

            let headerSubtextHTML = isSummaryExpanded ? "" : "<span class=\"paper-summary-subtext\">\(previewText.htmlEscaped)</span>"
            let actionIcon = isSummaryExpanded ? chevronDownSVG : chevronRightSVG

            return """
            <div class="paper-summary-card paper-summary-collapse \(isSummaryExpanded ? "is-expanded" : "is-collapsed")" id="paper-summary-card" data-paper-action="toggleSummary">
              <div class="paper-summary-header">
                <div class="paper-summary-header-left">
                  <span class="paper-summary-title">\(titleText)</span>
                  \(headerSubtextHTML)
                </div>
                <button class="paper-summary-ai-btn" data-paper-action="toggleSummary">
                  \(actionIcon)
                </button>
              </div>
              <div class="paper-summary-body \(bodyClass)">
                <div class="paper-summary-text">\(formattedContent)</div>
                \(statusFooter)
              </div>
            </div>
            """
        } else if isGeneratingSummary {
            let msg = aiStatusMessage ?? I18N.localized("正在生成，完成后会自动显示。")
            return """
            <div class="paper-summary-card paper-summary-collapse generating" id="paper-summary-card">
              <div class="paper-summary-header">
                <div class="paper-summary-header-left">
                  <span class="paper-summary-title">\(titleText)</span>
                  <span class="paper-summary-subtext"><span class="paper-spinner"></span> \(msg.htmlEscaped)</span>
                </div>
                <button class="paper-summary-ai-btn">
                  \(chevronRightSVG)
                </button>
              </div>
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
            let placeholderText = I18N.localized("尚未生成，点击后发送正文生成摘要").htmlEscaped
            return """
            <div class="paper-summary-card paper-summary-collapse ungenerated" id="paper-summary-card" data-paper-action="generateSummary" data-paper-force="false">
              \(errNotice)
              <div class="paper-summary-header">
                <div class="paper-summary-header-left">
                  <span class="paper-summary-title">\(titleText)</span>
                  <span class="paper-summary-subtext">\(placeholderText)</span>
                </div>
                <button class="paper-summary-ai-btn" data-paper-action="generateSummary" data-paper-force="false">
                  \(chevronRightSVG)
                </button>
              </div>
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

private func readerFontStack(for appearance: ReaderAppearance) -> String {
    let systemFallback = "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif"
    guard let family = appearance.fontFamilyName else { return systemFallback }
    let escaped = family
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    return "\"\(escaped)\", \(systemFallback)"
}

private func readerAppearanceStyle(
    _ appearance: ReaderAppearance,
    mode: ReaderAppearanceMode
) -> String {
    let palette = appearance.palette(for: mode)
    let variables = palette.cssVariables
        .sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value);" }
        .joined(separator: " ")
    return """
    :root { color-scheme: \(palette.colorScheme.rawValue); \(variables) --paper-body-font-family: \(readerFontStack(for: appearance)); }
    body { font-family: var(--paper-body-font-family); }
    .paper-header-container, .paper-summary-card, #paper-rss-toc-rail {
      font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
    }
    """
}

private func readerAppearanceJavaScript(
    _ appearance: ReaderAppearance,
    mode: ReaderAppearanceMode
) -> String {
    let palette = appearance.palette(for: mode)
    var variables = palette.cssVariables
    variables["--paper-body-font-family"] = readerFontStack(for: appearance)
    guard let data = try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else { return "" }
    return """
    (() => {
      const root = document.documentElement;
      const values = \(json);
      Object.entries(values).forEach(([key, value]) => root.style.setProperty(key, value));
      root.style.colorScheme = '\(palette.colorScheme.rawValue)';
      if (document.body) {
        document.body.style.fontFamily = values['--paper-body-font-family'];
      }
    })();
    """
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
  --paper-code-comment: #8a8172;
  --paper-code-keyword: #a04c33;
  --paper-code-string: #55713e;
  --paper-code-number: #8a651f;
  --paper-code-title: #47688f;
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
    --paper-code-comment: #8f8778;
    --paper-code-keyword: #d18b73;
    --paper-code-string: #9eaf91;
    --paper-code-number: #d0a95f;
    --paper-code-title: #8fb0cc;
  }
}
html {
  background: transparent;
  scrollbar-width: none;
  overscroll-behavior: none;
  overscroll-behavior-y: none;
}
html::-webkit-scrollbar {
  width: 0;
  height: 0;
  display: none;
}
body {
  overscroll-behavior: none;
  overscroll-behavior-y: none;
  max-width: 820px;
  margin: 0 auto 42px auto;
  padding-left: 32px;
  padding-right: 32px;
  padding-top: var(--paper-reader-top-inset, 84px);
  box-sizing: border-box;
  color: var(--paper-ink);
  background: transparent;
  font-size: 17px;
  font-family: var(--paper-body-font-family, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif);
  font-weight: 400;
  line-height: 1.72;
  letter-spacing: .006em;
  overflow-wrap: anywhere;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
}
body > :not(.paper-header-container):not(#paper-rss-toc-rail):not(#paper-rss-toc-preview) {
  font-size: var(--paper-font-size, 17px);
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
  border-radius: 8px;
  padding: 10px 14px;
  margin: 0 0 20px 0;
  font-size: 0.92em;
  cursor: pointer;
  transition: border-color 0.15s ease, background-color 0.15s ease;
  user-select: none;
}
.paper-summary-card:hover {
  border-color: var(--paper-accent);
}
.paper-summary-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.paper-summary-header-left {
  display: flex;
  align-items: center;
  gap: 10px;
  flex: 1;
  min-width: 0;
}
.paper-summary-title {
  font-weight: 600;
  color: var(--paper-accent);
  white-space: nowrap;
  font-size: 0.95em;
  flex-shrink: 0;
}
.paper-summary-subtext {
  font-size: 0.88em;
  font-weight: normal;
  color: var(--paper-muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  flex: 1;
  min-width: 0;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.paper-summary-ai-btn {
  background: transparent;
  border: none;
  border-radius: 4px;
  width: 24px;
  height: 24px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  color: var(--paper-accent);
  padding: 0;
  flex-shrink: 0;
  opacity: 0.75;
  transition: opacity 0.15s ease;
}
.paper-summary-card:hover .paper-summary-ai-btn,
.paper-summary-ai-btn:hover {
  opacity: 1;
}
.paper-summary-icon {
  width: 15px;
  height: 15px;
}
.paper-summary-body {
  margin-top: 10px;
  padding-top: 10px;
  border-top: 1px dashed var(--paper-rule);
  line-height: 1.6;
  color: var(--paper-ink);
  font-size: 0.95em;
}
.paper-summary-body.collapsed {
  display: none;
}
.paper-summary-text {
  line-height: 1.6;
}
.paper-summary-text strong,
.paper-summary-text b {
  font-size: 1em;
  font-weight: 600;
  color: var(--paper-ink);
}
.paper-spinner {
  display: inline-block;
  width: 12px;
  height: 12px;
  border: 2px solid var(--paper-wash);
  border-top-color: var(--paper-accent);
  border-radius: 50%;
  animation: paper-spin 0.8s linear infinite;
  flex-shrink: 0;
  vertical-align: middle;
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
/* 图片对齐语法（Obsidian ![[x|40|left]] / HTML align）归一化后的受控类：
   块级独占一行，仅改变水平对齐方向（居中为默认） */
img.paper-align-left {
  margin-left: 0;
  margin-right: auto;
}
img.paper-align-right {
  margin-left: auto;
  margin-right: 0;
}
/* 多图 wrap 行容器：有声明宽度的图尊重原文尺寸、总宽超行时自然换行；
   无声明宽度的图均分共享一行（画廊语义）；整行居中 */
.paper-img-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: .75em;
  margin: 1.2em 0;
}
.paper-img-row img {
  flex: 1 1 0;      /* 无声明宽度：basis 0 + 均分，全部并入同一行各占等宽（画廊语义） */
  min-width: 0;     /* 覆盖 flex 自动最小尺寸（固有宽），否则图片拒绝收缩 */
  margin: 0;
}
.paper-img-row img[width] {
  flex: 0 0 auto;   /* 有声明宽度：尊重原文尺寸，总宽超出行时自然换行 */
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
pre code .hljs-comment, pre code .hljs-quote {
  color: var(--paper-code-comment);
  font-style: italic;
}
pre code .hljs-keyword, pre code .hljs-selector-tag,
pre code .hljs-built_in, pre code .hljs-doctag {
  color: var(--paper-code-keyword);
}
pre code .hljs-string, pre code .hljs-regexp, pre code .hljs-addition {
  color: var(--paper-code-string);
}
pre code .hljs-number, pre code .hljs-literal, pre code .hljs-symbol,
pre code .hljs-bullet, pre code .hljs-link, pre code .hljs-meta {
  color: var(--paper-code-number);
}
pre code .hljs-title, pre code .hljs-title.function_, pre code .hljs-title.class_,
pre code .hljs-section, pre code .hljs-name,
pre code .hljs-selector-id, pre code .hljs-selector-class {
  color: var(--paper-code-title);
  font-weight: 600;
}
pre code .hljs-deletion { color: var(--paper-code-keyword); }
pre code .hljs-emphasis { font-style: italic; }
pre code .hljs-strong { font-weight: 700; }
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
.paper-rss-subparagraph {
  margin: 0 0 1em 0;
  line-height: 1.6;
}
.paper-rss-translation {
  margin: -.5em 0 1.25em;
  padding: 0;
  color: var(--paper-muted);
  font-size: 0.96em;
  line-height: 1.68;
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
mjx-container[jax="SVG"][display="true"] {
  display: block !important;
  overflow-x: auto !important;
  overflow-y: hidden !important;
  max-width: 100% !important;
  padding: 0.35em 0;
  margin: 0.6em 0;
}
mjx-container[jax="SVG"]:not([display="true"]) {
  display: inline-block !important;
  vertical-align: middle;
}
"""

@MainActor
enum PaperReaderBridge {
    static let scrollMessageName = "paperRssReaderScroll"
    static let visibleParagraphsMessageName = "paperRssVisibleParagraphs"
    static let explainSelectionMessageName = "paperRssExplainSelection"
    static let askSelectionMessageName = "paperRssAskSelection"

    static let translationSynchronizationScript = """
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
      label.setAttribute("aria-label", window.paperRssSelectionOptions?.labels?.translationLabel || "译文");
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
      aside.setAttribute("aria-label", update.isLoading
        ? (window.paperRssSelectionOptions?.labels?.generatingTranslation || "正在生成译文")
        : (window.paperRssSelectionOptions?.labels?.translationLabel || "译文"));
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

    static var localizedSelectionLabels: [String: String] {
        [
            "explain": I18N.localized("解释所选文字"),
            "ask": I18N.localized("问 AI 所选文字"),
            "translate": I18N.localized("翻译所选文字"),
            "questionPrefix": I18N.localized("问："),
            "questionPlaceholder": I18N.localized("针对划选文字提问..."),
            "sendQuestion": I18N.localized("发送提问"),
            "translationTitle": I18N.localized("翻译"),
            "questionTitle": I18N.localized("问 AI 答疑"),
            "explanationTitle": I18N.localized("AI 解释"),
            "loadingTranslation": I18N.localized("正在翻译…"),
            "loadingAnswer": I18N.localized("正在生成解答…"),
            "loadingExplanation": I18N.localized("正在结合全文理解这段文字…"),
            "loadingGeneric": I18N.localized("正在生成…"),
            "retryError": I18N.localized("暂时无法完成，请稍后重试。"),
            "unavailableExplanation": I18N.localized("解释暂不可用。"),
            "reopenExplanation": I18N.localized("点击重新查看 AI 解释"),
            "completedExplanation": I18N.localized("已完成解释，点击重新查看"),
            "closeImage": I18N.localized("关闭（Esc）"),
            "translationLabel": I18N.localized("译文"),
            "generatingTranslation": I18N.localized("正在生成译文"),
            "tocRailLabel": I18N.localized("文章章节导航", englishFallback: "Article Navigation")
        ]
    }
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
            const topPreloadBound = -viewportHeight * 0.30;
            const bottomPreloadBound = viewportHeight * 1.30;
            const paragraphIDs = Array.from(observedParagraphs.values())
              .map(node => ({ id: node.dataset.paperRssId, rect: node.getBoundingClientRect() }))
              .filter(item =>
                item.id &&
                item.rect.bottom > topPreloadBound &&
                item.rect.top < bottomPreloadBound
              )
              .sort((lhs, rhs) => {
                const lhsVisible = lhs.rect.top < viewportHeight && lhs.rect.bottom > 0 ? 0 : 1;
                const rhsVisible = rhs.rect.top < viewportHeight && rhs.rect.bottom > 0 ? 0 : 1;
                return lhsVisible - rhsVisible || lhs.rect.top - rhs.rect.top;
              })
              .slice(0, 10)
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

          const refreshLayout = () => {
            scheduleScroll();
            scheduleParagraphs();
            window.paperRssTOCRail?.refresh?.();
          };
          window.addEventListener("paperRssLayoutRefresh", refreshLayout);

          // IntersectionObserver 覆盖当前视口以及屏幕外 30% 的上下预加载缓冲区，
          // 支持用户快速滚动时的即时 AI 翻译预加载。
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
            rootMargin: "30% 0px 50% 0px",
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
          refreshLayout();
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    #if os(macOS)
    /// A compact, local-only chapter rail for long article documents.  It is
    /// intentionally a macOS-only user script: iOS keeps its native reader
    /// scrolling surface and does not receive this overlay.
    static let tocRailScript = WKUserScript(
        source: """
        (() => {
          if (window.paperRssTOCRail?.destroy) window.paperRssTOCRail.destroy();

          const root = document.documentElement;
          const state = {
            anchors: [], buttons: [], rail: null, preview: null, style: null,
            observer: null, resizeObserver: null, scheduled: false,
            hoverTimer: null, closeTimer: null, hoveredElement: null, hoveredIndex: null,
            dragging: false, dragged: false, dragPointerId: null, dragTarget: null,
            dragStartY: 0, dragStartX: 0, hasMovedPastThreshold: false,
            suppressClick: false, navigatingAnchor: null, navigatingTimer: null,
            hideTimer: null, mouseNear: false, railHovered: false
          };
          const currentRailLabel = () => window.paperRssSelectionOptions?.labels?.tocRailLabel || "文章章节导航";
          state.setRailLabel = label => {
            state.rail?.setAttribute("aria-label", label || currentRailLabel());
          };
          const textOf = node => (node?.textContent || "").replace(/\\s+/g, " ").trim();
          const normalized = value => textOf({ textContent: value })
            .toLocaleLowerCase()
            .replace(/[^\\p{L}\\p{N}]+/gu, "");
          const currentScrollTop = () => Math.max(
            0,
            window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0
          );
          const viewportHeight = () => Math.max(
            1,
            window.innerHeight || document.documentElement.clientHeight || 0
          );
          const documentHeight = () => Math.max(
            document.documentElement.scrollHeight || 0,
            document.body.scrollHeight || 0
          );

          const absoluteTopOf = element => {
            const rect = element?.getBoundingClientRect?.();
            const top = Number(rect?.top);
            return Number.isFinite(top) ? top + currentScrollTop() : 0;
          };

          const documentOrder = element => {
            const path = [];
            let node = element;
            while (node?.parentNode) {
              path.unshift(Array.from(node.parentNode.children || []).indexOf(node));
              node = node.parentNode;
            }
            return path;
          };

          const compareDocumentOrder = (lhs, rhs) => {
            const left = documentOrder(lhs.element);
            const right = documentOrder(rhs.element);
            const length = Math.min(left.length, right.length);
            for (let index = 0; index < length; index += 1) {
              if (left[index] !== right[index]) return left[index] - right[index];
            }
            return left.length - right.length;
          };

          const splitExcerpt = text => {
            const match = text.match(/^[\\s\\S]*?[.!?。！？]/);
            if (!match) return { label: text, excerpt: "" };
            const label = match[0].trim();
            return { label, excerpt: text.slice(match[0].length).trim() };
          };

          const hasBlockChildren = node => Array.from(node?.children || []).some(child =>
            /^(P|LI|BLOCKQUOTE|PRE|FIGURE|SECTION|ARTICLE|DIV|UL|OL|DL|TABLE)$/i.test(child.tagName || "")
          );

          const showRail = () => {
            if (!state.rail) return;
            state.rail.classList.add("is-visible");
          };

          const scheduleHide = (delay = 1400) => {
            if (state.hideTimer !== null) window.clearTimeout(state.hideTimer);
            state.hideTimer = window.setTimeout(() => {
              state.hideTimer = null;
              if (
                !state.rail ||
                state.dragging ||
                state.mouseNear ||
                state.railHovered ||
                state.preview ||
                state.navigatingAnchor ||
                state.rail.matches?.(":focus-within")
              ) {
                return;
              }
              state.rail.classList.remove("is-visible");
            }, delay);
          };

          const wakeRail = (delay = 1400) => {
            showRail();
            scheduleHide(delay);
          };

          const clearPreviewTimers = () => {
            if (state.hoverTimer !== null) window.clearTimeout(state.hoverTimer);
            if (state.closeTimer !== null) window.clearTimeout(state.closeTimer);
            state.hoverTimer = null;
            state.closeTimer = null;
          };

          const closePreview = () => {
            clearPreviewTimers();
            state.preview?.remove();
            state.preview = null;
          };

          const clearHoverPeak = () => {
            state.hoveredIndex = null;
            state.buttons.forEach(button => {
              const line = button.children?.[0];
              if (line?.style) line.style.width = "";
            });
            updateActive();
          };

          const setHoverPeak = index => {
            state.hoveredIndex = index;
            state.buttons.forEach((button, buttonIndex) => {
              const line = button.children?.[0];
              if (!line?.style) return;
              const distance = Math.abs(buttonIndex - index);
              line.style.width = distance === 0
                ? "29px"
                : distance === 1
                  ? "21px"
                  : distance === 2
                    ? "14px"
                    : "";
              const active = buttonIndex === index;
              button.classList.toggle("is-current", active);
              button.setAttribute("aria-current", active ? "true" : "false");
            });
          };

          const dismissPreview = () => {
            state.hoveredElement = null;
            clearHoverPeak();
            closePreview();
          };

          const schedulePreviewClose = () => {
            clearHoverPeak();
            if (state.closeTimer !== null) window.clearTimeout(state.closeTimer);
            state.closeTimer = window.setTimeout(() => {
              state.closeTimer = null;
              state.hoveredElement = null;
              closePreview();
            }, 80);
          };

          const previewContent = anchor => {
            const title = textOf(anchor.element);
            if (anchor.kind === "fallback") {
              const current = splitExcerpt(textOf(anchor.element));
              return { title: current.label, excerpt: current.excerpt };
            }
            const headings = Array.from(document.querySelectorAll("h1,h2,h3,h4,h5,h6"))
              .filter(node => !node.classList.contains("paper-header-title"));
            const nextHeading = headings[headings.indexOf(anchor.element) + 1];
            const start = absoluteTopOf(anchor.element);
            const end = nextHeading ? absoluteTopOf(nextHeading) : Number.POSITIVE_INFINITY;
            const blocks = Array.from(document.querySelectorAll("p,li,blockquote,pre,div"))
              .filter(node => {
                if (!textOf(node) || node === anchor.element) return false;
                if (node.closest?.(".paper-header-container, .paper-summary-card, #paper-rss-toc-rail, #paper-rss-toc-preview")) return false;
                if (hasBlockChildren(node)) return false;
                const position = absoluteTopOf(node);
                return position > start + 1 && position < end;
              })
              .sort((lhs, rhs) => absoluteTopOf(lhs) - absoluteTopOf(rhs));
            return { title, excerpt: blocks[0] ? textOf(blocks[0]) : anchor.excerpt || "" };
          };

          const showPreview = (anchor, buttonElement) => {
            showRail();
            const content = previewContent(anchor);
            const index = state.anchors.indexOf(anchor);
            const targetButton = buttonElement || (index >= 0 ? state.buttons[index] : null);
            const vh = viewportHeight();
            let clampedTop = vh / 2;
            if (targetButton && typeof targetButton.getBoundingClientRect === "function") {
              const btnRect = targetButton.getBoundingClientRect();
              const btnCenterY = (btnRect.top || 0) + ((btnRect.height || 14) / 2);
              const cardHalfH = (state.preview?.offsetHeight || 80) / 2;
              clampedTop = Math.max(16 + cardHalfH, Math.min(vh - 16 - cardHalfH, btnCenterY));
            }

            // 如果已有 preview 卡片，直接复用 DOM 节点，原地更新内容并触发平滑位移跟随
            if (state.preview && state.preview.parentNode) {
              const titleEl = state.preview.querySelector(".paper-toc-preview-title");
              let excerptEl = state.preview.querySelector(".paper-toc-preview-excerpt");
              if (titleEl) titleEl.textContent = content.title;
              if (content.excerpt) {
                if (!excerptEl) {
                  excerptEl = document.createElement("div");
                  excerptEl.classList.add("paper-toc-preview-excerpt");
                  state.preview.appendChild(excerptEl);
                }
                excerptEl.textContent = content.excerpt;
              } else if (excerptEl) {
                excerptEl.remove();
              }
              state.preview.style.top = clampedTop + "px";
              return;
            }

            // 初次创建卡片：先赋好计算后的 top 坐标再挂载，确保纯原地浮现，绝不从 50% 飞跃
            const card = document.createElement("aside");
            card.id = "paper-rss-toc-preview";
            card.classList.add("paper-toc-preview");
            card.style.width = Math.min(360, Math.max(0, (window.innerWidth || 0) - 64)) + "px";
            card.style.right = "48px";
            card.style.top = clampedTop + "px";
            card.setAttribute("data-paper-toc-preview", "true");
            const title = document.createElement("div");
            title.classList.add("paper-toc-preview-title");
            title.textContent = content.title;
            card.appendChild(title);
            if (content.excerpt) {
              const excerpt = document.createElement("div");
              excerpt.classList.add("paper-toc-preview-excerpt");
              excerpt.textContent = content.excerpt;
              card.appendChild(excerpt);
            }
            card.addEventListener("mouseenter", () => {
              if (state.closeTimer !== null) window.clearTimeout(state.closeTimer);
              state.closeTimer = null;
              showRail();
            });
            card.addEventListener("mouseleave", () => {
              state.hoveredElement = null;
              schedulePreviewClose();
              if (!state.railHovered && !state.mouseNear) scheduleHide(600);
            });
            card.addEventListener("pointerdown", dismissPreview);
            root.appendChild(card);
            state.preview = card;
          };

          const schedulePreview = (anchor, buttonElement) => {
            if (state.hoverTimer !== null) window.clearTimeout(state.hoverTimer);
            if (state.closeTimer !== null) window.clearTimeout(state.closeTimer);
            state.closeTimer = null;
            state.hoveredElement = anchor.element;
            // 浮窗处于打开状态时，0ms 立即切换跟随，鼠标移到哪立刻显示到哪，绝无滞后；初次呼出 40ms
            if (state.preview && state.preview.parentNode) {
              showPreview(anchor, buttonElement);
              return;
            }
            state.hoverTimer = window.setTimeout(() => {
              state.hoverTimer = null;
              if (state.hoveredElement === anchor.element) showPreview(anchor, buttonElement);
            }, 40);
          };

          const isLongLeaf = node => {
            if (!node || node.matches?.("h1,h2,h3,h4,h5,h6")) return false;
            if (node.closest?.(".paper-header-container, .paper-summary-card, #paper-rss-toc-rail")) return false;
            const text = textOf(node);
            if (text.length < 80) return false;
            if (hasBlockChildren(node)) return false;
            const style = typeof getComputedStyle === "function" ? getComputedStyle(node) : null;
            if (style?.display === "none" || style?.visibility === "hidden") return false;
            const rect = node.getBoundingClientRect?.() || { height: 0 };
            const lineHeight = Number.parseFloat(style?.lineHeight || "") || 27;
            const estimatedLines = Math.max(1, Math.ceil(text.length / 32));
            const lineCount = rect.height > 0 ? Math.ceil(rect.height / lineHeight) : estimatedLines;
            return lineCount >= 6;
          };

          const fallbackCandidates = () => {
            const selectors = "p,li,blockquote,pre,figure,section,article,div";
            return Array.from(document.querySelectorAll(selectors))
              .filter(isLongLeaf)
              .map(element => {
                const text = textOf(element);
                const excerpt = splitExcerpt(text);
                return {
                  element,
                  label: excerpt.label,
                  excerpt: excerpt.excerpt,
                  kind: "fallback",
                  level: 7,
                  position: absoluteTopOf(element)
                };
              });
          };

          const sampleUniformly = (items, count) => {
            if (count <= 0 || !items.length) return [];
            if (count >= items.length) return items.slice();
            const ordered = items.slice().sort((lhs, rhs) => lhs.position - rhs.position || compareDocumentOrder(lhs, rhs));
            const firstPosition = ordered[0].position;
            const lastPosition = ordered[ordered.length - 1].position;
            const targets = count === 1
              ? [(firstPosition + lastPosition) / 2]
              : Array.from({ length: count }, (_, index) =>
                firstPosition + (lastPosition - firstPosition) * index / (count - 1)
              );
            const available = ordered.slice();
            return targets.map(target => {
              const atOrAfter = available
                .map((item, index) => ({ item, index }))
                .filter(candidate => candidate.item.position >= target)
                .sort((lhs, rhs) => lhs.item.position - rhs.item.position)[0];
              const bestIndex = atOrAfter?.index ?? available.length - 1;
              return available.splice(bestIndex, 1)[0];
            });
          };

          const compressAnchors = anchors => {
            if (anchors.length <= 18) return anchors;
            const first = anchors[0];
            const last = anchors[anchors.length - 1];
            const middle = anchors.slice(1, -1);
            const picks = [];
            const bucketCount = 16;
            const positions = anchors.map(anchor => anchor.position).filter(Number.isFinite);
            const firstPosition = Math.min(...positions);
            const lastPosition = Math.max(...positions);
            const span = Math.max(1, lastPosition - firstPosition);
            const available = middle.slice();
            for (let bucketIndex = 0; bucketIndex < bucketCount; bucketIndex += 1) {
              const start = firstPosition + span * bucketIndex / bucketCount;
              const end = firstPosition + span * (bucketIndex + 1) / bucketCount;
              const target = (start + end) / 2;
              const bucket = available.filter(anchor =>
                anchor.position >= start && (bucketIndex === bucketCount - 1 ? anchor.position <= end : anchor.position < end)
              );
              const pool = bucket.length ? bucket : available;
              if (!pool.length) continue;
              const semantic = pool
                .filter(anchor => anchor.kind === "heading")
                .sort((lhs, rhs) => lhs.level - rhs.level || Math.abs(lhs.position - target) - Math.abs(rhs.position - target) || compareDocumentOrder(lhs, rhs));
              const ranked = semantic.length ? semantic : pool.slice().sort((lhs, rhs) => {
                const lhsAfter = lhs.position >= target;
                const rhsAfter = rhs.position >= target;
                if (lhsAfter !== rhsAfter) return lhsAfter ? -1 : 1;
                return Math.abs(lhs.position - target) - Math.abs(rhs.position - target) || compareDocumentOrder(lhs, rhs);
              });
              const selected = ranked[0];
              picks.push(selected);
              available.splice(available.indexOf(selected), 1);
            }
            return [first, ...picks.sort(compareDocumentOrder), last];
          };

          const clearRail = () => {
            closePreview();
            if (state.hideTimer !== null) window.clearTimeout(state.hideTimer);
            state.hideTimer = null;
            state.mouseNear = false;
            state.railHovered = false;
            state.hoveredIndex = null;
            if (state.navigatingTimer !== null) window.clearTimeout(state.navigatingTimer);
            state.navigatingTimer = null;
            state.navigatingAnchor = null;
            if (state.dragging && state.dragPointerId !== null) {
              state.buttons.forEach(button => button.releasePointerCapture?.(state.dragPointerId));
              state.dragTarget?.releasePointerCapture?.(state.dragPointerId);
            }
            state.dragging = false;
            state.dragged = false;
            state.hasMovedPastThreshold = false;
            state.dragPointerId = null;
            state.dragTarget = null;
            state.suppressClick = false;
            state.rail?.remove();
            state.rail = null;
            state.buttons = [];
            state.anchors = [];
            root.classList.remove("paper-toc-rail-active");
          };

          const visualFocusOffset = () => Math.round(
            Math.min(160, Math.max(64, viewportHeight() * 0.2))
          );

          const updateActive = () => {
            if (!state.anchors.length) return;
            if (state.dragging) return;
            if (state.hoveredIndex !== null && state.hoveredIndex >= 0 && state.hoveredIndex < state.buttons.length) {
              return;
            }
            if (state.navigatingAnchor) {
              const lockedIndex = state.anchors.indexOf(state.navigatingAnchor);
              if (lockedIndex >= 0) {
                state.buttons.forEach((button, index) => {
                  const active = index === lockedIndex;
                  button.classList.toggle("is-current", active);
                  button.setAttribute("aria-current", active ? "true" : "false");
                });
                return;
              }
            }

            const sTop = currentScrollTop();
            const vHeight = viewportHeight();
            const dHeight = documentHeight();

            // 触底判定：当页面滚动到接近最底部（剩余小于 24px）时，强制高亮最后一格，解决底部内容不足一屏导致最后一格不高亮的问题
            if (dHeight > vHeight && (sTop + vHeight) >= (dHeight - 24)) {
              const lastIndex = state.anchors.length - 1;
              state.buttons.forEach((button, index) => {
                const active = index === lastIndex;
                button.classList.toggle("is-current", active);
                button.setAttribute("aria-current", active ? "true" : "false");
              });
              return;
            }

            const offset = visualFocusOffset();
            const threshold = sTop + offset + 8;
            let activeIndex = 0;
            state.anchors.forEach((anchor, index) => {
              const absoluteTop = anchor.element.getBoundingClientRect().top + sTop;
              if (absoluteTop <= threshold) activeIndex = index;
            });
            state.buttons.forEach((button, index) => {
              const active = index === activeIndex;
              button.classList.toggle("is-current", active);
              button.setAttribute("aria-current", active ? "true" : "false");
            });
          };

          const navigateTo = anchor => {
            const isFirst = state.anchors[0] === anchor;
            const offset = isFirst ? 0 : visualFocusOffset();
            const target = Math.max(
              0,
              isFirst ? 0 : anchor.element.getBoundingClientRect().top + currentScrollTop() - offset
            );
            const reducedMotion = typeof window.matchMedia === "function" &&
              window.matchMedia("(prefers-reduced-motion: reduce)").matches;
            window.scrollTo({ top: target, behavior: reducedMotion ? "auto" : "smooth" });
          };

          const activateAnchor = (anchor, isInstantJump) => {
            wakeRail(1600);
            const index = state.anchors.indexOf(anchor);
            if (index >= 0) {
              state.buttons.forEach((button, i) => {
                const active = i === index;
                button.classList.toggle("is-current", active);
                button.setAttribute("aria-current", active ? "true" : "false");
              });
            }
            state.navigatingAnchor = anchor;
            if (state.navigatingTimer !== null) window.clearTimeout(state.navigatingTimer);
            state.navigatingTimer = window.setTimeout(() => {
              state.navigatingAnchor = null;
              state.navigatingTimer = null;
              updateActive();
            }, isInstantJump ? 60 : 700);
            navigateTo(anchor);
          };

          const dragScrollTo = event => {
            const rail = state.rail;
            const rect = rail?.getBoundingClientRect?.();
            const clientY = Number(event.clientY);
            if (!rect || !Number.isFinite(clientY) || !rect.height) return;
            const ratio = Math.min(1, Math.max(0, (clientY - rect.top) / rect.height));
            const range = Math.max(0, documentHeight() - viewportHeight());
            window.scrollTo({ top: range * ratio, behavior: "auto" });

            // 拖动期间：高亮位置精准跟随鼠标按住的条目
            if (state.buttons.length > 0) {
              const activeIndex = Math.min(
                state.buttons.length - 1,
                Math.max(0, Math.floor(ratio * state.buttons.length))
              );
              state.buttons.forEach((button, index) => {
                const active = index === activeIndex;
                button.classList.toggle("is-current", active);
                button.setAttribute("aria-current", active ? "true" : "false");
              });
            }
          };

          const dragTargetForEvent = event =>
            event.target?.closest?.("[data-paper-toc-button]") || state.rail;

          const startDrag = event => {
            if (state.dragging) return;
            if (event.button !== undefined && event.button !== 0) return;
            const target = dragTargetForEvent(event);
            if (!target) return;
            showRail();
            state.dragging = true;
            state.dragged = false;
            state.hasMovedPastThreshold = false;
            state.dragStartY = event.clientY;
            state.dragStartX = event.clientX;
            state.dragPointerId = event.pointerId;
            state.dragTarget = target;
            state.suppressClick = false;
            dismissPreview();
            target.setPointerCapture?.(event.pointerId);

            // 按下一瞬间直接更新高亮条目，不触发多余滚动
            const rail = state.rail;
            const rect = rail?.getBoundingClientRect?.();
            const clientY = Number(event.clientY);
            if (rect && Number.isFinite(clientY) && rect.height && state.buttons.length > 0) {
              const ratio = Math.min(1, Math.max(0, (clientY - rect.top) / rect.height));
              const activeIndex = Math.min(
                state.buttons.length - 1,
                Math.max(0, Math.floor(ratio * state.buttons.length))
              );
              state.buttons.forEach((button, index) => {
                const active = index === activeIndex;
                button.classList.toggle("is-current", active);
                button.setAttribute("aria-current", active ? "true" : "false");
              });
            }
          };

          const moveDrag = event => {
            if (!state.dragging || state.dragPointerId !== event.pointerId) return;
            showRail();
            state.dragged = true;
            if (state.navigatingAnchor) {
              state.navigatingAnchor = null;
              if (state.navigatingTimer !== null) window.clearTimeout(state.navigatingTimer);
              state.navigatingTimer = null;
            }
            dragScrollTo(event);
            event.preventDefault?.();
          };

          const endDrag = event => {
            if (!state.dragging || state.dragPointerId !== event.pointerId) return;
            const target = state.dragTarget;
            if (state.dragged && event.type === "pointerup") {
              state.suppressClick = true;
              window.setTimeout(() => { state.suppressClick = false; }, 50);
            }
            state.dragging = false;
            state.hasMovedPastThreshold = false;
            state.dragPointerId = null;
            target?.releasePointerCapture?.(event.pointerId);
            state.dragTarget = null;
            updateActive();
            scheduleHide(1000);
          };

          const showScrollbarThumb = (opacity, animated = true) => {
            if (!state.scrollbarThumb || state.rail || root.classList.contains("paper-toc-rail-active")) return;
            if (state.scrollbarFadeTimer !== null) {
              window.clearTimeout(state.scrollbarFadeTimer);
              state.scrollbarFadeTimer = null;
            }
            state.scrollbarThumb.classList.remove("is-fading-out");
            state.scrollbarThumb.style.opacity = String(opacity);
          };

          const scheduleScrollbarFadeOut = (delay = 800) => {
            if (!state.scrollbarThumb || state.scrollbarHovered || state.scrollbarDragging) return;
            if (state.scrollbarFadeTimer !== null) window.clearTimeout(state.scrollbarFadeTimer);
            state.scrollbarFadeTimer = window.setTimeout(() => {
              state.scrollbarFadeTimer = null;
              if (!state.scrollbarThumb || state.scrollbarHovered || state.scrollbarDragging) return;
              state.scrollbarThumb.classList.add("is-fading-out");
              state.scrollbarThumb.style.opacity = "0";
            }, delay);
          };

          const ensureScrollbar = () => {
            if (state.scrollbar) return;
            ensureStyle();
            const scrollbar = document.createElement("div");
            scrollbar.id = "paper-rss-floating-scrollbar";
            scrollbar.setAttribute("aria-hidden", "true");

            const thumb = document.createElement("div");
            thumb.className = "paper-floating-thumb";
            thumb.setAttribute("aria-hidden", "true");
            thumb.style.opacity = "0";

            thumb.addEventListener("mouseenter", () => {
              state.scrollbarHovered = true;
              showScrollbarThumb(0.28, true);
            });

            thumb.addEventListener("mouseleave", () => {
              state.scrollbarHovered = false;
              if (!state.scrollbarDragging) {
                scheduleScrollbarFadeOut(300);
              }
            });

            thumb.addEventListener("pointerdown", event => {
              if (event.button !== undefined && event.button !== 0) return;
              event.preventDefault();
              event.stopPropagation();
              state.scrollbarDragging = true;
              state.scrollbarDragStartY = event.clientY;
              state.scrollbarDragStartScrollY = currentScrollTop();
              state.scrollbarDragPointerId = event.pointerId;
              thumb.setPointerCapture?.(event.pointerId);
              showScrollbarThumb(0.36, true);
            });

            thumb.addEventListener("pointermove", event => {
              if (!state.scrollbarDragging || state.scrollbarDragPointerId !== event.pointerId) return;
              const deltaY = event.clientY - state.scrollbarDragStartY;
              const availableTravel = state.scrollbarData?.availableTravel || 1;
              const scrollableH = state.scrollbarData?.scrollableH || 0;
              const deltaProgress = deltaY / Math.max(1, availableTravel);
              const targetScrollY = state.scrollbarDragStartScrollY + (deltaProgress * scrollableH);
              const clampedY = Math.max(0, Math.min(scrollableH, targetScrollY));
              window.scrollTo({ top: clampedY, behavior: "auto" });
            });

            const endScrollbarDrag = event => {
              if (!state.scrollbarDragging || (state.scrollbarDragPointerId !== null && state.scrollbarDragPointerId !== event.pointerId)) return;
              state.scrollbarDragging = false;
              state.scrollbarDragPointerId = null;
              thumb.releasePointerCapture?.(event.pointerId);
              if (!state.scrollbarHovered) {
                scheduleScrollbarFadeOut(500);
              } else {
                showScrollbarThumb(0.28, true);
              }
            };

            thumb.addEventListener("pointerup", endScrollbarDrag);
            thumb.addEventListener("pointercancel", endScrollbarDrag);

            scrollbar.appendChild(thumb);
            root.appendChild(scrollbar);
            state.scrollbar = scrollbar;
            state.scrollbarThumb = thumb;
          };

          const syncScrollbarGeometry = () => {
            if (state.rail || root.classList.contains("paper-toc-rail-active")) {
              if (state.scrollbar) state.scrollbar.style.display = "none";
              return;
            }
            ensureScrollbar();
            if (!state.scrollbar || !state.scrollbarThumb) return;
            state.scrollbar.style.display = "";

            const viewportH = viewportHeight();
            const documentH = Math.max(viewportH, documentHeight());
            const scrollableH = documentH - viewportH;
            const usableTrackH = Math.max(1, viewportH - 12);

            if (usableTrackH <= 0 || scrollableH <= 1) {
              state.scrollbarThumb.style.display = "none";
              return;
            }

            const visibleRatio = Math.max(0.01, Math.min(1, viewportH / documentH));
            const rawThumbH = usableTrackH * visibleRatio;
            const thumbH = Math.max(24, Math.min(usableTrackH, rawThumbH));
            const availableTravel = Math.max(0, usableTrackH - thumbH);
            const scrollProgress = Math.max(0, Math.min(1, currentScrollTop() / scrollableH));
            const thumbY = 6 + (scrollProgress * availableTravel);

            state.scrollbarData = { availableTravel, scrollableH };
            state.scrollbarThumb.style.display = "";
            state.scrollbarThumb.style.height = thumbH.toFixed(1) + "px";
            state.scrollbarThumb.style.transform = `translateY(${thumbY.toFixed(1)}px)`;
          };

          const ensureStyle = () => {
            if (document.getElementById("paper-rss-toc-rail-style")) return;
            const style = document.createElement("style");
            style.id = "paper-rss-toc-rail-style";
            style.textContent = `
              html {
                scrollbar-width: none;
                overscroll-behavior: none;
                overscroll-behavior-y: none;
              }
              html::-webkit-scrollbar { width: 0; height: 0; display: none; }
              html.paper-toc-rail-active {
                scrollbar-width: none;
                overscroll-behavior: none;
                overscroll-behavior-y: none;
              }
              html.paper-toc-rail-active::-webkit-scrollbar { width: 0; height: 0; display: none; }
              #paper-rss-floating-scrollbar {
                position: fixed; z-index: 10000; right: 0; top: 0; bottom: 0;
                width: 12px; pointer-events: none; user-select: none; box-sizing: border-box;
              }
              html.paper-toc-rail-active #paper-rss-floating-scrollbar {
                display: none !important;
              }
              #paper-rss-floating-scrollbar .paper-floating-thumb {
                position: absolute; right: 2.5px; top: 0; width: 4.5px; min-height: 24px;
                border-radius: 2.25px; background: var(--paper-ink);
                opacity: 0; pointer-events: auto; box-sizing: border-box;
                will-change: transform, opacity;
                transition: opacity .12s ease-out;
              }
              #paper-rss-floating-scrollbar .paper-floating-thumb.is-fading-out {
                transition: opacity .28s cubic-bezier(.16, 1, .3, 1);
              }
              #paper-rss-toc-rail {
                position: fixed; z-index: 10000; right: 8px; top: 50%;
                transform: translateY(-50%); width: 34px; min-height: 42px;
                max-height: min(45vh, 280px); display: flex; flex-direction: column;
                justify-content: stretch; align-items: stretch;
                opacity: 0; pointer-events: auto; user-select: none; box-sizing: border-box;
                transition: opacity .28s cubic-bezier(.16, 1, .3, 1);
              }
              #paper-rss-toc-rail.is-visible,
              #paper-rss-toc-rail:hover,
              #paper-rss-toc-rail:focus-within {
                opacity: 1;
              }
              #paper-rss-toc-rail .paper-toc-rail-button {
                appearance: none; border: 0; padding: 0; margin: 0;
                width: 100%; flex: 1 1 0; min-height: 0; height: auto;
                display: grid; place-items: center;
                background: transparent; cursor: pointer; pointer-events: auto;
              }
              #paper-rss-toc-rail .paper-toc-rail-line {
                display: block; width: 8px; height: 3px; border-radius: 2px;
                background: rgba(80, 80, 80, .24);
                transition: width .14s ease, background-color .14s ease;
              }
              #paper-rss-toc-rail .paper-toc-rail-button.is-current .paper-toc-rail-line {
                width: 8px; background: rgba(45, 45, 45, .78);
              }
              #paper-rss-toc-preview {
                position: fixed; z-index: 10001; right: 48px;
                transform: translateY(-50%);
                box-sizing: border-box; max-width: calc(100vw - 64px);
                max-height: min(280px, calc(100vh - 24px)); overflow: hidden;
                padding: 12px 14px; border: .5px solid var(--paper-rule);
                border-radius: 12px; color: var(--paper-ink);
                background: var(--paper-card); box-shadow: 0 10px 26px rgba(35, 31, 25, .16);
                pointer-events: auto; user-select: text; font: 13px/1.48 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                animation: paper-toc-preview-pop .10s cubic-bezier(0, 0, .2, 1) both;
                transition: top .08s cubic-bezier(0, 0, .2, 1);
              }
              @keyframes paper-toc-preview-pop {
                from { opacity: 0; transform: translateY(-50%) scale(0.97); }
                to { opacity: 1; transform: translateY(-50%) scale(1); }
              }
              #paper-rss-toc-preview .paper-toc-preview-title {
                display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2;
                overflow: hidden; margin: 0 0 6px; font-weight: 680;
              }
              #paper-rss-toc-preview .paper-toc-preview-excerpt {
                display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 4;
                overflow: hidden; color: var(--paper-muted); white-space: pre-wrap;
              }
              @media (prefers-color-scheme: dark) {
                #paper-rss-toc-rail .paper-toc-rail-line { background: rgba(220, 220, 220, .28); }
                #paper-rss-toc-rail .paper-toc-rail-button.is-current .paper-toc-rail-line { background: rgba(245, 245, 245, .86); }
              }
              @media (prefers-reduced-motion: reduce) {
                #paper-rss-toc-rail { transition: none; }
                #paper-rss-toc-preview { transition: none; }
              }
            `;
            document.head.appendChild(style);
            state.style = style;
          };

          const buildRail = () => {
            const previousHoverElement = state.hoveredElement;
            const wasVisible = state.rail ? state.rail.classList.contains("is-visible") : false;
            const title = document.querySelector(".paper-header-title");
            const titleText = textOf(title);
            const bodyHeadings = Array.from(document.querySelectorAll("h1,h2,h3,h4,h5,h6"))
              .filter(node => !node.classList.contains("paper-header-title"));
            const anchors = [];
            const titleAnchor = title && titleText
              ? { element: title, label: titleText, excerpt: "", kind: "heading", level: 1, position: absoluteTopOf(title) }
              : null;
            if (titleAnchor) anchors.push(titleAnchor);
            const titleKey = normalized(titleText);
            bodyHeadings.forEach((element, index) => {
              const label = textOf(element);
              if (!label) return;
              if (index === 0 && titleKey && normalized(label) === titleKey) return;
              anchors.push({
                element,
                label,
                excerpt: "",
                kind: "heading",
                level: Number(element.tagName.slice(1)) || 6,
                position: absoluteTopOf(element)
              });
            });

            if (anchors.length < 3) {
              const candidates = fallbackCandidates();
              const supplemental = sampleUniformly(candidates, 3 - anchors.length);
              anchors.push(...supplemental);
              anchors.sort(compareDocumentOrder);
              if (titleAnchor) {
                anchors.splice(anchors.indexOf(titleAnchor), 1);
                anchors.unshift(titleAnchor);
              }
            }

            const height = documentHeight();
            const viewport = viewportHeight();
            const candidateCount = anchors.length;
            const enabled = height > viewport * 2 && candidateCount >= 3;
            if (!enabled) {
              clearRail();
              state.hoveredElement = null;
              syncScrollbarGeometry();
              return;
            }
            const newAnchors = compressAnchors(anchors);

            // In-place reconciliation: 如果已有 rail 且锚点未变，直接就地更新，避免任何 DOM 销毁重建闪烁
            const canReuse = state.rail &&
              state.anchors.length === newAnchors.length &&
              state.anchors.every((a, idx) => a.element === newAnchors[idx].element && a.label === newAnchors[idx].label);

            if (canReuse) {
              state.anchors = newAnchors;
              state.rail.style.height = Math.min(Math.max(42, state.anchors.length * 14), Math.min(viewportHeight() * .45, 280)) + "px";
              updateActive();
              const preservedAnchor = state.anchors.find(anchor => anchor.element === previousHoverElement);
              if (preservedAnchor && state.preview) {
                const preservedIndex = state.anchors.indexOf(preservedAnchor);
                setHoverPeak(preservedIndex);
                showPreview(preservedAnchor, state.buttons[preservedIndex]);
              }
              return;
            }

            clearRail();
            state.anchors = newAnchors;
            ensureStyle();
            if (state.scrollbar) state.scrollbar.style.display = "none";
            const rail = document.createElement("nav");
            rail.id = "paper-rss-toc-rail";
            rail.setAttribute("aria-label", currentRailLabel());
            rail.setAttribute("data-paper-toc-rail", "true");
            rail.style.height = Math.min(Math.max(42, state.anchors.length * 14), Math.min(viewportHeight() * .45, 280)) + "px";

            state.anchors.forEach((anchor, index) => {
              const button = document.createElement("button");
              button.className = "paper-toc-rail-button";
              button.dataset.paperTocButton = "true";
              button.dataset.paperTocLabel = anchor.label;
              button.dataset.paperTocExcerpt = anchor.excerpt || "";
              button.type = "button";
              button.setAttribute("aria-label", anchor.label);
              button.setAttribute("aria-current", "false");
              const line = document.createElement("span");
              line.className = "paper-toc-rail-line";
              line.setAttribute("aria-hidden", "true");
              button.appendChild(line);
              button.addEventListener("click", event => {
                event.preventDefault();
                if (state.suppressClick) {
                  state.suppressClick = false;
                  return;
                }
                const reducedMotion = typeof window.matchMedia === "function" &&
                  window.matchMedia("(prefers-reduced-motion: reduce)").matches;
                activateAnchor(anchor, reducedMotion);
              });
              button.addEventListener("keydown", event => {
                if (event.key !== "Enter" && event.key !== " ") return;
                event.preventDefault();
                event.stopPropagation();
                dismissPreview();
                const reducedMotion = typeof window.matchMedia === "function" &&
                  window.matchMedia("(prefers-reduced-motion: reduce)").matches;
                activateAnchor(anchor, reducedMotion);
              });
              button.addEventListener("focus", showRail);
              button.addEventListener("blur", () => scheduleHide(600));
              button.addEventListener("mouseenter", () => {
                setHoverPeak(index);
                schedulePreview(anchor, button);
              });
              button.addEventListener("mouseleave", schedulePreviewClose);
              rail.appendChild(button);
              state.buttons.push(button);
            });
            rail.addEventListener("mouseenter", () => {
              state.railHovered = true;
              if (state.hideTimer !== null) {
                window.clearTimeout(state.hideTimer);
                state.hideTimer = null;
              }
              showRail();
            });
            rail.addEventListener("mouseleave", () => {
              state.railHovered = false;
              schedulePreviewClose();
              scheduleHide(600);
            });
            rail.addEventListener("pointerdown", dismissPreview);
            rail.addEventListener("pointerdown", startDrag);
            rail.addEventListener("pointermove", moveDrag);
            rail.addEventListener("pointerup", endDrag);
            rail.addEventListener("pointercancel", endDrag);
            root.appendChild(rail);
            state.rail = rail;
            root.classList.add("paper-toc-rail-active");
            if (wasVisible || state.mouseNear || state.railHovered) {
              rail.classList.add("is-visible");
            }
            updateActive();
            const preservedAnchor = state.anchors.find(anchor => anchor.element === previousHoverElement);
            if (preservedAnchor) {
              const preservedIndex = state.anchors.indexOf(preservedAnchor);
              setHoverPeak(preservedIndex);
              showPreview(preservedAnchor, state.buttons[preservedIndex]);
            }
          };

          const refresh = () => {
            if (state.scheduled) return;
            state.scheduled = true;
            window.requestAnimationFrame(() => {
              state.scheduled = false;
              buildRail();
            });
          };
          const onScroll = () => {
            if (state.rail) {
              wakeRail(1400);
              window.requestAnimationFrame(updateActive);
            } else {
              syncScrollbarGeometry();
              if (!state.scrollbarHovered && !state.scrollbarDragging) {
                showScrollbarThumb(0.18, false);
                scheduleScrollbarFadeOut(800);
              }
            }
          };
          const onResize = () => {
            syncScrollbarGeometry();
            refresh();
          };
          const onWheel = () => {
            if (state.rail) {
              wakeRail(1400);
              if (state.navigatingAnchor) {
                state.navigatingAnchor = null;
                if (state.navigatingTimer !== null) window.clearTimeout(state.navigatingTimer);
                state.navigatingTimer = null;
                updateActive();
              }
            } else {
              syncScrollbarGeometry();
              if (!state.scrollbarHovered && !state.scrollbarDragging) {
                showScrollbarThumb(0.18, false);
                scheduleScrollbarFadeOut(800);
              }
            }
          };
          const onPointerMove = event => {
            const clientX = Number(event?.clientX);
            if (!Number.isFinite(clientX)) return;
            const windowWidth = Number(window.innerWidth || document.documentElement.clientWidth || 0);
            if (state.rail) {
              const nearEdge = windowWidth > 0 && clientX >= windowWidth - 64;
              if (nearEdge) {
                state.mouseNear = true;
                if (state.hideTimer !== null) {
                  window.clearTimeout(state.hideTimer);
                  state.hideTimer = null;
                }
                showRail();
              } else if (state.mouseNear) {
                state.mouseNear = false;
                scheduleHide(600);
              }
            } else {
              const nearScrollbarEdge = windowWidth > 0 && clientX >= windowWidth - 12;
              if (nearScrollbarEdge) {
                if (!state.scrollbarHovered && !state.scrollbarDragging) {
                  showScrollbarThumb(0.28, true);
                }
              } else if (!state.scrollbarHovered && !state.scrollbarDragging && !state.scrollbarFadeTimer) {
                scheduleScrollbarFadeOut(300);
              }
            }
          };
          const onKeyDown = event => {
            if (event.key === "Escape") dismissPreview();
          };
          state.refresh = refresh;
          state.syncScrollbarGeometry = syncScrollbarGeometry;
          state.destroy = () => {
            if (state.hideTimer !== null) window.clearTimeout(state.hideTimer);
            if (state.navigatingTimer !== null) window.clearTimeout(state.navigatingTimer);
            if (state.scrollbarFadeTimer !== null) window.clearTimeout(state.scrollbarFadeTimer);
            state.observer?.disconnect();
            state.resizeObserver?.disconnect();
            document.removeEventListener("scroll", onScroll, { capture: true });
            document.removeEventListener("keydown", onKeyDown, { capture: true });
            document.removeEventListener("pointermove", onPointerMove);
            window.removeEventListener("resize", onResize);
            window.removeEventListener("wheel", onWheel, { capture: true });
            clearRail();
            state.scrollbar?.remove();
            state.scrollbar = null;
            state.scrollbarThumb = null;
            state.style?.remove();
            if (window.paperRssTOCRail === state) delete window.paperRssTOCRail;
          };
          window.paperRssTOCRail = state;
          document.addEventListener("scroll", onScroll, { passive: true, capture: true });
          document.addEventListener("keydown", onKeyDown, { capture: true });
          document.addEventListener("pointermove", onPointerMove, { passive: true });
          window.addEventListener("resize", onResize, { passive: true });
          window.addEventListener("wheel", onWheel, { passive: true, capture: true });
          if (typeof MutationObserver !== "undefined") {
            state.observer = new MutationObserver((mutations) => {
              const shouldIgnore = mutations.every(m => {
                const node = m.target;
                const el = (node && node.nodeType === 1) ? node : (node ? node.parentElement : null);
                if (!el || typeof el.closest !== "function") return false;
                return el.closest('#paper-summary-card') ||
                       el.closest('.paper-selection-popover') ||
                       el.closest('#paper-rss-toc-rail') ||
                       el.closest('#paper-rss-toc-preview') ||
                       el.closest('#paper-rss-floating-scrollbar');
              });
              if (!shouldIgnore) {
                refresh();
              }
            });
            state.observer.observe(document.body, { childList: true, subtree: true, characterData: true });
          }
          if (typeof ResizeObserver !== "undefined") {
            state.resizeObserver = new ResizeObserver(refresh);
            state.resizeObserver.observe(document.body);
          }
          refresh();
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )
    #endif

    static let selectionScript = WKUserScript(
        source: """
        (() => {
          if (window.paperRssSelectionAssistant) return;

          const selectionLabel = (key, fallback) => window.paperRssSelectionOptions?.labels?.[key] || fallback;
          const hasEnabledAction = options =>
            options?.showsExplanation !== false ||
            options?.showsAsk !== false ||
            options?.showsTranslation !== false;

          let actionBar = null;
          let activeRange = null;
          let activeSelection = null;
          let activePopover = null;
          let activeAnchorRect = null;
          let activeAnchorElement = null;
          let selectionTimer = null;

          let isAsking = false;

          const canonicalOptionsSignature = value => {
            if (Array.isArray(value)) return "[" + value.map(item => canonicalOptionsSignature(item)).join(",") + "]";
            if (value && typeof value === "object") {
              return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonicalOptionsSignature(value[key])).join(",") + "}";
            }
            return JSON.stringify(value);
          };

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
            title.textContent = kind === "translation"
              ? selectionLabel("translationTitle", "翻译")
              : (question ? selectionLabel("questionTitle", "问 AI 答疑") : selectionLabel("explanationTitle", "AI 解释"));
            header.append(title);
            popover.append(header);
            if (question) {
              const qBox = document.createElement("div");
              qBox.className = "paper-rss-question-tag";
              qBox.style.cssText = "font-size:12px;opacity:0.8;margin:4px 0 8px;font-weight:600;";
              qBox.textContent = (window.paperRssSelectionOptions?.labels?.questionPrefix || "问：") + question;
              popover.append(qBox);
            }
            const body = document.createElement("div");
            body.className = "paper-rss-explanation-body";
            body.textContent = text || (kind === "translation"
              ? selectionLabel("loadingTranslation", "正在翻译…")
              : (question ? selectionLabel("loadingAnswer", "正在生成解答…") : selectionLabel("loadingExplanation", "正在结合全文理解这段文字…")));
            popover.append(body);
            document.body.append(popover);
            activePopover = popover;
            positionNear(popover, rect, true);
          };

          const updatePopover = (id, text, state, kind) => {
            if (!activePopover || activePopover.dataset.explanationId !== id) return;
            activePopover.className = "paper-rss-explanation " + (state || "") + (kind === "translation" ? " is-translation" : "");
            const body = activePopover.querySelector(".paper-rss-explanation-body");
            if (body) body.textContent = text || (state === "is-error"
              ? selectionLabel("retryError", "暂时无法完成，请稍后重试。")
              : selectionLabel("loadingGeneric", "正在生成…"));
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
            input.placeholder = window.paperRssSelectionOptions?.labels?.questionPlaceholder || "针对划选文字提问...";
            input.style.cssText = "border:none;background:transparent;outline:none;font-size:13px;color:var(--paper-ink);width:150px;";

            const sendBtn = document.createElement("button");
            sendBtn.type = "submit";
            sendBtn.className = "paper-rss-selection-action";
            sendBtn.append(svgIcon("ask"));
            sendBtn.setAttribute("title", window.paperRssSelectionOptions?.labels?.sendQuestion || "发送提问");

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
            const selection = window.getSelection();
            const selectedText = selection?.toString().trim() || "";
            // 选区文本未变化时不得拆除重建工具条：pointerup/selectionchange 都会
            // 触发本函数，若在用户按下工具条按钮到 click 派发之间移除并重建按钮
            // 节点，click 的目标节点已被替换，按钮的 click 监听永远无法命中
            // （表现：工具条消失且不出现任何 AI 弹窗）。选区真正变化时才重建。
            if (actionBar && activeSelection === selectedText) return;
            removeAction();
            if (!selection || selection.rangeCount === 0 || selectedText.length < 2) return;
            const range = selection.getRangeAt(0).cloneRange();
            const origin = range.commonAncestorContainer.nodeType === Node.TEXT_NODE ? range.commonAncestorContainer.parentElement : range.commonAncestorContainer;
            if (origin?.closest?.(".paper-rss-selection-actions")) return;
            const focusRect = focusRectForSelection(selection, range);
            if (!focusRect || (!focusRect.width && !focusRect.height)) return;
            const opts = window.paperRssSelectionOptions || { showsExplanation: true, showsAsk: true, showsTranslation: true };
            if (!hasEnabledAction(opts)) return;
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
            const buttons = [];
            if (opts.showsExplanation !== false) buttons.push(makeButton("note", opts.labels?.explain || "解释所选文字"));
            if (opts.showsAsk !== false) buttons.push(makeButton("ask", opts.labels?.ask || "问 AI 所选文字"));
            if (opts.showsTranslation !== false) buttons.push(makeButton("translation", opts.labels?.translate || "翻译所选文字"));
            if (buttons.length === 0) return;
            buttons.forEach(btn => bar.append(btn));
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
              showPopover(target.dataset.explanationId, rect, loading ? "" : (target.dataset.explanation || selectionLabel("unavailableExplanation", "解释暂不可用。")), loading ? "is-loading" : "", "explanation", icon);
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
            updateOptions(options) {
              // 原生 updateNSView 每次 SwiftUI 更新都会重发同一份 options。
              // 若据此无条件 removeAction()，用户按住工具条按钮的瞬间工具条会被
              // 拆除重建，click 派发时目标按钮已被替换 —— 按钮监听永远无法命中
              // （表现：划词后点击解释/提问/翻译毫无反应，工具条消失且无弹窗）。
              // 仅在选项真正变化时才清除过期的工具条/弹窗。签名必须按键排序
              // 规范化：同一 payload 反复序列化的键序不保证一致。
              const signature = canonicalOptionsSignature(options);
              if (window.paperRssSelectionOptionsSignature === signature && window.paperRssSelectionOptions) {
                window.paperRssSelectionOptions = options;
                return;
              }
              window.paperRssSelectionOptionsSignature = signature;
              window.paperRssSelectionOptions = options;
              removeAction();
              if (!hasEnabledAction(options)) dismissPopover();
            },
            append(id, text, kind) {
              if (!text) return;
              const body = activePopover?.dataset.explanationId === id ? activePopover.querySelector(".paper-rss-explanation-body") : null;
              if (body) {
                const loadingTexts = [
                  selectionLabel("loadingExplanation", "正在结合全文理解这段文字…"),
                  selectionLabel("loadingTranslation", "正在翻译…"),
                  selectionLabel("loadingAnswer", "正在生成解答…"),
                  selectionLabel("loadingGeneric", "正在生成…")
                ];
                body.textContent = loadingTexts.includes(body.textContent) ? text : body.textContent + text;
              }
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
                    btn.setAttribute("title", selectionLabel("reopenExplanation", "点击重新查看 AI 解释"));
                  }
                });
                standaloneIcons.forEach(icon => {
                  icon.classList.remove("is-pending");
                  icon.dataset.explanation = text;
                  icon.setAttribute("aria-label", selectionLabel("completedExplanation", "已完成解释，点击重新查看"));
                  icon.setAttribute("title", selectionLabel("reopenExplanation", "点击重新查看 AI 解释"));
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

    /// 画廊归一：博客 feed 常以原生 HTML `<div><img><img></div>` 输出多图画廊，
    /// 阅读器默认样式会把每个 img 拉成全宽竖排。此脚本把「子元素全部为 ≥2 个 IMG
    /// 且无可见文本」的 div 归一为 `paper-img-row` wrap 行容器，与 Markdown 管线
    /// 的分组产物共用同一套布局语义（对已缓存的旧文章同样生效）。
    static let imageGalleryScript = WKUserScript(
        source: """
        (() => {
          const isGalleryContainer = element => {
            if (!element || element.tagName !== "DIV") return false;
            if (element.classList.contains("paper-img-row")) return false;
            if (typeof element.closest === "function" && element.closest("pre, code")) return false;
            const children = Array.from(element.children || []);
            if (children.length < 2) return false;
            if (!children.every(child => child && child.tagName === "IMG")) return false;
            return String(element.textContent || "").trim() === "";
          };
          document.querySelectorAll("div").forEach(element => {
            if (isGalleryContainer(element)) element.classList.add("paper-img-row");
          });
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

    static let nextArticleMessageName = "paperRssNextArticle"
    static let focusListMessageName = "paperRssFocusList"
    static let readerShortcutMessageName = "paperRssReaderShortcut"

    static let readerShortcutScript = WKUserScript(
        source: """
        (() => {
          const actions = {
            c: "toggleBilingual",
            v: "showSummary",
            k: "previousArticle",
            j: "nextArticle",
            m: "toggleStar",
            f: "toggleFullScreen"
          };

          const isEditable = element => {
            if (!element) return false;
            const tag = String(element.tagName || "").toUpperCase();
            return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || element.isContentEditable;
          };

          const hasTransientReaderUI = () => Boolean(document.querySelector(
            ".paper-rss-selection-actions, .paper-rss-explanation"
          ));

          window.addEventListener("keydown", event => {
            if (event.defaultPrevented || event.isComposing || event.repeat) return;
            if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;

            const action = actions[String(event.key || "").toLowerCase()];
            if (!action) return;
            if (window.paperRssReaderInteractive === false &&
                !(window.paperRssReaderNavigationEnabled === true &&
                  (action === "previousArticle" || action === "nextArticle"))) return;
            if (isEditable(document.activeElement)) return;

            const selection = window.getSelection();
            if (selection && !selection.isCollapsed && selection.toString().trim().length > 0) return;
            if (hasTransientReaderUI()) return;

            const handler = window.webkit?.messageHandlers?.\(readerShortcutMessageName);
            if (!handler) return;
            event.preventDefault();
            event.stopPropagation();
            handler.postMessage({ action });
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: .defaultClient
    )

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

              // 关键：首位阻止默认行为，杜绝 WebKit 原生 Space 键连续冲量撞底引发的橡皮筋拉扯
              event.preventDefault();
              event.stopPropagation();

              if (window.paperRssReaderInteractive === false &&
                  window.paperRssReaderNavigationEnabled !== true) return;

              if (window.paperRssReaderInteractive === false) {
                if (!event.repeat) {
                  window.webkit?.messageHandlers?.\(nextArticleMessageName)?.postMessage({});
                }
                return;
              }

              const scrollHeight = Math.max(
                document.documentElement.scrollHeight,
                document.body.scrollHeight
              );
              const clientHeight = window.innerHeight;
              const scrollTop = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
              const maxScrollTop = Math.max(0, scrollHeight - clientHeight);
              const isAtBottom = scrollTop >= (maxScrollTop - 4);

              if (isAtBottom) {
                // 触底时：严禁发起任何滚动！单次按键（非长按连续触发）才发送切篇消息
                if (!event.repeat && window.webkit?.messageHandlers?.\(nextArticleMessageName)) {
                  window.webkit.messageHandlers.\(nextArticleMessageName).postMessage({});
                }
              } else {
                const pageDistance = Math.max(120, clientHeight * 0.382);
                const targetTop = Math.min(maxScrollTop, scrollTop + pageDistance);
                window.scrollTo({
                  top: targetTop,
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
                  <button class="paper-rss-lightbox-close" title="${window.paperRssSelectionOptions?.labels?.closeImage || "关闭（Esc）"}">
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

    private static var _cachedMathJaxSource: String?
    private static var _cachedMathJaxConfigSource: String?

    static func loadMathJaxConfigSource() -> String? {
        if let cached = _cachedMathJaxConfigSource {
            return cached
        }
        if let url = Bundle.main.url(forResource: "paper-rss-config", withExtension: "js", subdirectory: "MathJax") ??
                     Bundle.main.url(forResource: "paper-rss-config", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.isEmpty {
            _cachedMathJaxConfigSource = content
            return content
        }
        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.url(forResource: "paper-rss-config", withExtension: "js", subdirectory: "Resources/MathJax") ??
                           Bundle.module.url(forResource: "paper-rss-config", withExtension: "js"),
           let content = try? String(contentsOf: moduleURL, encoding: .utf8),
           !content.isEmpty {
            _cachedMathJaxConfigSource = content
            return content
        }
        #endif
        let localPath = "PaperRss/Resources/MathJax/paper-rss-config.js"
        if let content = try? String(contentsOfFile: localPath, encoding: .utf8), !content.isEmpty {
            _cachedMathJaxConfigSource = content
            return content
        }
        return nil
    }

    public static func loadMathJaxBundleSource() -> String? {
        if let cached = _cachedMathJaxSource {
            return cached
        }
        // 1. 尝试从 App Bundle / Resources 加载
        if let url = Bundle.main.url(forResource: "tex-mml-svg", withExtension: "js", subdirectory: "MathJax") ??
                     Bundle.main.url(forResource: "tex-mml-svg", withExtension: "js") {
            if let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
                _cachedMathJaxSource = content
                return content
            }
        }
        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.url(forResource: "tex-mml-svg", withExtension: "js", subdirectory: "Resources/MathJax") ??
                           Bundle.module.url(forResource: "tex-mml-svg", withExtension: "js") {
            if let content = try? String(contentsOf: moduleURL, encoding: .utf8), !content.isEmpty {
                _cachedMathJaxSource = content
                return content
            }
        }
        #endif
        // 2. 本地开发源码目录相对路径兜底
        let localPath = "PaperRss/Resources/MathJax/tex-mml-svg.js"
        if let text = try? String(contentsOfFile: localPath, encoding: .utf8), !text.isEmpty {
            _cachedMathJaxSource = text
            return text
        }
        return nil
    }

    private static var _cachedHighlightSource: String?

    /// 加载本地打包的 highlight.js 运行时（common 语言集，约 125KB）。
    /// 回退顺序与 MathJax 一致：App Bundle → SPM Bundle.module → 源码目录相对路径。
    public static func loadHighlightRuntimeSource() -> String? {
        if let cached = _cachedHighlightSource {
            return cached
        }
        // 1. 尝试从 App Bundle / Resources 加载
        if let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js", subdirectory: "Highlight") ??
                     Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
            _cachedHighlightSource = content
            return content
        }
        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.url(forResource: "highlight.min", withExtension: "js", subdirectory: "Resources/Highlight") ??
                            Bundle.module.url(forResource: "highlight.min", withExtension: "js"),
           let content = try? String(contentsOf: moduleURL, encoding: .utf8), !content.isEmpty {
            _cachedHighlightSource = content
            return content
        }
        #endif
        // 2. 本地开发源码目录相对路径兜底
        let localPath = "PaperRss/Resources/Highlight/highlight.min.js"
        if let text = try? String(contentsOfFile: localPath, encoding: .utf8), !text.isEmpty {
            _cachedHighlightSource = text
            return text
        }
        return nil
    }

    public static func mathUserScripts(containsMath: Bool) -> [WKUserScript] {
        guard containsMath else { return [] }
        // 仅注入轻量配置脚本。TeX 运行时（tex-mml-svg.js，约 1.8MB）不再作为
        // user script 注入：大体量 WKUserScript 存在被 WebKit 静默丢弃的风险，
        // 且文档 CSP（script-src 'none'）可能限制其运行期行为。
        // 运行时改为导航完成后经 evaluateJavaScript 显式求值——原生求值不受
        // 页面 CSP 约束，见 Coordinator.injectMathJaxRuntimeIfNeeded(in:)。
        return [mathConfigScript]
    }

    static func installStandardUserScripts(in controller: WKUserContentController) {
        controller.addUserScript(observerScript)
        #if os(macOS)
        controller.addUserScript(tocRailScript)
        #endif
        controller.addUserScript(selectionScript)
        controller.addUserScript(imageRecoveryScript)
        controller.addUserScript(imageGalleryScript)
        #if os(macOS)
        controller.addUserScript(readerShortcutScript)
        #endif
        controller.addUserScript(spacebarScript)
        controller.addUserScript(mediaFullscreenScript)
        #if os(macOS)
        controller.addUserScript(fontSizeScript)
        #endif
    }

    static func synchronizeMathScripts(
        in webView: WKWebView,
        containsMath: Bool,
        currentlyEnabled: Bool
    ) -> Bool {
        guard containsMath != currentlyEnabled else { return currentlyEnabled }

        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        installStandardUserScripts(in: controller)
        if containsMath {
            for script in mathUserScripts(containsMath: true) {
                controller.addUserScript(script)
            }
        }
        return containsMath
    }

    /// 在页面世界中严格串行完成配置、运行时求值和首次排版。只有
    /// startup.promise 完成且页面实际生成公式节点时才返回成功。
    @MainActor
    static func injectMathJaxRuntime(in webView: WKWebView) async throws -> Int {
        guard let configSource = loadMathJaxConfigSource(),
              let runtimeSource = loadMathJaxBundleSource() else {
            throw NSError(
                domain: "PaperRss.MathJax",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "MathJax runtime resource is unavailable"]
            )
        }

        let hasStartup = (try await webView.evaluateJavaScript(
            "Boolean(window.MathJax?.startup?.promise)"
        ) as? Bool) ?? false
        if !hasStartup {
            _ = try await webView.evaluateJavaScript(configSource)
            _ = try await webView.evaluateJavaScript(runtimeSource)
        }
        let value = try await webView.callAsyncJavaScript(
            """
            const startup = window.MathJax?.startup?.promise;
            if (!startup) {
              throw new Error("MathJax startup promise is unavailable");
            }
            await startup;
            const renderedCount = document.querySelectorAll('mjx-container').length;
            window.dispatchEvent(new CustomEvent("paperRssLayoutRefresh"));
            return renderedCount;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let renderedCount = (value as? NSNumber)?.intValue ?? 0
        guard renderedCount > 0 else {
            throw NSError(
                domain: "PaperRss.MathJax",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "MathJax completed without rendering formulas"]
            )
        }
        return renderedCount
    }

    /// 代码高亮着色脚本：仅处理带 `language-*` / `lang-*` 标注的 `pre code` 块。
    /// 不做语言自动猜测（对任意代码误判率高，与 Folo `guessCodeLanguage` 默认关闭一致）；
    /// 通过 `data-paper-hljs` 标记保证幂等，完成后派发布局刷新事件。
    private static let codeHighlightScriptBody = """
    const targets = [];
    for (const element of document.querySelectorAll('pre code')) {
      if (element.dataset.paperHljs === "1") continue;
      const classes = (element.className || "").split(/\\s+/);
      let language = null;
      for (const cls of classes) {
        const match = /^(?:language|lang)-([A-Za-z0-9_+#.-]+)$/.exec(cls);
        if (match) { language = match[1]; break; }
      }
      if (!language || !window.hljs.getLanguage(language)) continue;
      targets.push({ element, language });
    }
    if (!targets.length) return 0;
    let highlighted = 0;
    for (const { element, language } of targets) {
      try {
        element.innerHTML = window.hljs.highlight(element.textContent, {
          language,
          ignoreIllegals: true
        }).value;
        element.dataset.paperHljs = "1";
        highlighted += 1;
      } catch (error) { /* 单块失败不阻断其余块 */ }
    }
    if (highlighted > 0) {
      window.dispatchEvent(new CustomEvent("paperRssLayoutRefresh"));
    }
    return highlighted;
    """

    /// 文档导航完成后按需注入 highlight.js 并为带语言标注的代码块着色。
    /// 门控：文档没有带语言标注的 `pre code` 时不求值运行时（约 125KB），零成本返回。
    /// 注意 `[class*="lang-"]` 匹配不到 `language-python`（子串不含 `lang-`），
    /// 因此必须同时覆盖 `language-` 与 `lang-` 两种前缀。
    /// 原生求值不受页面 CSP（script-src 'none'）约束，与 MathJax 运行时注入同构。
    @MainActor
    static func injectCodeHighlightRuntime(in webView: WKWebView) async throws -> Int {
        let taggedCount = (try? await webView.evaluateJavaScript(
            "document.querySelectorAll('pre code[class*=\"language-\"], pre code[class*=\"lang-\"]').length"
        ) as? Int) ?? 0
        guard taggedCount > 0 else { return 0 }

        let hasRuntime = (try? await webView.evaluateJavaScript("Boolean(window.hljs)")) as? Bool ?? false
        if !hasRuntime {
            guard let runtimeSource = loadHighlightRuntimeSource() else {
                throw NSError(
                    domain: "PaperRss.Highlight",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "highlight.js runtime resource is unavailable"]
                )
            }
            _ = try await webView.evaluateJavaScript(runtimeSource)
        }
        let runtimeReady = (try? await webView.evaluateJavaScript("Boolean(window.hljs)")) as? Bool ?? false
        guard runtimeReady else {
            throw NSError(
                domain: "PaperRss.Highlight",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "highlight.js runtime evaluation failed"]
            )
        }

        let value = try await webView.callAsyncJavaScript(
            codeHighlightScriptBody,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        return (value as? NSNumber)?.intValue ?? 0
    }

    static func isSameDocumentAnchor(_ url: URL, baseURL: URL?) -> Bool {
        guard url.fragment != nil else { return false }
        guard let baseURL else {
            return url.scheme == nil || (url.scheme?.lowercased() == "about" && url.path == "blank")
        }
        guard
              var targetComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        targetComponents.fragment = nil
        baseComponents.fragment = nil
        return targetComponents.url == baseComponents.url
    }

    static let mathConfigScript = WKUserScript(
        source: loadMathJaxConfigSource() ?? "",
        injectionTime: .atDocumentStart,
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
    let article: PreparedArticle
    let loadSession: Int
    let contentTopInset: CGFloat
    let readerParagraphs: [ReaderParagraph]
    let inlineTranslations: [BilingualSegment]
    let pendingTranslationIDs: Set<String>
    let selectionAnnotations: [ReaderSelectionAnnotation]
    let isBilingualMode: Bool
    let fontSize: Int
    let readerAppearance: ReaderAppearance
    let readerAppearanceMode: ReaderAppearanceMode
    let isInteractive: Bool
    let allowsNavigationWhenInactive: Bool
    let onDocumentReady: (String) -> Bool
    let onDocumentLoadFailed: (String) -> Void
    let summaryArtifact: AIArtifact?
    let isSummaryExpanded: Bool
    let isGeneratingSummary: Bool
    let aiStatusMessage: String?
    let errorMessage: String?
    var showsAISummary: Bool = true
    var showsSelectionExplanation: Bool = true
    var showsSelectionAsk: Bool = true
    var showsSelectionTranslation: Bool = true
    let onVisibleParagraphIDsChange: ([String]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void
    let onSelectionRequest: (
        ReaderSelectionRequest,
        @escaping @Sendable (String) async -> Void
    ) async -> ReaderSelectionResponse
    let onGenerateSummary: (Bool) -> Void
    let onToggleSummary: () -> Void
    var onReaderShortcut: (ReaderShortcutAction) -> Void = { _ in }
    var onSelectNextEntry: () -> Void = {}
    var onFocusListView: () -> Void = {}
    var onAdjustFontSize: ((String) -> Void)? = nil

    private var html: String { article.html }
    private var baseURL: URL? { article.baseURL }
    private var features: ArticleFeatures { article.features }

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
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: PaperReaderBridge.readerShortcutMessageName
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
        PaperReaderBridge.installStandardUserScripts(in: configuration.userContentController)

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
        webView.setAccessibilityLabel(I18N.localized(isBilingualMode ? "原文与逐段翻译" : "原文内容"))
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
        context.coordinator.synchronizeInteractivity(in: webView)
        context.coordinator.synchronizeReaderAppearance(in: webView)
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--paper-font-size', '\(fontSize)px')")
        guard isInteractive else { return }
        context.coordinator.synchronizeSummaryCard(in: webView)
        context.coordinator.synchronizeSelectionOptions(in: webView)
        context.coordinator.restoreSelectionAnnotations(in: webView)
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
            forName: PaperReaderBridge.readerShortcutMessageName,
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
        private var loadedDocumentIdentity: String?
        private var loadedArticle: PreparedArticle?
        private var observedLoadSession: Int?
        private var completedArticleKey: String?
        private var renderedTranslations: [String: String] = [:]
        private var renderedPendingTranslationIDs = Set<String>()
        private var renderedReaderAppearance: ReaderAppearance?
        private var renderedReaderAppearanceMode: ReaderAppearanceMode?
        private var renderedSelectionOptionsJSON: String?
        private struct SummaryRenderSignature: Equatable {
            let content: String
            let isExpanded: Bool
            let isGenerating: Bool
            let statusMessage: String?
            let errorMessage: String?
            let showsAISummary: Bool
            // 完成态翻转必须触发重渲染：否则"上次生成未完成"的旧页脚
            // 会因签名相等而被跳过更新，残留在 DOM 中。
            let isComplete: Bool
        }
        private var renderedSummarySignature: SummaryRenderSignature?
        private var selectionExplanationTask: Task<Void, Never>?
        private var activeSelectionExplanationID: String?
        private var pendingSelectionExplanationRequests: [ReaderSelectionRequest] = []
        private var mathScriptsEnabled = false
        weak var webView: WKWebView?

        init(parent: ArticleHTMLView) {
            self.parent = parent
        }

        func synchronizeReaderAppearance(in webView: WKWebView, force: Bool = false) {
            guard force || renderedReaderAppearance != parent.readerAppearance ||
                    renderedReaderAppearanceMode != parent.readerAppearanceMode else { return }
            renderedReaderAppearance = parent.readerAppearance
            renderedReaderAppearanceMode = parent.readerAppearanceMode
            webView.evaluateJavaScript(
                readerAppearanceJavaScript(parent.readerAppearance, mode: parent.readerAppearanceMode)
            )
        }

        func synchronizeSummaryCard(in webView: WKWebView) {
            guard parent.showsAISummary else {
                let sig = SummaryRenderSignature(
                    content: "",
                    isExpanded: false,
                    isGenerating: false,
                    statusMessage: nil,
                    errorMessage: nil,
                    showsAISummary: false,
                    isComplete: true
                )
                guard renderedSummarySignature != sig else { return }
                renderedSummarySignature = sig
                let script = "(() => { const card = document.getElementById('paper-summary-card'); if (card) card.style.display = 'none'; })();"
                webView.evaluateJavaScript(script)
                return
            }

            let sig = SummaryRenderSignature(
                content: parent.summaryArtifact?.content ?? "",
                isExpanded: parent.isSummaryExpanded,
                isGenerating: parent.isGeneratingSummary,
                statusMessage: parent.aiStatusMessage,
                errorMessage: parent.errorMessage,
                showsAISummary: true,
                isComplete: parent.summaryArtifact?.isComplete ?? true
            )
            guard renderedSummarySignature != sig else { return }
            renderedSummarySignature = sig

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
              const oldCard = document.getElementById('paper-summary-card');
              if (!oldCard) return;

              const temp = document.createElement('div');
              temp.innerHTML = \(jsonEncoded);
              const newCard = temp.firstElementChild;
              if (!newCard) return;

              if (oldCard.className === newCard.className) {
                const oldText = oldCard.querySelector('.paper-summary-text');
                const newText = newCard.querySelector('.paper-summary-text');
                if (oldText && newText) {
                  oldText.innerHTML = newText.innerHTML;
                }

                const oldSubtext = oldCard.querySelector('.paper-summary-subtext');
                const newSubtext = newCard.querySelector('.paper-summary-subtext');
                if (oldSubtext && !newSubtext) {
                  oldSubtext.remove();
                } else if (!oldSubtext && newSubtext) {
                  const headerLeft = oldCard.querySelector('.paper-summary-header-left');
                  if (headerLeft) headerLeft.appendChild(newSubtext.cloneNode(true));
                } else if (oldSubtext && newSubtext) {
                  const oldSpinner = oldSubtext.querySelector('.paper-spinner');
                  const newSpinner = newSubtext.querySelector('.paper-spinner');
                  if (oldSpinner && newSpinner) {
                    const oldSpan = oldSubtext.querySelector('span:not(.paper-spinner)');
                    const newSpan = newSubtext.querySelector('span:not(.paper-spinner)');
                    if (oldSpan && newSpan) {
                      oldSpan.innerHTML = newSpan.innerHTML;
                    }
                  } else {
                    oldSubtext.innerHTML = newSubtext.innerHTML;
                  }
                }

                const oldStatus = oldCard.querySelector('.paper-summary-status');
                const newStatus = newCard.querySelector('.paper-summary-status');
                if (oldStatus && !newStatus) {
                  oldStatus.remove();
                } else if (!oldStatus && newStatus) {
                  const body = oldCard.querySelector('.paper-summary-body');
                  if (body) body.appendChild(newStatus.cloneNode(true));
                } else if (oldStatus && newStatus) {
                  const oldSpinner = oldStatus.querySelector('.paper-spinner');
                  const newSpinner = newStatus.querySelector('.paper-spinner');
                  if (oldSpinner && newSpinner) {
                    const oldSpan = oldStatus.querySelector('span:not(.paper-spinner)');
                    const newSpan = newStatus.querySelector('span:not(.paper-spinner)');
                    if (oldSpan && newSpan) {
                      oldSpan.innerHTML = newSpan.innerHTML;
                    }
                  } else {
                    oldStatus.innerHTML = newStatus.innerHTML;
                  }
                }
                return;
              }

              oldCard.outerHTML = \(jsonEncoded);
            })();
            """
            webView.evaluateJavaScript(script)
        }

        func synchronizeSelectionOptions(in webView: WKWebView) {
            let showsExplanation = parent.showsSelectionExplanation
            let showsAsk = parent.showsSelectionAsk
            let showsTranslation = parent.showsSelectionTranslation
            let options: [String: Any] = [
                "showsExplanation": showsExplanation,
                "showsAsk": showsAsk,
                "showsTranslation": showsTranslation,
                "labels": PaperReaderBridge.localizedSelectionLabels
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: options),
                  let json = String(data: data, encoding: .utf8) else { return }
            // 该函数随每次 SwiftUI 更新（updateNSView）被调用。JS 侧
            // updateOptions 收到 options 会清掉当前划词工具条；若这里不去重，
            // 用户按住按钮的瞬间工具条被拆除重建，click 永远无法命中按钮。
            // JSONSerialization 键序在多次序列化间并不保证一致，必须缓存
            // 序列化结果本身做幂等判断；页面重载后（世界重置）强制重发。
            guard json != renderedSelectionOptionsJSON else { return }
            renderedSelectionOptionsJSON = json
            let script = """
            (() => {
              const options = \(json);
              if (window.paperRssSelectionAssistant) {
                window.paperRssSelectionAssistant.updateOptions(options);
              } else {
                window.paperRssSelectionOptions = options;
              }
              window.paperRssTOCRail?.setRailLabel(options.labels?.tocRailLabel);
            })();
            """
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
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
            if !parent.isInteractive {
                guard parent.allowsNavigationWhenInactive else { return }
                if message.name == PaperReaderBridge.nextArticleMessageName {
                    parent.onSelectNextEntry()
                } else if message.name == PaperReaderBridge.readerShortcutMessageName,
                          let payload = message.body as? [String: Any],
                          let rawAction = payload["action"] as? String,
                          let action = ReaderShortcutAction(rawValue: rawAction),
                          action == .previousArticle || action == .nextArticle {
                    parent.onReaderShortcut(action)
                }
                return
            }
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
            case PaperReaderBridge.readerShortcutMessageName:
                guard let payload = message.body as? [String: Any],
                      let rawAction = payload["action"] as? String,
                      let action = ReaderShortcutAction(rawValue: rawAction) else { return }
                parent.onReaderShortcut(action)
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

        /// 已注入 TeX 运行时的导航键（entryID|renderSignature|generation），避免同次导航重复求值。
        private var lastMathInjectionKey: String?
        private var mathInjectionAttempts: [String: Int] = [:]

        /// 已注入 highlight.js 的导航键（entryID|renderSignature|generation），避免同次导航重复求值。
        private var lastCodeHighlightInjectionKey: String?

        /// 导航完成后按需注入 highlight.js：文档无带语言标注代码块时运行时零求值。
        /// 运行时约 125KB 且求值为同步幂等着色，无需 MathJax 式重试。
        private func injectCodeHighlightingIfNeeded(in webView: WKWebView) {
            let injectionKey = "\(parent.entry.id)|\(loadedArticleKey ?? "")|\(currentLoadGeneration)"
            guard lastCodeHighlightInjectionKey != injectionKey else { return }
            lastCodeHighlightInjectionKey = injectionKey
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                do {
                    _ = try await PaperReaderBridge.injectCodeHighlightRuntime(in: webView)
                } catch {
                    print("[PaperRss][Highlight] runtime evaluation failed: \(error.localizedDescription)")
                }
            }
        }

        /// 导航完成后经原生求值注入 MathJax 运行时：原生 evaluateJavaScript 不受
        /// 页面 CSP 约束，也规避大体量 WKUserScript 被静默丢弃的风险。
        private func injectMathJaxRuntimeIfNeeded(in webView: WKWebView) {
            guard parent.features.containsMath else { return }
            let injectionKey = "\(parent.entry.id)|\(loadedArticleKey ?? "")|\(currentLoadGeneration)"
            guard lastMathInjectionKey != injectionKey else { return }
            let attempt = (mathInjectionAttempts[injectionKey] ?? 0) + 1
            guard attempt <= 2 else { return }
            mathInjectionAttempts = [injectionKey: attempt]

            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    _ = try await PaperReaderBridge.injectMathJaxRuntime(in: webView)
                    guard injectionKey == "\(self.parent.entry.id)|\(self.loadedArticleKey ?? "")|\(self.currentLoadGeneration)" else { return }
                    self.lastMathInjectionKey = injectionKey
                    self.mathInjectionAttempts.removeValue(forKey: injectionKey)
                } catch {
                    guard injectionKey == "\(self.parent.entry.id)|\(self.loadedArticleKey ?? "")|\(self.currentLoadGeneration)" else { return }
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        self.injectMathJaxRuntimeIfNeeded(in: webView)
                    } else {
                        print("[PaperRss][MathJax] runtime evaluation failed after retry: \(error.localizedDescription)")
                    }
                }
            }
        }

        private func synchronizeMathScripts(in webView: WKWebView) {
            mathScriptsEnabled = PaperReaderBridge.synchronizeMathScripts(
                in: webView,
                containsMath: parent.features.containsMath,
                currentlyEnabled: mathScriptsEnabled
            )
        }

        func synchronizeInteractivity(in webView: WKWebView) {
            let value = parent.isInteractive ? "true" : "false"
            let navigationValue = parent.allowsNavigationWhenInactive ? "true" : "false"
            webView.evaluateJavaScript(
                "window.paperRssReaderInteractive = \(value); window.paperRssReaderNavigationEnabled = \(navigationValue)",
                in: nil,
                in: .defaultClient
            ) { _ in }
        }

        func loadIfNeeded(into webView: WKWebView) {
            if observedLoadSession != parent.loadSession {
                observedLoadSession = parent.loadSession
                failedLoadAttempts.removeAll()
            }
            synchronizeInteractivity(in: webView)
            synchronizeMathScripts(in: webView)
            if loadedDocumentIdentity == parent.entry.id,
               loadedArticle == parent.article,
               let renderSignature = loadedArticleKey {
                if failedLoadAttempts[renderSignature, default: 0] >= 2 {
                    parent.onDocumentLoadFailed(parent.entry.id)
                    return
                }
                if completedArticleKey == renderSignature {
                    let entryID = parent.entry.id
                    DispatchQueue.main.async {
                        guard self.parent.entry.id == entryID,
                              self.completedArticleKey == renderSignature else { return }
                        guard self.parent.onDocumentReady(entryID) else { return }
                        self.scrollToTop(in: webView)
                    }
                }
                synchronizeContentTopInset(in: webView)
                if parent.isInteractive {
                    synchronizeTranslations(in: webView)
                    synchronizeSelectionOptions(in: webView)
                }
                return
            }
            // 连击合并：同一 runloop 内快速连续切换时只加载最终目标，
            // 跳过中间文章的全文构建与 WebKit 导航（NetNewsWire 式无中间态）。
            if scheduledNavigationEntryID == parent.entry.id { return }
            scheduledNavigationEntryID = parent.entry.id
            let requestedEntryID = parent.entry.id
            DispatchQueue.main.async {
                self.performDocumentLoad(entryID: requestedEntryID, in: webView)
            }
        }

        private func performDocumentLoad(entryID: String, in webView: WKWebView) {
            guard scheduledNavigationEntryID == entryID,
                  parent.entry.id == entryID else { return }
            scheduledNavigationEntryID = nil
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
                showsAISummary: parent.showsAISummary,
                isBilingualMode: parent.isBilingualMode,
                titleSegment: parent.inlineTranslations.first(where: { $0.id == "title" }),
                isTitlePending: parent.pendingTranslationIDs.contains("title")
            )
            let document = ReaderDocumentRenderer.renderDocument(
                article: parent.article,
                documentIdentity: parent.entry.id,
                bodyHTML: readerHTML,
                headerHTML: headerHTML,
                topInset: Double(parent.contentTopInset),
                fontSize: parent.fontSize,
                extraStyleCSS: paperArticleStyle + readerAppearanceStyle(
                    parent.readerAppearance,
                    mode: parent.readerAppearanceMode
                )
            )
            renderedSummarySignature = nil
            renderedSelectionOptionsJSON = nil
            loadedArticleKey = document.renderSignature
            loadedDocumentIdentity = parent.entry.id
            loadedArticle = parent.article
            completedArticleKey = nil
            renderedTranslations = initialTranslationState.translations
            renderedPendingTranslationIDs = initialTranslationState.pendingIDs
            pendingScrollOffset = 0
            currentLoadGeneration += 1
            let generation = currentLoadGeneration
            if let navigation = webView.loadHTMLString(document.html, baseURL: document.baseURL) {
                navigationLoads[ObjectIdentifier(navigation)] = (
                    entryID: parent.entry.id,
                    signature: document.renderSignature,
                    generation: generation
                )
            } else {
                handleLoadFailure(
                    entryID: parent.entry.id,
                    signature: document.renderSignature,
                    generation: generation,
                    in: webView
                )
            }
            synchronizeSelectionOptions(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let load = navigation.flatMap {
                navigationLoads.removeValue(forKey: ObjectIdentifier($0))
            }
            DispatchQueue.main.async {
                guard let load,
                      load.entryID == self.parent.entry.id,
                      load.signature == self.loadedArticleKey,
                      load.generation == self.currentLoadGeneration else { return }
                self.completedArticleKey = load.signature
                self.failedLoadAttempts.removeValue(forKey: load.signature)
                self.synchronizeReaderAppearance(in: webView, force: true)
                self.injectMathJaxRuntimeIfNeeded(in: webView)
                self.injectCodeHighlightingIfNeeded(in: webView)
                guard self.parent.onDocumentReady(load.entryID) else { return }
                self.synchronizeSelectionOptions(in: webView)
                if let offset = self.pendingScrollOffset,
                   let scrollView = self.readerScrollView(in: webView) {
                    self.pendingScrollOffset = nil
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    self.parent.onScrollOffsetChange(max(0, offset))
                }
                self.synchronizeContentTopInset(in: webView)
                self.synchronizeInteractivity(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(navigation, in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(navigation, in: webView)
        }

        private func handleNavigationFailure(_ navigation: WKNavigation?, in webView: WKWebView) {
            guard let navigation,
                  let load = navigationLoads.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
            handleLoadFailure(
                entryID: load.entryID,
                signature: load.signature,
                generation: load.generation,
                in: webView
            )
        }

        private func handleLoadFailure(
            entryID: String,
            signature: String,
            generation: Int,
            in webView: WKWebView
        ) {
            guard signature == loadedArticleKey,
                  generation == currentLoadGeneration else { return }
            let attempts = failedLoadAttempts[signature, default: 0] + 1
            failedLoadAttempts[signature] = attempts
            if attempts == 1 {
                loadedArticleKey = nil
                DispatchQueue.main.async { self.loadIfNeeded(into: webView) }
            } else {
                parent.onDocumentLoadFailed(entryID)
            }
        }

        private func scrollToTop(in webView: WKWebView) {
            guard let scrollView = readerScrollView(in: webView) else { return }
            pendingScrollOffset = nil
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            parent.onScrollOffsetChange(0)
        }

        func restoreSelectionAnnotations(in webView: WKWebView) {
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
                updates.append(["id": id, "text": I18N.localized("正在翻译…"), "isLoading": true])
            }

            guard !updates.isEmpty || !removals.isEmpty else { return }
            renderedTranslations = desired.translations
            renderedPendingTranslationIDs = desired.pendingIDs
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    PaperReaderBridge.translationSynchronizationScript,
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
                if PaperReaderBridge.isSameDocumentAnchor(url, baseURL: parent.baseURL) {
                    decisionHandler(.allow)
                    return
                }
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
        private var currentLoadGeneration = 0
        /// 已排定待执行导航的目标条目；同 runloop 内被更新目标覆盖即作废。
        private var scheduledNavigationEntryID: String?
        private var navigationLoads: [ObjectIdentifier: (entryID: String, signature: String, generation: Int)] = [:]
        private var failedLoadAttempts: [String: Int] = [:]
    }
}
#endif

#if os(iOS)
private struct ArticleHTMLView: UIViewRepresentable {
    let entry: Entry
    let feedTitle: String?
    let article: PreparedArticle
    let loadSession: Int
    let contentTopInset: CGFloat
    let readerParagraphs: [ReaderParagraph]
    let inlineTranslations: [BilingualSegment]
    let pendingTranslationIDs: Set<String>
    let selectionAnnotations: [ReaderSelectionAnnotation]
    let isBilingualMode: Bool
    let fontSize: Int
    let readerAppearance: ReaderAppearance
    let readerAppearanceMode: ReaderAppearanceMode
    let isInteractive: Bool
    let allowsNavigationWhenInactive: Bool
    let onDocumentReady: (String) -> Bool
    let onDocumentLoadFailed: (String) -> Void
    let summaryArtifact: AIArtifact?
    let isSummaryExpanded: Bool
    let isGeneratingSummary: Bool
    let aiStatusMessage: String?
    let errorMessage: String?
    var showsAISummary: Bool = true
    var showsSelectionExplanation: Bool = true
    var showsSelectionAsk: Bool = true
    var showsSelectionTranslation: Bool = true
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

    private var html: String { article.html }
    private var baseURL: URL? { article.baseURL }
    private var features: ArticleFeatures { article.features }

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
        PaperReaderBridge.installStandardUserScripts(in: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.alwaysBounceVertical = true
        webView.accessibilityLabel = I18N.localized(isBilingualMode ? "原文与逐段翻译" : "原文内容")
        context.coordinator.webView = webView
        context.coordinator.loadIfNeeded(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(into: webView)
        context.coordinator.synchronizeInteractivity(in: webView)
        context.coordinator.synchronizeReaderAppearance(in: webView)
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--paper-font-size', '\(fontSize)px')")
        guard isInteractive else { return }
        context.coordinator.synchronizeSummaryCard(in: webView)
        context.coordinator.synchronizeSelectionOptions(in: webView)
        context.coordinator.restoreSelectionAnnotations(in: webView)
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
        private var loadedDocumentIdentity: String?
        private var loadedArticle: PreparedArticle?
        private var observedLoadSession: Int?
        private var completedArticleKey: String?
        private var pendingContentOffset: CGPoint?
        private var currentLoadGeneration = 0
        /// 已排定待执行导航的目标条目；同 runloop 内被更新目标覆盖即作废。
        private var scheduledNavigationEntryID: String?
        private var navigationLoads: [ObjectIdentifier: (entryID: String, signature: String, generation: Int)] = [:]
        private var failedLoadAttempts: [String: Int] = [:]
        private var renderedTranslations: [String: String] = [:]
        private var renderedPendingTranslationIDs = Set<String>()
        private var renderedReaderAppearance: ReaderAppearance?
        private var renderedReaderAppearanceMode: ReaderAppearanceMode?
        private var renderedSelectionOptionsJSON: String?
        private struct SummaryRenderSignature: Equatable {
            let content: String
            let isExpanded: Bool
            let isGenerating: Bool
            let statusMessage: String?
            let errorMessage: String?
            let showsAISummary: Bool
            // 完成态翻转必须触发重渲染：否则"上次生成未完成"的旧页脚
            // 会因签名相等而被跳过更新，残留在 DOM 中。
            let isComplete: Bool
        }
        private var renderedSummarySignature: SummaryRenderSignature?
        private var selectionExplanationTask: Task<Void, Never>?
        private var activeSelectionExplanationID: String?
        private var pendingSelectionExplanationRequests: [ReaderSelectionRequest] = []
        private var mathScriptsEnabled = false
        weak var webView: WKWebView?

        init(parent: ArticleHTMLView) {
            self.parent = parent
        }

        func synchronizeReaderAppearance(in webView: WKWebView, force: Bool = false) {
            guard force || renderedReaderAppearance != parent.readerAppearance ||
                    renderedReaderAppearanceMode != parent.readerAppearanceMode else { return }
            renderedReaderAppearance = parent.readerAppearance
            renderedReaderAppearanceMode = parent.readerAppearanceMode
            webView.evaluateJavaScript(
                readerAppearanceJavaScript(parent.readerAppearance, mode: parent.readerAppearanceMode)
            )
        }

        func synchronizeSummaryCard(in webView: WKWebView) {
            guard parent.showsAISummary else {
                let sig = SummaryRenderSignature(
                    content: "",
                    isExpanded: false,
                    isGenerating: false,
                    statusMessage: nil,
                    errorMessage: nil,
                    showsAISummary: false,
                    isComplete: true
                )
                guard renderedSummarySignature != sig else { return }
                renderedSummarySignature = sig
                let script = "(() => { const card = document.getElementById('paper-summary-card'); if (card) card.style.display = 'none'; })();"
                webView.evaluateJavaScript(script)
                return
            }

            let sig = SummaryRenderSignature(
                content: parent.summaryArtifact?.content ?? "",
                isExpanded: parent.isSummaryExpanded,
                isGenerating: parent.isGeneratingSummary,
                statusMessage: parent.aiStatusMessage,
                errorMessage: parent.errorMessage,
                showsAISummary: true,
                isComplete: parent.summaryArtifact?.isComplete ?? true
            )
            guard renderedSummarySignature != sig else { return }
            renderedSummarySignature = sig
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
              const oldCard = document.getElementById('paper-summary-card');
              if (!oldCard) return;

              const temp = document.createElement('div');
              temp.innerHTML = \(jsonEncoded);
              const newCard = temp.firstElementChild;
              if (!newCard) return;

              if (oldCard.className === newCard.className) {
                const oldText = oldCard.querySelector('.paper-summary-text');
                const newText = newCard.querySelector('.paper-summary-text');
                if (oldText && newText) {
                  oldText.innerHTML = newText.innerHTML;
                }

                const oldSubtext = oldCard.querySelector('.paper-summary-subtext');
                const newSubtext = newCard.querySelector('.paper-summary-subtext');
                if (oldSubtext && !newSubtext) {
                  oldSubtext.remove();
                } else if (!oldSubtext && newSubtext) {
                  const headerLeft = oldCard.querySelector('.paper-summary-header-left');
                  if (headerLeft) headerLeft.appendChild(newSubtext.cloneNode(true));
                } else if (oldSubtext && newSubtext) {
                  const oldSpinner = oldSubtext.querySelector('.paper-spinner');
                  const newSpinner = newSubtext.querySelector('.paper-spinner');
                  if (oldSpinner && newSpinner) {
                    const oldSpan = oldSubtext.querySelector('span:not(.paper-spinner)');
                    const newSpan = newSubtext.querySelector('span:not(.paper-spinner)');
                    if (oldSpan && newSpan) {
                      oldSpan.innerHTML = newSpan.innerHTML;
                    }
                  } else {
                    oldSubtext.innerHTML = newSubtext.innerHTML;
                  }
                }

                const oldStatus = oldCard.querySelector('.paper-summary-status');
                const newStatus = newCard.querySelector('.paper-summary-status');
                if (oldStatus && !newStatus) {
                  oldStatus.remove();
                } else if (!oldStatus && newStatus) {
                  const body = oldCard.querySelector('.paper-summary-body');
                  if (body) body.appendChild(newStatus.cloneNode(true));
                } else if (oldStatus && newStatus) {
                  const oldSpinner = oldStatus.querySelector('.paper-spinner');
                  const newSpinner = newStatus.querySelector('.paper-spinner');
                  if (oldSpinner && newSpinner) {
                    const oldSpan = oldStatus.querySelector('span:not(.paper-spinner)');
                    const newSpan = newStatus.querySelector('span:not(.paper-spinner)');
                    if (oldSpan && newSpan) {
                      oldSpan.innerHTML = newSpan.innerHTML;
                    }
                  } else {
                    oldStatus.innerHTML = newStatus.innerHTML;
                  }
                }
                return;
              }

              oldCard.outerHTML = \(jsonEncoded);
            })();
            """
            webView.evaluateJavaScript(script)
        }

        func synchronizeSelectionOptions(in webView: WKWebView) {
            let showsExplanation = parent.showsSelectionExplanation
            let showsAsk = parent.showsSelectionAsk
            let showsTranslation = parent.showsSelectionTranslation
            let options: [String: Any] = [
                "showsExplanation": showsExplanation,
                "showsAsk": showsAsk,
                "showsTranslation": showsTranslation,
                "labels": PaperReaderBridge.localizedSelectionLabels
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: options),
                  let json = String(data: data, encoding: .utf8) else { return }
            // 与 macOS 协调器一致：同一份 options 不重复下发，避免 SwiftUI
            // 每次更新都触发 JS 侧拆除重建划词工具条（详见 macOS 侧注释）。
            guard json != renderedSelectionOptionsJSON else { return }
            renderedSelectionOptionsJSON = json
            let script = """
            (() => {
              const options = \(json);
              if (window.paperRssSelectionAssistant) {
                window.paperRssSelectionAssistant.updateOptions(options);
              } else {
                window.paperRssSelectionOptions = options;
              }
            })();
            """
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if !parent.isInteractive {
                guard parent.allowsNavigationWhenInactive,
                      message.name == PaperReaderBridge.nextArticleMessageName else { return }
                parent.onSelectNextEntry()
                return
            }
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

        /// 已注入 TeX 运行时的导航键（entryID|renderSignature|generation），避免同次导航重复求值。
        private var lastMathInjectionKey: String?
        private var mathInjectionAttempts: [String: Int] = [:]

        /// 已注入 highlight.js 的导航键（entryID|renderSignature|generation），避免同次导航重复求值。
        private var lastCodeHighlightInjectionKey: String?

        /// 导航完成后按需注入 highlight.js：文档无带语言标注代码块时运行时零求值。
        /// 运行时约 125KB 且求值为同步幂等着色，无需 MathJax 式重试。
        private func injectCodeHighlightingIfNeeded(in webView: WKWebView) {
            let injectionKey = "\(parent.entry.id)|\(loadedArticleKey ?? "")|\(currentLoadGeneration)"
            guard lastCodeHighlightInjectionKey != injectionKey else { return }
            lastCodeHighlightInjectionKey = injectionKey
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                do {
                    _ = try await PaperReaderBridge.injectCodeHighlightRuntime(in: webView)
                } catch {
                    print("[PaperRss][Highlight] runtime evaluation failed: \(error.localizedDescription)")
                }
            }
        }

        /// 导航完成后经原生求值注入 MathJax 运行时：原生 evaluateJavaScript 不受
        /// 页面 CSP 约束，也规避大体量 WKUserScript 被静默丢弃的风险。
        private func injectMathJaxRuntimeIfNeeded(in webView: WKWebView) {
            guard parent.features.containsMath else { return }
            let injectionKey = "\(parent.entry.id)|\(loadedArticleKey ?? "")|\(currentLoadGeneration)"
            guard lastMathInjectionKey != injectionKey else { return }
            let attempt = (mathInjectionAttempts[injectionKey] ?? 0) + 1
            guard attempt <= 2 else { return }
            mathInjectionAttempts = [injectionKey: attempt]

            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    _ = try await PaperReaderBridge.injectMathJaxRuntime(in: webView)
                    guard injectionKey == "\(self.parent.entry.id)|\(self.loadedArticleKey ?? "")|\(self.currentLoadGeneration)" else { return }
                    self.lastMathInjectionKey = injectionKey
                    self.mathInjectionAttempts.removeValue(forKey: injectionKey)
                } catch {
                    guard injectionKey == "\(self.parent.entry.id)|\(self.loadedArticleKey ?? "")|\(self.currentLoadGeneration)" else { return }
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        self.injectMathJaxRuntimeIfNeeded(in: webView)
                    } else {
                        print("[PaperRss][MathJax] runtime evaluation failed after retry: \(error.localizedDescription)")
                    }
                }
            }
        }

        private func synchronizeMathScripts(in webView: WKWebView) {
            mathScriptsEnabled = PaperReaderBridge.synchronizeMathScripts(
                in: webView,
                containsMath: parent.features.containsMath,
                currentlyEnabled: mathScriptsEnabled
            )
        }

        func synchronizeInteractivity(in webView: WKWebView) {
            let value = parent.isInteractive ? "true" : "false"
            let navigationValue = parent.allowsNavigationWhenInactive ? "true" : "false"
            webView.evaluateJavaScript(
                "window.paperRssReaderInteractive = \(value); window.paperRssReaderNavigationEnabled = \(navigationValue)",
                in: nil,
                in: .defaultClient
            ) { _ in }
        }

        func loadIfNeeded(into webView: WKWebView) {
            if observedLoadSession != parent.loadSession {
                observedLoadSession = parent.loadSession
                failedLoadAttempts.removeAll()
            }
            synchronizeInteractivity(in: webView)
            synchronizeMathScripts(in: webView)
            if loadedDocumentIdentity == parent.entry.id,
               loadedArticle == parent.article,
               let renderSignature = loadedArticleKey {
                if failedLoadAttempts[renderSignature, default: 0] >= 2 {
                    parent.onDocumentLoadFailed(parent.entry.id)
                    return
                }
                if completedArticleKey == renderSignature {
                    let entryID = parent.entry.id
                    DispatchQueue.main.async {
                        guard self.parent.entry.id == entryID,
                              self.completedArticleKey == renderSignature else { return }
                        guard self.parent.onDocumentReady(entryID) else { return }
                        self.scrollToTop(in: webView)
                    }
                }
                synchronizeContentTopInset(in: webView)
                if parent.isInteractive {
                    synchronizeTranslations(in: webView)
                    synchronizeSelectionOptions(in: webView)
                }
                return
            }
            // 连击合并：同一 runloop 内快速连续切换时只加载最终目标，
            // 跳过中间文章的全文构建与 WebKit 导航（NetNewsWire 式无中间态）。
            if scheduledNavigationEntryID == parent.entry.id { return }
            scheduledNavigationEntryID = parent.entry.id
            let requestedEntryID = parent.entry.id
            DispatchQueue.main.async {
                self.performDocumentLoad(entryID: requestedEntryID, in: webView)
            }
        }

        private func performDocumentLoad(entryID: String, in webView: WKWebView) {
            guard scheduledNavigationEntryID == entryID,
                  parent.entry.id == entryID else { return }
            scheduledNavigationEntryID = nil
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
                showsAISummary: parent.showsAISummary,
                isBilingualMode: parent.isBilingualMode,
                titleSegment: parent.inlineTranslations.first(where: { $0.id == "title" }),
                isTitlePending: parent.pendingTranslationIDs.contains("title")
            )
            let document = ReaderDocumentRenderer.renderDocument(
                article: parent.article,
                documentIdentity: parent.entry.id,
                bodyHTML: readerHTML,
                headerHTML: headerHTML,
                topInset: Double(parent.contentTopInset),
                fontSize: parent.fontSize,
                extraStyleCSS: paperArticleStyle + readerAppearanceStyle(
                    parent.readerAppearance,
                    mode: parent.readerAppearanceMode
                )
            )
            renderedSummarySignature = nil
            renderedSelectionOptionsJSON = nil
            loadedArticleKey = document.renderSignature
            loadedDocumentIdentity = parent.entry.id
            loadedArticle = parent.article
            completedArticleKey = nil
            renderedTranslations = initialTranslationState.translations
            renderedPendingTranslationIDs = initialTranslationState.pendingIDs
            pendingContentOffset = .zero
            currentLoadGeneration += 1
            let generation = currentLoadGeneration
            if let navigation = webView.loadHTMLString(document.html, baseURL: document.baseURL) {
                navigationLoads[ObjectIdentifier(navigation)] = (
                    entryID: parent.entry.id,
                    signature: document.renderSignature,
                    generation: generation
                )
            } else {
                handleLoadFailure(
                    entryID: parent.entry.id,
                    signature: document.renderSignature,
                    generation: generation,
                    in: webView
                )
            }
            synchronizeSelectionOptions(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let load = navigation.flatMap {
                navigationLoads.removeValue(forKey: ObjectIdentifier($0))
            }
            let offset = pendingContentOffset
            DispatchQueue.main.async {
                guard let load,
                      load.entryID == self.parent.entry.id,
                      load.signature == self.loadedArticleKey,
                      load.generation == self.currentLoadGeneration else { return }
                self.completedArticleKey = load.signature
                self.failedLoadAttempts.removeValue(forKey: load.signature)
                self.synchronizeReaderAppearance(in: webView, force: true)
                self.pendingContentOffset = nil
                self.injectMathJaxRuntimeIfNeeded(in: webView)
                self.injectCodeHighlightingIfNeeded(in: webView)
                guard self.parent.onDocumentReady(load.entryID) else { return }
                self.synchronizeSelectionOptions(in: webView)
                if let offset {
                    webView.scrollView.setContentOffset(offset, animated: false)
                    self.parent.onScrollOffsetChange(
                        max(0, offset.y + webView.scrollView.adjustedContentInset.top)
                    )
                }
                self.synchronizeContentTopInset(in: webView)
                self.synchronizeInteractivity(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(navigation, in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(navigation, in: webView)
        }

        private func handleNavigationFailure(_ navigation: WKNavigation?, in webView: WKWebView) {
            guard let navigation,
                  let load = navigationLoads.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
            handleLoadFailure(
                entryID: load.entryID,
                signature: load.signature,
                generation: load.generation,
                in: webView
            )
        }

        private func handleLoadFailure(
            entryID: String,
            signature: String,
            generation: Int,
            in webView: WKWebView
        ) {
            guard signature == loadedArticleKey,
                  generation == currentLoadGeneration else { return }
            let attempts = failedLoadAttempts[signature, default: 0] + 1
            failedLoadAttempts[signature] = attempts
            if attempts == 1 {
                loadedArticleKey = nil
                DispatchQueue.main.async { self.loadIfNeeded(into: webView) }
            } else {
                parent.onDocumentLoadFailed(entryID)
            }
        }

        private func scrollToTop(in webView: WKWebView) {
            pendingContentOffset = nil
            webView.scrollView.setContentOffset(.zero, animated: false)
            parent.onScrollOffsetChange(0)
        }

        func restoreSelectionAnnotations(in webView: WKWebView) {
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
                updates.append(["id": id, "text": I18N.localized("正在翻译…"), "isLoading": true])
            }

            guard !updates.isEmpty || !removals.isEmpty else { return }
            renderedTranslations = desired.translations
            renderedPendingTranslationIDs = desired.pendingIDs
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    PaperReaderBridge.translationSynchronizationScript,
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
                if PaperReaderBridge.isSameDocumentAnchor(url, baseURL: parent.baseURL) {
                    decisionHandler(.allow)
                    return
                }
                if let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
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
                        Text(I18N.localized("正在翻译接下来的段落…"))
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text(I18N.localized("继续向下阅读以翻译下一段"))
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
                Label(I18N.localized("全文翻译完成"), systemImage: "checkmark.circle.fill")
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
    @Environment(\.paperAppearancePalette) private var appearancePalette
    @Environment(\.readerCapsuleMaterialHostedByAppKit) private var materialHostedByAppKit

    var body: some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            capsuleContent
        } else if materialHostedByAppKit {
            capsuleContent
        } else {
            capsuleContent
                .padding(.vertical, 4)
                .background { legacyCapsuleBackground }
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 7, x: 0, y: 3)
        }
        #else
        capsuleContent
        #endif
    }

    private var capsuleContent: some View {
        HStack(spacing: 6) {
            Button(action: onToggleBilingual) {
                translationToolbarIcon(isActive: isBilingualActive)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel("\(I18N.localized(isBilingualActive ? "关闭逐段翻译" : "开启逐段翻译")) (C)")
            .help("\(I18N.localized(isBilingualActive ? "关闭逐段翻译" : "开启逐段翻译")) (C)")

            Button(action: onToggleRead) {
                toolbarSymbol(isRead ? "envelope.open" : "envelope", isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18N.localized(isRead ? "标为未读" : "标为已读"))
            .help(I18N.localized(isRead ? "标为未读" : "标为已读"))

            Button(action: onToggleStar) {
                toolbarSymbol(isStarred ? "star.fill" : "star", isActive: isStarred)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(I18N.localized(isStarred ? "取消收藏" : "收藏")) (M)")
            .help("\(I18N.localized(isStarred ? "取消收藏" : "收藏")) (M)")

            Button(action: onToggleZenMode) {
                toolbarSymbol(
                    isZenMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    isActive: isZenMode
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(I18N.localized(isZenMode ? "退出禅模式" : "禅模式全屏阅读"))
            .help(I18N.localized(isZenMode ? "退出禅模式" : "禅模式全屏阅读"))
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    #if os(macOS)
    @ViewBuilder
    private var legacyCapsuleBackground: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color(paperHex: appearancePalette.backgroundHex).opacity(0.64))
        }
    }
    #endif

    private func translationToolbarIcon(isActive: Bool) -> some View {
        ZStack {
            Image(systemName: isActive ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 16, weight: .medium))
            
            Text(I18N.shared.isEnglish ? "A" : "文")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .offset(x: 0.2, y: -1.5)
        }
        .offset(y: 0.6)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .frame(width: 28, height: 26)
        .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear), in: Circle())
        .contentShape(Circle())
    }

    private func toolbarSymbol(_ name: String, isActive: Bool) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 26)
            .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Circle())
    }
}
