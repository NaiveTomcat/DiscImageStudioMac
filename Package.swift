// swift-tools-version: 6.0
import PackageDescription

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
        // Shared, medium-agnostic model. Owned by the lead; no media encoding here.
        .target(name: "DiscImageCore"),

        // One target per medium so parallel work never blocks another medium's build.
        .target(name: "DiscImageDvd", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageCd", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageBluRay", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageBurning", dependencies: ["DiscImageCore"]),

        // SwiftUI shell.
        .target(
            name: "DiscImageUI",
            dependencies: ["DiscImageCore", "DiscImageDvd", "DiscImageCd", "DiscImageBluRay", "DiscImageBurning", "DiscImageCLI"]
        ),

        .executableTarget(name: "DiscImageCLI", dependencies: ["DiscImageCore", "DiscImageDvd", "DiscImageCd", "DiscImageBluRay"]),
        .executableTarget(name: "DiscImageStudioApp", dependencies: ["DiscImageUI", "DiscImageCore"]),

        .testTarget(name: "DiscImageCoreTests", dependencies: ["DiscImageCore"]),
        .testTarget(name: "DiscImageDvdTests", dependencies: ["DiscImageDvd", "DiscImageCore"]),
        .testTarget(name: "DiscImageCdTests", dependencies: ["DiscImageCd", "DiscImageCore"]),
        .testTarget(name: "DiscImageBluRayTests", dependencies: ["DiscImageBluRay", "DiscImageCore"]),
        .testTarget(name: "DiscImageUITests", dependencies: ["DiscImageUI", "DiscImageCore"]),
    ],
    swiftLanguageModes: [.v5]
)
