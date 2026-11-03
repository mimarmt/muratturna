// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoopnoteCore",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "LoopnoteCore", targets: ["LoopnoteCore"])
    ],
    targets: [
        .target(name: "LoopnoteCore"),
        .testTarget(name: "LoopnoteCoreTests", dependencies: ["LoopnoteCore"])
    ]
)
