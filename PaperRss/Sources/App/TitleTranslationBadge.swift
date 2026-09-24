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
