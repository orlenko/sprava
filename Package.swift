// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sprava",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SpravaCore", targets: ["SpravaCore"]),
        .executable(name: "sprava", targets: ["sprava"]),
        .executable(name: "SpravaApp", targets: ["SpravaApp"]),
        .executable(name: "sprava-runtime", targets: ["sprava-runtime"]),
        .executable(name: "sprava-mcp", targets: ["sprava-mcp"]),
    ],
    targets: [
        .target(name: "SpravaCore"),
        .executableTarget(name: "sprava", dependencies: ["SpravaCore"]),
        .executableTarget(name: "SpravaApp", dependencies: ["SpravaCore"]),
        .executableTarget(name: "sprava-runtime", dependencies: ["SpravaCore"]),
        .executableTarget(name: "sprava-mcp", dependencies: ["SpravaCore"]),
        .testTarget(
            name: "SpravaCoreTests",
            dependencies: ["SpravaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
