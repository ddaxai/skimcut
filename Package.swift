// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkimCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkimCore", targets: ["SkimCore"]),
        .executable(name: "skimcut", targets: ["skimcut"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // 跨平台核心逻辑，只依赖 Foundation。
        .target(name: "SkimCore"),
        // 跨平台命令行工具。
        .executableTarget(
            name: "skimcut",
            dependencies: [
                "SkimCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SkimCoreTests", dependencies: ["SkimCore"]),
    ]
)

// SwiftUI / AppKit 界面只在 macOS 上加入；Linux 上的 SwiftPM 看不到这个 target。
#if os(macOS)
package.targets.append(
    .executableTarget(name: "SkimCutApp", dependencies: ["SkimCore"])
)
package.products.append(
    .executable(name: "SkimCutApp", targets: ["SkimCutApp"])
)
#endif
