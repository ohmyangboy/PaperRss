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
            resources: [.process("../../Resources")]
        ),
        .testTarget(
            name: "PaperRssCoreTests",
            dependencies: [
                "PaperRssCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests",
            exclude: [
                "reader-shortcuts.test.mjs",
                "reader-toc.test.mjs",
                "repository-policy.test.mjs",
                "selection-assistant-sync.test.mjs",
                "website-github-stars.test.mjs",
                "website-locale.test.mjs"
            ]
        )
    ]
)
