// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperRss",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaperRssCore", targets: ["PaperRssCore"]),
        .executable(name: "PaperRssDesktop", targets: ["PaperRssDesktop"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: [
        .target(
            name: "PaperRssCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "PaperRss/Sources/Core",
            resources: [.process("../../Resources/Localization/Localizable.xcstrings")]
        ),
        .executableTarget(
            name: "PaperRssDesktop",
            dependencies: ["PaperRssCore"],
            path: "PaperRss/Sources/App",
            exclude: ["../../Resources/iOS-Info.plist", "../../Resources/macOS-Info.plist", "../../Resources/PaperRss.entitlements.template"],
            resources: [
                .process("../../Resources/Assets.xcassets"),
                .process("../../Resources/Localization/Localizable.xcstrings"),
                .copy("../../Resources/MathJax")
            ]
        ),
        .testTarget(
            name: "PaperRssCoreTests",
            dependencies: [
                "PaperRssCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            exclude: [
                "mathjax-runtime.test.mjs",
                "reader-shortcuts.test.mjs",
                "reader-toc.test.mjs",
                "repository-policy.test.mjs",
                "selection-assistant-sync.test.mjs",
                "summary-card.test.mjs",
                "website-github-stars.test.mjs",
                "website-locale.test.mjs"
            ]
        )
    ]
)
