import Foundation
import NaturalLanguage

/// 声明只是辅助证据；scope 绑定到当前正文来源，不用于推断地域。
public struct ArticleLanguageHint: Codable, Hashable, Sendable {
    public var language: String
    public var scope: String
    public init(language: String, scope: String) {
        self.language = language
        self.scope = scope
    }

    public static func htmlDeclarations(in html: String) -> [Self] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<(html|article|main|p|div|section|span)\b[^>]*?\slang\s*=\s*["']([^"']+)["']"#) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let lang = Range(match.range(at: 2), in: html), let tag = Range(match.range(at: 1), in: html) else { return nil }
            return Self(language: String(html[lang]), scope: "html:\(html[tag].lowercased())")
        }
    }
}

public struct ArticleLanguageAnalysis: Equatable, Sendable {
    public enum Status: String, Sendable { case single, mixed, unknown }
    public var contentHash: String
    public var detectorVersion: Int
    public var status: Status
    public var dominantLanguage: String?
    public var candidateScores: [[String: Double]]
    public var evidence: [ArticleLanguageHint]
    public var sampledLetterCount: Int = 0
}

public protocol ArticleLanguageRecognizing: Sendable {
    func candidates(for text: String) -> [String: Double]
}

public struct SystemArticleLanguageRecognizer: ArticleLanguageRecognizing {
    public init() {}
    public func candidates(for text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 3).map { ($0.key.rawValue, $0.value) })
    }
}

/// 独立 actor 避免正文检测阻塞主线程，也避免识别器跨文章累积输入。
public actor LanguageDetectionService {
    public static let version = 2
    public static let minimumLetters = 80
    public static let maximumSampleCharacters = 2_000
    public static let minimumScore = 0.85
    public static let minimumMargin = 0.20
    public static let minimumDominance = 0.80
    public static let minimumCoverage = 0.60
    private let recognizer: any ArticleLanguageRecognizing
    private let capacity: Int
    private var cache: [String: ArticleLanguageAnalysis] = [:]
    private var order: [String] = []

    public init(recognizer: any ArticleLanguageRecognizing = SystemArticleLanguageRecognizer(), capacity: Int = 128) {
        self.recognizer = recognizer
        self.capacity = max(1, capacity)
    }

    public func analyze(_ article: PreparedArticle) -> ArticleLanguageAnalysis {
        let samples = Self.samples(html: article.html, fallback: article.text)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let hints = (try? encoder.encode(article.languageHints)) ?? Data()
        let key = (samples.joined(separator: "\u{0}") + String(decoding: hints, as: UTF8.self) + "|\(Self.version)").stableDigest
        if var hit = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            hit.contentHash = article.text.stableDigest
            return hit
        }
        var result = ArticleLanguageAnalysis(contentHash: article.text.stableDigest, detectorVersion: Self.version,
                                             status: .unknown, candidateScores: [], evidence: article.languageHints)
        let total = samples.reduce(0) { $0 + Self.letterCount($1) }
        result.sampledLetterCount = total
        if total >= Self.minimumLetters {
            var weights: [String: Int] = [:]
            for sample in samples {
                let scores = recognizer.candidates(for: sample)
                result.candidateScores.append(scores)
                let sorted = scores.sorted { $0.value > $1.value }
                guard let best = sorted.first, best.value >= Self.minimumScore,
                      best.value - (sorted.dropFirst().first?.value ?? 0) >= Self.minimumMargin,
                      let language = AIAutomationPolicy.baseLanguage(best.key) else { continue }
                weights[language, default: 0] += Self.letterCount(sample)
            }
            let trusted = weights.values.reduce(0, +)
            if let best = weights.max(by: { $0.value < $1.value }),
               Double(trusted) / Double(total) >= Self.minimumCoverage,
               Double(best.value) / Double(max(1, trusted)) >= Self.minimumDominance {
                result.status = .single
                result.dominantLanguage = best.key
            } else if weights.count > 1 {
                result.status = .mixed
            }
        }
        cache[key] = result
        order.append(key)
        while order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    static func samples(html: String, fallback: String) -> [String] {
        var clean = html.isEmpty ? fallback : html
        for pattern in [
            #"(?is)<(pre|code|math|script|style|nav|footer|button)\b[^>]*>.*?</\1\s*>"#,
            #"(?s)\$\$.*?\$\$|\\\[.*?\\\]|\\\(.*?\\\)|(?<!\$)\$[^$\n]+\$(?!\$)"#,
            #"https?://[^\s<>]+"#
        ] {
            clean = clean.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        clean = clean.replacingOccurrences(of: #"(?i)</(?:p|div|li|blockquote|h[1-6]|section)>|<br\s*/?>"#, with: "\n", options: .regularExpression)
        // 保持自然段边界，以正文文字位置取窗口；不让日期、文件标签占掉整个样本。
        let blocks = clean.components(separatedBy: "\n").map { $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { letterCount($0) > 0 }
        guard !blocks.isEmpty else { return [] }
        let prose = blocks.filter { letterCount($0) >= 40 }
        let selected = prose.reduce(0, { $0 + letterCount($1) }) >= minimumLetters ? prose : blocks
        let characters = selected.map(Array.init)
        let total = characters.reduce(0) { $0 + $1.count }
        let windows: [Range<Int>]
        if total <= maximumSampleCharacters * 3 {
            windows = [0..<total]
        } else {
            windows = [0..<maximumSampleCharacters,
                       (total - maximumSampleCharacters) / 2..<(total + maximumSampleCharacters) / 2,
                       (total - maximumSampleCharacters)..<total]
        }
        var samples: [String] = []
        for window in windows {
            var offset = 0
            for block in characters {
                let lower = max(window.lowerBound, offset) - offset
                let upper = min(window.upperBound, offset + block.count) - offset
                if upper > lower {
                    var start = lower
                    while start < upper {
                        let end = min(start + maximumSampleCharacters, upper)
                        samples.append(String(block[start..<end]))
                        start = end
                    }
                }
                offset += block.count
            }
        }
        return samples
    }
}
