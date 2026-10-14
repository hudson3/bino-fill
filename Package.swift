// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bino",
    // The Voice tool needs the on-device transcriber that arrived in macOS 26; the rest runs on macOS 15.
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .executable(name: "bino", targets: ["bino"]),
        .library(name: "BinoCore", targets: ["BinoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "BinoCore"),
        .executableTarget(
            name: "bino",
            dependencies: [
                "BinoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BinoCoreTests", dependencies: ["BinoCore"]),
    ],
    swiftLanguageModes: [.v5]
)
