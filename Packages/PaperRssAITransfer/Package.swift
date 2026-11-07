// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperRssAITransfer",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [.library(name: "PaperRssAITransfer", targets: ["PaperRssAITransfer"])],
    targets: [
        .target(name: "PaperRssAITransfer"),
        .testTarget(name: "PaperRssAITransferTests", dependencies: ["PaperRssAITransfer"])
    ]
)
