// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipBox",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClipBoxCore", targets: ["ClipBoxCore"]),
        .executable(name: "clipbox", targets: ["ClipBoxCLI"]),
        .executable(name: "ClipBoxApp", targets: ["ClipBoxApp"])
    ],
    targets: [
        .target(name: "ClipBoxCore"),
        .executableTarget(
            name: "ClipBoxCLI",
            dependencies: ["ClipBoxCore"]
        ),
        .executableTarget(
            name: "ClipBoxApp",
            dependencies: ["ClipBoxCore"]
        ),
        .testTarget(
            name: "ClipBoxCoreTests",
            dependencies: ["ClipBoxCore"]
        )
    ]
)
