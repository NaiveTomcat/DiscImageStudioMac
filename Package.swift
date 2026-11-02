// swift-tools-version: 6.0
import PackageDescription

// 架构约定见 HANDOFF.md §4：
// - 每种介质一个独立 target，避免并行开发互相阻塞编译；
// - Swift 6 编译器 + Swift 5 语言模式（不升级到 .v6）；
// - DiscImageCore 不依赖 SwiftUI/AppKit。
//
// 相对 HANDOFF §4.3 的两处必要修正（SwiftPM 硬性要求所致，见 docs/ARCHITECTURE.md）：
// 1. `DiscImageUI` 不再依赖 `DiscImageCLI`——SwiftPM 不允许 library target 依赖
//    executable target；UI 直接依赖三介质引擎 + 刻录封装，符合「UI 单向依赖引擎」。
// 2. `DiscImageCd` 依赖 `DiscImageDvd`——CD 数据盘模式复用工作包 A 的 ISO9660 写入器
//    （HANDOFF §6.B 明确要求），只能靠 target 依赖表达。
let package = Package(
    name: "DiscImageStudioMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiscImageStudio", targets: ["DiscImageStudioApp"]),
        .executable(name: "discimage-cli", targets: ["DiscImageCLI"]),
        .library(name: "DiscImageCore", targets: ["DiscImageCore"]),
        .library(name: "DiscImageDvd", targets: ["DiscImageDvd"]),
        .library(name: "DiscImageCd", targets: ["DiscImageCd"]),
        .library(name: "DiscImageBluRay", targets: ["DiscImageBluRay"]),
        .library(name: "DiscImageBurning", targets: ["DiscImageBurning"]),
        .library(name: "DiscImageUI", targets: ["DiscImageUI"]),
    ],
    targets: [
        // 共享、与介质无关的模型。由 lead 独占。
        .target(name: "DiscImageCore"),

        // 每种介质一个 target。
        .target(name: "DiscImageDvd", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageCd", dependencies: ["DiscImageCore", "DiscImageDvd"]),
        .target(name: "DiscImageBluRay", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageBurning", dependencies: ["DiscImageCore"]),

        // SwiftUI 外壳：单向依赖引擎与刻录封装。
        .target(
            name: "DiscImageUI",
            dependencies: ["DiscImageCore", "DiscImageDvd", "DiscImageCd", "DiscImageBluRay", "DiscImageBurning"]
        ),

        .executableTarget(name: "DiscImageCLI", dependencies: ["DiscImageCore", "DiscImageDvd", "DiscImageCd", "DiscImageBluRay"]),
        .executableTarget(name: "DiscImageStudioApp", dependencies: ["DiscImageUI", "DiscImageCore"]),

        .testTarget(name: "DiscImageCoreTests", dependencies: ["DiscImageCore"]),
        .testTarget(name: "DiscImageDvdTests", dependencies: ["DiscImageDvd", "DiscImageCore"]),
        .testTarget(name: "DiscImageCdTests", dependencies: ["DiscImageCd", "DiscImageCore"]),
        .testTarget(name: "DiscImageBluRayTests", dependencies: ["DiscImageBluRay", "DiscImageCore"]),
        .testTarget(name: "DiscImageUITests", dependencies: ["DiscImageUI", "DiscImageCore"]),
        .testTarget(name: "DiscImageBurningTests", dependencies: ["DiscImageBurning", "DiscImageCore"]),
    ],
    swiftLanguageModes: [.v5]
)
