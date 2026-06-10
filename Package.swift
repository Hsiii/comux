// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "comux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "comux", targets: ["Comux"])
    ],
    targets: [
        .executableTarget(
            name: "Comux",
            path: "src",
            sources: [
                "App.swift",
                "Model.swift",
                "AccountIdentity.swift",
                "AccountSnapshotMerger.swift",
                "UsagePayloadParser.swift",
                "WorkspaceLabelResolver.swift",
                "SystemRefreshErrorPolicy.swift",
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
            name: "ComuxTests",
            dependencies: ["Comux"]
        )
    ]
)
