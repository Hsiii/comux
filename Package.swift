// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexMux", targets: ["CodexMux"])
    ],
    targets: [
        .executableTarget(
            name: "CodexMux",
            path: "src",
            sources: [
                "App.swift",
                "Model.swift",
                "AccountIdentity.swift",
                "AccountSnapshotMerger.swift",
                "UsagePayloadParser.swift",
                "Path.swift",
                "Persistence.swift",
                "Store.swift",
                "Pulse.swift",
                "Format.swift",
                "Card.swift",
                "Menu.swift",
                "LaunchAtLogin.swift",
                "Resources.swift",
            ],
            resources: [
                .process("../assets")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodexMuxTests",
            dependencies: ["CodexMux"]
        )
    ]
)
