// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperRss",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaperRssCore", targets: ["PaperRssCore"]),
        .executable(name: "PaperRssDesktop", targets: ["PaperRssDesktop"])
    ],
    targets: [
        .target(name: "PaperRssCore", path: "PaperRss/Sources/Core"),
        .executableTarget(
            name: "PaperRssDesktop",
            dependencies: ["PaperRssCore"],
            path: "PaperRss/Sources/App",
            resources: [.process("../../Resources")]
        ),
        .testTarget(name: "PaperRssCoreTests", dependencies: ["PaperRssCore"], path: "Tests")
    ]
)
