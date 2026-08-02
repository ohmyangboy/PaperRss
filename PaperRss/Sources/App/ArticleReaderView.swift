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

struct ArticleReaderView: View {
    @ObservedObject var store: AppStore
    let entry: Entry
    @State private var text = ""
    @State private var html: String?
    /// Parsing a long document's paragraph structure is deliberately done once
    /// per article. The same stable index drives viewport translation requests
    /// and validation of returned translations.
    @State private var parsedReaderParagraphs: [ReaderParagraph] = []
    @State private var articleBaseURL: URL?
    @State private var isLoading = true
    @State private var activeLoadEntryID: String?
    @State private var readerMode: ReaderMode = .original
    @State private var isSummaryExpanded = false
    @State private var isReaderAtTop = true
    @State private var isHeaderManuallyExpanded = false
    @State private var visibleBilingualParagraphIDs: [String] = []
    @State private var pendingBilingualParagraphIDs: Set<String> = []
    @State private var failedBilingualParagraphIDs: Set<String> = []
    @State private var streamingBilingualTranslations: [String: String] = [:]
    @State private var expandedReaderHeaderContentHeight: CGFloat = 176
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

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

    private var readerParagraphs: [ReaderParagraph] { parsedReaderParagraphs }

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
                id: "saved-(artifact.id.uuidString)",
                selection: selection,
                explanation: artifact.content,
                paragraphID: anchor.paragraphID,
                startOffset: anchor.startOffset,
                endOffset: anchor.endOffset
            )
        }
    }

    var body: some View {
        ZStack {
            if hasReaderContent {
                readerBody
            }
            if isLoading {
                loadingOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PaperSurface(kind: .page)
                .ignoresSafeArea()
        }
        .navigationTitle(entry.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { articleToolbar }
        .onPreferenceChange(ReaderHeaderHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - expandedReaderHeaderContentHeight) > 0.5 else { return }
            expandedReaderHeaderContentHeight = height
        }
        .task(id: entry.id) {
            let requestedEntry = entry
            activeLoadEntryID = requestedEntry.id
            isLoading = true
            readerMode = .original
            isSummaryExpanded = false
            isReaderAtTop = true
            isHeaderManuallyExpanded = false
            visibleBilingualParagraphIDs = []
            pendingBilingualParagraphIDs = []
            failedBilingualParagraphIDs = []
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
                return ArticleExtractor.readerParagraphs(in: loadedHTML)
            }.value
            guard !Task.isCancelled, activeLoadEntryID == requestedEntry.id else { return }

            text = loadedText
            html = loadedHTML
            parsedReaderParagraphs = parsedParagraphs
            articleBaseURL = store.articleSourceURL(for: requestedEntry)
            isLoading = false
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
            // A WKWebView already owns a well-tuned AppKit scroll view. Placing it
            // inside another SwiftUI ScrollView drops wheel events while the cursor
            // is over the page, so keep exactly one vertical scrolling surface.
            ZStack(alignment: .top) {
                ArticleHTMLView(
                    articleID: entry.id,
                    html: html,
                    baseURL: articleBaseURL,
                    contentTopInset: readerContentTopInset,
                    readerParagraphs: readerParagraphs,
                    inlineTranslations: bilingualSegments,
                    pendingTranslationIDs: pendingBilingualParagraphIDs,
                    selectionAnnotations: savedSelectionAnnotations,
                    isBilingualMode: readerMode == .bilingual,
                    onVisibleParagraphIDsChange: handleVisibleParagraphIDs,
                    onScrollOffsetChange: updateReaderScrollOffset,
                    onSelectionRequest: performSelectionRequest
                )
                    .frame(maxWidth: 960, maxHeight: .infinity, alignment: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 32)

                adaptiveReaderChrome
            }
        } else {
            ScrollView {
                readerContents
            }
        }
        #else
        if usesNativeHTMLScroller, let html {
            ZStack(alignment: .top) {
                ArticleHTMLView(
                    articleID: entry.id,
                    html: html,
                    baseURL: articleBaseURL,
                    contentTopInset: readerContentTopInset,
                    readerParagraphs: readerParagraphs,
                    inlineTranslations: bilingualSegments,
                    pendingTranslationIDs: pendingBilingualParagraphIDs,
                    selectionAnnotations: savedSelectionAnnotations,
                    isBilingualMode: readerMode == .bilingual,
                    onVisibleParagraphIDsChange: handleVisibleParagraphIDs,
                    onScrollOffsetChange: updateReaderScrollOffset,
                    onSelectionRequest: performSelectionRequest
                )
                .padding(.horizontal, 20)

                adaptiveReaderChrome
            }
        } else {
            ScrollView {
                readerContents
            }
        }
        #endif
    }

    private var readerContents: some View {
        VStack(alignment: .leading, spacing: 18) {
            readerChrome
            content
        }
        .frame(maxWidth: 960, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
    }

    private var readerChrome: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summaryCard

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            PaperTheme.noteBorder(scheme: colorScheme).opacity(0.1),
                            PaperTheme.noteBorder(scheme: colorScheme).opacity(0.75),
                            PaperTheme.noteBorder(scheme: colorScheme).opacity(0.1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReaderHeaderHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private var adaptiveReaderChrome: some View {
        Group {
            if isReaderHeaderExpanded {
                ZStack(alignment: .topTrailing) {
                    readerChrome

                    if !isReaderAtTop {
                        readerDisclosureButton(isExpanded: true, action: collapseReaderHeader)
                    }
                }
                .transition(.opacity)
            } else {
                compactReaderChrome
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, readerHeaderHorizontalPadding)
        .padding(.vertical, isReaderHeaderExpanded ? readerHeaderExpandedPadding : 8)
        .background(PaperHeaderSurface())
        .shadow(
            color: .black.opacity(isReaderHeaderExpanded ? 0 : (colorScheme == .dark ? 0.24 : 0.08)),
            radius: isReaderHeaderExpanded ? 0 : 8,
            y: isReaderHeaderExpanded ? 0 : 3
        )
        .animation(readerHeaderAnimation, value: isReaderHeaderExpanded)
        .accessibilityElement(children: .contain)
    }

    private var compactReaderChrome: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let url = entry.url {
                    Link(destination: url) {
                        Text(entry.title)
                            .font(.system(.headline, design: .serif).weight(.semibold))
                            .tracking(0.15)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("打开原网页")
                } else {
                    Text(entry.title)
                        .font(.system(.headline, design: .serif).weight(.semibold))
                        .tracking(0.15)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let feed = store.feed(for: entry) {
                        Text(feed.title)
                    }
                    if let date = entry.publishedAt {
                        Text(date, format: .dateTime.month().day())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            readerDisclosureButton(isExpanded: false, action: expandReaderHeader)
        }
        .frame(maxWidth: 960)
    }

    private func readerDisclosureButton(isExpanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PaperTheme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(PaperTheme.accent.opacity(0.10), in: Circle())
        .overlay {
            Circle().stroke(PaperTheme.accent.opacity(0.14), lineWidth: 0.5)
        }
        .help(isExpanded ? "收起标题与 AI 摘要" : "展开标题与 AI 摘要")
        .accessibilityLabel(isExpanded ? "收起页头" : "展开页头")
    }

    private var isReaderHeaderExpanded: Bool {
        isReaderAtTop || isHeaderManuallyExpanded
    }

    private var readerHeaderHorizontalPadding: CGFloat {
        #if os(macOS)
        32
        #else
        20
        #endif
    }

    private var readerHeaderExpandedPadding: CGFloat {
        #if os(macOS)
        24
        #else
        16
        #endif
    }

    private var readerHeaderAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private var readerContentTopInset: CGFloat {
        expandedReaderHeaderContentHeight + readerHeaderExpandedPadding * 2 + 16
    }

    private func updateReaderScrollOffset(_ rawOffset: CGFloat) {
        let offset = max(0, rawOffset)
        if offset <= 10 {
            guard !isReaderAtTop || isHeaderManuallyExpanded else { return }
            withAnimation(readerHeaderAnimation) {
                isReaderAtTop = true
                isHeaderManuallyExpanded = false
            }
        } else if offset >= max(128, readerContentTopInset - 72),
                  isReaderAtTop || isHeaderManuallyExpanded {
            withAnimation(readerHeaderAnimation) {
                isReaderAtTop = false
                isHeaderManuallyExpanded = false
            }
        }
    }

    private func expandReaderHeader() {
        withAnimation(readerHeaderAnimation) {
            isHeaderManuallyExpanded = true
        }
    }

    private func collapseReaderHeader() {
        withAnimation(readerHeaderAnimation) {
            isHeaderManuallyExpanded = false
            isReaderAtTop = false
        }
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
                Text(text).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled)
                #endif
            } else {
                Text(text).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled)
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
                                Button("重新生成") { generateSummary() }
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
                HStack(spacing: 8) {
                    Text("尚未生成；仅在你点按后发送正文。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("生成摘要") { generateSummary() }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.semibold))
                        .disabled(text.isEmpty)
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
        .accessibilityElement(children: .contain)
    }

    @ToolbarContentBuilder private var articleToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            ControlGroup {
                Button(action: toggleBilingualTranslation) {
                    toolbarSymbol(
                        readerMode == .bilingual ? "character.bubble.fill" : "character.bubble",
                        isActive: readerMode == .bilingual
                    )
                }
                .disabled(text.isEmpty || store.activeAIRequest != nil)
                .accessibilityLabel(readerMode == .bilingual ? "关闭逐段翻译" : "开启逐段翻译")
                .help(readerMode == .bilingual ? "关闭逐段翻译" : "开启逐段翻译")

                Button {
                    store.markRead(entry, read: !entry.isRead)
                } label: {
                    toolbarSymbol(entry.isRead ? "envelope.open.fill" : "envelope.open", isActive: entry.isRead)
                }
                .accessibilityLabel(entry.isRead ? "标为未读" : "标为已读")
                .help(entry.isRead ? "标为未读" : "标为已读")

                Button {
                    store.toggleStar(entry)
                } label: {
                    toolbarSymbol(entry.isStarred ? "star.fill" : "star", isActive: entry.isStarred)
                }
                .accessibilityLabel(entry.isStarred ? "取消收藏" : "收藏")
                .help(entry.isStarred ? "取消收藏" : "收藏")
            }
            .controlGroupStyle(.navigation)
        }
    }

    private func toolbarSymbol(_ name: String, isActive: Bool) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? AnyShapeStyle(PaperTheme.accent) : AnyShapeStyle(.primary))
            .frame(width: 29, height: 29)
            .background(isActive ? AnyShapeStyle(PaperTheme.accent.opacity(0.18)) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Circle())
    }

    private func toggleBilingualTranslation() {
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            readerMode = readerMode == .bilingual ? .original : .bilingual
        }
        requestVisibleTranslationsIfPossible()
    }

    private func generateSummary() {
        guard !text.isEmpty, store.activeAIRequest == nil else { return }
        withAnimation(readerHeaderAnimation) {
            isSummaryExpanded = true
        }
        Task { await store.generateSummary(entry: entry, text: text) }
    }

    private func generateBilingualTranslation() {
        guard !text.isEmpty else { return }
        readerMode = .bilingual
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
                result = try await store.explainSelection(
                    entry: entry,
                    selection: request.selection,
                    localContext: request.localContext,
                    articleText: text,
                    selectionAnchor: request.anchor,
                    onDelta: onDelta
                )
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
            failedBilingualParagraphIDs.removeAll()
            visibleBilingualParagraphIDs = normalized
        }
        requestVisibleTranslationsIfPossible()
    }

    private func requestVisibleTranslationsIfPossible() {
        guard readerMode == .bilingual,
              !text.isEmpty,
              store.activeAIRequest == nil else { return }

        let translatedIDs = Set(bilingualSegments.map(\.id))
        let batch = Array(
            visibleBilingualParagraphIDs
                .filter {
                    !translatedIDs.contains($0)
                        && !pendingBilingualParagraphIDs.contains($0)
                        && !failedBilingualParagraphIDs.contains($0)
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
            }
            failedBilingualParagraphIDs.formUnion(unsuccessfulIDs)
            requestVisibleTranslationsIfPossible()
        }
    }

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
  margin: 0 2px 42px;
  padding-top: var(--paper-reader-top-inset, 220px);
  box-sizing: border-box;
  color: var(--paper-ink);
  background: transparent;
  font: 17px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
  font-weight: 400;
  line-height: 1.72;
  letter-spacing: .006em;
  overflow-wrap: anywhere;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
}
::selection { background: rgba(116, 137, 100, .24); }
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
  margin: 1.2em 0;
  border: .5px solid var(--paper-rule);
  border-radius: 6px;
}
figure img { margin-bottom: .48em; }
figcaption {
  color: var(--paper-muted);
  font-size: .88em;
  line-height: 1.55;
  letter-spacing: .015em;
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
  gap: 3px;
  padding: 3px;
  border: .5px solid var(--paper-rule);
  border-radius: 19px;
  color: var(--paper-ink);
  background: var(--paper-card);
  box-shadow: 0 7px 22px rgba(35, 31, 25, .18);
  backdrop-filter: blur(18px) saturate(1.15);
  animation: paper-rss-materialize .18s ease-out both;
}
.paper-rss-selection-action {
  display: grid;
  place-items: center;
  width: 31px;
  height: 31px;
  padding: 0;
  border: 0;
  border-radius: 50%;
  color: inherit;
  background: transparent;
  cursor: pointer;
  -webkit-appearance: none;
}
.paper-rss-selection-action .paper-rss-icon,
.paper-rss-explanation-header .paper-rss-icon {
  width: 17px;
  height: 17px;
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
  gap: 3px;
  box-sizing: border-box;
  margin: 0 .22em;
  padding: .12em .45em;
  color: var(--paper-accent);
  font-size: .82em;
  font-weight: 600;
  vertical-align: .08em;
  border: .5px solid color-mix(in srgb, var(--paper-accent) 30%, transparent);
  border-radius: 12px;
  background: var(--paper-wash);
  opacity: .92;
  pointer-events: auto;
  cursor: pointer;
  transition: all .15s ease;
}
.paper-rss-annotation-icon:hover {
  background: color-mix(in srgb, var(--paper-accent) 22%, transparent);
  transform: translateY(-1px);
}
.paper-rss-annotation-icon.is-pending {
  opacity: .60;
  animation: paper-rss-pulse 1.2s ease-in-out infinite;
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
private enum PaperReaderBridge {
    static let scrollMessageName = "paperRssReaderScroll"
    static let visibleParagraphsMessageName = "paperRssVisibleParagraphs"
    static let explainSelectionMessageName = "paperRssExplainSelection"
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

          const removeAction = () => {
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
              ? ["M5 8h7M8.5 5v3c0 3.3-1.3 5.4-4 7M5 11c1.7 1.6 3.7 2.7 6 3.2M14 14h7M17.5 11v3c0 3.3-1.3 5.4-4 7M14 17c1.6 1.2 3.4 2.1 5.5 2.6"]
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
              btn.append(svgIcon("note"));
              const label = document.createElement("span");
              label.className = "paper-rss-annotation-label";
              label.textContent = "AI 解释";
              btn.append(label);
              return btn;
            };

            const last = marks[0];
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

          const showPopover = (id, rect, text, state, kind, anchorElement = null) => {
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
            title.textContent = kind === "translation" ? "翻译" : "AI 解释";
            header.append(title);
            const body = document.createElement("div");
            body.className = "paper-rss-explanation-body";
            body.textContent = text || (kind === "translation" ? "正在翻译…" : "正在结合全文理解这段文字…");
            popover.append(header, body);
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

          const postRequest = (kind, range, selectedText) => {
            const requestID = "selection-" + Date.now() + "-" + Math.random().toString(36).slice(2);
            const rect = focusRectForSelection(window.getSelection(), range);
            const anchor = kind === "explanation" ? selectionAnchorForRange(range) : null;
            const markers = kind === "explanation" ? markRange(range, requestID, selectedText) : [];
            let marker = markers[0]?.querySelector?.(".paper-rss-annotation-icon") || markers[0] || null;
            if (!marker && kind === "translation") {
              // Selection translations have no persistent icon, so give the
              // popover an invisible inline anchor at the selection end. It
              // scrolls with the text and is removed when the popover closes.
              const anchorSpan = document.createElement("span");
              anchorSpan.className = "paper-rss-selection-anchor";
              anchorSpan.setAttribute("aria-hidden", "true");
              const endRange = range.cloneRange();
              endRange.collapse(false);
              endRange.insertNode(anchorSpan);
              marker = anchorSpan;
            }
            showPopover(requestID, marker?.getBoundingClientRect?.() || rect, "", "is-loading", kind, marker);
            removeAction();
            window.getSelection()?.removeAllRanges();
            window.webkit.messageHandlers.paperRssExplainSelection.postMessage({
              id: requestID,
              kind,
              selection: selectedText.slice(0, 4000),
              localContext: kind === "explanation" ? localContextForRange(range).slice(0, 8000) : "",
              anchor
            });
          };

          const presentActionForSelection = () => {
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
                postRequest(kind, activeRange.cloneRange(), activeSelection);
              });
              return button;
            };
            bar.append(makeButton("note", "解释所选文字"), makeButton("translation", "翻译所选文字"));
            actionBar = bar;
            document.body.append(bar);
            positionNear(bar, { left: focusRect.left - 24, top: focusRect.top, width: 48, height: Math.max(1, focusRect.height), bottom: focusRect.bottom });
          };

          const scheduleSelectionAction = () => {
            clearTimeout(selectionTimer);
            selectionTimer = setTimeout(presentActionForSelection, 90);
          };

          document.addEventListener("selectionchange", scheduleSelectionAction);
          document.addEventListener("pointerup", scheduleSelectionAction);
          document.addEventListener("keyup", scheduleSelectionAction);
          document.addEventListener("pointerdown", event => {
            if (!event.target.closest?.(".paper-rss-selection-actions") && !event.target.closest?.(".paper-rss-explanation")) removeAction();
          }, true);
          document.addEventListener("click", event => {
            const icon = event.target.closest?.(".paper-rss-annotation-icon");
            const mark = event.target.closest?.(".paper-rss-explained");
            if (icon || mark) {
              event.preventDefault();
              const target = mark || icon;
              const loading = target.classList.contains("is-pending");
              const rect = (icon || mark)?.getBoundingClientRect();
              showPopover(target.dataset.explanationId, rect, loading ? "" : (target.dataset.explanation || "解释暂不可用。"), loading ? "is-loading" : "", "explanation", icon || mark);
              return;
            }
            if (!event.target.closest?.(".paper-rss-explanation") && !event.target.closest?.(".paper-rss-selection-actions")) dismissPopover();
          });
          // The popover is positioned in document coordinates, so it follows
          // the page on its own while scrolling. Reposition only when layout
          // changes under it (images loading, translations inserted, window
          // resize), keeping the anchor element as the source of truth.
          document.addEventListener("scroll", removeAction, { passive: true, capture: true });
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
}

#if os(macOS)
private struct ArticleHTMLView: NSViewRepresentable {
    let articleID: String
    let html: String
    let baseURL: URL?
    let contentTopInset: CGFloat
    let readerParagraphs: [ReaderParagraph]
    let inlineTranslations: [BilingualSegment]
    let pendingTranslationIDs: Set<String>
    let selectionAnnotations: [ReaderSelectionAnnotation]
    let isBilingualMode: Bool
    let onVisibleParagraphIDsChange: ([String]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void
    let onSelectionRequest: (
        ReaderSelectionRequest,
        @escaping @Sendable (String) async -> Void
    ) async -> ReaderSelectionResponse

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
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
        configuration.userContentController.addUserScript(PaperReaderBridge.observerScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.selectionScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.imageRecoveryScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(isBilingualMode ? "原文与中文逐段翻译" : "原文内容")
        webView.enclosingScrollView?.hasVerticalScroller = true
        webView.enclosingScrollView?.autohidesScrollers = true
        webView.enclosingScrollView?.verticalScrollElasticity = .automatic
        webView.enclosingScrollView?.horizontalScrollElasticity = .none
        context.coordinator.webView = webView
        context.coordinator.loadIfNeeded(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(into: webView)
        for segment in inlineTranslations {
            context.coordinator.updateInlineTranslationInWebView(id: segment.id, translation: segment.translation)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
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
            case PaperReaderBridge.explainSelectionMessageName:
                guard let payload = message.body as? [String: Any],
                      let id = payload["id"] as? String,
                      let selection = payload["selection"] as? String,
                      let localContext = payload["localContext"] as? String,
                      !selection.isEmpty else { return }
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
                    localContext: localContext,
                    kind: ReaderSelectionKind(rawValue: payload["kind"] as? String ?? "explanation") ?? .explanation,
                    anchor: anchor
                )
                pendingSelectionExplanationRequests.append(request)
                startNextSelectionExplanationIfNeeded()
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
            let articleKey = "\(parent.articleID)|\(secureBaseURL?.absoluteString ?? "")"
            guard loadedArticleKey != articleKey else {
                synchronizeContentTopInset(in: webView)
                synchronizeTranslations(in: webView)
                return
            }
            let initialTranslationState = translationState()
            let readerHTML = ArticleExtractor.insertingInlineTranslations(
                into: parent.html,
                segments: parent.inlineTranslations,
                pendingIDs: parent.isBilingualMode ? parent.pendingTranslationIDs : []
            )
            let document = Self.documentHTML(body: readerHTML, topInset: parent.contentTopInset)
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

        private static func documentHTML(body: String, topInset: CGFloat) -> String {
            return """
            <!doctype html>
            <html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https: data: blob:; style-src 'unsafe-inline'; font-src 'none'; media-src http: https: data: blob:; object-src 'none'; frame-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'">
            <style>:root { --paper-reader-top-inset: \(max(0, topInset))px; }\(paperArticleStyle)</style>
            </head><body>\(body)</body></html>
            """
        }
    }
}
#endif

#if os(iOS)
private struct ArticleHTMLView: UIViewRepresentable {
    let articleID: String
    let html: String
    let baseURL: URL?
    let contentTopInset: CGFloat
    let readerParagraphs: [ReaderParagraph]
    let inlineTranslations: [BilingualSegment]
    let pendingTranslationIDs: Set<String>
    let selectionAnnotations: [ReaderSelectionAnnotation]
    let isBilingualMode: Bool
    let onVisibleParagraphIDsChange: ([String]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void
    let onSelectionRequest: (
        ReaderSelectionRequest,
        @escaping @Sendable (String) async -> Void
    ) async -> ReaderSelectionResponse

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
        configuration.userContentController.addUserScript(PaperReaderBridge.observerScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.selectionScript)
        configuration.userContentController.addUserScript(PaperReaderBridge.imageRecoveryScript)

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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case PaperReaderBridge.scrollMessageName:
                guard let offset = message.body as? Double else { return }
                parent.onScrollOffsetChange(CGFloat(max(0, offset)))
            case PaperReaderBridge.visibleParagraphsMessageName:
                guard let paragraphIDs = message.body as? [String] else { return }
                parent.onVisibleParagraphIDsChange(paragraphIDs)
            case PaperReaderBridge.explainSelectionMessageName:
                guard let payload = message.body as? [String: Any],
                      let id = payload["id"] as? String,
                      let selection = payload["selection"] as? String,
                      let localContext = payload["localContext"] as? String,
                      !selection.isEmpty else { return }
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
                    localContext: localContext,
                    kind: ReaderSelectionKind(rawValue: payload["kind"] as? String ?? "explanation") ?? .explanation,
                    anchor: anchor
                )
                pendingSelectionExplanationRequests.append(request)
                startNextSelectionExplanationIfNeeded()
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
            let articleKey = "\(parent.articleID)|\(secureBaseURL?.absoluteString ?? "")"
            guard loadedArticleKey != articleKey else {
                synchronizeContentTopInset(in: webView)
                synchronizeTranslations(in: webView)
                return
            }
            let initialTranslationState = translationState()
            let readerHTML = ArticleExtractor.insertingInlineTranslations(
                into: parent.html,
                segments: parent.inlineTranslations,
                pendingIDs: parent.isBilingualMode ? parent.pendingTranslationIDs : []
            )
            let document = Self.documentHTML(body: readerHTML, topInset: parent.contentTopInset)
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

        private static func documentHTML(body: String, topInset: CGFloat) -> String {
            return """
            <!doctype html>
            <html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https: data: blob:; style-src 'unsafe-inline'; font-src 'none'; media-src http: https: data: blob:; object-src 'none'; frame-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'">
            <style>:root { --paper-reader-top-inset: \(max(0, topInset))px; }\(paperArticleStyle)</style>
            </head><body>\(body)</body></html>
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
