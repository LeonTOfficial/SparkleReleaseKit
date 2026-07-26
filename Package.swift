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
        .target(
            name: "SparkleReleaseKitCLISupport",
            dependencies: ["SparkleReleaseKitCore"]
        ),
        .executableTarget(
            name: "SparkleReleaseKitCLI",
            dependencies: ["SparkleReleaseKitCore", "SparkleReleaseKitCLISupport"]
        ),
        .testTarget(
            name: "SparkleReleaseKitCoreTests",
            dependencies: ["SparkleReleaseKitCore", "SparkleReleaseKitCLISupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
