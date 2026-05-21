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
                "Path.swift",
                "Store.swift",
                "Pulse.swift",
                "Format.swift",
                "Card.swift",
                "Manage.swift",
                "Menu.swift",
                "Resources.swift",
            ],
            resources: [
                .process("../assets")
            ]
        )
    ]
)
