import Foundation

public enum FeedbackChannel: Sendable {
    case issue
    case email
}

public enum FeedbackModule: String, CaseIterable, Sendable {
    case general
    case refresh
    case reader
    case ai
    case settings
    case update

    public func localizedName(for language: AppLanguage) -> String {
        switch (self, language.resolvedLocalization()) {
        case (.general, .en): "General"
        case (.refresh, .en): "Refresh"
        case (.reader, .en): "Reader"
        case (.ai, .en): "AI"
        case (.settings, .en): "Settings"
        case (.update, .en): "Update"
        case (.general, _): "通用"
        case (.refresh, _): "刷新"
        case (.reader, _): "阅读器"
        case (.ai, _): "AI"
        case (.settings, _): "设置"
        case (.update, _): "更新"
        }
    }
}

public struct FeedbackErrorSnapshot: Equatable, Sendable {
    public let module: FeedbackModule
    public let message: String
    public let occurredAt: Date

    public init(module: FeedbackModule, message: String, occurredAt: Date = .now) {
        self.module = module
        self.message = FeedbackRedactor.redact(message)
        self.occurredAt = occurredAt
    }
}

public struct FeedbackDiagnosticSnapshot: Equatable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let osBuild: String?
    public let deviceModel: String?
    public let architecture: String
    public let processorCount: Int
    public let appLanguage: String
    public let systemRegion: String
    public let displayResolution: String?
    public let displayScale: Double?
    public let recentError: FeedbackErrorSnapshot?

    public init(
        appVersion: String,
        appBuild: String,
        osVersion: String,
        osBuild: String? = nil,
        deviceModel: String? = nil,
        architecture: String,
        processorCount: Int,
        appLanguage: String,
        systemRegion: String,
        displayResolution: String? = nil,
        displayScale: Double? = nil,
        recentError: FeedbackErrorSnapshot? = nil
    ) {
        self.appVersion = FeedbackRedactor.redact(appVersion)
        self.appBuild = FeedbackRedactor.redact(appBuild)
        self.osVersion = FeedbackRedactor.redact(osVersion)
        self.osBuild = osBuild.map(FeedbackRedactor.redact)
        self.deviceModel = deviceModel.map(FeedbackRedactor.redact)
        self.architecture = FeedbackRedactor.redact(architecture)
        self.processorCount = max(0, processorCount)
        self.appLanguage = FeedbackRedactor.redact(appLanguage)
        self.systemRegion = FeedbackRedactor.redact(systemRegion)
        self.displayResolution = displayResolution.map(FeedbackRedactor.redact)
        self.displayScale = displayScale
        self.recentError = recentError
    }

    public func renderedDiagnosticText(language: AppLanguage) -> String {
        let isEnglish = language.resolvedLocalization() == .en
        var lines: [String] = []

        if isEnglish {
            lines.append("App version: PaperRss v\(appVersion) (\(appBuild))")
            lines.append("Operating system: macOS \(osVersion)\(osBuild.map { " (\($0))" } ?? "")")
            if let deviceModel {
                lines.append("Device model: \(deviceModel)")
            }
            lines.append("Processor: \(architecture), \(processorCount) cores")
            lines.append("App language: \(appLanguage)")
            lines.append("System region: \(systemRegion)")
            if let displayResolution {
                let scale = displayScale.map { " (@\(Self.scaleText($0))x)" } ?? ""
                lines.append("Main display: \(displayResolution)\(scale)")
            }
            if let recentError {
                lines.append("Recent error time: \(Self.timestampText(recentError.occurredAt))")
                lines.append("Recent error: [\(recentError.module.localizedName(for: language))] \(recentError.message)")
            }
        } else {
            lines.append("应用版本: PaperRss v\(appVersion) (\(appBuild))")
            lines.append("操作系统: macOS \(osVersion)\(osBuild.map { " (\($0))" } ?? "")")
            if let deviceModel {
                lines.append("设备型号: \(deviceModel)")
            }
            lines.append("处理器: \(architecture), \(processorCount) 核")
            lines.append("应用语言: \(appLanguage)")
            lines.append("系统区域: \(systemRegion)")
            if let displayResolution {
                let scale = displayScale.map { " (@\(Self.scaleText($0))x)" } ?? ""
                lines.append("主显示器: \(displayResolution)\(scale)")
            }
            if let recentError {
                lines.append("最近错误时间: \(Self.timestampText(recentError.occurredAt))")
                lines.append("最近错误: [\(recentError.module.localizedName(for: language))] \(recentError.message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func scaleText(_ scale: Double) -> String {
        if scale.rounded() == scale {
            return String(Int(scale))
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), scale)
    }

    private static func timestampText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public enum FeedbackRedactor {
    private static let patterns: [(pattern: String, replacement: String)] = [
        (#"(?i)authorization\s*:\s*(?:bearer\s+)?[^\s,;]+"#, "Authorization: <redacted>"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "<redacted>"),
        (#"(?i)\b(?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|token|secret|password|passwd)\b\s*[:=]\s*[^\s,;]+"#, "<redacted>"),
        (#"(?i)\bhttps?://[^\s<>\]})\"']+"#, "<url>"),
        (#"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#, "<email>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
        (#"(?<![\w])/(?:Users|private|var|tmp|Applications|Volumes|home)/[^\s,;]+"#, "<path>"),
        (#"(?i)\b(?:user|username|account)\s*[:=]\s*[^\s,;]+"#, "<user>"),
    ]

    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { partial, item in
            partial.replacingOccurrences(
                of: item.pattern,
                with: item.replacement,
                options: .regularExpression
            )
        }
    }
}

public struct FeedbackDraft: Equatable, Sendable {
    public let subject: String
    public let body: String

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}

public enum FeedbackComposer {
    public static let emailAddress = "ohmyangboy@gmail.com"
    public static let issueURL = URL(string: "https://github.com/ohmyangboy/PaperRss/issues/new")!

    public static func draft(
        for channel: FeedbackChannel,
        snapshot: FeedbackDiagnosticSnapshot,
        language: AppLanguage
    ) -> FeedbackDraft {
        let isEnglish = language.resolvedLocalization() == .en
        let subject: String
        if isEnglish {
            subject = channel == .issue
                ? "[Feedback] PaperRss v\(snapshot.appVersion)"
                : "[PaperRss v\(snapshot.appVersion)] Feedback"
        } else {
            subject = channel == .issue
                ? "[反馈] PaperRss v\(snapshot.appVersion)"
                : "[PaperRss v\(snapshot.appVersion)] 反馈"
        }

        let body: String
        if isEnglish {
            body = """
            ### Problem / Suggestion


            ### Steps to reproduce
            1.
            2.

            ### Expected and actual result


            ---
            ### Environment Diagnostics
            ```text
            \(snapshot.renderedDiagnosticText(language: language))
            ```
            """
        } else {
            body = """
            ### 问题描述 / 建议


            ### 复现步骤
            1.
            2.

            ### 预期效果与实际结果


            ---
            ### 设备与环境诊断信息
            ```text
            \(snapshot.renderedDiagnosticText(language: language))
            ```
            """
        }

        return FeedbackDraft(subject: subject, body: body)
    }

    public static func url(
        for channel: FeedbackChannel,
        snapshot: FeedbackDiagnosticSnapshot,
        language: AppLanguage
    ) -> URL? {
        let draft = draft(for: channel, snapshot: snapshot, language: language)
        var components: URLComponents

        switch channel {
        case .issue:
            components = URLComponents(url: issueURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        case .email:
            components = URLComponents()
            components.scheme = "mailto"
            components.path = emailAddress
        }

        components.queryItems = [
            URLQueryItem(name: channel == .issue ? "title" : "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body),
        ]
        return components.url
    }
}
