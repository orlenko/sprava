// swift-tools-version: 6.2
import PackageDescription

// The targets and their layers: docs/code-structure.md. A target depends only on targets in lower layers.
let package = Package(
    name: "Sprava",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "sprava-extract", targets: ["sprava-extract"]),
    ],
    targets: [
        // Layer 0: JSON, atomic files, state files, dates, ids, paths.
        .target(name: "SpravaKit"),
        .testTarget(name: "SpravaKitTests", dependencies: ["SpravaKit", "SpravaTestSupport"]),
        // The invented fixtures and helpers several test targets share.
        .target(name: "SpravaTestSupport", dependencies: ["SpravaKit"],
                path: "Tests/SpravaTestSupport", resources: [.copy("Fixtures")]),

        // Layer 1: reading a binder.
        .target(name: "BinderFormat", dependencies: ["SpravaKit"]),
        .testTarget(name: "BinderFormatTests", dependencies: ["BinderFormat", "SpravaTestSupport", "SpravaKit"]),

        // Layer 2: writing a binder.
        .target(name: "BinderStore", dependencies: ["BinderFormat", "SpravaKit"]),
        .testTarget(name: "BinderStoreTests", dependencies: ["BinderStore", "BinderFormat", "SpravaTestSupport", "SpravaKit"]),

        // Layer 3: which binders exist here; reading files; the clerk.
        .target(name: "Shelf", dependencies: ["BinderStore", "BinderFormat", "SpravaKit"]),
        .testTarget(name: "ShelfTests", dependencies: ["Shelf", "SpravaTestSupport"]),
        .target(name: "Extract", dependencies: ["BinderFormat", "SpravaKit"]),
        .testTarget(name: "ExtractTests", dependencies: ["Extract", "BinderFormat"]),

        // Layer 6: executables.
        // A sandboxed command-line tool needs an embedded Info.plist, or the sandbox stops it at launch.
        .executableTarget(name: "sprava-extract", dependencies: ["Extract", "SpravaKit"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                                         "-Xlinker", "Resources/sprava-extract-Info.plist"])]),
    ]
)
