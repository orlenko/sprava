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
        .executable(name: "sprava-extract", targets: ["sprava-extract"]),
    ],
    targets: [
        .target(name: "SpravaCore"),
        .executableTarget(name: "sprava", dependencies: ["SpravaCore"]),
        .executableTarget(name: "SpravaApp", dependencies: ["SpravaCore"]),
        .executableTarget(name: "sprava-runtime", dependencies: ["SpravaCore"]),
        .executableTarget(name: "sprava-mcp", dependencies: ["SpravaCore"]),
        // A sandboxed command-line tool needs an embedded Info.plist, or the sandbox stops it at launch.
        .executableTarget(name: "sprava-extract", dependencies: ["SpravaCore"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                                         "-Xlinker", "Resources/sprava-extract-Info.plist"])]),
        .testTarget(
            name: "SpravaCoreTests",
            dependencies: ["SpravaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
