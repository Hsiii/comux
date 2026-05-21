// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexBoardPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexBoardPulse", targets: ["CodexBoardPulse"])
    ],
    targets: [
        .executableTarget(
            name: "CodexBoardPulse",
            path: ".",
            exclude: ["README.md", ".gitignore"],
            sources: ["main.swift"]
        )
    ]
)
