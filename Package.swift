// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SparkleReleaseKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SparkleReleaseKitCore", targets: ["SparkleReleaseKitCore"]),
        .executable(name: "sparklekit", targets: ["SparkleReleaseKitCLI"]),
    ],
    targets: [
        .target(
            name: "SparkleReleaseKitCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "SparkleReleaseKitCLI",
            dependencies: ["SparkleReleaseKitCore"]
        ),
        .testTarget(
            name: "SparkleReleaseKitCoreTests",
            dependencies: ["SparkleReleaseKitCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
