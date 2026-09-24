import SwiftUI
#if canImport(PaperRssCore)
import PaperRssCore
#endif

/// 当前列表范围内可用的译文（entryID → 标题/摘要译文）。列表、卡片与杂志
/// 统一从环境读取，译文到达时由 SwiftUI 自动刷新受影响的行。
private struct EntryTranslationsKey: EnvironmentKey {
    static let defaultValue: [String: TranslatedEntryText] = [:]
}

extension EnvironmentValues {
    var entryTranslations: [String: TranslatedEntryText] {
        get { self[EntryTranslationsKey.self] }
        set { self[EntryTranslationsKey.self] = newValue }
    }
}

/// 原文向左退页，译文作为一张页面从右侧进入并完成替换。两页在裁切区内首尾相接，
/// 只保留很轻的淡入淡出用于柔化切换；叠放测量仍保留原文与译文中的最大高度。
struct TranslatedTextPage<Original: View, Translation: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showsTranslation: Bool
    @ViewBuilder let original: Original
    @ViewBuilder let translation: Translation

    var body: some View {
        PageLayout(
            translationProgress: showsTranslation ? 1 : 0
        ) {
            original
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(showsTranslation ? 0.9 : 1)
                .accessibilityHidden(showsTranslation)
            translation
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(showsTranslation ? 1 : 0.65)
                .accessibilityHidden(!showsTranslation)
        }
        .clipped()
        .animation(
            reduceMotion ? nil : .timingCurve(0.22, 1, 0.32, 1, duration: 0.24),
            value: showsTranslation
        )
    }

    private struct PageLayout: Layout, Animatable {
        var translationProgress: CGFloat

        var animatableData: CGFloat {
            get { translationProgress }
            set { translationProgress = newValue }
        }

        func sizeThatFits(
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) -> CGSize {
            let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            let childProposal = ProposedViewSize(width: width, height: proposal.height)
            let originalSize = subviews[0].sizeThatFits(childProposal)
            let translationSize = subviews[1].sizeThatFits(childProposal)
            return CGSize(
                width: width ?? max(originalSize.width, translationSize.width),
                height: max(originalSize.height, translationSize.height)
            )
        }

        func placeSubviews(
            in bounds: CGRect,
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) {
            let progress = min(max(translationProgress, 0), 1)
            let childProposal = ProposedViewSize(bounds.size)
            subviews[0].place(
                at: CGPoint(x: bounds.minX - bounds.width * progress, y: bounds.minY),
                anchor: .topLeading,
                proposal: childProposal
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + bounds.width * (1 - progress), y: bounds.minY),
                anchor: .topLeading,
                proposal: childProposal
            )
        }
    }
}

extension View {
    /// 标题翻译只在最左侧窄热区触发，方向与从右向左的替换动画一致。
    func translationRevealHotArea(
        isEnabled: Bool,
        isRevealingOriginal: Binding<Bool>
    ) -> some View {
        modifier(
            TranslationRevealHotAreaModifier(
                isEnabled: isEnabled,
                isRevealingOriginal: isRevealingOriginal
            )
        )
    }
}

private struct TranslationRevealHotAreaModifier: ViewModifier {
    private static let hotAreaWidth: CGFloat = 72

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("title_translation_reveal_hint_shown_v1") private var hasShownHint = false
    @Binding private var isRevealingOriginal: Bool
    @State private var hoverTask: Task<Void, Never>?
    @State private var hintDismissTask: Task<Void, Never>?
    @State private var showsHint = false
    let isEnabled: Bool

    init(isEnabled: Bool, isRevealingOriginal: Binding<Bool>) {
        self.isEnabled = isEnabled
        self._isRevealingOriginal = isRevealingOriginal
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if isEnabled {
                    Color.clear
                        .frame(width: Self.hotAreaWidth)
                        .contentShape(Rectangle())
                        .onHover(perform: handleHover)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .leading) {
                if showsHint {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
                        }
                        .frame(width: Self.hotAreaWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsHint {
                    Label {
                        Text(I18N.shared.localized(
                            "移到标题左侧查看原文",
                            "Move left on a title to view the original"
                        ))
                    } icon: {
                        Image(systemName: "arrow.left")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 80)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled else { return }
                hoverTask?.cancel()
                isRevealingOriginal = false
            }
            .onDisappear {
                hoverTask?.cancel()
                hintDismissTask?.cancel()
                showsHint = false
            }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        guard hovering else {
            isRevealingOriginal = false
            return
        }
        guard isEnabled else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, isEnabled else { return }
            isRevealingOriginal = true
            presentHintIfNeeded()
        }
    }

    private func presentHintIfNeeded() {
        guard !hasShownHint else { return }
        hasShownHint = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showsHint = true
        }
        hintDismissTask?.cancel()
        hintDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                showsHint = false
            }
        }
    }
}

/// 行内翻译标识：`bubble.left` + A/文 的语义由 `character.bubble` 承载，
/// 以 `Text` 行内图片参与排版——首行带图标，换行后的文字回到行首，
/// 不把整段文本挤出一列；显示原文时完全不出现（无图标、无占位）。
enum TitleTranslationBadge {
    static func inline(fontSize: CGFloat) -> Text {
        Text(Image(systemName: "character.bubble"))
            .font(.system(size: fontSize))
            .foregroundStyle(.secondary)
    }
}
