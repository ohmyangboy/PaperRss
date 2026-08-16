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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(
            name: "PaperRssCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "PaperRss/Sources/Core"
        ),
        .executableTarget(
            name: "PaperRssDesktop",
            dependencies: ["PaperRssCore"],
            path: "PaperRss/Sources/App"
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
                "website-locale.test.mjs"
            ]
        )
    ]
)
