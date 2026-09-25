import Combine
import Foundation
import NaturalLanguage

/// 一条待翻译的列表条目：标题必填，摘要（描述）可选。
/// 标题与摘要会作为独立的翻译单元参与批处理，但共享同一个按需调度。
public struct TitleTranslationCandidate: Hashable, Sendable {
    public let entryID: String
    public let feedID: UUID
    public let title: String
    public let summary: String?

    public init(entryID: String, feedID: UUID, title: String, summary: String? = nil) {
        self.entryID = entryID
        self.feedID = feedID
        self.title = title
        self.summary = summary
    }
}

/// 单条列表项已获得的译文。字段可分别到达（标题与摘要各自成批），
/// 因此用可选字段表达部分完成。
public struct TranslatedEntryText: Equatable, Sendable {
    public var title: String?
    public var summary: String?

    public init(title: String? = nil, summary: String? = nil) {
        self.title = title
        self.summary = summary
    }
}

/// 一次批量请求的结果：`translations` 按原文返回译文，
/// `failedTexts` 用于失败退避，避免滚动时反复为坏文本付费。
public struct TitleTranslationBatchResult: Sendable {
    public let translations: [String: String]
    public let failedTexts: Set<String>

    public init(translations: [String: String] = [:], failedTexts: Set<String> = []) {
        self.translations = translations
        self.failedTexts = failedTexts
    }

    public static let empty = TitleTranslationBatchResult()
}

/// 当前可用的标题/摘要翻译会话。`sessionID` 由模型、目标语言与提示版本构成；
/// 变化时内存译文与失败计数一并作废，避免展示旧模型的译文。
public struct TitleTranslationContext: Sendable {
    public let sessionID: String
    public let targetLanguage: String
    public let feedLists: [UUID: TranslationFeedList]

    public init(sessionID: String, targetLanguage: String, feedLists: [UUID: TranslationFeedList]) {
        self.sessionID = sessionID
        self.targetLanguage = targetLanguage
        self.feedLists = feedLists
    }
}

/// 列表标题与摘要的按需翻译调度器。
///
/// 视图只上报“当前展示范围”，调度器负责：滚动停止后去抖、跳过缓存命中与
/// 黑白名单、把未翻译文本合并成批量请求、单条失败退避，以及把结果按 entryID
/// 发布给列表行。并发固定为一批，快速滚动不会形成请求风暴。
@MainActor
public final class FeedTitleTranslationCoordinator: ObservableObject {
    public typealias ConfigurationProvider = @MainActor @Sendable () -> TitleTranslationContext?
    public typealias TranslateOperation = @MainActor @Sendable (
        [String],
        TitleTranslationContext
    ) async -> TitleTranslationBatchResult
    /// (文本, 目标语言) -> 是否需要翻译。返回 false 表示文本已是目标语言。
    public typealias LanguageProbe = @Sendable (String, String) -> Bool

    @Published public private(set) var translations: [String: TranslatedEntryText] = [:]

    private enum TranslatedField: Sendable {
        case title
        case summary
    }

    private struct PendingItem: Sendable {
        let entryID: String
        let field: TranslatedField
    }

    private let configurationProvider: ConfigurationProvider
    private let translate: TranslateOperation
    private let languageProbe: LanguageProbe

    private var visibleCandidates: [TitleTranslationCandidate] = []
    /// 失败计数按翻译单元（文本指纹）而不是条目计数：标题成功、摘要失败时
    /// 只退避失败的那一项。
    private var failedAttempts: [String: Int] = [:]
    private var translationOrder: [String] = []
    private var activeSessionID: String?
    private var debounceTask: Task<Void, Never>?
    /// 执行任务独立于去抖任务：视图布局更新会不断取消去抖任务，
    /// 但已发出的翻译请求不能被取消，否则结果被丢弃、行会缺少译文。
    private var processingTask: Task<Void, Never>?
    private var isProcessing = false
    private var needsAnotherPass = false
    /// 首屏（切换范围后的第一次上报）立即翻译，不必等去抖；
    /// 之后滚动中的更新仍走去抖，避免逐帧探测与请求。
    private var hasPerformedInitialPass = false

    /// 滚动停止后多久开始请求，避免滚动过程中的中间可见集合被翻译。
    public var debounceInterval: Duration = .milliseconds(150)
    /// 单轮调度最多覆盖的翻译单元数（标题、摘要各算一个），
    /// 防止大屏/长按翻页一次性释放过多请求。
    public let maximumTextsPerPass: Int
    /// 同一文本连续失败多少次后不再重试（到功能、模型或订阅范围变化为止）。
    public let maximumFailuresPerText: Int
    /// 内存译文的保留上限（FIFO）。
    public let maximumCachedTranslations: Int

    public init(
        configurationProvider: @escaping ConfigurationProvider,
        translate: @escaping TranslateOperation,
        languageProbe: @escaping LanguageProbe = { text, targetLanguage in
            TitleTranslationLanguageProbe.needsTranslation(title: text, targetLanguage: targetLanguage)
        },
        maximumTextsPerPass: Int = 60,
        maximumFailuresPerText: Int = 2,
        maximumCachedTranslations: Int = 2_000
    ) {
        self.configurationProvider = configurationProvider
        self.translate = translate
        self.languageProbe = languageProbe
        self.maximumTextsPerPass = max(1, maximumTextsPerPass)
        self.maximumFailuresPerText = max(1, maximumFailuresPerText)
        self.maximumCachedTranslations = max(1, maximumCachedTranslations)
    }

    /// 视图上报当前展示范围（列表可见行 / 卡片可见瓦片 / 杂志当前页）。
    /// 可以在滚动帧里高频调用；首屏立即翻译，之后的更新等滚动停止后触发。
    public func updateScope(_ candidates: [TitleTranslationCandidate]) {
        var seen = Set<String>()
        let uniqueCandidates = candidates.filter { seen.insert($0.entryID).inserted }
        guard uniqueCandidates != visibleCandidates else { return }
        visibleCandidates = uniqueCandidates
        let shouldRunImmediately = !hasPerformedInitialPass && !isProcessing
        scheduleWork(afterDebounce: !shouldRunImmediately)
    }

    /// 设置变化（开关、模型、目标语言、黑白名单、刷新）后立即重新判定。
    public func refresh() {
        scheduleWork(afterDebounce: false)
    }

    /// 切走整个列表范围时调用：丢弃展示范围与失败计数，保留已翻译缓存。
    public func resetScope() {
        debounceTask?.cancel()
        debounceTask = nil
        visibleCandidates = []
        hasPerformedInitialPass = false
    }

    private func scheduleWork(afterDebounce: Bool) {
        debounceTask?.cancel()
        let delay = debounceInterval
        debounceTask = Task { @MainActor [weak self] in
            if afterDebounce {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.startProcessing()
        }
    }

    private func startProcessing() {
        guard !isProcessing else {
            needsAnotherPass = true
            return
        }
        hasPerformedInitialPass = true
        isProcessing = true
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processPending()
            self.isProcessing = false
            self.processingTask = nil
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.startProcessing()
            }
        }
    }

    private func processPending() async {
        guard let context = configurationProvider() else {
            // 功能关闭或模型未就绪：停止工作并清空展示，恢复原文。
            if activeSessionID != nil {
                activeSessionID = nil
                translations.removeAll()
                translationOrder.removeAll()
                failedAttempts.removeAll()
            }
            return
        }
        if activeSessionID != context.sessionID {
            activeSessionID = context.sessionID
            translations.removeAll()
            translationOrder.removeAll()
            failedAttempts.removeAll()
        }

        // NaturalLanguage may take tens of milliseconds for a visible page.
        // Snapshot coordinator state, then do language detection off MainActor.
        let candidates = visibleCandidates
        let translated = translations
        let failures = failedAttempts
        let probe = languageProbe
        let limit = maximumTextsPerPass
        let failureLimit = maximumFailuresPerText
        let pending = await Task.detached(priority: .userInitiated) {
            Self.pendingItems(
                candidates: candidates, translated: translated, failures: failures,
                context: context, limit: limit, failureLimit: failureLimit, languageProbe: probe
            )
        }.value
        guard configurationProvider()?.sessionID == context.sessionID else { return }
        if visibleCandidates != candidates {
            needsAnotherPass = true
            return
        }
        guard !pending.isEmpty else { return }

        // 批次切分（数量与字符上限）在翻译端口内部完成；这里一次提交本轮
        // 全部待翻译文本，端口按批串行发送。
        let result = await translate(Array(pending.keys), context)
        // 结果即使在新范围到来后也要发布：译文会写入翻译记忆，滚动回去时
        // 直接命中缓存；丢弃结果会造成"部分行永远没有译文"。
        for (text, translation) in result.translations {
            guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            for item in pending[text] ?? [] {
                var value = translations[item.entryID] ?? TranslatedEntryText()
                switch item.field {
                case .title: value.title = translation
                case .summary: value.summary = translation
                }
                store(value, for: item.entryID)
                failedAttempts.removeValue(forKey: text.stableDigest)
            }
        }
        for text in result.failedTexts {
            failedAttempts[text.stableDigest, default: 0] += 1
        }
    }

    /// 每轮只判定一次黑白名单与语言，并按文本去重；失败重试留给后续触发。
    private nonisolated static func pendingItems(
        candidates: [TitleTranslationCandidate],
        translated: [String: TranslatedEntryText],
        failures: [String: Int],
        context: TitleTranslationContext,
        limit: Int,
        failureLimit: Int,
        languageProbe: LanguageProbe
    ) -> [String: [PendingItem]] {
        var pending: [String: [PendingItem]] = [:]
        var seenEntries = Set<String>()
        var textCount = 0
        for candidate in candidates {
            guard textCount < limit else { break }
            guard seenEntries.insert(candidate.entryID).inserted else { continue }
            let existing = translated[candidate.entryID]
            let units: [(TranslatedField, String)] = [
                (.title, candidate.title),
                (.summary, candidate.summary ?? "")
            ]
            for (field, text) in units {
                guard textCount < limit else { break }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                switch field {
                case .title where existing?.title != nil: continue
                case .summary where existing?.summary != nil: continue
                default: break
                }
                let digest = text.stableDigest
                guard (failures[digest] ?? 0) < failureLimit else { continue }
                switch context.feedLists[candidate.feedID] {
                case .blacklist: continue
                case .whitelist: break
                case nil:
                    guard languageProbe(text, context.targetLanguage) else { continue }
                }
                if pending[text] == nil {
                    textCount += 1
                }
                pending[text, default: []].append(PendingItem(entryID: candidate.entryID, field: field))
            }
        }
        return pending
    }

    private func store(_ value: TranslatedEntryText, for entryID: String) {
        if translations.updateValue(value, forKey: entryID) == nil {
            translationOrder.append(entryID)
        }
        while translationOrder.count > maximumCachedTranslations {
            let oldest = translationOrder.removeFirst()
            translations.removeValue(forKey: oldest)
        }
    }
}

/// 文本语言探测：本地 NaturalLanguage 识别，不产生网络请求。
/// 短文本置信度不足时保守地返回“需要翻译”，避免漏翻外语标题/摘要；
/// 白名单订阅由调度器直接放行，不经过这里。
public enum TitleTranslationLanguageProbe {
    public static let minimumConfidence = 0.6

    public static func needsTranslation(title: String, targetLanguage: String) -> Bool {
        guard let target = AIAutomationPolicy.baseLanguage(targetLanguage) else { return true }
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        guard let best = hypotheses.max(by: { $0.value < $1.value }),
              best.value >= minimumConfidence,
              let detected = AIAutomationPolicy.baseLanguage(best.key.rawValue) else {
            return true
        }
        return detected != target
    }
}
