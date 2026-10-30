// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HephaestusKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HephUI", targets: ["HephUI"]),
        .library(name: "HephHost", targets: ["HephHost"]),
        .library(name: "HephCore", targets: ["HephCore"]),
        .library(name: "HephNet", targets: ["HephNet"]),
        .library(name: "HephClient", targets: ["HephClient"]),
        .library(name: "HephEditor", targets: ["HephEditor"]),
        .library(name: "HephMarkdown", targets: ["HephMarkdown"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "HephCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .target(name: "HephNet", dependencies: ["HephCore"]),
        .target(name: "HephHost", dependencies: ["HephCore", "HephNet"]),
        .target(name: "HephClient", dependencies: ["HephCore", "HephNet"]),
        .target(name: "HephEditor", dependencies: ["HephCore"]),
        .target(
            name: "HephMarkdown",
            dependencies: ["HephCore", "HephEditor", .product(name: "Markdown", package: "swift-markdown")]
        ),
        .target(
            name: "HephUI",
            dependencies: ["HephCore", "HephNet", "HephHost", "HephClient", "HephEditor", "HephMarkdown"]
        ),
        .testTarget(name: "HephCoreTests", dependencies: ["HephCore"]),
        .testTarget(name: "HephNetTests", dependencies: ["HephNet", "HephCore"]),
        .testTarget(
            name: "HephHostTests",
            dependencies: ["HephHost", "HephClient", "HephNet", "HephCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HephEditorTests", dependencies: ["HephEditor", "HephCore"]),
        .testTarget(name: "HephClientTests", dependencies: ["HephClient", "HephNet", "HephCore"]),
        .testTarget(name: "HephUISnapshotTests", dependencies: ["HephUI", "HephHost", "HephClient", "HephCore"]),
    ],
    swiftLanguageModes: [.v5]
)
