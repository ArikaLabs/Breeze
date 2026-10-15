// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Breeze",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MideaKit", targets: ["MideaKit"]),
        .executable(name: "Breeze", targets: ["Breeze"]),
        .executable(name: "midea-cli", targets: ["MideaCLI"]),
    ],
    targets: [
        .target(name: "MideaKit", path: "Sources/MideaKit"),
        .executableTarget(name: "MideaCLI", dependencies: ["MideaKit"], path: "Sources/MideaCLI"),
        .executableTarget(name: "Breeze", dependencies: ["MideaKit"], path: "Sources/Breeze"),
        .testTarget(name: "MideaKitTests", dependencies: ["MideaKit"], path: "Tests/MideaKitTests",
                    resources: [.copy("vectors.json")]),
    ]
)
