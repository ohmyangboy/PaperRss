// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperRss",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaperRssCore", targets: ["PaperRssCore"]),
        .library(name: "PaperRssUpdateSupport", targets: ["PaperRssUpdateSupport"]),
        .executable(name: "PaperRssDesktop", targets: ["PaperRssDesktop"]),
        .executable(name: "paperrss-agent", targets: ["PaperRssAgentHelper"])
    ],
    dependencies: [
        .package(path: "Packages/PaperRssAITransfer"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6")
    ],
    targets: [
        .target(name: "PaperRssAgentProtocol", path: "PaperRss/Sources/Core/AgentProtocol"),
        .target(name: "PaperRssAgentMCP", dependencies: ["PaperRssAgentProtocol"], path: "PaperRss/Sources/AgentMCP"),
        .executableTarget(name: "PaperRssAgentHelper", dependencies: ["PaperRssAgentProtocol", "PaperRssAgentMCP"], path: "PaperRss/Sources/AgentHelper"),
        .testTarget(name: "PaperRssAgentMCPTests", dependencies: ["PaperRssAgentProtocol", "PaperRssAgentMCP"], path: "Tests/AgentMCPTests"),
        .target(
            name: "PaperRssCore",
            dependencies: [
                "PaperRssAgentProtocol",
                .product(name: "PaperRssAITransfer", package: "PaperRssAITransfer"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "PaperRss/Sources/Core",
            exclude: ["AgentProtocol"],
            resources: [.process("../../Resources/Localization/Localizable.xcstrings")]
        ),
        .target(
            name: "PaperRssUpdateSupport",
            path: "PaperRss/Sources/AppUpdateSupport"
        ),
        .executableTarget(
            name: "PaperRssDesktop",
            dependencies: [
                "PaperRssCore",
                "PaperRssUpdateSupport",
                "PaperRssAgentProtocol",
                .product(name: "PaperRssAITransfer", package: "PaperRssAITransfer"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "PaperRss/Sources/App",
            exclude: ["../../Resources/iOS-Info.plist", "../../Resources/macOS-Info.plist", "../../Resources/PaperRss.entitlements.template"],
            resources: [
                .process("../../Resources/Assets.xcassets"),
                .process("../../Resources/Localization/Localizable.xcstrings"),
                .copy("../../Resources/MathJax"),
                .copy("../../Resources/Highlight"),
                .process("../../Resources/Audio")
            ]
        ),
        .testTarget(
            name: "PaperRssCoreTests",
            dependencies: [
                "PaperRssCore",
                "PaperRssAgentProtocol",
                .product(name: "PaperRssAITransfer", package: "PaperRssAITransfer"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests",
            exclude: [
                "AgentMCPTests",
                "fixtures",
                "CodeHighlightWebKitProbe.swift",
                "MathJaxWebKitProbe.swift",
                "ReaderMediaLoadingWebKitProbe.swift",
                "ReaderImageInversionWebKitProbe.swift",
                "build-support.test.mjs",
                "reader-media-loading.test.mjs",
                "reader-image-inversion.test.mjs",
                "sidebar-unread-filter.test.mjs",
                "mathjax-runtime.test.mjs",
                "code-highlighting.test.mjs",
                "reader-shortcuts.test.mjs",
                "reader-auto-translation.test.mjs",
                "reader-emoji-image.test.mjs",
                "reader-toc.test.mjs",
                "repository-policy.test.mjs",
                "pr-policy.test.mjs",
                "selection-assistant-sync.test.mjs",
                "sparkle-local-real-upgrade.test.mjs",
                "sparkle-publish-dry-run.test.mjs",
                "sparkle-release-gates.test.mjs",
                "sparkle-release.test.mjs",
                "sparkle-upgrade-recovery.test.mjs",
                "summary-card.test.mjs",
                "website-github-stars.test.mjs",
                "website-locale.test.mjs"
            ]
        ),
        .testTarget(
            name: "PaperRssAppTests",
            dependencies: ["PaperRssUpdateSupport", "PaperRssDesktop", "PaperRssCore"],
            path: "AppTests"
        )
    ]
)
