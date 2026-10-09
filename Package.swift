// swift-tools-version: 6.2
import PackageDescription

// The targets and their layers: docs/code-structure.md. A target depends only on targets in lower layers.
let package = Package(
    name: "Sprava",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "sprava", targets: ["sprava"]),
        .executable(name: "sprava-runtime", targets: ["sprava-runtime"]),
        .executable(name: "sprava-extract", targets: ["sprava-extract"]),
        .executable(name: "sprava-mcp", targets: ["sprava-mcp"]),
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
        .target(name: "Clerk", dependencies: ["Extract", "Shelf", "BinderStore", "BinderFormat", "SpravaKit"]),
        .testTarget(name: "ClerkTests", dependencies: ["Clerk", "ClerkTestSupport", "Extract", "SpravaTestSupport", "SpravaKit"]),
        .target(name: "ClerkTestSupport", dependencies: ["Clerk", "SpravaKit"], path: "Tests/ClerkTestSupport"),

        // Layer 4: capture, the hub lane, backup, brains.
        .target(name: "Capture", dependencies: ["Clerk", "Extract", "Shelf", "BinderStore", "BinderFormat", "SpravaKit"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "CaptureTestSupport", "ClerkTestSupport", "Clerk", "Extract",
                                                         "Shelf", "BinderStore", "BinderFormat", "SpravaTestSupport", "SpravaKit"]),
        .target(name: "CaptureTestSupport", dependencies: ["Capture", "BinderStore", "SpravaKit"],
                path: "Tests/CaptureTestSupport"),
        .target(name: "Hub", dependencies: ["Shelf", "BinderStore", "BinderFormat", "SpravaKit"]),
        .testTarget(name: "HubTests", dependencies: ["Hub", "Shelf", "BinderStore", "BinderFormat", "SpravaTestSupport",
                                                     "SpravaKit"]),
        .target(name: "Backup", dependencies: ["Hub", "Shelf", "BinderStore", "BinderFormat", "SpravaKit"]),
        .testTarget(name: "BackupTests", dependencies: ["Backup", "Hub", "Shelf", "BinderStore", "BinderFormat",
                                                        "SpravaTestSupport", "SpravaKit"]),
        .target(name: "Brains", dependencies: ["Capture", "Shelf", "BinderStore", "BinderFormat", "SpravaKit"]),
        .testTarget(name: "BrainsTests", dependencies: ["Brains", "CaptureTestSupport", "Capture", "Extract", "Shelf",
                                                        "BinderStore", "BinderFormat", "SpravaTestSupport", "SpravaKit"]),

        // Layer 5: the command layer and what reads across areas.
        .target(name: "Services", dependencies: ["Brains", "Backup", "Hub", "Capture", "Shelf", "BinderStore", "BinderFormat",
                                                 "SpravaKit"]),
        .testTarget(name: "ServicesTests", dependencies: ["Services", "Brains", "Backup", "CaptureTestSupport", "Capture",
                                                          "ClerkTestSupport", "Clerk", "Extract", "Shelf", "BinderStore",
                                                          "BinderFormat", "SpravaTestSupport", "SpravaKit"]),

        // Layer 6: executables.
        .executableTarget(name: "sprava", dependencies: ["Services", "Brains", "Hub", "Capture", "Clerk", "Extract", "Shelf",
                                                         "BinderStore", "BinderFormat", "SpravaKit"]),
        .executableTarget(name: "sprava-runtime", dependencies: ["Services", "Brains", "Backup", "Hub", "Capture", "Clerk",
                                                                 "Extract", "Shelf", "BinderStore", "BinderFormat", "SpravaKit"]),
        .executableTarget(name: "sprava-mcp", dependencies: ["Brains", "SpravaKit"]),
        // A sandboxed command-line tool needs an embedded Info.plist, or the sandbox stops it at launch.
        .executableTarget(name: "sprava-extract", dependencies: ["Extract", "SpravaKit"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                                         "-Xlinker", "Resources/sprava-extract-Info.plist"])]),
    ]
)
