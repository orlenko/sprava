// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sprava",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SpravaCore", targets: ["SpravaCore"]),
        .executable(name: "sprava", targets: ["sprava"]),
    ],
    targets: [
        .target(name: "SpravaCore"),
        .executableTarget(name: "sprava", dependencies: ["SpravaCore"]),
        .testTarget(
            name: "SpravaCoreTests",
            dependencies: ["SpravaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
